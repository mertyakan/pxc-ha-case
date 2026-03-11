#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 1. Secrets ────────────────────────────────────────────────
info "Creating secrets..."
mkdir -p secrets

if [[ ! -f secrets/mysql_root_password.txt ]]; then
    openssl rand -base64 20 | tr -dc 'A-Za-z0-9' | head -c 20 > secrets/mysql_root_password.txt
    info "Generated MySQL root password"
fi
if [[ ! -f secrets/xtrabackup_password.txt ]]; then
    openssl rand -base64 20 | tr -dc 'A-Za-z0-9' | head -c 20 > secrets/xtrabackup_password.txt
    info "Generated XtraBackup password"
fi
chmod 600 secrets/*.txt
MYSQL_PASS=$(cat secrets/mysql_root_password.txt)

# ── 2. Check Docker ───────────────────────────────────────────
command -v docker >/dev/null 2>&1 || error "Docker not found."

# ── 3. PMM Server ─────────────────────────────────────────────
info "Starting PMM Server..."
docker compose up -d pmm-server
info "Waiting 45s for PMM Server..."
sleep 45

# ── 4. PXC Cluster ────────────────────────────────────────────
info "Bootstrapping pxc1..."
docker compose up -d pxc1
info "Waiting 60s for pxc1..."
sleep 60

info "Joining pxc2 and pxc3..."
docker compose up -d pxc2 pxc3
info "Waiting 60s for SST sync..."
sleep 60

# ── 5. HAProxy ────────────────────────────────────────────────
info "Starting HAProxy instances..."
docker compose up -d haproxy1 haproxy2

# ── 6. HAProxy health-check user ─────────────────────────────
info "Creating haproxy_check user..."
docker exec pxc1 mysql -uroot -p"${MYSQL_PASS}" -e \
  "CREATE USER IF NOT EXISTS 'haproxy_check'@'%' IDENTIFIED BY ''; FLUSH PRIVILEGES;" \
  && info "haproxy_check created." || warn "Could not create haproxy_check user"

# ── 7. PMM monitoring user ────────────────────────────────────
info "Creating PMM monitoring user in MySQL..."
docker exec pxc1 mysql -uroot -p"${MYSQL_PASS}" -e "
  CREATE USER IF NOT EXISTS 'pmm'@'%' IDENTIFIED BY 'pmmpass' WITH MAX_USER_CONNECTIONS 10;
  GRANT SELECT, PROCESS, SUPER, REPLICATION CLIENT, RELOAD ON *.* TO 'pmm'@'%';
  GRANT SELECT, UPDATE, DELETE, DROP ON performance_schema.* TO 'pmm'@'%';
  FLUSH PRIVILEGES;
" && info "PMM user created." || warn "Could not create PMM user"

# ── 8. Cluster sağlık kontrolü ───────────────────────────────
info "Waiting for all 3 PXC nodes to be healthy..."

wait_for_cluster() {
    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        CLUSTER_SIZE=$(docker exec pxc1 mysql -uroot -p"${MYSQL_PASS}" \
            -se "SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null | awk '{print $2}')
        if [[ "$CLUSTER_SIZE" == "3" ]]; then
            info "Cluster size: 3 — all nodes synced ✓"
            return 0
        fi
        attempt=$((attempt + 1))
        info "Cluster size: ${CLUSTER_SIZE:-?} — waiting... ($attempt/$max_attempts)"
        sleep 10
    done
    warn "Cluster did not reach size 3 in time, proceeding anyway"
}

wait_for_cluster
sleep 5

# ── pxc1 config güncelle: bootstrap → full HA ────────────────
info "Updating pxc1 wsrep_cluster_address for full HA..."
docker exec pxc1 bash -c \
  "sed -i 's|wsrep_cluster_address.*=.*gcomm://\$|wsrep_cluster_address           = gcomm://pxc1,pxc2,pxc3|' \
  /etc/percona-xtradb-cluster.conf.d/custom.cnf" \
  && info "pxc1 HA config updated ✓ (takes effect on next restart)" \
  || warn "Could not update pxc1 config"

# ── 9. PMM: servis kaydı ─────────────────────────────────────
info "Registering PXC nodes with PMM Server..."

for NODE in pxc1 pxc2 pxc3; do
    info "Registering ${NODE}..."
    RESP=$(curl -s -k -u admin:admin \
      -X POST "https://localhost/v1/management/MySQL/Add" \
      -H "Content-Type: application/json" \
      -d "{
        \"add_node\": {
          \"node_type\": \"REMOTE_NODE\",
          \"node_name\": \"${NODE}\"
        },
        \"pmm_agent_id\": \"pmm-server\",
        \"service_name\": \"${NODE}-mysql\",
        \"address\": \"${NODE}\",
        \"port\": 3306,
        \"username\": \"pmm\",
        \"password\": \"pmmpass\",
        \"query_source\": \"perfschema\"
      }")

    if echo "$RESP" | grep -q "service_id"; then
        info "${NODE} registered with PMM ✓"
    else
        warn "${NODE} registration failed. Response: $RESP"
    fi
done

# ── 10. Summary ───────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  PXC HA Cluster is UP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  MySQL WRITE  → localhost:3306   (via HAProxy1)"
echo "  MySQL WRITE  → localhost:3316   (via HAProxy2)"
echo "  MySQL READ   → localhost:3307   (via HAProxy1)"
echo "  MySQL READ   → localhost:3317   (via HAProxy2)"
echo ""
echo "  Direct node access:"
echo "    pxc1 → localhost:3311"
echo "    pxc2 → localhost:3312"
echo "    pxc3 → localhost:3313"
echo ""
echo "  HAProxy1 Stats → http://localhost:8404/stats"
echo "  HAProxy2 Stats → http://localhost:8405/stats"
echo "                   (admin / admin)"
echo ""
echo "  PMM Dashboard  → https://localhost"
echo "                   (admin / admin)"
echo ""
echo "  MySQL root password → ${MYSQL_PASS}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
