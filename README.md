# PostgreSQL High-Availability Cluster Setup

> ⚠️ **WORK IN PROGRESS - NOT PRODUCTION READY**
>
> **Current Status:**
> - This code is under active development and not working yet
> - Current focus: Getting the script to work in Docker environment with one primary and one replica
> - Known Issues:
>   - Container creation works but connection to logstream fails
>   - Docker networking between primary and replica needs debugging
>
> **Next Steps:**
> - Debug container log streaming issues
> - Test and verify primary-replica communication
> - Validate replication setup in Docker environment

## Features

- Primary node with configurable number of read replicas
- PgBouncer connection pooling
- HAProxy load balancing with health checks
- Automated backup configuration
- Comprehensive monitoring setup
- Performance tuning
- Security hardening options

## Quick Start

1. Clone the repository
2. Run the setup script as root:

```bash
#!/bin/bash
# Setup primary node
./postgres_cluster.sh primary
# Setup replica node
PRIMARY_IP=192.168.1.10 ./postgres_cluster.sh replica 1
```

## Docker Development Setup (Current WIP)

The project is currently being adapted to work in a Docker environment. To try the current development version:

1. Build and run the containers:
```bash
docker-compose -f docker-compose.test.yml up --build
```

2. Expected Endpoints (when working):
- Primary PostgreSQL: localhost:5432
- Replica PostgreSQL: localhost:5433
- Grafana: http://localhost:3000
- Prometheus: http://localhost:9090
- HAProxy Stats: http://localhost:7000

3. Known Issues:
- Container log streaming may fail
- Replication setup between containers needs verification
- Some monitoring endpoints may not be accessible yet

4. Debugging:
```bash
# View container logs
docker-compose -f docker-compose.test.yml logs -f

# Access container shell
docker-compose -f docker-compose.test.yml exec pg_primary bash
docker-compose -f docker-compose.test.yml exec pg_replica bash

# Check PostgreSQL status
docker-compose -f docker-compose.test.yml exec pg_primary pg_isready -U postgres
docker-compose -f docker-compose.test.yml exec pg_replica pg_isready -U postgres
```

## Configuration Parameters

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| PRIMARY_IP | IP address of primary node | 192.168.1.10 |
| REPLICA_IPS | Comma-separated list of replica IPs | 192.168.1.11,192.168.1.12 |
| NETWORK_SUBNET | Network subnet for pg_hba.conf | 192.168.1.0/24 |
| PG_VERSION | PostgreSQL version | 15 |
| PG_USER | PostgreSQL admin user | postgres |
| PG_PASSWORD | PostgreSQL admin password | random |
| REPLICATION_USER | Replication user | replicator |
| REPLICATION_PASSWORD | Replication password | random |
| BACKUP_DIR | Backup directory | /var/lib/postgresql/backups |
| MAX_CONNECTIONS | Maximum connections | 200 |
| DEBUG | Enable debug mode | 0 |

## Monitoring Setup

### Local Access (On the VM)

1. Command Line Tools:

```bash
#!/bin/bash
# Quick overview
pg_monitor.sh all
# Specific metrics
pg_monitor.sh cpu # CPU usage
pg_monitor.sh mem # Memory usage
pg_monitor.sh io # I/O operations
pg_monitor.sh queries # Slow queries
pg_monitor.sh stats # Database statistics
# Additional tools
pgmetrics --host=localhost --port=5432 --username=postgres
iotop # I/O monitoring
nethogs # Network usage
```

2. Web Interfaces (Local):
- Grafana: http://localhost:3000
- Prometheus: http://localhost:9090
- Node Exporter: http://localhost:9100/metrics
- PostgreSQL Metrics: http://localhost:9187/metrics

### Remote Access

After running the security setup script, you can access:

1. Grafana Dashboard:
   - URL: https://YOUR_SERVER_IP:3000
   - Default login: admin/admin
   - You'll be prompted to change password on first login

2. Prometheus:
   - URL: https://YOUR_SERVER_IP:9090

3. Raw Metrics:
   - Node Exporter: https://YOUR_SERVER_IP:9100/metrics
   - PostgreSQL: https://YOUR_SERVER_IP:9187/metrics

## Security Setup

After installation, run the security setup script:

```bash
#!/bin/bash
./secure_postgres_cluster.sh
```

This will:
1. Configure firewall rules for your IP
2. Set up SSL/TLS certificates
3. Change default passwords


## Backup and Recovery

Automated backups are configured to run daily at 1 AM and keep backups for 7 days.
Backup location: /var/lib/postgresql/backups

## Troubleshooting

Check service status:

```bash
#!/bin/bash
systemctl status postgresql
systemctl status pgbouncer
systemctl status haproxy
systemctl status prometheus
systemctl status grafana-server
```


View logs:
```bash
#!/bin/bash
journalctl -u postgresql
journalctl -u pgbouncer
journalctl -u haproxy
```

## License

This project is licensed under GNU GPL v3.0. Any derivative work must:
- Maintain the same open-source license
- Provide attribution to this original repository
- Include a link to this repository
- Document any changes made

For the full license text, see the [LICENSE](LICENSE) file.

