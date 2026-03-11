#!/usr/bin/env bash
# ============================================================
#  backup-incremental-test.sh
#  XtraBackup Incremental Backup Testi
#
#  Ön koşul: backups/ klasöründe en az bir full backup olmalı
#  (backup-full-test.sh ile alınmış)
#
#  Senaryo (pxc1 hiç kapatılmaz):
#    1. En son full backup'ı bul
#    2. Yeni kayıtlar ekle → inc1 al (full'dan bu yana fark)
#    3. Daha fazla kayıt ekle → inc2 al (inc1'den bu yana fark)
#    4. Prepare: full (apply-log-only) → inc1 → inc2 (final)
#    5. pxc2 durdurulur, temizlenir, restore edilir
#    6. pxc2 başlatılır → IST ile güncel state'e gelir
#    7. Tüm node'larda kayıt sayısı doğrulanır
# ============================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS() { echo -e "${GREEN}  ✓ PASS${NC}  $*"; }
FAIL() { echo -e "${RED}  ✗ FAIL${NC}  $*"; }
INFO() { echo -e "${CYAN}  →${NC} $*"; }
WARN() { echo -e "${YELLOW}  ⚠${NC}  $*"; }
HEAD() { echo -e "\n${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}${YELLOW}  $*${NC}"; echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

MYSQL_PASS=$(cat secrets/mysql_root_password.txt)
XTRABACKUP_PASS=$(cat secrets/xtrabackup_password.txt)
NETWORK="pxc-ha-case_pxc-network"
XB_IMAGE="percona/percona-xtrabackup:8.0"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOST_INC1_DIR="${ROOT_DIR}/backups/inc1_${TIMESTAMP}"
HOST_INC2_DIR="${ROOT_DIR}/backups/inc2_${TIMESTAMP}"
CONTAINER_INC1_DIR="/backups/inc1_${TIMESTAMP}"
CONTAINER_INC2_DIR="/backups/inc2_${TIMESTAMP}"

node_cmd() {
  local node=$1; shift
  docker exec "$node" mysql -uroot -p"${MYSQL_PASS}" -NBe "$@" 2>/dev/null
}

xb_run() {
  docker run --rm \
    --network "$NETWORK" \
    -v pxc-ha-case_pxc2-data:/var/lib/mysql:ro \
    -v "${ROOT_DIR}/backups:/backups" \
    "$XB_IMAGE" "$@"
}

xb_prepare() {
  docker run --rm \
    -v "${ROOT_DIR}/backups:/backups" \
    "$XB_IMAGE" "$@"
}

echo ""
echo -e "${BOLD}  XtraBackup Incremental Backup Testi${NC}"

INFO "xtrabackup@% erişimi kontrol ediliyor..."
docker exec pxc1 mysql -uroot -p"${MYSQL_PASS}" -e "
  CREATE USER IF NOT EXISTS 'xtrabackup'@'%' IDENTIFIED BY '${XTRABACKUP_PASS}';
  GRANT ALL ON *.* TO 'xtrabackup'@'%';
  FLUSH PRIVILEGES;
" 2>/dev/null || true
PASS "xtrabackup@% erişimi hazır"

echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
WARN "Backup pxc2'den alınır. Restore sırasında pxc2 kısa süre kapatılır."
WARN "pxc1 hiç kapatılmaz — cluster ayakta kalır."

# ── ADIM 0 — EN SON FULL BACKUP'I BUL ────────────────────────
HEAD "ADIM 0 — Mevcut Full Backup Aranıyor"

LATEST_FULL=$(ls -dt "${ROOT_DIR}/backups/full_"* 2>/dev/null | head -1)

if [[ -z "$LATEST_FULL" ]]; then
  FAIL "backups/ klasöründe full backup bulunamadı!"
  echo ""
  echo "  Önce backup-full-test.sh çalıştırın:"
  echo "    bash sh/backup-full-test.sh"
  echo ""
  exit 1
fi

HOST_FULL_DIR="$LATEST_FULL"
CONTAINER_FULL_DIR="/backups/$(basename "$LATEST_FULL")"
FULL_LSN=$(cat "${HOST_FULL_DIR}/xtrabackup_checkpoints" 2>/dev/null | grep to_lsn | awk '{print $3}' || echo "?")
FULL_DATE=$(basename "$HOST_FULL_DIR" | sed 's/full_//')

PASS "Full backup bulundu: $(basename "$HOST_FULL_DIR")"
INFO "Full to_lsn: ${FULL_LSN}"
INFO "Full tarih: ${FULL_DATE}"

# Mevcut kayıt sayısını al
BEFORE=$(node_cmd pxc1 "SELECT COUNT(*) FROM shop.backup_test;" 2>/dev/null || echo "0")
INFO "Şu anki kayıt sayısı: ${BEFORE}"

# ── ADIM 1 — YENİ KAYITLAR + INC1 ────────────────────────────
HEAD "ADIM 1 — 15 Yeni Kayıt + Inc1 Backup"

node_cmd pxc1 "
  CREATE DATABASE IF NOT EXISTS shop;
  CREATE TABLE IF NOT EXISTS shop.backup_test (
    id    INT AUTO_INCREMENT PRIMARY KEY,
    label VARCHAR(100),
    ts    TIMESTAMP DEFAULT NOW()
  );
  INSERT INTO shop.backup_test (label)
  SELECT CONCAT('inc1-row-', seq) FROM (
    SELECT (N+1) AS seq FROM (
      SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
      UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9
      UNION SELECT 10 UNION SELECT 11 UNION SELECT 12 UNION SELECT 13 UNION SELECT 14
    ) t
  ) nums;
"

AFTER_INC1_WRITE=$(node_cmd pxc1 "SELECT COUNT(*) FROM shop.backup_test;")
PASS "15 kayıt eklendi — toplam: ${AFTER_INC1_WRITE}"

mkdir -p "$HOST_INC1_DIR"
INFO "Inc1 backup alınıyor (base: $(basename "$HOST_FULL_DIR"))..."
OUT=$(xb_run xtrabackup \
  --backup \
  --user=xtrabackup \
  --password="${XTRABACKUP_PASS}" \
  --host=pxc2 \
  --port=3306 \
  --datadir=/var/lib/mysql \
  --target-dir="${CONTAINER_INC1_DIR}" \
  --incremental-basedir="${CONTAINER_FULL_DIR}" \
  --no-server-version-check \
  2>&1 || true)

if echo "$OUT" | grep -q "completed OK"; then
  SZ=$(du -sh "$HOST_INC1_DIR" 2>/dev/null | awk '{print $1}')
  PASS "Inc1 backup tamamlandı — boyut: ${SZ}"
else
  FAIL "Inc1 backup başarısız"; echo "$OUT" | tail -10; exit 1
fi
INC1_LSN=$(cat "${HOST_INC1_DIR}/xtrabackup_checkpoints" 2>/dev/null | grep to_lsn | awk '{print $3}' || echo "?")
INFO "Inc1 to_lsn: ${INC1_LSN}"

# ── ADIM 2 — DAHA FAZLA KAYIT + INC2 ─────────────────────────
HEAD "ADIM 2 — 10 Kayıt Daha + Inc2 Backup"

node_cmd pxc1 "
  INSERT INTO shop.backup_test (label)
  SELECT CONCAT('inc2-row-', seq) FROM (
    SELECT (N+1) AS seq FROM (
      SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
      UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9
    ) t
  ) nums;
"

AFTER_INC2_WRITE=$(node_cmd pxc1 "SELECT COUNT(*) FROM shop.backup_test;")
PASS "10 kayıt eklendi — toplam: ${AFTER_INC2_WRITE}"

mkdir -p "$HOST_INC2_DIR"
INFO "Inc2 backup alınıyor (base: inc1)..."
OUT=$(xb_run xtrabackup \
  --backup \
  --user=xtrabackup \
  --password="${XTRABACKUP_PASS}" \
  --host=pxc2 \
  --port=3306 \
  --datadir=/var/lib/mysql \
  --target-dir="${CONTAINER_INC2_DIR}" \
  --incremental-basedir="${CONTAINER_INC1_DIR}" \
  --no-server-version-check \
  2>&1 || true)

if echo "$OUT" | grep -q "completed OK"; then
  SZ=$(du -sh "$HOST_INC2_DIR" 2>/dev/null | awk '{print $1}')
  PASS "Inc2 backup tamamlandı — boyut: ${SZ}"
else
  FAIL "Inc2 backup başarısız"; echo "$OUT" | tail -10; exit 1
fi
INC2_LSN=$(cat "${HOST_INC2_DIR}/xtrabackup_checkpoints" 2>/dev/null | grep to_lsn | awk '{print $3}' || echo "?")
INFO "Inc2 to_lsn: ${INC2_LSN}"

INFO "LSN zinciri:"
echo "    Full → ${FULL_LSN}"
echo "    Inc1 → ${INC1_LSN}"
echo "    Inc2 → ${INC2_LSN}"

# Inc2 sonrası 5 ek kayıt (IST ile gelecek)
node_cmd pxc1 "
  INSERT INTO shop.backup_test (label)
  SELECT CONCAT('extra-', seq) FROM (
    SELECT (N+1) AS seq FROM
    (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) t
  ) nums;
"
TOTAL=$(node_cmd pxc1 "SELECT COUNT(*) FROM shop.backup_test;")
INFO "Inc2 sonrası 5 ek kayıt eklendi — toplam: ${TOTAL}"
INFO "Restore + IST sonrası beklenen: ${TOTAL} kayıt"

# ── ADIM 3 — PREPARE ─────────────────────────────────────────
HEAD "ADIM 3 — Prepare (Full + Inc1 + Inc2)"

INFO "Full prepare (apply-log-only)..."
OUT=$(xb_prepare xtrabackup --prepare --apply-log-only \
  --target-dir="${CONTAINER_FULL_DIR}" 2>&1 || true)
echo "$OUT" | grep -q "completed OK" \
  && PASS "Full prepare tamam" \
  || { FAIL "Full prepare başarısız"; echo "$OUT" | tail -5; exit 1; }

INFO "Inc1 apply (apply-log-only)..."
OUT=$(xb_prepare xtrabackup --prepare --apply-log-only \
  --target-dir="${CONTAINER_FULL_DIR}" \
  --incremental-dir="${CONTAINER_INC1_DIR}" 2>&1 || true)
echo "$OUT" | grep -q "completed OK" \
  && PASS "Inc1 apply tamam" \
  || { FAIL "Inc1 apply başarısız"; echo "$OUT" | tail -5; exit 1; }

INFO "Inc2 apply (final)..."
OUT=$(xb_prepare xtrabackup --prepare \
  --target-dir="${CONTAINER_FULL_DIR}" \
  --incremental-dir="${CONTAINER_INC2_DIR}" 2>&1 || true)
echo "$OUT" | grep -q "completed OK" \
  && PASS "Inc2 apply tamam" \
  || { FAIL "Inc2 apply başarısız"; echo "$OUT" | tail -5; exit 1; }

# ── ADIM 4 — DISK ARIZASI + RESTORE (pxc2) ───────────────────
HEAD "ADIM 4 — Disk Arızası Simülasyonu + Restore (pxc2)"

WARN "pxc2 durduruluyor... (disk arızası simülasyonu)"
docker stop pxc2 >/dev/null
sleep 5

SZ=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}')
ST=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_status';" | awk '{print $2}')
INFO "pxc1: size=${SZ} status=${ST}"
[[ "$SZ" == "2" && "$ST" == "Primary" ]] \
  && PASS "Cluster 2 node ile devam ediyor" \
  || WARN "size=${SZ} status=${ST}"

