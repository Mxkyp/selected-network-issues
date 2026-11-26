# Zero-Trust authorization policies

mTLS (step 2) encrypts traffic and gives every service a cryptographic identity, but it
does not decide who may call whom: without these policies any pod can still call
`paymentservice`. The manifests here add that decision. Each service accepts only the
callers and the gRPC methods listed below, and everything else is denied by the
Linkerd proxy before it reaches the application.

## Allow-matrix

Identities are the ServiceAccounts of the calling pods (namespace `default`).

The matrix was taken from the Online Boutique source and confirmed against live traffic
(loadgenerator traffic plus orders placed by hand): `linkerd viz edges` showed which
services talk to each other, and `linkerd viz tap` which methods each caller uses. The
stage 3 report describes the capture.

| Service | Pod port | Method | Allowed callers |
|---|---|---|---|
| `adservice` | 9555 | `hipstershop.AdService/GetAds` | frontend |
| `recommendationservice` | 8080 | `hipstershop.RecommendationService/ListRecommendations` | frontend |
| `checkoutservice` | 5050 | `hipstershop.CheckoutService/PlaceOrder` | frontend |
| `paymentservice` | 50051 | `hipstershop.PaymentService/Charge` | checkoutservice |
| `emailservice` | 8080 (Service port 5000) | `hipstershop.EmailService/SendOrderConfirmation` | checkoutservice |
| `cartservice` | 7070 | `hipstershop.CartService/GetCart`, `EmptyCart` | frontend, checkoutservice |
| | | `hipstershop.CartService/AddItem` | frontend |
| `currencyservice` | 7000 | `hipstershop.CurrencyService/Convert` | frontend, checkoutservice |
| | | `hipstershop.CurrencyService/GetSupportedCurrencies` | frontend |
| `shippingservice` | 50051 | `hipstershop.ShippingService/GetQuote` | frontend, checkoutservice |
| | | `hipstershop.ShippingService/ShipOrder` | checkoutservice |
| `productcatalogservice` | 3550 | `hipstershop.ProductCatalogService/GetProduct` | frontend, checkoutservice |
| | | `hipstershop.ProductCatalogService/ListProducts` | frontend, recommendationservice |
| | | `hipstershop.ProductCatalogService/SearchProducts` | nobody (never called by the shop) |
| `redis-cart` | 6379 (TCP) | whole port | cartservice |
| `frontend` | 8080 (HTTP) | whole port | anyone (public entry point) |

`loadgenerator` receives no traffic, so it has no policy.

Traffic that is not service-to-service:

| Traffic | How it is allowed |
|---|---|
| Browsers → `frontend`, through the k3d load balancer on `localhost:8080` | `any-network` on the `frontend` port |
| `loadgenerator` → `frontend` | same |
| Kubelet health probes → every service (`grpc.health.v1.Health/Check`, `/_healthz`, TCP on Redis) | `kubelet-probes`: the node addresses `10.42.0.1`, `10.42.1.1`, `10.42.2.1` |
| Prometheus → proxy metrics on port 4191 | open in phase 1; restricted to the scraper in phase 2 (see "Namespace default-deny") |

## How the manifests are built

- `00-authentications.yaml`: who a caller can be. One `MeshTLSAuthentication` per set of
  allowed identities, plus two `NetworkAuthentication` objects for callers without a
  mesh identity.
- One file per service. A `Server` selects the service's port; each `GRPCRoute` selects
  one group of methods; each `AuthorizationPolicy` connects a route to the
  authentication that may use it.

A request is allowed only if it matches a route **and** the caller matches that route's
authentication. That gives an attacker two different answers:

| Request | Result |
|---|---|
| a real method, wrong caller | gRPC `PermissionDenied` (status 7) |
| a method with no route (for example `SearchProducts`) | gRPC `NotFound` (status 5) |

## Apply and remove

`setup.sh` leaves the cluster meshed but unprotected on purpose, so the attack can be
shown before and after (`setup.sh --protect` turns the policies and the namespace
default-deny on).

The simple way is `zero-trust.sh` in the repo root (Windows: `zero-trust.ps1`), which
also creates the attacker test pods and keeps the right order:

```bash
./zero-trust.sh on       # protect
./zero-trust.sh off      # back to the unprotected state
./zero-trust.sh status   # what is on right now
```

What it does, by hand, from the repo root:

```bash
export PATH="$PWD/.tools:$PATH"

# protect
kubectl apply -f policies/

# back to the unprotected state
kubectl delete server,grpcroute,authorizationpolicy,meshtlsauthentication,networkauthentication \
  -l app.kubernetes.io/part-of=zero-trust-policies
```

Both take effect within a few seconds and restart nothing.

The order of objects matters, because a `Server` without its authorizations denies
everything on its port:

- In every file the `Server` is the last object, so `kubectl apply` creates the routes
  and authorizations first.
- The delete command lists `server` first for the same reason. Do not use
  `kubectl delete -f policies/`: it would remove the authorizations before the
  `Server`s and the shop would answer with errors for a moment.

Removing the policies this way denied no legitimate request in our tests. Applying them
can still deny a few: for a second or two after a `Server` appears, its proxy may not
have the routes yet and answers "no route found". In three remove/apply cycles this hit
0 to 5 requests from the `frontend` per apply (loadgenerator traffic), and an occasional
kubelet probe. One failed probe does not restart a pod. For a demo, apply the policies
a few seconds before showing the attack.

Re-running `kubectl apply -f policies/` prints `configured` for the `GRPCRoute` objects
every time. Nothing changes in the cluster (their generation stays the same); it is
only how `kubectl` compares routes.

## Verify

```bash
kubectl apply -f attack/attackers.yaml   # three test pods, once
attack/verify.sh                         # with policies: attacks denied, shop works
attack/verify.sh --expect-open           # without policies: attacks reach the services
```

`verify.sh` calls every method of the matrix from a pod outside the mesh and from a
meshed pod with the `adservice` identity, tries the methods the `frontend` identity must
not reach, places a real order through the shop and checks that no pod restarted. It
exits non-zero if any case fails. On Windows run it from Git Bash.

Two checks guard against a false pass:

- Before testing, it checks that each attacker pod has the identity it claims: the two
  `attacker-as-*` pods must run the Linkerd proxy under the named ServiceAccount, and
  `attacker-outside` must not run the proxy. A pod that came up without the proxy would
  otherwise be denied as an anonymous client and the test would prove nothing about the
  `adservice` identity.
- With policies applied, it reads the proxies' denial counters before and after the run
  (`linkerd diagnostics proxy-metrics`) and fails if any legitimate caller was denied
  meanwhile. This covers everything the loadgenerator does during the run, not only the
  one scripted order, so a caller/method pair missing from the policies shows up here.

## Namespace default-deny (phase 2, optional)

The policies above cover every application port. Ports without a `Server` still use
Linkerd's default policy, `all-unauthenticated`. In practice that is the proxy admin
port 4191, where any pod can read a service's traffic metrics. Phase 2 sets the
namespace default to `deny` and allows only the metrics scraper and kubelet probes on
that port. How to enable it, how to pick the Prometheus allowed to scrape, and how to
turn it off again: [`namespace-default-deny/README.md`](namespace-default-deny/README.md).

## Assumptions

- **Three nodes.** `kubelet-probes` lists the pod-network address of each node created
  by `cluster/k3d-config.yaml`. With more nodes, pods on the extra node fail their
  probes until its `10.42.<n>.1` address is added to `00-authentications.yaml`.
- **Linkerd edge-26.11.1**, the version pinned in the setup scripts.
