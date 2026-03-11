#!/usr/bin/env bash
PASS=bXjAoIU3QpMBaxF7H2j2

mysql -h pxc1 -uroot -p$PASS testdb -e "
CREATE TABLE IF NOT EXISTS repl_test (
  id INT AUTO_INCREMENT PRIMARY KEY,
  val VARCHAR(100),
  written_at TIMESTAMP(6) DEFAULT CURRENT_TIMESTAMP(6),
  written_by VARCHAR(50)
);" 2>/dev/null

i=0
while true; do
  i=$((i+1))
  mysql -h pxc1 -uroot -p$PASS testdb \
    -e "INSERT INTO repl_test (val, written_by) VALUES ('batch-$i', @@hostname);" 2>/dev/null
  echo "$(date '+%H:%M:%S') → Wrote batch-$i to pxc1"
  sleep 0.5
done
