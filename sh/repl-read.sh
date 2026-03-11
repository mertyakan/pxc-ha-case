#!/usr/bin/env bash
PASS=bXjAoIU3QpMBaxF7H2j2

while true; do
  C1=$(mysql -h pxc1 -uroot -p$PASS testdb -se "SELECT COUNT(*) FROM repl_test;" 2>/dev/null)
  C2=$(mysql -h pxc2 -uroot -p$PASS testdb -se "SELECT COUNT(*) FROM repl_test;" 2>/dev/null)
  C3=$(mysql -h pxc3 -uroot -p$PASS testdb -se "SELECT COUNT(*) FROM repl_test;" 2>/dev/null)

  if [[ "$C1" == "$C2" && "$C2" == "$C3" ]]; then
    SYNC="✓ IN SYNC"
  else
    SYNC="✗ OUT OF SYNC"
  fi

  echo "$(date '+%H:%M:%S') | pxc1: ${C1:-ERR} | pxc2: ${C2:-ERR} | pxc3: ${C3:-ERR} | $SYNC"
  sleep 0.5
done
