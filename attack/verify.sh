#!/usr/bin/env bash
# Checks the authorization policies end to end.
#   attack/verify.sh                policies applied: attacks must be denied, the shop must work
#   attack/verify.sh --expect-open  no policies: attacks must reach the services, the shop must work
# Exits 1 if any case fails. Requires: kubectl apply -f attack/attackers.yaml
set -uo pipefail
. "$(dirname "$0")/lib.sh"

MODE=enforced
case "${1:-}" in
  "") ;;
  --expect-open) MODE=open ;;
  *) echo "usage: $0 [--expect-open]" >&2; exit 2 ;;
esac

SHOP=${SHOP_URL:-http://localhost:8080}
ALL="attacker-outside attacker-as-adservice attacker-as-frontend"
STRANGERS="attacker-outside attacker-as-adservice"

# Every method the shop uses (the allow-matrix in policies/README.md).
METHODS="
adservice:9555/hipstershop.AdService/GetAds
recommendationservice:8080/hipstershop.RecommendationService/ListRecommendations
checkoutservice:5050/hipstershop.CheckoutService/PlaceOrder
paymentservice:50051/hipstershop.PaymentService/Charge
emailservice:5000/hipstershop.EmailService/SendOrderConfirmation
cartservice:7070/hipstershop.CartService/GetCart
cartservice:7070/hipstershop.CartService/EmptyCart
cartservice:7070/hipstershop.CartService/AddItem
currencyservice:7000/hipstershop.CurrencyService/Convert
currencyservice:7000/hipstershop.CurrencyService/GetSupportedCurrencies
shippingservice:50051/hipstershop.ShippingService/GetQuote
shippingservice:50051/hipstershop.ShippingService/ShipOrder
productcatalogservice:3550/hipstershop.ProductCatalogService/GetProduct
productcatalogservice:3550/hipstershop.ProductCatalogService/ListProducts
"
# Methods the frontend identity has no reason to call.
FRONTEND_FORBIDDEN="
paymentservice:50051/hipstershop.PaymentService/Charge
shippingservice:50051/hipstershop.ShippingService/ShipOrder
emailservice:5000/hipstershop.EmailService/SendOrderConfirmation
"

fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1: expected $2, got $3"; fails=$((fails + 1)); }

# check_status <pod> <target> <denied|reached|noroute>
check_status() {
  local pod=$1 target=$2 want=$3 http status msg name
  read -r http status msg <<<"$(grpc_call "$pod" "$target")"
  name="$pod -> $target"
  case "$want" in
    denied)  [ "$status" = 7 ] && pass "$name (denied)" || fail "$name" "grpc-status 7" "$status" ;;
    noroute) [ "$status" = 5 ] && pass "$name (no route)" || fail "$name" "grpc-status 5" "$status" ;;
    reached) case "$status" in
               7|none|"") fail "$name" "a reply from the application" "$status" ;;
               *) pass "$name (reached the application, grpc-status $status)" ;;
             esac ;;
  esac
}

restarts() { kubectl get pods -l 'app' -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[*].restartCount} {end}'; }

# ---- pre-flight -------------------------------------------------------------
nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if [ "$nodes" -ne 3 ]; then
  echo "Pre-flight failed: expected a 3-node cluster, found $nodes. The kubelet-probes addresses in policies/00-authentications.yaml assume the nodes from cluster/k3d-config.yaml." >&2
  exit 1
fi
for pod in $ALL; do
  ready=$(kubectl get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [ "$ready" != True ]; then
    echo "Pre-flight failed: pod $pod is missing or not Ready. Run: kubectl apply -f attack/attackers.yaml" >&2
    exit 1
  fi
done

echo "Mode: $MODE"
restarts_before=$(restarts)

# ---- attacks ----------------------------------------------------------------
if [ "$MODE" = enforced ]; then
  for pod in $STRANGERS; do for t in $METHODS; do check_status "$pod" "$t" denied; done; done
  for t in $FRONTEND_FORBIDDEN; do check_status attacker-as-frontend "$t" denied; done
  # The frontend identity keeps its legitimate access.
  check_status attacker-as-frontend shippingservice:50051/hipstershop.ShippingService/GetQuote reached
  for pod in $ALL; do
    check_status "$pod" productcatalogservice:3550/hipstershop.ProductCatalogService/SearchProducts noroute
    check_status "$pod" paymentservice:50051/grpc.health.v1.Health/Check denied
  done
else
  for pod in $STRANGERS; do for t in $METHODS; do check_status "$pod" "$t" reached; done; done
  for t in $FRONTEND_FORBIDDEN; do check_status attacker-as-frontend "$t" reached; done
  check_status attacker-as-frontend shippingservice:50051/hipstershop.ShippingService/GetQuote reached
  for pod in $ALL; do check_status "$pod" paymentservice:50051/grpc.health.v1.Health/Check reached; done
fi

for pod in $ALL; do
  answer=$(redis_ping "$pod")
  if [ "$MODE" = enforced ]; then
    case "$answer" in *PONG*) fail "$pod -> redis-cart:6379 PING" "no answer" "$answer" ;; *) pass "$pod -> redis-cart:6379 PING (no answer)" ;; esac
  else
    case "$answer" in *PONG*) pass "$pod -> redis-cart:6379 PING (answered)" ;; *) fail "$pod -> redis-cart:6379 PING" "PONG" "${answer:-nothing}" ;; esac
  fi
done

# ---- the shop still works ---------------------------------------------------
jar=$(mktemp); body=$(mktemp); trap 'rm -f "$jar" "$body"' EXIT
shop() { curl -s -L -m 30 -c "$jar" -b "$jar" -o "$body" -w '%{http_code}' "$@"; }

code=$(shop "$SHOP/")
[ "$code" = 200 ] && pass "shop: home page" || fail "shop: home page" "HTTP 200" "$code"
code=$(shop -d 'product_id=OLJCESPC7Z&quantity=1' "$SHOP/cart")
[ "$code" = 200 ] && pass "shop: add to cart" || fail "shop: add to cart" "HTTP 200" "$code"
code=$(shop "$SHOP/cart/checkout" \
  -d 'email=someone@example.com' -d 'street_address=1600 Amphitheatre Parkway' -d 'zip_code=94043' \
  -d 'city=Mountain View' -d 'state=CA' -d 'country=United States' \
  -d 'credit_card_number=4432801561520454' -d 'credit_card_expiration_month=1' \
  -d 'credit_card_expiration_year=2030' -d 'credit_card_cvv=672')
if [ "$code" = 200 ] && grep -q 'Your order is complete' "$body"; then
  pass "shop: checkout (order confirmed)"
else
  fail "shop: checkout" "HTTP 200 with an order confirmation" "HTTP $code"
fi

# ---- pods stayed healthy ----------------------------------------------------
not_ready=$(kubectl get pods -l 'app' --no-headers | awk '$2 != "2/2" {print $1 "(" $2 ")"}' | tr '\n' ' ')
[ -z "$not_ready" ] && pass "pods: all application pods are 2/2" || fail "pods: readiness" "all 2/2" "$not_ready"
restarts_after=$(restarts)
[ "$restarts_before" = "$restarts_after" ] && pass "pods: no restarts during the run" || fail "pods: restarts" "$restarts_before" "$restarts_after"

echo
if [ "$fails" -eq 0 ]; then echo "All cases passed."; else echo "$fails case(s) failed."; exit 1; fi
