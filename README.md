# PXC High Availability Cluster

Percona XtraDB Cluster (Galera Multi-Master) + Dual HAProxy + PMM Monitoring — Docker Compose ile tam otomatik kurulum.

---

## Mimari

```
Uygulama / İstemci
    ├── HAProxy 1 (172.20.0.21)  →  :3306 Write  |  :3307 Read  |  :8404 Stats
    └── HAProxy 2 (172.20.0.22)  →  :3316 Write  |  :3317 Read  |  :8405 Stats
              │
              ├── pxc1 (172.20.0.11:3311)  ←→  Galera wsrep sync
              ├── pxc2 (172.20.0.12:3312)  ←→  Galera wsrep sync
              └── pxc3 (172.20.0.13:3313)
                        │
                    PMM Server (172.20.0.30)  :80 / :443
```

**Network:** `172.20.0.0/24`  
**Replication:** Synchronous (Galera)  
**SST Method:** xtrabackup-v2  
**Quorum:** 2/3 node gerekli — 1 node kaybında cluster ayakta kalır

---

## Dosya Yapısı

```
pxc-ha-case/
├── docker-compose.yml            # Tüm servisler ve bağımlılık zinciri
├── setup.sh                      # Otomatik kurulum scripti
├── cluster-status.sh             # Canlı cluster durum dashboard'u
├── recovery.sh                   # Split-brain recovery scripti
├── repl-write.sh                 # Replication lag test — yazma
├── repl-read.sh                  # Replication lag test — okuma
├── repl-metrics.sh               # Galera wsrep metrik monitörü
├── haproxy/
│   ├── haproxy1.cfg              # HAProxy 1 konfigürasyonu
│   └── haproxy2.cfg              # HAProxy 2 konfigürasyonu
├── pxc-config/
│   ├── pxc1.cnf                  # PXC Node 1 — bootstrap (gcomm://)
│   ├── pxc2.cnf                  # PXC Node 2 — gcomm://pxc1,pxc2,pxc3
│   └── pxc3.cnf                  # PXC Node 3 — gcomm://pxc1,pxc2,pxc3
└── secrets/
    ├── mysql_root_password.txt   # Root şifresi (setup.sh tarafından üretilir)
    └── xtrabackup_password.txt   # XtraBackup şifresi (setup.sh tarafından üretilir)
```

---

## Kurulum

```bash
git clone <repo-url>
cd pxc-ha-case
chmod +x setup.sh
./setup.sh
```

`setup.sh` sırasıyla şunları yapar:

1. `openssl rand` ile güçlü rastgele şifreler üretir
2. PMM Server'ı başlatır, 45 saniye sağlık kontrolü bekler
3. pxc1'i bootstrap eder (`gcomm://`), 60 saniye bekler
4. pxc2 ve pxc3'ü join eder, SST ile senkronize olurlar
5. HAProxy 1 ve 2'yi başlatır
6. `haproxy_check` kullanıcısı oluşturur (şifresiz, sadece health check)
7. `pmm` kullanıcısı oluşturur
8. `wsrep_cluster_size=3` olana kadar bekler (max 5 dakika)
9. pxc1 config'ini günceller: `gcomm://` → `gcomm://pxc1,pxc2,pxc3`
10. Her node'u PMM'e REST API üzerinden kaydeder

### Servis Bağımlılık Zinciri

```
pmm-server
    └── pxc1 (bootstrap)
            └── pxc2 (joins pxc1)
                    └── pxc3 (joins pxc2)
                            └── haproxy1, haproxy2
                                    └── pmm-client-pxc1/2/3
```

Her servis bir öncekinin `healthy` durumuna ulaşmasını bekler — race condition olmadan sıralı başlatma.

---

## Erişim

| Servis | Adres | Kullanıcı |
|--------|-------|-----------|
| MySQL Write | `localhost:3306` / `localhost:3316` | root / secrets dosyası |
| MySQL Read | `localhost:3307` / `localhost:3317` | root / secrets dosyası |
| HAProxy Stats | `http://localhost:8404/stats` | admin / admin |
| HAProxy Stats | `http://localhost:8405/stats` | admin / admin |
| PMM Dashboard | `https://localhost` | admin / admin |
| pxc1 Direct | `localhost:3311` | — |
| pxc2 Direct | `localhost:3312` | — |
| pxc3 Direct | `localhost:3313` | — |

Root şifresine erişmek için:
```bash
cat secrets/mysql_root_password.txt
```

---

## HAProxy Yük Dağılımı

**Write (`:3306` / `:3316`)** — `balance first`  
pxc1 sağlıklı olduğu sürece tüm write trafiği oraya gider. pxc1 düşerse pxc2 devralır.

**Read (`:3307` / `:3317`)** — `balance roundrobin`  
3 node arasında eşit dağılım. Galera synchronous replication sayesinde hangi node'dan okunursa okunsun veri aynıdır.

**Health Check:** `mysql-check user haproxy_check` — 3 saniyede bir, 3 başarısızlıkta DOWN, 2 başarıda UP.

---

## Cluster Durumu

```bash
./cluster-status.sh
```

Manuel kontrol:
```bash
docker exec pxc1 mysql -uroot -p$(cat secrets/mysql_root_password.txt) \
  -e "SHOW STATUS LIKE 'wsrep%';"
```

---

## Sağlıklı Kapatma

Galera için sıralı kapatma önemlidir — en son kapanan node `safe_to_bootstrap: 1` olarak işaretlenir.

```bash
docker compose stop pxc3 pxc2 pxc1 haproxy1 haproxy2 pmm-server
```

## Yeniden Başlatma

```bash
docker compose start pxc1
# pxc1 healthy olduktan sonra
docker compose start pxc2 pxc3 haproxy1 haproxy2 pmm-server
```

---

## Split-Brain Recovery

Cluster NON-PRIMARY durumuna düşerse:

```bash
./recovery.sh
```

Manuel adımlar için `recovery.sh` dosyasını inceleyin.

---

## Backup / Restore (XtraBackup)

```bash
# Backup
docker run --rm \
  --network pxc-ha-case_pxc-network \
  -v pxc-ha-case_pxc1-data:/var/lib/mysql:ro \
  -v $(pwd)/backups:/backups \
  percona/percona-xtrabackup:8.0 \
  xtrabackup --backup \
    --host=pxc1 \
    --user=root \
    --password=$(cat secrets/mysql_root_password.txt) \
    --target-dir=/backups/$(date +%Y%m%d_%H%M%S) \
    --no-server-version-check

# Prepare
docker run --rm -v $(pwd)/backups:/backups \
  percona/percona-xtrabackup:8.0 \
  xtrabackup --prepare --target-dir=/backups/<TIMESTAMP>
```

---

## Galera Quorum

| Node Durumu | Cluster | Yazma |
|-------------|---------|-------|
| 3/3 node | PRIMARY | ✓ Açık |
| 2/3 node | PRIMARY | ✓ Açık |
| 1/3 node | NON-PRIMARY | ✗ Kapalı |

---

## Gereksinimler

- Docker Engine 24+
- Docker Compose v2
- 4GB+ RAM (3 PXC node + HAProxy + PMM)
- macOS / Linux

---

## Notlar

- `pxc_encrypt_cluster_traffic = OFF` — lab ortamı için. Production'da `ON` yapılmalı.
- HAProxy çift kurulum Keepalived olmadan çalışır — farklı portlar üzerinden (3306/3316). VIP failover için Keepalived eklenmeli.
- PMM node kaydı otomatik kurulumda zaman zaman timing sorunu yaşayabilir, elle UI üzerinden eklenebilir.
