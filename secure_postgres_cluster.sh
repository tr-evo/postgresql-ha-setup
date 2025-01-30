#!/bin/bash

# Exit on error
set -e

# Helper functions
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $@"
}

error() {
    log "ERROR: $@" >&2
    exit 1
}

# Check if running as root
if [ "$(id -u)" != "0" ]; then
    error "This script must be run as root"
fi

# Prompt for remote IP
read -p "Enter your remote IP address for firewall rules: " REMOTE_IP
if [[ ! $REMOTE_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Invalid IP address format"
fi

# Install UFW if not present
apt-get install -y ufw

# Configure firewall
log "Configuring firewall rules..."
ufw allow from $REMOTE_IP to any port 3000  # Grafana
ufw allow from $REMOTE_IP to any port 9090  # Prometheus
ufw allow from $REMOTE_IP to any port 9100  # Node Exporter
ufw allow from $REMOTE_IP to any port 9187  # PostgreSQL Exporter
ufw allow from $REMOTE_IP to any port 5432  # PostgreSQL
ufw allow from $REMOTE_IP to any port 6432  # PgBouncer
ufw --force enable

# SSL/TLS Setup
log "Setting up SSL/TLS..."
apt-get install -y certbot

# Generate self-signed certificate for Grafana
mkdir -p /etc/grafana/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/grafana/ssl/grafana.key \
    -out /etc/grafana/ssl/grafana.crt \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"

# Configure Grafana SSL
sed -i 's/;protocol = http/protocol = https/' /etc/grafana/grafana.ini
sed -i 's/;cert_file =/cert_file = \/etc\/grafana\/ssl\/grafana.crt/' /etc/grafana/grafana.ini
sed -i 's/;cert_key =/cert_key = \/etc\/grafana\/ssl\/grafana.key/' /etc/grafana/grafana.ini

# Configure PostgreSQL SSL
PG_VERSION=$(psql -V | awk '{print $3}' | cut -d. -f1)
PG_DATA="/var/lib/postgresql/$PG_VERSION/main"

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout $PG_DATA/server.key \
    -out $PG_DATA/server.crt \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"

chmod 600 $PG_DATA/server.key
chown postgres:postgres $PG_DATA/server.key $PG_DATA/server.crt

# Update PostgreSQL config
sed -i "s/#ssl = off/ssl = on/" $PG_DATA/postgresql.conf
sed -i "s/#ssl_cert_file/ssl_cert_file/" $PG_DATA/postgresql.conf
sed -i "s/#ssl_key_file/ssl_key_file/" $PG_DATA/postgresql.conf

# Change passwords
log "Updating passwords..."

# Grafana password
read -s -p "Enter new Grafana admin password: " GRAFANA_PASS
echo
grafana-cli admin reset-admin-password "$GRAFANA_PASS"

# PostgreSQL password
read -s -p "Enter new PostgreSQL admin password: " PG_PASS
echo
su - postgres -c "psql -c \"ALTER USER postgres WITH PASSWORD '$PG_PASS';\""

# Update monitoring configuration with new password
sed -i "s/Password \".*\"/Password \"$PG_PASS\"/" /etc/collectd/collectd.conf
sed -i "s/password='.*'/password='$PG_PASS'/" /usr/local/bin/pg_healthcheck.py

# Restart services
log "Restarting services..."
systemctl restart postgresql grafana-server prometheus

log "Security setup completed successfully!"
cat << EOF

Security Configuration Complete!
------------------------------
- Firewall configured for IP: $REMOTE_IP
- SSL/TLS certificates generated and configured
- Passwords updated for Grafana and PostgreSQL
- Services restarted with new configurations

Access your services securely:
- Grafana: https://<server-ip>:3000
- Prometheus: http://<server-ip>:9090 (consider setting up SSL if needed)
- PostgreSQL: ssl=on host=<server-ip> port=5432

Remember to:
1. Keep your SSL certificates safe
2. Regularly update passwords
3. Monitor access logs
4. Keep system and packages updated

EOF