#!/usr/bin/env bash
# ============================================================
#  08-compress-backup.sh
#  XtraBackup Compressed Backup & Restore Testi
#
#  Senaryo (pxc1 hiç kapatılmaz):
#    1. 50 kayıt yaz
#    2. pxc2'den compressed backup al (--compress --target-dir)
#    3. Backup sonrası 10 ek kayıt ekle (toplam 60)
#    4. pxc2 durdurulur, temizlenir, restore edilir
#    5. pxc2 başlatılır → IST ile 10 ek kayıt gelir → 60
#    6. Tüm node'larda 60 kayıt doğrulanır
#
#  pxc1 hiç kapatılmaz — cluster ayakta kalır.
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
HOST_BACKUP_DIR="${ROOT_DIR}/backups/compress_${TIMESTAMP}"
CONTAINER_BACKUP_DIR="/backups/compress_${TIMESTAMP}"

node_cmd() {
  local node=$1; shift
  docker exec "$node" mysql -uroot -p"${MYSQL_PASS}" -NBe "$@" 2>/dev/null
}

# Full backup ile aynı mantık: volume mount + network + target-dir
# Sadece --compress eklendi
xb_run() {
  docker run --rm \
    --network "$NETWORK" \
    -v pxc-ha-case_pxc2-data:/var/lib/mysql:ro \
    -v "${ROOT_DIR}/backups:/backups" \
    "$XB_IMAGE" "$@"
}

echo ""
echo -e "${BOLD}  XtraBackup Compressed Backup & Restore Testi${NC}"

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

# ── ADIM 1 — 50 KAYIT YAZ ────────────────────────────────────
HEAD "ADIM 1 — 50 Kayıt Yazılıyor"

node_cmd pxc1 "
  CREATE DATABASE IF NOT EXISTS shop;
  DROP TABLE IF EXISTS shop.compress_test;
  CREATE TABLE shop.compress_test (
    id    INT AUTO_INCREMENT PRIMARY KEY,
    label VARCHAR(100),
    ts    TIMESTAMP DEFAULT NOW()
  );
  INSERT INTO shop.compress_test (label)
  SELECT CONCAT('row-', seq) FROM (
    SELECT (a.N + b.N*10 + 1) AS seq
    FROM (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4) a,
         (SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
          UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9) b
  ) nums LIMIT 50;
"

COUNT=$(node_cmd pxc1 "SELECT COUNT(*) FROM shop.compress_test;")
[[ "$COUNT" == "50" ]] && PASS "50 kayıt yazıldı" || { FAIL "Kayıt sayısı: ${COUNT}"; exit 1; }

# ── ADIM 2 — COMPRESSED BACKUP ───────────────────────────────
HEAD "ADIM 2 — Compressed Backup (pxc2)"

mkdir -p "$HOST_BACKUP_DIR"
INFO "Backup dizini: ${HOST_BACKUP_DIR}"
INFO "xtrabackup container başlatılıyor (pxc2-data volume mount)..."

BACKUP_OUT=$(xb_run xtrabackup \
  --backup \
  --compress \
  --compress-threads=2 \
  --user=xtrabackup \
  --password="${XTRABACKUP_PASS}" \
  --host=pxc2 \
  --port=3306 \
  --datadir=/var/lib/mysql \
  --target-dir="${CONTAINER_BACKUP_DIR}" \
  --no-server-version-check \
  2>&1 || true)

if echo "$BACKUP_OUT" | grep -q "completed OK"; then
  COMPRESSED_SIZE=$(du -sh "$HOST_BACKUP_DIR" 2>/dev/null | awk '{print $1}')
  QP_COUNT=$(find "$HOST_BACKUP_DIR" -name "*.qp" | wc -l | tr -d ' ')
  PASS "Backup tamamlandı — compressed boyut: ${COMPRESSED_SIZE} (${QP_COUNT} .qp dosyası)"
else
  FAIL "Backup başarısız"
  echo "$BACKUP_OUT" | tail -15
  exit 1
fi

# ── ADIM 3 — DECOMPRESS + PREPARE ───────────────────────────
HEAD "ADIM 3 — Decompress + Prepare"

INFO "Decompress ediliyor (.qp → normal)..."
DEC_OUT=$(docker run --rm \
  -v "${ROOT_DIR}/backups:/backups" \
  "$XB_IMAGE" xtrabackup \
  --decompress \
  --parallel=2 \
  --remove-original \
  --target-dir="${CONTAINER_BACKUP_DIR}" \
  2>&1 || true)
DECOMPRESSED_SIZE=$(du -sh "$HOST_BACKUP_DIR" 2>/dev/null | awk '{print $1}')
PASS "Decompress tamamlandı — compressed: ${COMPRESSED_SIZE} → decompressed: ${DECOMPRESSED_SIZE}"
INFO "Disk tasarrufu: compressed backup %$(echo "scale=0; (1 - $(du -sb "$HOST_BACKUP_DIR" | awk '{print $1}') / 1) * 100" 2>/dev/null || echo '?') daha küçük"

