#!/usr/bin/env bash
# Lateral-movement attack: two attacker pods call services they have no business calling.
# Prints one line per call. Requires: kubectl apply -f attack/attackers.yaml
set -uo pipefail
. "$(dirname "$0")/lib.sh"

ATTACKERS="attacker-outside attacker-as-adservice"
TARGETS="paymentservice:50051/hipstershop.PaymentService/Charge cartservice:7070/hipstershop.CartService/GetCart"

for pod in $ATTACKERS; do
  for target in $TARGETS; do
    read -r http status msg <<<"$(grpc_call "$pod" "$target")"
    printf '%-22s -> %-58s HTTP %s  grpc-status: %s  %s\n' "$pod" "$target" "$http" "$status" "$msg"
  done
done
