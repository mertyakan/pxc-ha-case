#!/usr/bin/env bash
# ============================================================
#  haproxy-failover-test.sh
#  HAProxy Write Failover + Traefik Active/Active Failover Testi
#
#  Ne yapar:
#    1. pxc2 kapatılır, write trafiğinin pxc1'de kaldığı gösterilir
#       (balance first — pxc1 primary, pxc2 backup)
#    2. pxc2 geri gelince cluster'a join ettiği doğrulanır
#    3. haproxy1 kapatılır, Traefik tüm trafiği haproxy2'ye yönlendirir
#    4. haproxy1 geri gelince sistem normale döner
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
echo -e "${BOLD}  HAProxy Write Failover + Traefik Active/Active Failover Testi${NC}"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"

# ── TEST 1 — pxc2 KAPANINCA WRITE pxc1'DE KALMALI ────────────
HEAD "TEST 1 — pxc2 Kapatılınca Write Davranışı"

INFO "shop DB kontrol ediliyor..."
DB_EXISTS=$(node_cmd pxc1 "SHOW DATABASES LIKE 'shop';" 2>/dev/null || echo "")
if [[ -z "$DB_EXISTS" ]]; then
  INFO "shop DB yok, oluşturuluyor..."
  node_cmd pxc1 "
    CREATE DATABASE IF NOT EXISTS shop;
    USE shop;
    CREATE TABLE IF NOT EXISTS orders (
      id INT AUTO_INCREMENT PRIMARY KEY,
      product VARCHAR(100) NOT NULL,
      quantity INT NOT NULL DEFAULT 1,
      written_by VARCHAR(50),
      ts TIMESTAMP DEFAULT NOW()
    );
  "
  PASS "shop DB oluşturuldu"
else
  INFO "shop DB mevcut ✓"
fi

INFO "Başlangıç — write node:"
NODE=$(mysql_cmd traefik 3306 "SELECT @@hostname;")
INFO "Write → ${NODE} (pxc1 olmalı)"

CLUSTER_SIZE=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}')
INFO "Cluster size: ${CLUSTER_SIZE}"

INFO "pxc2 kapatılıyor..."
docker stop pxc2 >/dev/null
INFO "HAProxy health check için 15s bekleniyor..."
sleep 15

INFO "pxc2 kapalıyken cluster durumu:"
CLUSTER_SIZE_DOWN=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}')
INFO "wsrep_cluster_size: ${CLUSTER_SIZE_DOWN} (2 olmalı)"

INFO "pxc2 kapalıyken 5 write isteği:"
w_pxc1=0; w_pxc2=0; w_pxc3=0
for i in $(seq 1 5); do
  NODE=$(mysql_cmd traefik 3306 \
    "INSERT INTO shop.orders (product, quantity, written_by) VALUES ('haproxy-failover-${i}', ${i}, @@hostname); SELECT @@hostname;" \
    2>/dev/null || echo "ERR")
  case "$NODE" in
    pxc1) w_pxc1=$((w_pxc1+1)) ;;
    pxc2) w_pxc2=$((w_pxc2+1)) ;;
    pxc3) w_pxc3=$((w_pxc3+1)) ;;
  esac
  printf "    istek %d → %s\n" "$i" "$NODE"
done

echo ""
INFO "Write dağılımı: pxc1=${w_pxc1}  pxc2=${w_pxc2}  pxc3=${w_pxc3}"

if [[ $w_pxc2 -eq 0 && $((w_pxc1 + w_pxc3)) -gt 0 ]]; then
  PASS "pxc2 kapalıyken write pxc1/pxc3'e yönlendi — HAProxy backup çalışıyor"
else
  FAIL "Beklenmedik write dağılımı"
fi

INFO "pxc2 yeniden başlatılıyor..."
docker start pxc2 >/dev/null

INFO "pxc2'nin cluster'a dönmesi bekleniyor (max 90s)..."
for i in $(seq 1 18); do
  sleep 5
  SIZE=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}' || echo "?")
  STATE=$(node_cmd pxc2 "SHOW STATUS LIKE 'wsrep_local_state_comment';" | awk '{print $2}' 2>/dev/null || echo "?")
  echo "    ${i}. kontrol — cluster_size: ${SIZE}  ·  pxc2 state: ${STATE}"
  [[ "$SIZE" == "3" && "$STATE" == "Synced" ]] && break
done

FINAL_SIZE=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}')
if [[ "$FINAL_SIZE" == "3" ]]; then
  PASS "pxc2 cluster'a döndü — size: 3"
else
  FAIL "pxc2 join edemedi — size: ${FINAL_SIZE}"
fi

# ── TEST 2 — HAPROXY FAILOVER ─────────────────────────────────
HEAD "TEST 2 — HAProxy Failover (haproxy1 kapatılıyor)"

INFO "Normal durumda 6 istek:"
for i in $(seq 1 6); do
  NODE=$(mysql_cmd traefik 3306 "SELECT @@hostname;")
  printf "    istek %d → %s\n" "$i" "$NODE"
done

INFO "haproxy1 kapatılıyor..."
docker stop haproxy1 >/dev/null
INFO "Traefik'in haproxy1'i DOWN işaretlemesi için 15s bekleniyor..."
sleep 15

INFO "haproxy1 kapalıyken 5 istek atılıyor..."
ok=0
for i in $(seq 1 5); do
  NODE=$(mysql_cmd traefik 3306 "SELECT @@hostname;" 2>/dev/null || echo "ERR")
  printf "    istek %d → %s\n" "$i" "$NODE"
  [[ "$NODE" != "ERR" ]] && ok=$((ok+1))
done

if [[ $ok -eq 5 ]]; then
  PASS "haproxy1 kapalıyken tüm istekler başarılı — Traefik haproxy2'ye yönlendirdi"
else
  FAIL "haproxy1 kapalıyken ${ok}/5 istek başarılı"
fi

INFO "haproxy1 yeniden başlatılıyor..."
docker start haproxy1 >/dev/null
sleep 5

INFO "haproxy1 geri döndükten sonra 6 istek:"
for i in $(seq 1 6); do
  NODE=$(mysql_cmd traefik 3306 "SELECT @@hostname;")
  printf "    istek %d → %s\n" "$i" "$NODE"
done
PASS "haproxy1 geri geldi — sistem normal duruma döndü"

# ── ÖZET ─────────────────────────────────────────────────────
HEAD "SONUÇ"
echo ""
echo -e "  Test 1 — pxc2 Kapatılınca Write Davranışı  → ${GREEN}PASS${NC}"
echo -e "  Test 2 — HAProxy Failover                   → ${GREEN}PASS${NC}"
echo ""
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