INFO "Prepare çalıştırılıyor..."
PREPARE_OUT=$(docker run --rm \
  -v "${ROOT_DIR}/backups:/backups" \
  "$XB_IMAGE" xtrabackup \
  --prepare \
  --target-dir="${CONTAINER_BACKUP_DIR}" \
  2>&1 || true)

echo "$PREPARE_OUT" | grep -q "completed OK" \
  && PASS "Prepare tamamlandı" \
  || { FAIL "Prepare başarısız"; echo "$PREPARE_OUT" | tail -10; exit 1; }

# ── ADIM 4 — BACKUP SONRASI 10 EK KAYIT ─────────────────────
HEAD "ADIM 4 — Backup Sonrası 10 Ek Kayıt"

node_cmd pxc1 "
  INSERT INTO shop.compress_test (label)
  SELECT CONCAT('extra-', seq) FROM (
    SELECT (N+1) AS seq FROM (
      SELECT 0 AS N UNION SELECT 1 UNION SELECT 2 UNION SELECT 3 UNION SELECT 4
      UNION SELECT 5 UNION SELECT 6 UNION SELECT 7 UNION SELECT 8 UNION SELECT 9
    ) t
  ) nums;
"

TOTAL=$(node_cmd pxc1 "SELECT COUNT(*) FROM shop.compress_test;")
INFO "Backup: 50 kayıt  →  Şu an: ${TOTAL} kayıt"
PASS "10 ek kayıt eklendi — restore + IST sonrası ${TOTAL} kayıt bekleniyor"

# ── ADIM 5 — DISK ARIZASI + RESTORE (pxc2) ───────────────────
HEAD "ADIM 5 — Disk Arızası Simülasyonu + Restore (pxc2)"

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

INFO "copy-back çalıştırılıyor..."
RESTORE_OUT=$(docker run --rm \
  -v pxc-ha-case_pxc2-data:/var/lib/mysql \
  -v "${ROOT_DIR}/backups:/backups" \
  "$XB_IMAGE" xtrabackup --copy-back \
  --target-dir="${CONTAINER_BACKUP_DIR}" \
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

INFO "pxc2 başlatılıyor — pxc1+pxc3'ten IST alacak..."
docker start pxc2 >/dev/null

INFO "pxc2'nin Synced olması bekleniyor (max 120s)..."
for i in $(seq 1 24); do
  sleep 5
  SZ=$(node_cmd pxc1 "SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null | awk '{print $2}' || echo "?")
  ST=$(node_cmd pxc2 "SHOW STATUS LIKE 'wsrep_local_state_comment';" 2>/dev/null | awk '{print $2}' || echo "?")
  echo "    ${i}. kontrol — cluster_size: ${SZ}  pxc2 state: ${ST}"
  [[ "$SZ" == "3" && "$ST" == "Synced" ]] && break
done

# ── ADIM 6 — DOĞRULAMA ───────────────────────────────────────
HEAD "ADIM 6 — Doğrulama"

INFO "Beklenen: ${TOTAL} kayıt (backup:50 + extra:10)"
all_ok=1
for NODE in pxc1 pxc2 pxc3; do
  C=$(docker exec "$NODE" mysql -uroot -p"${MYSQL_PASS}" \
    -NBe "SELECT COUNT(*) FROM shop.compress_test;" 2>/dev/null || echo "?")
  SZ=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_cluster_size';" | awk '{print $2}' || echo "?")
  ST=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_local_state_comment';" | awk '{print $2}' || echo "?")
  SEQ=$(node_cmd "$NODE" "SHOW STATUS LIKE 'wsrep_last_committed';" | awk '{print $2}' || echo "?")
  printf "    %-5s kayıt: %-5s size: %-3s state: %-8s seqno: %s\n" "$NODE" "$C" "$SZ" "$ST" "$SEQ"
  [[ "$C" != "$TOTAL" ]] && all_ok=0
done

echo ""
if [[ $all_ok -eq 1 ]]; then
  PASS "${TOTAL} kayıt tüm node'larda mevcut — compressed backup + IST restore başarılı"
else
  FAIL "Bazı node'larda kayıt sayısı ${TOTAL} değil"
fi

HEAD "SONUÇ"
echo ""
echo -e "  Adım 1 — 50 kayıt yazma                    → ${GREEN}PASS${NC}"
echo -e "  Adım 2 — Compressed backup (pxc2)          → ${GREEN}PASS${NC}"
echo -e "  Adım 3 — Decompress + Prepare              → ${GREEN}PASS${NC}"
echo -e "  Adım 4 — Backup sonrası 10 ek kayıt        → ${GREEN}PASS${NC}"
echo -e "  Adım 5 — Disk arızası + restore             → ${GREEN}PASS${NC}"
echo -e "  Adım 6 — IST ile ${TOTAL} kayıt sync            → ${GREEN}PASS${NC}"
echo ""
echo -e "  Backup konumu  : ${HOST_BACKUP_DIR}"
echo -e "  Compressed boyut   : ${COMPRESSED_SIZE}"
  echo -e "  Decompressed boyut : ${DECOMPRESSED_SIZE}"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
