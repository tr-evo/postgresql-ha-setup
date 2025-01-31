#!/bin/bash

# PostgreSQL High-Availability Cluster Setup Script
# Features:
# - 1 primary node with configurable number of read replicas
# - PgBouncer connection pooling
# - HAProxy load balancing with health checks
# - Automated backup configuration
# - Monitoring setup
# - Performance tuning

# Exit on any error and enable debug mode
set -euo pipefail
[ "${DEBUG:-0}" = "1" ] && set -x

###################
# Configuration
###################
# Network configuration
PRIMARY_IP="${PRIMARY_IP:-192.168.1.10}"
REPLICA_IPS="${REPLICA_IPS:-192.168.1.11,192.168.1.12}"  # Comma-separated list
NETWORK_SUBNET="${NETWORK_SUBNET:-192.168.1.0/24}"

# PostgreSQL configuration
PG_VERSION="${PG_VERSION:-15}"
PG_USER="${PG_USER:-postgres}"
PG_PASSWORD="${PG_PASSWORD:-$(openssl rand -base64 32)}"
REPLICATION_USER="${REPLICATION_USER:-replicator}"
REPLICATION_PASSWORD="${REPLICATION_PASSWORD:-$(openssl rand -base64 32)}"
INSTANCE_NAME="${INSTANCE_NAME:-main}"
PG_DATA="/var/lib/postgresql/$PG_VERSION/$INSTANCE_NAME"
PG_PORT="${PG_PORT:-5432}"
PGBOUNCER_PORT="${PGBOUNCER_PORT:-6432}"
PG_CONF="$PG_DATA/postgresql.conf"
PG_HBA="$PG_DATA/pg_hba.conf"
BACKUP_DIR="${BACKUP_DIR:-/var/lib/postgresql/backups}"

# System configuration
TOTAL_MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEMORY_MB=$((TOTAL_MEMORY_KB / 1024))
SHARED_BUFFERS=$((TOTAL_MEMORY_MB / 4))"MB"  # 25% of total RAM
EFFECTIVE_CACHE_SIZE=$((TOTAL_MEMORY_MB * 3 / 4))"MB"  # 75% of total RAM
MAINTENANCE_WORK_MEM=$((TOTAL_MEMORY_MB / 16))"MB"  # 6.25% of total RAM
MAX_CONNECTIONS="${MAX_CONNECTIONS:-200}"

###################
# Helper Functions
###################
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $@"
}

error() {
    log "ERROR: $@" >&2
    exit 1
}

cleanup() {
    if [ $? -ne 0 ]; then
        log "Installation failed. Check logs for details."
        # Attempt to stop services in case of failure
        systemctl stop postgresql pgbouncer haproxy pg_healthcheck 2>/dev/null || true
    fi
}

# Add trap for cleanup
trap cleanup EXIT

check_prerequisites() {
    # Check for required commands
    for cmd in wget curl systemctl openssl lsb-release gpg; do
        command -v $cmd >/dev/null 2>&1 || error "Required command $cmd not found"
    done
    
    # Check system requirements
    [ $(free -g | awk '/^Mem:/{print $2}') -lt 4 ] && error "Minimum 4GB RAM required"
    [ $(nproc) -lt 2 ] && error "Minimum 2 CPU cores required"
    
    # Check if ports are available
    for port in $PG_PORT $PGBOUNCER_PORT 8008 7000; do
        if netstat -tuln | grep -q ":$port "; then
            error "Port $port is already in use"
        fi
    done
}

