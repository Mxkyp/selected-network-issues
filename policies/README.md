# Zero-Trust authorization policies

mTLS (step 2) encrypts traffic and gives every service a cryptographic identity, but it
does not decide who may call whom: without these policies any pod can still call
`paymentservice`. The manifests here add that decision. Each service accepts only the
callers and the gRPC methods listed below, and everything else is denied by the
Linkerd proxy before it reaches the application.

## Allow-matrix

Identities are the ServiceAccounts of the calling pods (namespace `default`).

The matrix was taken from the Online Boutique source and confirmed against live traffic:
`stage3/evidence/01-edges.txt` (which services talk to each other) and
`stage3/evidence/02-methods.txt` (which methods each caller uses).

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
| Prometheus → proxy metrics on port 4191 | not restricted in phase 1; see "Namespace default-deny" |

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
shown before and after. From the repo root:

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

With this order no request from a legitimate caller was denied while applying or
removing the policies. A single kubelet probe can still fail during an apply; one
failed probe does not restart a pod.

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
exits non-zero if any case fails. On Windows run it from Git Bash or WSL.

## Namespace default-deny (not enabled yet)

The policies above cover every application port. Ports without a `Server` still use
Linkerd's default policy, `all-unauthenticated`. In practice that is the proxy admin
port 4191, where any pod can read a service's traffic metrics.

Closing it means setting `config.linkerd.io/default-inbound-policy: deny` on the
namespace and explicitly allowing the metrics scraper. That depends on which
Prometheus step 4 uses, so it is left for after that decision.

## Assumptions

- **Three nodes.** `kubelet-probes` lists the pod-network address of each node created
  by `cluster/k3d-config.yaml`. With more nodes, pods on the extra node fail their
  probes until its `10.42.<n>.1` address is added to `00-authentications.yaml`.
- **Linkerd edge-26.11.1**, the version pinned in the setup scripts.