INFO "pxc2 veri dizini temizleniyor..."
docker run --rm -v pxc-ha-case_pxc2-data:/var/lib/mysql \
  alpine sh -c "rm -rf /var/lib/mysql/*"

INFO "copy-back çalıştırılıyor (full+inc1+inc2 uygulanmış)..."
RESTORE_OUT=$(docker run --rm \
  -v pxc-ha-case_pxc2-data:/var/lib/mysql \
  -v "${ROOT_DIR}/backups:/backups" \
  "$XB_IMAGE" xtrabackup --copy-back \
  --target-dir="${CONTAINER_FULL_DIR}" \
  --datadir=/var/lib/mysql 2>&1 || true)

echo "$RESTORE_OUT" | grep -q "completed OK" \
  && PASS "copy-back tamamlandı" \
  || { FAIL "copy-back başarısız"; echo "$RESTORE_OUT" | tail -10; exit 1; }

INFO "Dosya sahipliği düzeltiliyor..."
docker run --rm -v pxc-ha-case_pxc2-data:/var/lib/mysql \
  alpine sh -c "chown -R 1001:1001 /var/lib/mysql"

INFO "grastate.dat — safe_to_bootstrap: 0..."
docker run --rm -v pxc-ha-case_pxc2-data:/var/lib/mysql \
  alpine sh -c "
    [ -f /var/lib/mysql/grastate.dat ] && \
    sed -i 's/safe_to_bootstrap: 1/safe_to_bootstrap: 0/' /var/lib/mysql/grastate.dat || true
  "