system_tuning() {
    log "Configuring system parameters..."
    
    # Calculate optimal values based on total memory and CPU
    local TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
    local CPU_CORES=$(nproc)
    
    # Adjust values based on available resources
    local MAX_SHM=$((TOTAL_MEM_KB * 1024))
    local TCP_BACKLOG=$((CPU_CORES * 1024))
    local VM_OVERCOMMIT_RATIO=85  # More conservative default
    
    # For systems with less than 8GB RAM, adjust overcommit settings
    if [ $TOTAL_MEM_GB -lt 8 ]; then
        VM_OVERCOMMIT_RATIO=70
        log "Small memory system detected ($TOTAL_MEM_GB GB) - using conservative memory settings"
    fi
    
    # For systems with more than 32GB RAM, adjust TCP settings
    if [ $TOTAL_MEM_GB -gt 32 ]; then
        TCP_BACKLOG=$((CPU_CORES * 4096))
    fi
    
    cat > /etc/sysctl.d/99-postgresql.conf << EOF
# PostgreSQL specific settings
kernel.shmmax = $MAX_SHM
kernel.shmall = $((MAX_SHM / 4096))
vm.swappiness = 1
vm.zone_reclaim_mode = 0
vm.overcommit_memory = 2
vm.overcommit_ratio = $VM_OVERCOMMIT_RATIO
vm.dirty_ratio = 30
vm.dirty_background_ratio = 10

# Network settings scaled by CPU cores
net.core.somaxconn = $((CPU_CORES * 1024))
net.ipv4.tcp_max_syn_backlog = $TCP_BACKLOG
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_tw_buckets = $((CPU_CORES * 2000))

# File system and I/O settings
fs.file-max = $((TOTAL_MEM_GB * 256 * 1024))
fs.aio-max-nr = $((TOTAL_MEM_GB * 128 * 1024))
EOF
    
    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-postgresql.conf || log "Warning: Some sysctl parameters might not be supported on this system"

    # Configure huge pages if available and system has enough memory
    if [ -d /sys/kernel/mm/transparent_hugepage ] && [ $TOTAL_MEM_GB -ge 8 ]; then
        log "Configuring huge pages for systems with ${TOTAL_MEM_GB}GB RAM"
        
        # Calculate huge pages - use about 75% of shared_buffers worth
        local HUGE_PAGE_SIZE_KB=$(grep Hugepagesize /proc/meminfo | awk '{print $2}')
        local SHARED_BUFFER_KB=$((TOTAL_MEM_KB / 4))  # 25% of RAM
        local NR_HUGE_PAGES=$(((SHARED_BUFFER_KB * 75 / 100) / HUGE_PAGE_SIZE_KB))
        
        # Don't set huge pages if the calculation resulted in 0
        if [ $NR_HUGE_PAGES -gt 0 ]; then
            echo $NR_HUGE_PAGES > /proc/sys/vm/nr_hugepages
            
            # Add to sysctl for persistence
            echo "vm.nr_hugepages = $NR_HUGE_PAGES" >> /etc/sysctl.d/99-postgresql.conf
            sysctl -p /etc/sysctl.d/99-postgresql.conf
            
            log "Configured system to use $NR_HUGE_PAGES huge pages"
        else
            log "Skipping huge pages configuration due to insufficient memory"
        fi
        
        # Disable transparent huge pages
        echo never > /sys/kernel/mm/transparent_hugepage/enabled
        echo never > /sys/kernel/mm/transparent_hugepage/defrag
    else
        log "Skipping huge pages configuration (either not supported or system has insufficient memory)"
    fi
    
    # Warn about potential issues
    if [ $TOTAL_MEM_GB -lt 4 ]; then
        log "Warning: System has less than 4GB RAM. Performance may be severely impacted."
    fi
    
    if [ $CPU_CORES -lt 2 ]; then
        log "Warning: System has only 1 CPU core. Performance may be limited."
    fi
}

wait_for_postgres() {
    local max_attempts=30
    local attempt=1
    local port=${1:-5432}
    
    log "Waiting for PostgreSQL to be ready on port $port..."
    while [ $attempt -le $max_attempts ]; do
        if PGPASSWORD=$PG_PASSWORD psql -h localhost -p $port -U $PG_USER -d postgres -c "SELECT 1" >/dev/null 2>&1; then
            log "PostgreSQL is ready on port $port"
            return 0
        fi
        log "Attempt $attempt/$max_attempts: PostgreSQL not ready yet..."
        sleep 2
        attempt=$((attempt + 1))
    done
    error "PostgreSQL failed to start on port $port after $max_attempts attempts"
}

