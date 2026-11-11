# Step 3: Zero-Trust authorization policies (design)

Date: 2026-11-11. Owner: Michał Domagała. Schedule: week 7, final deadline 27.11.2026.

## 1. Goal

After step 2 every connection in the mesh is encrypted and authenticated (mTLS), but
every service still accepts requests from anyone. Step 3 adds **authorization**: each
service accepts only the callers and the operations that Online Boutique really needs.

Success means:

1. The shop keeps working end to end (browse, add to cart, place an order).
2. The stage 2 attack (`stage2/evidence/09-attack-no-policies.txt`) is rejected with
   gRPC `PermissionDenied` from both attacker pods.
3. The policies can be switched on and off without restarting pods, so step 5 can show
   the same attack before and after.

Out of scope: Grafana/Prometheus dashboards (step 4, Kacper) and the full attack
scenario and its presentation (step 5). Step 3 only delivers the minimal attack
tooling needed to verify the policies; step 5 builds on it.

## 2. What the spike established (2026-11-11, Linkerd edge-26.11.1)

Tested on `paymentservice` and `redis-cart`, then removed.

- A `Server` with no authorization denies everything on its port, **including kubelet
  gRPC probes**: the pod went `1/2` and the container was restarted.
- Probes need their own route (`grpc.health.v1.Health/Check`) authorized by network,
  because the kubelet has no mesh identity.
- Once a `Server` has any route attached, a request matching no route is rejected
  (`grpc-status: 5`, "no route found"). Application methods therefore need routes too.
- `GRPCRoute` (`gateway.networking.k8s.io/v1`) works as a parent-ref'd route on a
  `Server` and as an `AuthorizationPolicy` target.
- With a route for `PaymentService/Charge` authorized for the `checkoutservice`
  identity: checkout succeeded, both attacker pods got `grpc-status: 7`.
- Probe authorization restricted to the node gateway addresses `10.42.0.1`,
  `10.42.1.1`, `10.42.2.1` keeps pods Ready and denies attackers on the health endpoint.
- `redis-cart` (opaque TCP): `cartservice` allowed, attackers cut off, pod stays Ready.
  Its `tcpSocket` probes still succeed but are counted as denied connections.

Not covered by the spike, verified during implementation: `frontend` (HTTP, traffic
from outside the mesh, `httpGet` probes), the namespace default-deny annotation, the
proxy admin port, and audit mode.

## 3. Approach

Per-method (L7) authorization for all nine gRPC services, port-level authorization for
`frontend` (public HTTP entry point) and `redis-cart` (opaque TCP). Since routes are
mandatory anyway (section 2), per-method routes cost little more than per-port ones.

Rejected alternatives:

- **Port-level identity only.** Still needs a probe route plus a catch-all route per
  service, so it saves almost nothing and gives coarser least privilege.
- **Kubernetes `NetworkPolicy`.** Based on IPs and labels, not cryptographic identity,
  and has no notion of gRPC methods. Kept as a comparison point for the report.

## 4. Authorization matrix

Identities are Kubernetes ServiceAccounts in namespace `default`. Caller/method pairs
come from the Online Boutique source and the 16 edges in `stage2/evidence/04-edges.txt`;
implementation confirms them by observing zero denials for legitimate identities
during a full order flow (section 8).

| Service (port) | Method | Allowed callers |
|---|---|---|
| `adservice` (9555) | `hipstershop.AdService/GetAds` | frontend |
| `recommendationservice` (8080) | `hipstershop.RecommendationService/ListRecommendations` | frontend |
| `checkoutservice` (5050) | `hipstershop.CheckoutService/PlaceOrder` | frontend |
| `paymentservice` (50051) | `hipstershop.PaymentService/Charge` | checkoutservice |
| `emailservice` (8080) | `hipstershop.EmailService/SendOrderConfirmation` | checkoutservice |
| `cartservice` (7070) | `hipstershop.CartService/GetCart`, `EmptyCart` | frontend, checkoutservice |
| | `hipstershop.CartService/AddItem` | frontend |
| `currencyservice` (7000) | `hipstershop.CurrencyService/Convert` | frontend, checkoutservice |
| | `hipstershop.CurrencyService/GetSupportedCurrencies` | frontend |
| `shippingservice` (50051) | `hipstershop.ShippingService/GetQuote` | frontend, checkoutservice |
| | `hipstershop.ShippingService/ShipOrder` | checkoutservice |
| `productcatalogservice` (3550) | `hipstershop.ProductCatalogService/GetProduct` | frontend, checkoutservice |
| | `hipstershop.ProductCatalogService/ListProducts` | frontend, recommendationservice |
| | `hipstershop.ProductCatalogService/SearchProducts` | nobody (no route) |
| all nine above | `grpc.health.v1.Health/Check` | kubelet (node addresses) |
| `frontend` (8080, HTTP) | everything | any network (public entry point) |
| `redis-cart` (6379, opaque) | whole port | cartservice; kubelet (node addresses) |

`loadgenerator` receives no traffic and gets no `Server`.

## 5. Resources

All in namespace `default`, all labelled `app.kubernetes.io/part-of: zero-trust-policies`.

**Shared authentications** (one file):

- `MeshTLSAuthentication` per distinct caller set, because the refs inside one
  `AuthorizationPolicy` are ANDed and "frontend or checkout" must be one object:
  `callers-frontend`, `callers-checkout`, `callers-frontend-checkout`,
  `callers-frontend-recommendation`, `callers-cart`.
- `NetworkAuthentication` `kubelet-probes`: `10.42.0.1/32`, `10.42.1.1/32`,
  `10.42.2.1/32`. These follow from the three nodes in `cluster/k3d-config.yaml`;
  the file carries a comment saying so.