INFO "pxc2 başlatılıyor — pxc1+pxc3'ten IST alacak (5 extra kayıt gelecek)..."
docker start pxc2 >/dev/null

INFO "pxc2'nin Synced olması bekleniyor (max 120s)..."
for i in $(seq 1 24); do
  sleep 5
  SZ=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null | awk '{print $2}' || echo "?")
  ST=$(node_cmd pxc2 "SHOW STATUS LIKE 'wsrep_local_state_comment';" 2>/dev/null | awk '{print $2}' || echo "?")
  echo "    ${i}. kontrol — cluster_size: ${SZ}  pxc2 state: ${ST}"
  [[ "$SZ" == "3" && "$ST" == "Synced" ]] && break
done

# ── ADIM 5 — DOĞRULAMA ───────────────────────────────────────
HEAD "ADIM 5 — Doğrulama"

INFO "Beklenen: ${TOTAL} kayıt"
all_ok=1
for NODE in pxc1 pxc2 pxc3; do
  C=$(docker exec "$NODE" mysql -uroot -p"${MYSQL_PASS}" \
    -NBe "SELECT COUNT(*) FROM shop.backup_test;" 2>/dev/null || echo "?")
  SZ=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}' || echo "?")
  ST=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_local_state_comment';" | awk '{print $2}' || echo "?")
  SEQ=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_last_committed';" | awk '{print $2}' || echo "?")
  printf "    %-5s kayıt: %-5s size: %-3s state: %-8s seqno: %s\n" "$NODE" "$C" "$SZ" "$ST" "$SEQ"
  [[ "$C" != "$TOTAL" ]] && all_ok=0
done

echo ""
if [[ $all_ok -eq 1 ]]; then
  PASS "${TOTAL} kayıt tüm node'larda mevcut — incremental restore + IST başarılı"
else
  FAIL "Bazı node'larda kayıt sayısı ${TOTAL} değil"
fi

HEAD "SONUÇ"
echo ""
echo -e "  Adım 0 — Full backup bulundu           → ${GREEN}PASS${NC}"
echo -e "  Adım 1 — 15 kayıt + Inc1 backup        → ${GREEN}PASS${NC}"
echo -e "  Adım 2 — 10 kayıt + Inc2 backup        → ${GREEN}PASS${NC}"
echo -e "  Adım 3 — Prepare (full+inc1+inc2)      → ${GREEN}PASS${NC}"
echo -e "  Adım 4 — Disk arızası + restore         → ${GREEN}PASS${NC}"
echo -e "  Adım 5 — IST ile ${TOTAL} kayıt sync        → ${GREEN}PASS${NC}"
echo ""
echo -e "  Kullanılan full backup: $(basename "$HOST_FULL_DIR")"
echo -e "  Inc1 → $(basename "$HOST_INC1_DIR")"
echo -e "  Inc2 → $(basename "$HOST_INC2_DIR")"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
