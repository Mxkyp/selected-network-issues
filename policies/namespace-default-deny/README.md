# Phase 2: namespace default-deny

The policies in `policies/` cover every application port. Any port without a `Server`
still falls back to Linkerd's default policy, `all-unauthenticated`: anyone may connect.
In practice that leaves one port open on every pod, the proxy admin port **4191**. Any
pod in the cluster, including a compromised one, can read a service's traffic metrics
from `http://<pod IP>:4191/metrics`.

Phase 2 turns the default around: the namespace gets
`config.linkerd.io/default-inbound-policy: deny`, so a port without explicit
authorization refuses everything. The admin port then needs its own policy
(`admin-port.yaml`):

| Path on port 4191 | Allowed for | Why |
|---|---|---|
| `/metrics` | the Prometheus that collects proxy metrics (`metrics-scraper`) | the step 4 dashboards are built from these metrics |
| `/live`, `/ready` | kubelet probes (node addresses) | without them the proxy never becomes Ready and pods restart |
| anything else | nobody | |

## Before you enable it

- **`setup.sh --protect` already enables it.** On a new cluster it applies the policies
  and the namespace default before the shop starts, so no pod restarts. The steps below
  are for a cluster that is already running.
- **linkerd-viz** (variant A below) is installed by the setup scripts before the shop.
  Without a scraper, phase 2 still protects the port, but nothing collects the proxy
  metrics.
- **The before/after demo changes.** With default-deny, deleting the policies in
  `policies/` no longer opens the shop: every port falls back to `deny` and the shop
  stops working. To get back to the unprotected state you have to turn phase 2 off first
  (see "Turn it off").
- **Every pod has to restart.** The proxy reads the default policy when it starts.
  Restart the deployments one at a time: restarting them all at once overloaded our
  laptops.
- **Pick the scraper first** (next section). If its identity is wrong, the dashboards go
  empty as soon as the pods restart.

## Choosing the scraper

Linkerd authorizes callers by identity. For a meshed pod, that identity is its
ServiceAccount and namespace. `admin-port.yaml` names the scraper in a single object,
the `MeshTLSAuthentication` called `metrics-scraper`, so switching Prometheus means
changing two values there.

### Variant A: the Prometheus from linkerd-viz (recommended)

This is what `admin-port.yaml` is set up for, and nothing has to change.

- ServiceAccount `prometheus`, namespace `linkerd-viz`.
- It is already meshed and already scrapes every proxy.
- Grafana can use it as a data source at
  `http://prometheus.linkerd-viz.svc.cluster.local:9090`.
- Limitation: it keeps data for only 6 hours. That is enough for a demo.

Grafana needs no policy on the application pods: it only queries Prometheus and never
connects to them. It does need one for the linkerd-viz Prometheus, which protects itself;
`observability/prometheus-access.yaml` adds it (see `observability/README.md`).

### Variant B: your own Prometheus, inside the mesh

Use this when you need longer retention or your own scrape configuration. For example:
the Prometheus from the `kube-prometheus-stack` Helm chart.

1. Mesh the Prometheus pod. Add the annotation `linkerd.io/inject: enabled` to its pod
   template, or to its namespace, and restart it. Check that it shows `2/2` containers
   and a `linkerd-proxy` container.
2. Find its identity:
   ```bash
   kubectl get pod -n <namespace> <prometheus-pod> -o jsonpath='{.spec.serviceAccountName}'
   ```
3. Put that ServiceAccount and namespace into `metrics-scraper` in `admin-port.yaml`:
   ```yaml
   identityRefs:
   - kind: ServiceAccount
     name: <serviceaccount>
     namespace: <namespace>
   ```
   To keep the linkerd-viz Prometheus working as well, add the new identity as a second
   entry. Entries in `identityRefs` are alternatives (any of them may scrape).
4. The Prometheus needs a scrape job for the proxies: pods with the
   `linkerd.io/control-plane-ns` label, container port `linkerd-admin`, path `/metrics`.
   The `linkerd-proxy` job in the linkerd-viz Prometheus config is a good template:
   ```bash
   kubectl get configmap -n linkerd-viz prometheus-config -o yaml
   ```

### Variant C: your own Prometheus, outside the mesh (not recommended)

A pod outside the mesh has no identity, so the only option is a
`NetworkAuthentication` with its IP address. That is weak:

- Pod IPs change on every restart.
- The only stable alternative is a whole pod range (`10.42.0.0/16`), which lets every pod
  in the cluster read the metrics. That is exactly what phase 2 is meant to stop.

If you must, replace the `MeshTLSAuthentication` reference in the `proxy-admin-metrics`
policy with a `NetworkAuthentication` listing the Prometheus pod's current `/32` address.
Meshing it (variant B) is simpler and safer.

## Turn it on

The short way: `./zero-trust.sh deny on` (and `./zero-trust.sh deny off`) in the repo root,
or `.\zero-trust.ps1 deny on` on Windows. It refuses to run while phase 1 is off and does
the steps below. By hand:

From the repo root, with the policies in `policies/` already applied.
`kubectl apply -f policies/` does not descend into this directory, so phase 2 is only
ever applied on purpose:

```bash
export PATH="$PWD/.tools:$PATH"

# 1. The admin-port policy first, so the port is covered the moment a proxy starts with deny.
kubectl apply -f policies/namespace-default-deny/admin-port.yaml

# 2. Switch the namespace default.
kubectl annotate namespace default config.linkerd.io/default-inbound-policy=deny

# 3. Restart the application, one deployment at a time.
for d in $(kubectl get deploy -n default -o name); do
  kubectl rollout restart -n default "$d"
  kubectl rollout status -n default "$d" --timeout=300s
done

# 4. The attacker pods are plain pods; recreate them so they pick up the new default too.
kubectl delete pod -l app.kubernetes.io/part-of=attack-simulation
kubectl apply -f attack/attackers.yaml
```

## Check it

```bash
attack/verify.sh                               # policies still work, shop still works
linkerd viz stat deploy -n default             # every deployment shows a success rate,
                                               # so Prometheus still gets the metrics

linkerd viz tap deploy/paymentservice -n default   # live requests still visible (Ctrl+C to stop)

# Another pod must not read the metrics: expect 403.
POD_IP=$(kubectl get pod -l app=paymentservice -o jsonpath='{.items[0].status.podIP}')
kubectl exec attacker-as-adservice -c curl -- \
  curl -s -o /dev/null -w '%{http_code}\n' "http://$POD_IP:4191/metrics"
```

If `linkerd viz tap` fails with `no_tls_from_remote`, or a pod shows `1/1` instead of
`2/2`, that pod started without its Linkerd proxy (this happens when the cluster was
overloaded and the proxy injector was down). It has no identity, so the policies treat
it as an outsider. Delete the pod and let its deployment recreate it:
`kubectl delete pod -n <namespace> <pod>`.

## Turn it off

```bash
kubectl annotate namespace default config.linkerd.io/default-inbound-policy-
for d in $(kubectl get deploy -n default -o name); do
  kubectl rollout restart -n default "$d"
  kubectl rollout status -n default "$d" --timeout=300s
done
kubectl delete server,httproutes.policy.linkerd.io,authorizationpolicy,meshtlsauthentication \
  -l app.kubernetes.io/part-of=zero-trust-default-deny
```

The phase 1 policies stay in place. The `HTTPRoute` kind has to be named with its group
(`httproutes.policy.linkerd.io`): the cluster also has the Gateway API `HTTPRoute`, and
the short name points to that one.
