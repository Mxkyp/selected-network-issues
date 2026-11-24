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
               # With policies, status 5 can also mean "no route found" in the proxy, i.e. a
               # missing or broken route. Without policies it is the application's own NOT_FOUND.
               5) if [ "$MODE" = enforced ]; then fail "$name" "a reply from the application" "5 ($msg)"
                  else pass "$name (reached the application, grpc-status 5)"; fi ;;
               *) pass "$name (reached the application, grpc-status $status)" ;;
             esac ;;
  esac
}

# Allowed (route, caller) pairs from the allow-matrix, as the proxies label them.
ALLOWED="
paymentservice-charge:checkoutservice
adservice-getads:frontend
recommendationservice-list:frontend
checkoutservice-placeorder:frontend
emailservice-send:checkoutservice
cartservice-read:frontend cartservice-read:checkoutservice
cartservice-additem:frontend
currencyservice-convert:frontend currencyservice-convert:checkoutservice
currencyservice-supported:frontend
shippingservice-quote:frontend shippingservice-quote:checkoutservice
shippingservice-shiporder:checkoutservice
productcatalogservice-getproduct:frontend productcatalogservice-getproduct:checkoutservice
productcatalogservice-list:frontend productcatalogservice-list:recommendationservice
redis-cart:cartservice
"
SERVERS="adservice recommendationservice checkoutservice paymentservice emailservice cartservice currencyservice shippingservice productcatalogservice frontend redis-cart"

# legit_denials: prints "<key> <count>" for denials of legitimate callers, where key is
#   <route>:<caller>           a caller denied on a route it is allowed to use
#   <server>:noroute:<caller>  a caller that may use some route of the server, denied because its
#                              request matched no route (a method missing from the policies)
# Any identity denied by the frontend counts, since the frontend is open to everyone.
# Counters are cumulative since the proxy started, so compare two snapshots.
legit_denials() {
  local s
  for s in $SERVERS; do
    linkerd diagnostics proxy-metrics -n default "deploy/$s" 2>/dev/null \
      | grep -E '^inbound_(http|tcp)_authz_deny_total'
  done | awk -v allowed="$ALLOWED" '
    function label(name,   r) { r = ""; if (match($0, name "=\"[^\"]*\"")) r = substr($0, RSTART + length(name) + 2, RLENGTH - length(name) - 3); return r }
    BEGIN {
      n = split(allowed, a, /[ \n]+/)
      for (i = 1; i <= n; i++) if (a[i] != "") {
        ok[a[i]] = 1; split(a[i], p, ":"); srv = p[1]; sub(/-[a-z]+$/, "", srv); may[srv ":" p[2]] = 1
      }
    }
    {
      srv = label("srv_name"); route = label("route_name"); caller = label("client_id"); sub(/\..*/, "", caller)
      if (caller == "") next
      if (srv == "frontend")                                  key = "frontend:" caller
      else if ($0 ~ /^inbound_tcp/) { if (ok[srv ":" caller]) key = srv ":" caller; else next }
      else if (route == "default") { if (may[srv ":" caller]) key = srv ":noroute:" caller; else next }
      else if (ok[route ":" caller])                           key = route ":" caller
      else next
      sum[key] += $NF
    }
    END { for (k in sum) print k, sum[k] }' | sort
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
  # Each attacker must have the identity it claims, otherwise the test proves nothing about it.
  info=$(kubectl get pod "$pod" -o jsonpath='{.spec.serviceAccountName} {.spec.initContainers[*].name} {.spec.containers[*].name}')
  sa=${info%% *}
  case "$pod" in
    attacker-outside) want_sa=default; want_proxy=no ;;
    attacker-as-*)    want_sa=${pod#attacker-as-}; want_proxy=yes ;;
  esac
  case " $info " in *" linkerd-proxy "*) has_proxy=yes ;; *) has_proxy=no ;; esac
  if [ "$sa" != "$want_sa" ] || [ "$has_proxy" != "$want_proxy" ]; then
    echo "Pre-flight failed: pod $pod has ServiceAccount '$sa' and Linkerd proxy: $has_proxy; expected '$want_sa' and proxy: $want_proxy. Recreate it: kubectl delete pod $pod && kubectl apply -f attack/attackers.yaml" >&2
    exit 1
  fi
done
if [ "$MODE" = enforced ] && ! command -v linkerd >/dev/null; then
  echo "Pre-flight failed: the linkerd CLI is needed to read the proxies' denial counters (run setup.sh once)." >&2
  exit 1
fi

echo "Mode: $MODE"
restarts_before=$(restarts)
[ "$MODE" = enforced ] && denials_before=$(legit_denials)

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
if [ "$MODE" = enforced ]; then
  # Covers every legitimate path the loadgenerator exercised during the run, not only the order above.
  new=$(join -a 2 -e 0 -o 0,1.2,2.2 <(printf '%s\n' "$denials_before") <(legit_denials) | awk '$3 > $2 {print $1 " +" ($3 - $2)}' | tr '\n' ' ')
  [ -z "$new" ] && pass "proxies: no allowed caller was denied during the run" || fail "proxies: allowed callers denied" "none" "$new"
fi
restarts_after=$(restarts)
[ "$restarts_before" = "$restarts_after" ] && pass "pods: no restarts during the run" || fail "pods: restarts" "$restarts_before" "$restarts_after"

echo
if [ "$fails" -eq 0 ]; then echo "All cases passed."; else echo "$fails case(s) failed."; exit 1; fi
