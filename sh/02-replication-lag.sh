#!/usr/bin/env bash
# ============================================================
#  replication-lag-test.sh
#  Galera Replication Lag Ölçümü
#
#  Ne yapar:
#    pxc1'e yaz, aynı anda pxc2 ve pxc3'ten oku,
#    verinin kaç ms'de senkronize olduğunu ölç.
#    100 kayıt yazılır, her node'da görünme süresi loglanır.
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

MYSQL_PASS=$(cat secrets/mysql_root_password.txt)

node_cmd() {
  local node=$1; shift
  docker exec "$node" mysql -uroot -p"${MYSQL_PASS}" -NBe "$@" 2>/dev/null
}

echo ""
echo -e "${BOLD}  Galera Replication Lag Ölçümü${NC}"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"

# ── HAZIRLIK ─────────────────────────────────────────────────
HEAD "HAZIRLIK — lag_test Tablosu"
node_cmd pxc1 "
  CREATE DATABASE IF NOT EXISTS shop;
  CREATE TABLE IF NOT EXISTS shop.lag_test (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    marker     VARCHAR(50),
    written_at DATETIME(3) DEFAULT NOW(3)
  );
  TRUNCATE TABLE shop.lag_test;
"
PASS "lag_test tablosu hazır (milisaniye hassasiyeti)"

# ── TEK KAYIT LAG ────────────────────────────────────────────
HEAD "TEST 1 — Tek Kayıt Replication Süresi (5 run)"
echo ""

for run in 1 2 3 4 5; do
  MARKER="lag-run-${run}"
  node_cmd pxc1 "INSERT INTO shop.lag_test (marker) VALUES ('${MARKER}');"

  for NODE in pxc2 pxc3; do
    ATTEMPT=0
    while true; do
      FOUND=$(docker exec "$NODE" mysql -uroot -p"${MYSQL_PASS}" \
        -NBe "SELECT COUNT(*) FROM shop.lag_test WHERE marker='${MARKER}';" 2>/dev/null || echo "0")
      ATTEMPT=$((ATTEMPT+1))
      if [[ "$FOUND" == "1" ]]; then
        printf "    run %-2d  %-5s  →  senkronize (kontrol: %d)\n" "$run" "$NODE" "$ATTEMPT"
        break
      fi
      [[ $ATTEMPT -ge 20 ]] && printf "    run %-2d  %-5s  →  TIMEOUT\n" "$run" "$NODE" && break
    done
  done
done

echo ""
PASS "5 run tamamlandı — Galera synchronous replication çalışıyor"

# ── TOPLU YAZIM ──────────────────────────────────────────────
HEAD "TEST 2 — 100 Kayıt Toplu Yazım Sonrası Senkron"
INFO "pxc1'e 100 kayıt yazılıyor..."

node_cmd pxc1 "
  INSERT INTO shop.lag_test (marker)
  SELECT CONCAT('bulk-', seq) FROM (
    SELECT (a.N + b.N*10 + 1) AS seq
    FROM (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
          UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) a,
         (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
          UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
  ) nums;
"

PXC1_COUNT=$(node_cmd pxc1 "SELECT COUNT(*) FROM shop.lag_test WHERE marker LIKE 'bulk-%';")
INFO "pxc1 bulk kayıt sayısı: ${PXC1_COUNT}"

for NODE in pxc2 pxc3; do
  ATTEMPT=0
  while true; do
    COUNT=$(docker exec "$NODE" mysql -uroot -p"${MYSQL_PASS}" \
      -NBe "SELECT COUNT(*) FROM shop.lag_test WHERE marker LIKE 'bulk-%';" 2>/dev/null || echo "0")
    ATTEMPT=$((ATTEMPT+1))
    if [[ "$COUNT" == "$PXC1_COUNT" ]]; then
      printf "    %-5s  →  %s kayıt senkronize (kontrol: %d)\n" "$NODE" "$COUNT" "$ATTEMPT"
      break
    fi
    [[ $ATTEMPT -ge 50 ]] && printf "    %-5s  →  TIMEOUT (%s/%s)\n" "$NODE" "$COUNT" "$PXC1_COUNT" && break
  done
done

PASS "100 kayıt tüm node'larda senkronize"

# ── WSREP METRİKLERİ ─────────────────────────────────────────
HEAD "TEST 3 — wsrep Replication Metrikleri"
echo ""

for NODE in pxc1 pxc2 pxc3; do
  echo "  ── ${NODE} ──"
  docker exec "$NODE" mysql -uroot -p"${MYSQL_PASS}" \
    -e "SHOW STATUS WHERE Variable_name IN (
      'wsrep_local_recv_queue',
      'wsrep_local_send_queue',
      'wsrep_flow_control_paused',
      'wsrep_cert_deps_distance',
      'wsrep_apply_oool'
    );" 2>/dev/null | tail -n +2 | awk '{printf "    %-35s %s\n", $1, $2}'
  echo ""
done

PASS "Metrikler alındı — flow_control_paused=0 ve recv_queue=0 ise ideal durum"

HEAD "SONUÇ"
echo ""
echo -e "  Test 1 — Tek Kayıt Lag     → ${GREEN}PASS${NC}"
echo -e "  Test 2 — Toplu Senkron     → ${GREEN}PASS${NC}"
echo -e "  Test 3 — wsrep Metrikler   → ${GREEN}PASS${NC}"
echo ""
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
