#!/usr/bin/env bash
PASS=bXjAoIU3QpMBaxF7H2j2

while true; do
  echo "=== $(date '+%H:%M:%S') ==="
  for NODE in pxc1 pxc2 pxc3; do
    RECV=$(mysql -h $NODE -uroot -p$PASS \
      -se "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='wsrep_local_recv_queue';" 2>/dev/null)
    FLOW=$(mysql -h $NODE -uroot -p$PASS \
      -se "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='wsrep_flow_control_paused';" 2>/dev/null)
    CERT=$(mysql -h $NODE -uroot -p$PASS \
      -se "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='wsrep_cert_deps_distance';" 2>/dev/null)
    STATE=$(mysql -h $NODE -uroot -p$PASS \
      -se "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='wsrep_local_state_comment';" 2>/dev/null)
    echo "  $NODE | state: ${STATE:-ERR} | recv_queue: ${RECV:-ERR} | flow_paused: ${FLOW:-ERR} | cert_dist: ${CERT:-ERR}"
  done
  echo ""
  sleep 2
done
