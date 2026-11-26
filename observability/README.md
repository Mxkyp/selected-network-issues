# Step 4: Grafana dashboard for allowed vs denied traffic

Grafana shows what the step 3 authorization policies do: which calls the Linkerd proxies let
through, which they refuse, and who was refused. It reads the Prometheus that comes with
linkerd-viz, so nothing else collects metrics.

```
Linkerd proxies --(metrics, port 4191)--> Prometheus (linkerd-viz) <--(queries, mTLS)-- Grafana
```

## Open it

`setup.sh` / `setup.ps1` install linkerd-viz and Grafana. Then open
**http://localhost:3000**. The dashboard "Zero Trust: allowed vs denied" is the home page and
can be viewed without logging in. To change it, edit the files here, not the UI.

A cluster created before step 4 has no port 3000 on its load balancer. Add it once:

```bash
.tools/k3d cluster edit sina --port-add 3000:3000@loadbalancer
```

## What the setup scripts do

| Step | Why |
|---|---|
| install linkerd-viz before the shop | every app pod starts ready for `linkerd viz tap`, no restart needed |
| deploy the shop | unchanged |
| `kubectl apply -k observability/` | Grafana, its data source and dashboard, and the policy below |

Both scripts skip linkerd-viz when it is already installed, so re-running them is safe.
`cluster/k3d-config.yaml` maps port 3000 to the load balancer for new clusters.

## Show an attack on the dashboard

```bash
kubectl apply -f policies/              # step 3 policies
kubectl apply -f attack/attackers.yaml  # test pods, once
attack/attack.sh                        # run it two or three times, ~15 s apart
```

The attacks appear within about 15 seconds (10 s scrape interval, 5 s refresh).

## Panels

| Panel | What it shows |
|---|---|
| Denied calls (since pod start) | gRPC/HTTP calls refused by the policies, without health checks |
| Allowed requests/s | calls let through, without health checks |
| Allowed with mTLS | share of allowed calls that arrived with a verified mesh identity |
| Denied TCP (5 min) | refused raw TCP connections, in practice to `redis-cart` |
| Denied probes (5 min) | refused kubelet health checks; must be 0 |
| Denied calls per service | refusals per second, by target service |
| Allowed requests per service | allowed calls per second, by target service |
| Who was denied, and where | target, method and caller identity of every refusal |

The numbers come from the proxies' counters `inbound_http_authz_allow_total`,
`inbound_http_authz_deny_total` and `inbound_tcp_authz_deny_total`. In the table, a caller with
an identity (for example `adservice.default.serviceaccount…`) is a meshed pod; an empty identity
with `no_tls_from_remote` is a pod outside the mesh.

## Why Grafana needs a policy

linkerd-viz protects its Prometheus: the `Server` `prometheus-admin` authorizes only
linkerd-viz's own `metrics-api`. Without `prometheus-access.yaml` every Grafana query fails
with **403**. Tested: the Prometheus proxy counted the denial for
`grafana.grafana.serviceaccount.identity.linkerd.cluster.local`. That is why the `grafana`
namespace is meshed (Grafana needs an identity) and the policy names that identity.

This corrects `policies/namespace-default-deny/README.md`, which says Grafana needs no policy.
That holds for the application pods, not for the Prometheus it queries.

## Tested

On a cluster built from zero with `setup.ps1` (Windows, 339 s), then `kubectl apply -f policies/`:

| Check | Result |
|---|---|
| All pods ready, including Grafana | yes |
| `attack/attack.sh` run 3 times (4 calls each) | 12 calls refused with gRPC status 7, 12 shown in "Denied calls" |
| "Who was denied" table | `adservice` identity and the pod outside the mesh, on `paymentservice-charge` and `cartservice-read` |
| Denied probes / denied TCP | 0 / 0 |
| Allowed with mTLS | about 99 % |
| `linkerd viz tap` right after setup | works, no pod restart |
| Grafana without `prometheus-access.yaml` | every query fails with 403 |

`setup.sh` was only checked for syntax after these changes, not run on Linux or macOS.
Performance overhead of the mesh and the policies is not measured yet.

Evidence from a second run (policies on, three attack runs), in `stage4/evidence/`:

| File | Shows |
|---|---|
| `01-components.txt` | linkerd-viz and Grafana pods, `linkerd viz check` passing |
| `02-grafana-without-policy.txt` | Grafana's query fails with 403 without `prometheus-access.yaml`, the Prometheus proxy counts the denial for the Grafana identity, and the query works again after re-applying it |
| `03-attack.txt` | three runs of `attack/attack.sh`: 12 calls, all gRPC status 7 |
| `04-dashboard-values.txt` | every dashboard query run through Grafana right after the attack: 12 denied calls, 0 denied probes, 0 denied TCP |
| `05-tap.txt` | `linkerd viz tap` working right after setup, every request `tls=true` |
| `06-dashboard.png` | the dashboard after the attack (headless Edge screenshot) |

The allowed-requests rate on the screenshot is lower than in `04`, because the two were taken
at different moments; the denial numbers match.

## Limits

- **Six hours of data.** The linkerd-viz Prometheus keeps metrics for 6 h and loses them when
  its pod restarts. Enough for a demo; longer history needs a separate Prometheus (variant B in
  `policies/namespace-default-deny/README.md`).
- **The first denial of a new caller/method pair is not in the per-second chart.** It starts a
  new counter, and a rate needs two samples. The "since pod start" panel and the table do count
  it. Run the attack more than once.
- **TCP denials have no method.** For `redis-cart`, an attacker and a blocked TCP probe look the
  same.
- **Counters reset when a pod restarts**, so "since pod start" is per pod lifetime.

## Denied probes is not 0

The step 3 policies allow kubelet probes from a fixed list of node addresses
(`kubelet-probes` in `policies/00-authentications.yaml`: `10.42.0.1`, `10.42.1.1`,
`10.42.2.1`). If a node gets another pod network, pods on it fail their probes and restart.
This happened after an interrupted `setup` run, where one node got `10.42.3.0/24`:
`checkoutservice`, `emailservice` and `recommendationservice` kept restarting and checkout
failed. Check the node networks with:

```bash
kubectl get nodes -o custom-columns=NODE:.metadata.name,CIDR:.spec.podCIDR
```

## Files

| File | Purpose |
|---|---|
| `kustomization.yaml` | applies everything: `kubectl apply -k observability/` |
| `grafana.yaml` | namespace (meshed), ServiceAccount, Deployment, Service on port 3000 |
| `prometheus-access.yaml` | lets the Grafana identity query the linkerd-viz Prometheus |
| `grafana/datasources.yaml` | Prometheus data source |
| `grafana/dashboard-provider.yaml` | loads dashboards from files |
| `grafana/dashboards/zero-trust.json` | the dashboard |

Grafana runs with anonymous view access and no persistent storage, which is fine for a local
demo cluster and not for anything shared.
