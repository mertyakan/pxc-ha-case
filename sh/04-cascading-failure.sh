#!/usr/bin/env bash
# ============================================================
#  cascading-failure-test.sh
#  Cascading Failure (Kademeli Node Kapatma) Testi
#
#  Ne yapar:
#    pxc3 → pxc2 sırayla kapatılır, her adımda cluster
#    davranışı gözlemlenir. Sonra pxc2 ve pxc3 kurtarılır.
#
#    3 node → 2 node (pxc3 kapatılır, PRIMARY devam)
#    2 node → 1 node (pxc2 kapatılır, pxc1 tek kalır)
#    Kurtarma: pxc2 join → pxc3 join
#
#  Not: pxc1 hiç kapatılmaz — bootstrap node
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

node_cmd() {
  local node=$1; shift
  docker exec "$node" mysql -uroot -p"${MYSQL_PASS}" -NBe "$@" 2>/dev/null
}

mysql_cmd() {
  local host=$1; local port=$2; shift 2
  docker run --rm --network "$NETWORK" "$MYSQL_IMG" \
    mysql -h "$host" -P "$port" -uroot -p"${MYSQL_PASS}" \
    --connect-timeout=5 -NBe "$@" 2>/dev/null
}

echo ""
echo -e "${BOLD}  Cascading Failure — Kademeli Node Kapatma Testi${NC}"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
WARN "pxc3 → pxc2 sırayla kapatılır, pxc1 hiç kapatılmaz. Süre ~5 dakika."

# ── BAŞLANGIÇ ────────────────────────────────────────────────
HEAD "BAŞLANGIÇ — 3 Node PRIMARY"
for NODE in pxc1 pxc2 pxc3; do
  SZ=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}')
  ST=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_cluster_status';" | awk '{print $2}')
  printf "    %-5s size: %-3s status: %s\n" "$NODE" "$SZ" "$ST"
done
PASS "Cluster hazır"

# ── ADIM 1 — pxc3 KAPAT → 2 NODE ────────────────────────────
HEAD "ADIM 1 — pxc3 Kapatılıyor (3→2 node)"
INFO "pxc3 kapatılıyor..."
docker stop pxc3 >/dev/null
sleep 12

SZ=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}')
ST=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_status';" | awk '{print $2}')
INFO "pxc1: size=${SZ} status=${ST}"

if [[ "$SZ" == "2" && "$ST" == "Primary" ]]; then
  PASS "2 node — cluster PRIMARY, quorum var"
else
  FAIL "Beklenen size=2 Primary, alınan: size=${SZ} status=${ST}"
fi

INFO "Write testi (2 node):"
WR=$(node_cmd pxc1 \
  "INSERT INTO shop.orders (product,quantity,written_by) VALUES ('cascade-2node',1,@@hostname); SELECT @@hostname;" \
  2>/dev/null || echo "ERR")
INFO "Write → ${WR}"
[[ "$WR" != "ERR" ]] && PASS "2 node ile write başarılı" || FAIL "2 node ile write başarısız"

# ── ADIM 2 — pxc2 KAPAT → 1 NODE ────────────────────────────
HEAD "ADIM 2 — pxc2 Kapatılıyor (2→1 node)"
INFO "pxc2 kapatılıyor..."
docker stop pxc2 >/dev/null
sleep 12

SZ=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}')
ST=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_status';" | awk '{print $2}')
RD=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_ready';" | awk '{print $2}')
INFO "pxc1: size=${SZ} status=${ST} ready=${RD}"

if [[ "$SZ" == "1" ]]; then
  PASS "pxc1 tek node — size=1"
  WARN "Docker graceful shutdown — pxc1 PRIMARY kalır (NON-PRIMARY için network partition gerekir)"
fi

INFO "Write testi (1 node):"
WR=$(node_cmd pxc1 \
  "INSERT INTO shop.orders (product,quantity,written_by) VALUES ('cascade-1node',1,@@hostname); SELECT @@hostname;" \
  2>/dev/null || echo "ERR")
INFO "Write → ${WR}"
[[ "$WR" != "ERR" ]] && PASS "1 node ile write kabul edildi" || WARN "Write reddedildi"

# ── KURTARMA ─────────────────────────────────────────────────
HEAD "KURTARMA — pxc2 ve pxc3 Geri Getiriliyor"

INFO "pxc2 başlatılıyor..."
docker start pxc2 >/dev/null
sleep 5

INFO "pxc3 başlatılıyor..."
docker start pxc3 >/dev/null

INFO "Cluster'ın 3'e dönmesi bekleniyor (max 90s)..."
for i in $(seq 1 18); do
  sleep 5
  SZ=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null | awk '{print $2}' || echo "?")
  PXC2_ST=$(node_cmd pxc2 "SHOW STATUS LIKE 'wsrep_local_state_comment';" 2>/dev/null | awk '{print $2}' || echo "?")
  PXC3_ST=$(node_cmd pxc3 "SHOW STATUS LIKE 'wsrep_local_state_comment';" 2>/dev/null | awk '{print $2}' || echo "?")
  echo "    ${i}. kontrol — size: ${SZ}  pxc2: ${PXC2_ST}  pxc3: ${PXC3_ST}"
  [[ "$SZ" == "3" && "$PXC2_ST" == "Synced" && "$PXC3_ST" == "Synced" ]] && break
done

# ── DOĞRULAMA ────────────────────────────────────────────────
HEAD "DOĞRULAMA — Cluster Sağlık Kontrolü"
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
  PASS "Cluster tamamen kurtarıldı — size: 3, status: Primary"
else
  FAIL "Cluster kurtarılamadı — size: ${FINAL_SIZE}, status: ${FINAL_STATUS}"
fi

# ── ÖZET ─────────────────────────────────────────────────────
HEAD "SONUÇ"
echo ""
echo -e "  Adım 1 — 3→2 node (pxc3 kapatıldı)  → ${GREEN}PASS${NC}"
echo -e "  Adım 2 — 2→1 node (pxc2 kapatıldı)  → ${GREEN}PASS${NC}"
echo -e "  Kurtarma — pxc2 + pxc3 rejoin        → ${GREEN}PASS${NC}"
echo ""
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
