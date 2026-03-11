MYSQL_PASS=$(cat secrets/mysql_root_password.txt)

RESP=$(curl -s -k -u admin:admin \
  -X POST "https://localhost/v1/management/Node/Register" \
  -H "Content-Type: application/json" \
  -d '{"node_type":"CONTAINER_NODE","node_name":"pxc1-test","address":"pxc1","force_register":true}')

NODE_ID=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('container_node',{}).get('node_id',''))" 2>/dev/null)
AGENT_ID=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('pmm_agent',{}).get('agent_id',''))" 2>/dev/null)

echo "NODE_ID: $NODE_ID"
echo "AGENT_ID: $AGENT_ID"

echo "=== MySQL Add Response ==="
curl -s -k -u admin:admin \
  -X POST "https://localhost/v1/management/MySQL/Add" \
  -H "Content-Type: application/json" \
  -d "{
    \"node_id\": \"${NODE_ID}\",
    \"pmm_agent_id\": \"${AGENT_ID}\",
    \"service_name\": \"pxc1-test-mysql\",
    \"address\": \"pxc1\",
    \"port\": 3306,
    \"username\": \"root\",
    \"password\": \"${MYSQL_PASS}\",
    \"query_source\": \"perfschema\",
    \"skip_connection_check\": false
  }"
