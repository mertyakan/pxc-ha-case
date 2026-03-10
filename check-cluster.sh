#!/usr/bin/env bash
# ================================================================
#  check-cluster.sh — Quick cluster health check
# ================================================================
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

MYSQL_PASS=$(cat secrets/mysql_root_password.txt 2>/dev/null || echo "")
[[ -z "$MYSQL_PASS" ]] && { echo "Run setup.sh first."; exit 1; }

run_query() {
    docker exec "$1" mysql -uroot -p"${MYSQL_PASS}" -e "$2" 2>/dev/null
}

echo -e "\n${CYAN}━━━ PXC Cluster Status ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

for NODE in pxc1 pxc2 pxc3; do
    echo -e "\n${YELLOW}▶ $NODE${NC}"
    run_query "$NODE" "
        SELECT VARIABLE_NAME, VARIABLE_VALUE
        FROM performance_schema.global_status
        WHERE VARIABLE_NAME IN (
            'wsrep_cluster_size',
            'wsrep_cluster_status',
            'wsrep_connected',
            'wsrep_ready',
            'wsrep_local_state_comment'
        );
    " || echo -e "  ${RED}Node unreachable${NC}"
done

echo -e "\n${CYAN}━━━ HAProxy Status ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
for PROXY in haproxy1 haproxy2; do
    STATUS=$(docker inspect --format='{{.State.Status}}' "$PROXY" 2>/dev/null || echo "not found")
    echo "  $PROXY → $STATUS"
done

echo -e "\n${CYAN}━━━ PMM Server ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
PMM_STATUS=$(docker inspect --format='{{.State.Status}}' pmm-server 2>/dev/null || echo "not found")
echo "  pmm-server → $PMM_STATUS"
echo ""
