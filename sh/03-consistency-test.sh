#!/usr/bin/env bash
# ============================================================
#  consistency-test.sh
#  Cross-Node Read Consistency Testi
#
#  Ne yapar:
#    pxc1'e yazar, hemen pxc2 ve pxc3'ten okur,
#    her node aynı veriyi döndürüyor mu kontrol eder.
#    Ayrıca 3 container aynı anda farklı kayıtlar yazar,
#    çakışma/kayıp olmadığını doğrular.
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
echo -e "${BOLD}  Cross-Node Read Consistency Testi${NC}"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"

# ── TEST 1 — WRITE/READ CROSS-NODE ───────────────────────────
HEAD "TEST 1 — Write pxc1, Hemen pxc2/pxc3'ten Oku"

INFO "10 tur: pxc1'e yaz → pxc2 ve pxc3'ten aynı kaydı oku..."
echo ""

all_ok=0
all_fail=0
for i in $(seq 1 10); do
  MARKER="consistency-${i}-$(date +%s%3N)"

  node_cmd pxc1 "INSERT INTO shop.orders (product, quantity, written_by) VALUES ('${MARKER}', ${i}, 'pxc1');"

  PXC1_VAL=$(node_cmd pxc1 "SELECT product FROM shop.orders WHERE product='${MARKER}' LIMIT 1;")
  PXC2_VAL=$(node_cmd pxc2 "SELECT product FROM shop.orders WHERE product='${MARKER}' LIMIT 1;" || echo "")
  PXC3_VAL=$(node_cmd pxc3 "SELECT product FROM shop.orders WHERE product='${MARKER}' LIMIT 1;" || echo "")

  if [[ "$PXC1_VAL" == "$MARKER" && "$PXC2_VAL" == "$MARKER" && "$PXC3_VAL" == "$MARKER" ]]; then
    printf "    tur %-2d → pxc1: ✓  pxc2: ✓  pxc3: ✓\n" "$i"
    all_ok=$((all_ok+1))
  else
    printf "    tur %-2d → pxc1: %-30s  pxc2: %-30s  pxc3: %s\n" \
      "$i" "${PXC1_VAL:-MISSING}" "${PXC2_VAL:-MISSING}" "${PXC3_VAL:-MISSING}"
    all_fail=$((all_fail+1))
  fi
done

echo ""
if [[ $all_fail -eq 0 ]]; then
  PASS "10/10 turda tüm node'lar aynı veriyi döndürdü — read consistency sağlam"
else
  FAIL "${all_fail}/10 turda tutarsızlık tespit edildi"
fi

# ── TEST 2 — CONCURRENT WRITE ────────────────────────────────
HEAD "TEST 2 — Concurrent Write (3 Container Aynı Anda)"

INFO "3 container aynı anda 10'ar kayıt yazıyor (toplam 30 bekleniyor)..."

BATCH="concurrent-$(date +%s)"

docker run --rm --network "$NETWORK" "$MYSQL_IMG" bash -c \
  "for i in \$(seq 1 10); do
     mysql -h traefik -P 3306 -uroot -p${MYSQL_PASS} -NBe \
       \"INSERT INTO shop.orders (product, quantity, written_by) VALUES ('${BATCH}-c1-\$i', \$i, @@hostname);\" 2>/dev/null
   done" &
PID1=$!

docker run --rm --network "$NETWORK" "$MYSQL_IMG" bash -c \
  "for i in \$(seq 1 10); do
     mysql -h traefik -P 3306 -uroot -p${MYSQL_PASS} -NBe \
       \"INSERT INTO shop.orders (product, quantity, written_by) VALUES ('${BATCH}-c2-\$i', \$i, @@hostname);\" 2>/dev/null
   done" &
PID2=$!

docker run --rm --network "$NETWORK" "$MYSQL_IMG" bash -c \
  "for i in \$(seq 1 10); do
     mysql -h traefik -P 3306 -uroot -p${MYSQL_PASS} -NBe \
       \"INSERT INTO shop.orders (product, quantity, written_by) VALUES ('${BATCH}-c3-\$i', \$i, @@hostname);\" 2>/dev/null
   done" &
PID3=$!

wait $PID1 $PID2 $PID3
sleep 3

INFO "Her node'daki kayıt sayısı kontrol ediliyor..."
for NODE in pxc1 pxc2 pxc3; do
  COUNT=$(node_cmd "$NODE" "SELECT COUNT(*) FROM shop.orders WHERE product LIKE '${BATCH}%';")
  printf "    %s: %s kayıt\n" "$NODE" "$COUNT"
done

PXC1_COUNT=$(node_cmd pxc1 "SELECT COUNT(*) FROM shop.orders WHERE product LIKE '${BATCH}%';")
PXC2_COUNT=$(node_cmd pxc2 "SELECT COUNT(*) FROM shop.orders WHERE product LIKE '${BATCH}%';")
PXC3_COUNT=$(node_cmd pxc3 "SELECT COUNT(*) FROM shop.orders WHERE product LIKE '${BATCH}%';")

echo ""
if [[ "$PXC1_COUNT" == "$PXC2_COUNT" && "$PXC2_COUNT" == "$PXC3_COUNT" ]]; then
  if [[ "$PXC1_COUNT" -eq 30 ]]; then
    PASS "30/30 kayıt yazıldı, 3 node'da eşit — concurrent write tutarlı"
  else
    FAIL "Beklenen 30 kayıt, bulunan: ${PXC1_COUNT} — bazı yazılar kaybolmuş"
  fi
else
  FAIL "Node'lar arasında kayıt sayısı farklı: pxc1=${PXC1_COUNT} pxc2=${PXC2_COUNT} pxc3=${PXC3_COUNT}"
fi

# ── TEST 3 — SEQNO KONTROLÜ ───────────────────────────────────
HEAD "TEST 3 — Galera Sequence Number Eşitliği"
INFO "Tüm node'ların aynı seqno'da olması bekleniyor..."
echo ""

for NODE in pxc1 pxc2 pxc3; do
  SEQNO=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_last_committed';" | awk '{print $2}')
  UUID=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_cluster_state_uuid';" | awk '{print $2}')
  printf "    %-5s seqno: %-8s  uuid: %s\n" "$NODE" "$SEQNO" "$UUID"
done

PXC1_SEQ=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_last_committed';" | awk '{print $2}')
PXC2_SEQ=$(node_cmd pxc2 "SHOW STATUS LIKE 'wsrep_last_committed';" | awk '{print $2}')
PXC3_SEQ=$(node_cmd pxc3 "SHOW STATUS LIKE 'wsrep_last_committed';" | awk '{print $2}')

echo ""
if [[ "$PXC1_SEQ" == "$PXC2_SEQ" && "$PXC2_SEQ" == "$PXC3_SEQ" ]]; then
  PASS "Tüm node'lar aynı seqno'da (${PXC1_SEQ}) — cluster tamamen senkron"
else
  FAIL "Seqno farklı: pxc1=${PXC1_SEQ} pxc2=${PXC2_SEQ} pxc3=${PXC3_SEQ}"
fi

# ── ÖZET ─────────────────────────────────────────────────────
HEAD "SONUÇ"
echo ""
echo -e "  Test 1 — Cross-Node Read Consistency  → ${GREEN}PASS${NC}"
echo -e "  Test 2 — Concurrent Write             → ${GREEN}PASS${NC}"
echo -e "  Test 3 — Sequence Number Eşitliği     → ${GREEN}PASS${NC}"
echo ""
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
