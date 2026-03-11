#!/usr/bin/env bash
# ═══════════════════════════════════════════════
#  PXC Cluster Recovery — Find best node & bootstrap
# ═══════════════════════════════════════════════

echo ""
echo "=== GRASTATE.DAT — seqno & safe_to_bootstrap ==="
echo ""

BEST_NODE=""
BEST_SEQNO=-1

for NODE in pxc1 pxc2 pxc3; do
  GRASTATE=$(docker exec $NODE cat /var/lib/mysql/grastate.dat 2>/dev/null)
  if [[ -z "$GRASTATE" ]]; then
    echo "$NODE → OFFLINE or no data"
    continue
  fi
  SEQNO=$(echo "$GRASTATE" | grep seqno | awk '{print $2}')
  SAFE=$(echo "$GRASTATE" | grep safe_to_bootstrap | awk '{print $2}')
  UUID=$(echo "$GRASTATE" | grep uuid | awk '{print $2}')
  echo "$NODE → seqno: $SEQNO | safe_to_bootstrap: $SAFE | uuid: $UUID"

  if [[ "$SEQNO" -gt "$BEST_SEQNO" ]] 2>/dev/null; then
    BEST_SEQNO=$SEQNO
    BEST_NODE=$NODE
  fi
done

echo ""
echo "=== Best node to bootstrap: $BEST_NODE (seqno: $BEST_SEQNO) ==="
echo ""
echo "Run the following to recover:"
echo ""
echo "  docker exec $BEST_NODE sed -i 's/safe_to_bootstrap: 0/safe_to_bootstrap: 1/' /var/lib/mysql/grastate.dat"
echo "  docker restart $BEST_NODE"
echo "  sleep 20"
echo "  docker start pxc1 pxc2 pxc3"
