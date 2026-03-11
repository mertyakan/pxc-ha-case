#!/usr/bin/env bash
# ============================================================
#  split-brain-test.sh
#  Galera Quorum & Split-Brain Koruması Testi
#
#  Ne yapar:
#    pxc2 ve pxc3 kapatılır, tek kalan pxc1'in durumu
#    gözlemlenir. Sonra pxc2 ve pxc3 tekrar join eder.
#
#  Not: pxc1 hiç kapatılmaz — bootstrap node
#  Not: Docker'da node kapatma graceful exit olduğu için
#       pxc1 PRIMARY kalır. Gerçek NON-PRIMARY için
#       network partition (iptables) gerekir.
# ============================================================

set -euo pipefail

# Proje kök dizini (sh/ altından da çalışır)
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS() { echo -e "${GREEN}  ✓ PASS${NC}  $*"; }
FAIL() { echo -e "${RED}  ✗ FAIL${NC}  $*"; }
INFO() { echo -e "${CYAN}  →${NC} $*"; }
WARN() { echo -e "${YELLOW}  ⚠${NC}  $*"; }
HEAD() { echo -e "\n${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}${YELLOW}  $*${NC}"; echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

NETWORK="pxc-ha-case_pxc-network"
MYSQL_PASS=$(cat secrets/mysql_root_password.txt)
MYSQL_IMG="mysql:8.0"

mysql_cmd() {
  local host=$1; local port=$2; shift 2
  docker run --rm --network "$NETWORK" "$MYSQL_IMG" \
    mysql -h "$host" -P "$port" -uroot -p"${MYSQL_PASS}" \
    --connect-timeout=5 -NBe "$@" 2>/dev/null
}

node_cmd() {
  local node=$1; shift
  docker exec "$node" mysql -uroot -p"${MYSQL_PASS}" -NBe "$@" 2>/dev/null
}

echo ""
echo -e "${BOLD}  Galera Quorum & Split-Brain Koruması Testi${NC}"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"

# ── BAŞLANGIÇ ────────────────────────────────────────────────
HEAD "BAŞLANGIÇ — Cluster Durumu"
SIZE=$(mysql_cmd traefik 3306 "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}')
STATUS=$(mysql_cmd traefik 3306 "SHOW STATUS LIKE 'wsrep_cluster_status';" | awk '{print $2}')
INFO "wsrep_cluster_size:   ${SIZE}"
INFO "wsrep_cluster_status: ${STATUS}"
for NODE in pxc1 pxc2 pxc3; do
  SEQNO=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_last_committed';" | awk '{print $2}')
  printf "    %-5s seqno: %s\n" "$NODE" "$SEQNO"
done

# ── pxc2 ve pxc3 KAPAT ───────────────────────────────────────
HEAD "ADIM 1 — pxc2 ve pxc3 Kapatılıyor (pxc1 ayakta kalır)"
INFO "pxc2 kapatılıyor..."
docker stop pxc2 >/dev/null
sleep 3
INFO "pxc3 kapatılıyor..."
docker stop pxc3 >/dev/null
INFO "HAProxy health check için 15s bekleniyor..."
sleep 15

# ── pxc1 DURUMU ──────────────────────────────────────────────
HEAD "ADIM 2 — Tek Kalan pxc1 Durumu"
PXC1_SIZE=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}' || echo "?")
PXC1_STATUS=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_status';" | awk '{print $2}' || echo "?")
PXC1_READY=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_ready';" | awk '{print $2}' || echo "?")
PXC1_SEQNO=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_last_committed';" | awk '{print $2}' || echo "?")

INFO "pxc1 cluster_size:   ${PXC1_SIZE}"
INFO "pxc1 cluster_status: ${PXC1_STATUS}"
INFO "pxc1 wsrep_ready:    ${PXC1_READY}"
INFO "pxc1 seqno:          ${PXC1_SEQNO}"

if [[ "$PXC1_SIZE" == "1" ]]; then
  PASS "pxc1 tek node olarak ayakta (size=1)"
  WARN "Docker graceful shutdown — pxc1 PRIMARY kalır"
  WARN "Gerçek NON-PRIMARY için network partition gerekir (iptables)"
fi

INFO "pxc1'e write testi (tek node, yazma devam etmeli):"
WR=$(node_cmd pxc1 \
  "INSERT INTO shop.orders (product,quantity,written_by) VALUES ('split-test',1,@@hostname); SELECT @@hostname;" \
  2>/dev/null || echo "ERR")
if [[ "$WR" != "ERR" ]]; then
  PASS "pxc1 tek başına write kabul etti — size=1 PRIMARY çalışıyor"
else
  FAIL "pxc1 write reddetti"
fi

# ── KURTARMA ─────────────────────────────────────────────────
HEAD "ADIM 3 — pxc2 ve pxc3 Geri Getiriliyor"
INFO "pxc2 başlatılıyor..."
docker start pxc2 >/dev/null
sleep 5

INFO "pxc3 başlatılıyor..."
docker start pxc3 >/dev/null

INFO "Cluster'ın 3'e dönmesi bekleniyor (max 90s)..."
for i in $(seq 1 18); do
  sleep 5
  SIZE=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null | awk '{print $2}' || echo "?")
  PXC2_STATE=$(node_cmd pxc2 "SHOW STATUS LIKE 'wsrep_local_state_comment';" 2>/dev/null | awk '{print $2}' || echo "?")
  PXC3_STATE=$(node_cmd pxc3 "SHOW STATUS LIKE 'wsrep_local_state_comment';" 2>/dev/null | awk '{print $2}' || echo "?")
  echo "    ${i}. kontrol — size: ${SIZE}  pxc2: ${PXC2_STATE}  pxc3: ${PXC3_STATE}"
  [[ "$SIZE" == "3" && "$PXC2_STATE" == "Synced" && "$PXC3_STATE" == "Synced" ]] && break
done

# ── DOĞRULAMA ────────────────────────────────────────────────
HEAD "ADIM 4 — Doğrulama"
for NODE in pxc1 pxc2 pxc3; do
  SZ=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}' || echo "?")
  ST=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_cluster_status';" | awk '{print $2}' || echo "?")
  STE=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_local_state_comment';" | awk '{print $2}' || echo "?")
  SEQ=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_last_committed';" | awk '{print $2}' || echo "?")
  printf "    %-5s size: %-3s status: %-10s state: %-8s seqno: %s\n" "$NODE" "$SZ" "$ST" "$STE" "$SEQ"
done

echo ""
FINAL_SIZE=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}')
FINAL_STATUS=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_status';" | awk '{print $2}')

if [[ "$FINAL_SIZE" == "3" && "$FINAL_STATUS" == "Primary" ]]; then
  PASS "Cluster kurtarıldı — size: 3, status: Primary"
else
  FAIL "Cluster kurtarılamadı — size: ${FINAL_SIZE}, status: ${FINAL_STATUS}"
fi

echo ""
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