install_postgresql() {
    log "Installing PostgreSQL $PG_VERSION..."
    
    # Add PostgreSQL repository
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/postgresql-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
    
    apt-get update
    apt-get install -y postgresql-$PG_VERSION postgresql-contrib postgresql-$PG_VERSION-repack
    systemctl stop postgresql
}

install_monitoring_tools() {
    log "Installing monitoring tools..."
    apt-get install -y prometheus-node-exporter postgresql-$PG_VERSION-prometheus-exporter pgbadger
    
    # Configure pg_stat_statements
    echo "shared_preload_libraries = 'pg_stat_statements'" >> $PG_CONF
    echo "pg_stat_statements.track = all" >> $PG_CONF
}

install_pgbouncer() {
    log "Installing PgBouncer..."
    apt-get install -y pgbouncer
    
    cat > /etc/pgbouncer/pgbouncer.ini << EOF
auth_query = SELECT usename, passwd FROM pg_shadow WHERE usename=$1
ignore_startup_parameters = extra_float_digits   

[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_port = 6432
listen_addr = *
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 2000
default_pool_size = 50
min_pool_size = 10
reserve_pool_size = 25
reserve_pool_timeout = 5
max_db_connections = 100
max_user_connections = 100
server_reset_query = DISCARD ALL
server_check_delay = 30
server_check_query = select 1
server_fast_close = 0
tcp_keepalive = 1
tcp_keepidle = 5
tcp_keepintvl = 1
EOF

    echo "\"$PG_USER\" \"$PG_PASSWORD\"" > /etc/pgbouncer/userlist.txt
    chown postgres:postgres /etc/pgbouncer/userlist.txt
    chmod 600 /etc/pgbouncer/userlist.txt
}

install_haproxy() {
    log "Installing HAProxy..."
    apt-get install -y haproxy
    
    # Generate more sophisticated HAProxy configuration
    cat > /etc/haproxy/haproxy.cfg << EOF
global
    maxconn 4096
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http
    errorfile 502 /etc/haproxy/errors/502.http
    errorfile 503 /etc/haproxy/errors/503.http
    errorfile 504 /etc/haproxy/errors/504.http

# Stats page
frontend stats
    bind *:7000
    mode http
    stats enable
    stats uri /
    stats refresh 10s
    stats admin if LOCALHOST

# Primary node for write operations
frontend postgres_write
    bind *:5000
    mode tcp
    option tcplog
    default_backend primary_backend

backend primary_backend
    mode tcp
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server primary $PRIMARY_IP:6432 check port 8008 weight 1

# Read replicas for read operations
frontend postgres_read
    bind *:5001
    mode tcp
    option tcplog
    default_backend replicas_backend

backend replicas_backend
    mode tcp
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
EOF

    # Add replica servers to HAProxy config
    IFS=',' read -ra REPLICA_ARRAY <<< "$REPLICA_IPS"
    for i in "${!REPLICA_ARRAY[@]}"; do
        echo "    server replica$((i+1)) ${REPLICA_ARRAY[i]}:6432 check port 8008 weight 1" >> /etc/haproxy/haproxy.cfg
    done

    systemctl restart haproxy
}

configure_postgresql_primary() {
    log "Configuring PostgreSQL primary node..."
    
    # Create WAL archive directory
    mkdir -p /var/lib/postgresql/archive
    chown postgres:postgres /var/lib/postgresql/archive
    chmod 700 /var/lib/postgresql/archive
    
    # Performance tuning
    cat > $PG_CONF << EOF
# Connection Settings
listen_addresses = '*'
max_connections = $MAX_CONNECTIONS
superuser_reserved_connections = 3

# Memory Settings
shared_buffers = $SHARED_BUFFERS
effective_cache_size = $EFFECTIVE_CACHE_SIZE
maintenance_work_mem = $MAINTENANCE_WORK_MEM
work_mem = 32MB
huge_pages = try

# Replication Settings
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 2GB
hot_standby = on
synchronous_commit = on

# WAL Archiving
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/archive/%f && cp %p /var/lib/postgresql/archive/%f'
archive_timeout = 60

# Checkpointing
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9
max_wal_size = 2GB
min_wal_size = 1GB

# Query Planning
random_page_cost = 1.1
effective_io_concurrency = 200
default_statistics_target = 100

# Autovacuum
autovacuum = on
autovacuum_max_workers = 4
autovacuum_naptime = 1min
autovacuum_vacuum_threshold = 50
autovacuum_analyze_threshold = 50
autovacuum_vacuum_scale_factor = 0.02
autovacuum_analyze_scale_factor = 0.01

# Logging
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 250ms
EOF

    # Configure access control
    cat > $PG_HBA << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all            postgres                                peer
local   all            all                                     md5
host    all            all             127.0.0.1/32           md5
host    all            all             ::1/128                md5
host    replication    $REPLICATION_USER  $NETWORK_SUBNET     md5
host    all            all             $NETWORK_SUBNET        md5
EOF

    # Create replication user
    su - postgres -c "psql -c \"CREATE USER $REPLICATION_USER REPLICATION LOGIN ENCRYPTED PASSWORD '$REPLICATION_PASSWORD';\""
    
    # Create replication slots for each replica
    IFS=',' read -ra REPLICA_ARRAY <<< "$REPLICA_IPS"
    for i in "${!REPLICA_ARRAY[@]}"; do
        su - postgres -c "psql -c \"SELECT pg_create_physical_replication_slot('replica${i+1}_slot');\""
    done
}

configure_postgresql_replica() {
    local REPLICA_NUM=$1
    local SLOT_NAME="replica${REPLICA_NUM}_slot"
    local PORT="$PG_PORT"
    
    # If running on the same server as primary, adjust ports
    if [ "$PRIMARY_IP" = "127.0.0.1" ] || [ "$PRIMARY_IP" = "localhost" ]; then
        PORT=$((5432 + REPLICA_NUM))
        PGBOUNCER_PORT=$((6432 + REPLICA_NUM))
        INSTANCE_NAME="replica$REPLICA_NUM"
        PG_DATA="/var/lib/postgresql/$PG_VERSION/$INSTANCE_NAME"
        
        # Create new systemd service for this instance
        cat > /etc/systemd/system/postgresql-$INSTANCE_NAME.service << EOF
[Unit]
Description=PostgreSQL Replica $REPLICA_NUM Database Server
Documentation=man:postgres(1)
After=network.target

[Service]
Type=simple
User=postgres
Environment=DATA_DIR=$PG_DATA
Environment=PGPORT=$PORT
ExecStart=/usr/lib/postgresql/$PG_VERSION/bin/postgres -D \${DATA_DIR}
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=mixed
KillSignal=SIGINT
TimeoutSec=0

[Install]
WantedBy=multi-user.target
EOF

        # Create new pgbouncer config for this instance
        cat > /etc/pgbouncer/pgbouncer-$INSTANCE_NAME.ini << EOF
[databases]
* = host=127.0.0.1 port=$PORT

[pgbouncer]
listen_port = $PGBOUNCER_PORT
listen_addr = *
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 20
EOF

        # Create new systemd service for pgbouncer instance
        cat > /etc/systemd/system/pgbouncer-$INSTANCE_NAME.service << EOF
[Unit]
Description=PgBouncer connection pooler for replica $REPLICA_NUM
Documentation=man:pgbouncer(1)
After=network.target

[Service]
Type=simple
User=postgres
ExecStart=/usr/sbin/pgbouncer /etc/pgbouncer/pgbouncer-$INSTANCE_NAME.ini
ExecReload=/bin/kill -HUP \$MAINPID
PIDFile=/run/postgresql/pgbouncer-$INSTANCE_NAME.pid

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
    fi
    
    log "Configuring PostgreSQL replica $REPLICA_NUM..."
    
    # Stop PostgreSQL and clear data directory
    systemctl stop postgresql
    rm -rf $PG_DATA/*
    
    # Create base backup
    su - postgres -c "pg_basebackup -h $PRIMARY_IP -U $REPLICATION_USER -p 5432 -D $PG_DATA -Fp -Xs -P -R \
        -C -S $SLOT_NAME \
        --write-recovery-conf"
    
    # Additional replica-specific configuration
    cat >> $PG_CONF << EOF
hot_standby = on
primary_conninfo = 'host=$PRIMARY_IP port=5432 user=$REPLICATION_USER password=$REPLICATION_PASSWORD application_name=replica$REPLICA_NUM'
primary_slot_name = '$SLOT_NAME'
recovery_target_timeline = 'latest'
promote_trigger_file = '/tmp/promote_trigger'
hot_standby_feedback = on
max_standby_streaming_delay = 30s
wal_receiver_status_interval = 1s
max_standby_archive_delay = 300s
EOF

    # Create recovery signal file
    touch $PG_DATA/standby.signal
    chown postgres:postgres $PG_DATA/standby.signal
}

setup_backup() {
    log "Configuring automated backups..."
    
    mkdir -p $BACKUP_DIR
    chown postgres:postgres $BACKUP_DIR
    
    # Create backup script
    cat > /usr/local/bin/pg_backup.sh << EOF
#!/bin/bash
BACKUP_DIR=$BACKUP_DIR
TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
pg_basebackup -D \$BACKUP_DIR/base_\$TIMESTAMP -F tar -X fetch -P -U $REPLICATION_USER
find \$BACKUP_DIR -type f -mtime +7 -delete
EOF
    
    chmod +x /usr/local/bin/pg_backup.sh
    chown postgres:postgres /usr/local/bin/pg_backup.sh
    
    # Add to crontab
    echo "0 1 * * * postgres /usr/local/bin/pg_backup.sh" > /etc/cron.d/pg_backup
}

setup_health_check() {
    log "Setting up health check endpoint..."
    
    apt-get install -y python3-flask python3-psycopg2
    
    cat > /usr/local/bin/pg_healthcheck.py << EOF
from flask import Flask
import psycopg2
import os

app = Flask(__name__)

def check_postgres():
    try:
        conn = psycopg2.connect(
            dbname='postgres',
            user='$PG_USER',
            password='$PG_PASSWORD',
            host='localhost',
            port=5432
        )
        cur = conn.cursor()
        cur.execute('SELECT pg_is_in_recovery()')
        is_replica = cur.fetchone()[0]
        cur.close()
        conn.close()
        return is_replica
    except:
        return None

@app.route('/primary')
def check_primary():
    is_replica = check_postgres()
    if is_replica is False:
        return 'OK', 200
    return 'Not primary', 503

@app.route('/replica')
def check_replica():
    is_replica = check_postgres()
    if is_replica is True:
        return 'OK', 200
    return 'Not replica', 503

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8008)
EOF

    # Create systemd service
    cat > /etc/systemd/system/pg_healthcheck.service << EOF
[Unit]
Description=PostgreSQL Health Check Service
After=network.target

[Service]
Type=simple
User=postgres
ExecStart=/usr/bin/python3 /usr/local/bin/pg_healthcheck.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable pg_healthcheck
    systemctl start pg_healthcheck
}

test_cluster() {
    log "Testing cluster setup..."
    
    # Wait for services to be ready
    wait_for_postgres 5000
    wait_for_postgres 5001
    
    # Test primary connection
    log "Testing primary connection..."
    PGPASSWORD=$PG_PASSWORD psql -h localhost -p 5000 -U $PG_USER -d postgres -c "SELECT current_timestamp;" || error "Primary connection failed"
    
    # Test replica connection
    log "Testing replica connection..."
    PGPASSWORD=$PG_PASSWORD psql -h localhost -p 5001 -U $PG_USER -d postgres -c "SELECT current_timestamp;" || error "Replica connection failed"
    
    # Test replication status
    log "Testing replication status..."
    PGPASSWORD=$PG_PASSWORD psql -h localhost -p 5000 -U $PG_USER -d postgres -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;" || error "Replication check failed"
    
    log "Cluster setup tests completed successfully!"
}

install_monitoring_stack() {
    log "Installing monitoring stack..."
    
    # Install monitoring tools
    apt-get install -y prometheus prometheus-node-exporter \
        grafana \
        postgresql-$PG_VERSION-pg-stat-monitor \
        pgmetrics \
        collectd \
        nethogs iotop

    # Configure pg_stat_monitor (enhanced statistics collection)
    cat >> $PG_CONF << EOF
# Monitoring settings
shared_preload_libraries = 'pg_stat_statements,pg_stat_monitor'
pg_stat_monitor.pgsm_track_planning = on
pg_stat_monitor.pgsm_track_utility = on
pg_stat_monitor.pgsm_normalized_query = on
EOF

    # Configure Prometheus
    cat > /etc/prometheus/prometheus.yml << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'postgresql'
    static_configs:
      - targets: ['localhost:9187']
    
  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']

  - job_name: 'pgbouncer'
    static_configs:
      - targets: ['localhost:9127']
EOF

    # Configure Grafana
    cat > /etc/grafana/provisioning/datasources/prometheus.yml << EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
EOF

    # Download and set up PostgreSQL dashboard for Grafana
    wget -O /etc/grafana/provisioning/dashboards/postgresql.json \
        'https://grafana.com/api/dashboards/9628/revisions/7/download'

    # Configure collectd for system metrics
    cat > /etc/collectd/collectd.conf << EOF
LoadPlugin cpu
LoadPlugin memory
LoadPlugin disk
LoadPlugin interface
LoadPlugin load
LoadPlugin postgresql

<Plugin postgresql>
    <Database postgres>
        Host "localhost"
        Port "5432"
        User "postgres"
        Password "$PG_PASSWORD"
    </Database>
</Plugin>
EOF

    # Create monitoring helper script
    cat > /usr/local/bin/pg_monitor.sh << 'EOF'
#!/bin/bash

show_usage() {
    echo "PostgreSQL Cluster Monitoring Tool"
    echo "Usage: $0 [option]"
    echo "Options:"
    echo "  cpu      - Show CPU usage per database connection"
    echo "  mem      - Show memory usage statistics"
    echo "  io       - Show I/O operations"
    echo "  queries  - Show slow queries"
    echo "  stats    - Show general statistics"
    echo "  all      - Show all metrics"
}

case "$1" in
    cpu)
        ps -eo pcpu,command | grep postgres | grep -v grep
        ;;
    mem)
        echo "PostgreSQL Memory Usage:"
        free -h
        echo -e "\nPostgreSQL Shared Buffers Usage:"
        psql -U postgres -c "SELECT pg_size_pretty(pg_database_size(current_database()))"
        ;;
    io)
        iostat -x 1 3
        ;;
    queries)
        psql -U postgres -c "SELECT query, calls, total_exec_time, mean_exec_time, rows 
                            FROM pg_stat_statements 
                            ORDER BY total_exec_time DESC 
                            LIMIT 10;"
        ;;
    stats)
        psql -U postgres -c "SELECT datname, numbackends, xact_commit, xact_rollback, 
                            blks_read, blks_hit, tup_returned, tup_fetched, tup_inserted, 
                            tup_updated, tup_deleted 
                            FROM pg_stat_database 
                            WHERE datname IS NOT NULL;"
        ;;
    all)
        $0 cpu
        echo -e "\n"
        $0 mem
        echo -e "\n"
        $0 io
        echo -e "\n"
        $0 queries
        echo -e "\n"
        $0 stats
        ;;
    *)
        show_usage
        ;;
esac
EOF

    chmod +x /usr/local/bin/pg_monitor.sh

    # Start and enable services
    systemctl enable prometheus grafana-server collectd
    systemctl start prometheus grafana-server collectd

    log "Monitoring stack installed successfully!"
    cat << EOF

Monitoring URLs:
--------------
Grafana:     http://localhost:3000 (default admin/admin)
Prometheus:  http://localhost:9090

Quick Monitoring Commands:
-----------------------
pg_monitor.sh cpu     - Show CPU usage
pg_monitor.sh mem     - Show memory usage
pg_monitor.sh io      - Show I/O operations
pg_monitor.sh queries - Show slow queries
pg_monitor.sh stats   - Show general statistics
pg_monitor.sh all     - Show all metrics

Additional Tools:
---------------
- pgmetrics: Run 'pgmetrics' for detailed PostgreSQL metrics
- iotop: Run 'iotop' for I/O monitoring
- nethogs: Run 'nethogs' for per-process network usage

EOF
}

###################
# Main Installation
###################
main() {
    # Use environment variables if arguments not provided
    local NODE_TYPE=${1:-${NODE_TYPE:-primary}}
    local REPLICA_NUM=${2:-${REPLICA_NUM:-1}}

    check_prerequisites

    # Common setup for all nodes
    log "Starting installation for $NODE_TYPE node..."
    apt-get update
    apt-get upgrade -y
    install_postgresql
    install_pgbouncer
    install_monitoring_tools
    
    case $NODE_TYPE in
        "primary")
            configure_postgresql_primary
            setup_backup
            install_haproxy
            install_monitoring_stack
            ;;
        "replica")
            configure_postgresql_replica "$REPLICA_NUM"
            ;;
        *)
            error "Invalid node type. Use 'primary' or 'replica'"
            ;;
    esac

    setup_health_check
    systemctl start postgresql
    systemctl start pgbouncer

    # Only test cluster from primary node
    if [ "$NODE_TYPE" = "primary" ]; then
        # Wait for services to fully start
        sleep 10
        test_cluster
    fi

    log "Installation completed successfully!"
    
    # Print connection information
    cat << EOF

==================================
PostgreSQL Cluster Setup Completed!
==================================

Connection Information:
---------------------
Write Operations (Primary):
    Host: $PRIMARY_IP
    Port: 5000
    User: $PG_USER
    Password: $PG_PASSWORD

Read Operations (Replicas):
    Host: $PRIMARY_IP
    Port: 5001
    User: $PG_USER
    Password: $PG_PASSWORD

HAProxy Stats:
    URL: http://$PRIMARY_IP:7000

Monitoring:
    Prometheus Node Exporter: http://$PRIMARY_IP:9100/metrics
    PostgreSQL Exporter: http://$PRIMARY_IP:9187/metrics

Backup Location: $BACKUP_DIR

To verify replication status:
PGPASSWORD=$PG_PASSWORD psql -h localhost -p 5000 -U $PG_USER -d postgres -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;"

EOF
}

# Check if script is run as root
if [ "$(id -u)" != "0" ]; then
    error "This script must be run as root"
fi

# Usage check
if [ "$#" -lt 1 ]; then
    cat << EOF
Usage: $0 <node_type> [replica_number]

Parameters:
    node_type       - Type of node to setup (primary|replica)
    replica_number  - Required when node_type is replica (1,2,3,...)

Environment variables:
    PRIMARY_IP           - IP address of primary node (default: 192.168.1.10)
    REPLICA_IPS         - Comma-separated list of replica IPs (default: 192.168.1.11,192.168.1.12)
    NETWORK_SUBNET      - Network subnet for pg_hba.conf (default: 192.168.1.0/24)
    PG_VERSION         - PostgreSQL version (default: 15)
    PG_USER           - PostgreSQL admin user (default: postgres)
    PG_PASSWORD       - PostgreSQL admin password (default: random)
    REPLICATION_USER   - Replication user (default: replicator)
    REPLICATION_PASSWORD - Replication password (default: random)
    BACKUP_DIR        - Backup directory (default: /var/lib/postgresql/backups)
    MAX_CONNECTIONS   - Maximum connections (default: 200)
    DEBUG            - Enable debug mode if set to 1

Example:
    # Setup primary node
    $0 primary

    # Setup first replica
    PRIMARY_IP=192.168.1.10 $0 replica 1
EOF
    exit 1
fi

# Modify Grafana configuration
sed -i 's/;http_addr = localhost/http_addr = 0.0.0.0/' /etc/grafana/grafana.ini

# Modify Prometheus configuration
sed -i 's/--web.listen-address=localhost:9090/--web.listen-address=0.0.0.0:9090/' /etc/default/prometheus

# Restart services
systemctl restart grafana-server prometheus

main "$@"