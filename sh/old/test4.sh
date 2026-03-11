#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════
#  PXC HA Cluster — Live Status Dashboard
# ═══════════════════════════════════════════════════════

PASS="bXjAoIU3QpMBaxF7H2j2"
MYSQL="mysql -uroot -p${PASS} --connect-timeout=2"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

up()   { echo -e "${GREEN}● UP${NC}"; }
down() { echo -e "${RED}● DOWN${NC}"; }
val()  { echo -e "${CYAN}$1${NC}"; }

divider() { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
header()  { echo -e "${BOLD}${YELLOW}  $1${NC}"; }

clear
echo ""
divider
echo -e "  ${BOLD}PXC HA CLUSTER STATUS$(date '+  %Y-%m-%d %H:%M:%S')${NC}"
divider

# ── 1. PXC NODE STATUS ──────────────────────────────────
echo ""
header "① GALERA CLUSTER NODES"
echo ""
printf "  ${BOLD}%-8s %-12s %-10s %-8s %-20s${NC}\n" "NODE" "STATE" "ROLE" "SIZE" "PEERS"
echo "  ──────────────────────────────────────────────────────"

for NODE in pxc1 pxc2 pxc3; do
  if docker exec $NODE mysqladmin ping -uroot -p${PASS} --silent 2>/dev/null; then
    STATE=$(docker exec $NODE $MYSQL -se \
      "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='wsrep_local_state_comment';" 2>/dev/null)
    SIZE=$(docker exec $NODE $MYSQL -se \
      "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='wsrep_cluster_size';" 2>/dev/null)
    STATUS=$(docker exec $NODE $MYSQL -se \
      "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='wsrep_cluster_status';" 2>/dev/null)
    PEERS=$(docker exec $NODE $MYSQL -se \
      "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='wsrep_incoming_addresses';" 2>/dev/null)

    COLOR=$GREEN
    [[ "$STATE" != "Synced" ]] && COLOR=$YELLOW
    printf "  ${COLOR}%-8s${NC} %-12s %-10s %-8s %-20s\n" "$NODE" "${STATE:-?}" "${STATUS:-?}" "${SIZE:-?}" "${PEERS:-?}"
  else
    printf "  ${RED}%-8s %-12s %-10s %-8s${NC}\n" "$NODE" "OFFLINE" "-" "-"
  fi
done

# ── 2. HAPROXY STATUS ───────────────────────────────────
echo ""
header "② HAPROXY LOAD BALANCERS"
echo ""
printf "  ${BOLD}%-12s %-22s %-8s %-8s %-8s${NC}\n" "HAPROXY" "BACKEND" "pxc1" "pxc2" "pxc3"
echo "  ──────────────────────────────────────────────────────"

for HA in "haproxy1:8404" "haproxy2:8405"; do
  NAME=$(echo $HA | cut -d: -f1)
  PORT=$(echo $HA | cut -d: -f2)

  CSV=$(curl -s -u admin:admin "http://localhost:${PORT}/stats;csv" 2>/dev/null)
  if [[ -z "$CSV" ]]; then
    printf "  ${RED}%-12s OFFLINE${NC}\n" "$NAME"
    continue
  fi

  for BACKEND in "mysql-write-back:WRITE" "mysql-read-back:READ "; do
    BK=$(echo $BACKEND | cut -d: -f1)
    LABEL=$(echo $BACKEND | cut -d: -f2)
    S1=$(echo "$CSV" | awk -F',' "\$1==\"$BK\" && \$2==\"pxc1\" {print \$18}")
    S2=$(echo "$CSV" | awk -F',' "\$1==\"$BK\" && \$2==\"pxc2\" {print \$18}")
    S3=$(echo "$CSV" | awk -F',' "\$1==\"$BK\" && \$2==\"pxc3\" {print \$18}")

    color_status() {
      [[ "$1" == "UP" ]] && echo -e "${GREEN}UP${NC}" || echo -e "${RED}${1:-?}${NC}"
    }

    printf "  %-12s %-22s %-18s %-18s %-8s\n" \
      "$NAME" "$LABEL" \
      "$(color_status $S1)" \
      "$(color_status $S2)" \
      "$(color_status $S3)"
  done
done

# ── 3. ACTIVE WRITE NODE ────────────────────────────────
echo ""
header "③ ACTIVE CONNECTIONS TEST"
echo ""

for HA in haproxy1 haproxy2; do
  PORT=3306
  WRITE_NODE=$(${MYSQL} -h $HA -P $PORT -se "SELECT @@hostname;" 2>/dev/null)
  READ_NODES=""
  for i in 1 2 3; do
    N=$(${MYSQL} -h $HA -P 3307 -se "SELECT @@hostname;" 2>/dev/null)
    READ_NODES="$READ_NODES $N"
  done

  if [[ -n "$WRITE_NODE" ]]; then
    echo -e "  ${GREEN}$HA${NC}  Write→ ${CYAN}${WRITE_NODE}${NC}  Read→ ${CYAN}${READ_NODES}${NC}"
  else
    echo -e "  ${RED}$HA  UNREACHABLE${NC}"
  fi
done

# ── 4. DATA CHECK ───────────────────────────────────────
echo ""
header "④ REPLICATION CHECK — testdb.test_writes"
echo ""

TOTAL=$(${MYSQL} -h haproxy1 -P 3306 testdb -se "SELECT COUNT(*) FROM test_writes;" 2>/dev/null || \
        ${MYSQL} -h haproxy2 -P 3306 testdb -se "SELECT COUNT(*) FROM test_writes;" 2>/dev/null)

for NODE in pxc1 pxc2 pxc3; do
  COUNT=$(docker exec $NODE $MYSQL testdb -se "SELECT COUNT(*) FROM test_writes;" 2>/dev/null)
  if [[ "$COUNT" == "$TOTAL" && -n "$COUNT" ]]; then
    echo -e "  ${GREEN}✓${NC} $NODE → ${CYAN}$COUNT rows${NC} (in sync)"
  else
    echo -e "  ${RED}✗${NC} $NODE → ${CYAN}${COUNT:-OFFLINE}${NC} (expected: $TOTAL)"
  fi
done

echo ""
divider
echo -e "  Tip: Run with ${CYAN}watch -n2 ./cluster-status.sh${NC} for live monitoring"
divider
echo ""