- `NetworkAuthentication` `any-network`: `0.0.0.0/0` and `::/0`, used only by `frontend`.

**Per gRPC service** (one file each):

- one `Server` (`policy.linkerd.io/v1beta3`, `proxyProtocol: gRPC`, pod selector `app: <name>`);
- one `GRPCRoute` `<svc>-health` plus an `AuthorizationPolicy` requiring `kubelet-probes`;
- one `GRPCRoute` per row of the matrix (methods with the same caller set share a
  route), each with an `AuthorizationPolicy` requiring the matching `callers-*`.

**`frontend`:** `Server` (`proxyProtocol: HTTP/1`) and one `AuthorizationPolicy` on the
`Server` requiring `any-network`. No routes, so probes, the k3d load balancer and
`loadgenerator` are all covered.

**`redis-cart`:** `Server` (`proxyProtocol: opaque`) and two `AuthorizationPolicy`
objects on the `Server`: one requiring `callers-cart`, one requiring `kubelet-probes`
(keeps probe connections out of the denial counters that step 4 will chart).

## 6. Repository layout

```
policies/
  00-authentications.yaml
  adservice.yaml  cartservice.yaml  checkoutservice.yaml  currencyservice.yaml
  emailservice.yaml  frontend.yaml  paymentservice.yaml  productcatalogservice.yaml
  recommendationservice.yaml  redis-cart.yaml  shippingservice.yaml
  namespace-default-deny/        # phase 2, see section 7
  README.md                      # matrix, how to apply/remove, how to verify
attack/
  attackers.yaml                 # test pods
  attack.sh                      # one gRPC call from a pod, prints status
  verify.sh                      # full check, section 8
stage3/evidence/                 # captured outputs for the report
```

`app/kubernetes-manifests.yaml` stays the unmodified upstream file. `setup.sh` and
`setup.ps1` keep producing the unprotected, meshed cluster (the "before" state);
`cluster/README.md` gains a short section pointing to `policies/README.md`.

## 7. Rollout

**Phase 1: per-port Servers (the core deliverable).**

1. `kubectl apply -f policies/` with every `Server` set to `accessPolicy: audit`.
   Run a full order flow and confirm from proxy metrics and logs that no legitimate
   request would have been denied. The exact audit signal is identified in the first
   implementation task; if audit mode does not cover unmatched routes, this step is
   replaced by applying one service at a time and watching `inbound_http_authz_deny_total`.
2. Switch to enforcing (remove `accessPolicy: audit`) and run `attack/verify.sh`.
3. On/off for the demo: `kubectl apply -f policies/` and
   `kubectl delete -f policies/`. No pod restarts.

**Phase 2: namespace default-deny (hardening, done after phase 1 is verified).**

Phase 1 leaves ports without a `Server` on the default `all-unauthenticated` policy;
in practice that is the proxy admin port 4191, which exposes metrics to any pod.

1. Annotate namespace `default` with `config.linkerd.io/default-inbound-policy: deny`
   and `kubectl rollout restart` the deployments (the proxy reads the default at start).
2. Add to `policies/namespace-default-deny/` a `Server` for the admin port with routes
   for the proxy's own probes (`/live`, `/ready`, authorized by `kubelet-probes`) and
   for `/metrics` (authorized for the `prometheus` ServiceAccount in `linkerd-viz`,
   the scraper step 4 starts with).
3. Re-run `attack/verify.sh`.

Phase 2 changes what step 4 can scrape, so it is applied only after agreeing the
scraper identity with Kacper. If he moves to a different Prometheus, the single
`MeshTLSAuthentication` for the scraper changes. Phase 2 does not block step 5.

## 8. Verification

`attack/attackers.yaml` defines three pods running `curlimages/curl`:

- `attacker-outside`: not meshed;
- `attacker-as-adservice`: meshed, ServiceAccount `adservice` (a compromised minor service);
- `attacker-as-frontend`: meshed, ServiceAccount `frontend` (a compromised service
  that has some legitimate access).

`attack/verify.sh` (bash; Windows users run it from Git Bash or WSL) exits non-zero on
any mismatch and prints one line per case:

| Case | From | Expected with policies |
|---|---|---|
| Every method in the matrix | `attacker-outside`, `attacker-as-adservice` | `grpc-status: 7` |
| `PaymentService/Charge`, `ShippingService/ShipOrder`, `EmailService/SendOrderConfirmation` | `attacker-as-frontend` | `grpc-status: 7` |
| `ShippingService/GetQuote` | `attacker-as-frontend` | not 7 (reaches the app) |
| `ProductCatalogService/SearchProducts` | all three | `grpc-status: 5` (no route) |
| `Health/Check` on `paymentservice` | all three | `grpc-status: 7` |
| Redis `PING` to `redis-cart:6379` | all three | no `PONG` |
| Home page, add to cart, checkout through `localhost:8080` | host | HTTP 200, order confirmation page |
| All application pods | cluster | `2/2 Ready`, restart counts unchanged during the run |
| Proxy metrics on every service | cluster | no `inbound_http_authz_deny_total` for the identities allowed in the matrix |

The script has a `--expect-open` mode for the "before" state, in which the attack
cases must succeed. Outputs of both modes go to `stage3/evidence/`.

## 9. Risks

- **A missed caller/method pair** breaks one path while the rest of the shop works.
  Mitigated by the audit step and the end-to-end order in `verify.sh`.
- **Probe addresses are tied to a three-node cluster.** A different node count makes
  pods on the extra node unready. Documented next to the CIDRs and in the README.
- **`frontend` and phase 2 are unverified** by the spike; each is the first thing its
  implementation task checks, before anything is built on top of it.
- **Edge release behaviour.** Everything is validated against the pinned edge-26.11.1 only.
