#!/usr/bin/env bash
# PMM node temizle + kaydet

MYSQL_PASS=$(cat secrets/mysql_root_password.txt)

echo "=== Mevcut node'ları listele ==="
curl -s -k -u admin:admin \
  -X POST "https://localhost/v1/inventory/Nodes" \
  -H "Content-Type: application/json" \
  -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
for key in d:
    for n in d[key]:
        if isinstance(n, dict):
            print(key, '-', n.get('node_name'), '-', n.get('node_id'))
"

echo ""
echo "=== Eski node'ları sil ==="
for NAME in test-node pxc1 pxc2 pxc3; do
  NODE_ID=$(curl -s -k -u admin:admin \
    -X POST "https://localhost/v1/inventory/Nodes" \
    -H "Content-Type: application/json" \
    -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
for key in d:
    for n in d[key]:
        if isinstance(n, dict) and n.get('node_name') == '${NAME}':
            print(n.get('node_id', ''))
" 2>/dev/null)

  if [[ -n "$NODE_ID" ]]; then
    DELRESP=$(curl -s -k -u admin:admin \
      -X POST "https://localhost/v1/inventory/Nodes/Remove" \
      -H "Content-Type: application/json" \
      -d "{\"node_id\":\"${NODE_ID}\",\"force\":true}")
    echo "Deleted ${NAME}: $DELRESP"
  else
    echo "Not found: ${NAME}"
  fi
done

echo ""
echo "=== Node'ları kaydet ==="
for NODE in pxc1 pxc2 pxc3; do
  case $NODE in
    pxc1) NODE_IP="172.20.0.11" ;;
    pxc2) NODE_IP="172.20.0.12" ;;
    pxc3) NODE_IP="172.20.0.13" ;;
  esac

  echo "--- $NODE ($NODE_IP) ---"

  RESP=$(curl -s -k -u admin:admin \
    -X POST "https://localhost/v1/management/Node/Register" \
    -H "Content-Type: application/json" \
    -d "{\"node_type\":\"CONTAINER_NODE\",\"node_name\":\"${NODE}\",\"address\":\"${NODE_IP}\",\"force_register\":true}")

  echo "Register response: $RESP"

  NODE_ID=$(echo "$RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('container_node', {}).get('node_id', ''))
" 2>/dev/null)

  AGENT_ID=$(echo "$RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('pmm_agent', {}).get('agent_id', ''))
" 2>/dev/null)

  echo "Node ID:  $NODE_ID"
  echo "Agent ID: $AGENT_ID"

  if [[ -z "$NODE_ID" || -z "$AGENT_ID" ]]; then
    echo "ERROR: Could not get node_id or agent_id, skipping service add"
    continue
  fi

  SVCRESP=$(curl -s -k -u admin:admin \
    -X POST "https://localhost/v1/management/MySQL/Add" \
    -H "Content-Type: application/json" \
    -d "{
      \"node_id\": \"${NODE_ID}\",
      \"pmm_agent_id\": \"${AGENT_ID}\",
      \"service_name\": \"${NODE}-mysql\",
      \"address\": \"${NODE_IP}\",
      \"port\": 3306,
      \"username\": \"pmm\",
      \"password\": \"pmmpass\",
      \"query_source\": \"perfschema\",
      \"skip_connection_check\": true
    }")

  echo "Service response: $SVCRESP"
  echo ""
done
