# k3d cluster + Linkerd + Online Boutique

Only **Docker** must be installed and running (Windows: Docker Desktop with WSL2 backend; >= 4 GB RAM).
k3d, kubectl and the linkerd CLI are downloaded automatically (pinned versions) into `./.tools/` — no admin rights needed.

| OS | Run from the repo root |
|----|-----|
| Linux / macOS | `./setup.sh` |
| Windows (PowerShell) | `powershell -ExecutionPolicy Bypass -File .\setup.ps1` |

The script creates the cluster, installs Linkerd and deploys `app/kubernetes-manifests.yaml` (Online Boutique v0.10.7) with a Linkerd proxy in every pod. It is idempotent: re-running reuses the existing cluster and Linkerd installation.

When it finishes, open http://localhost:8080.

Tear down: `.tools/k3d cluster delete sina` (Windows: `.tools\k3d.exe cluster delete sina`).

## Checking the mesh
All traffic between services is encrypted and authenticated with mTLS. The setup script stops there on purpose: no Authorization Policies are applied, so any caller is still allowed. The policies that close this gap, and the commands to apply and verify them, are in [`policies/README.md`](../policies/README.md).

```bash
.tools/linkerd check --proxy
.tools/linkerd diagnostics proxy-metrics -n default deploy/paymentservice | grep '^request_total' | grep 'direction="inbound"'
```

Requests with `tls="true"` and `client_id="checkoutservice..."` are mTLS traffic. `tls="no_identity"` on the same port is expected from kubelet health probes.

## Troubleshooting
- Pods `Pending`/`OOMKilled`: raise Docker memory.
- A pod shows `1/1` instead of `2/2` after the cluster was overloaded or restarted: it started while the Linkerd proxy injector was down, so it has no proxy and no identity, and the authorization policies treat it as an outsider. Delete the pod; its deployment recreates it with the proxy.
- Host becomes very slow, `kubectl` times out and pods restart in a loop after installing `linkerd-viz` or restarting several deployments: the Docker VM is swapping. 4 GB is the bare minimum for the shop alone; give Docker 6 GB or more when `linkerd-viz` is installed.
- Pods stuck in `PodInitializing` or `ImagePullBackOff`: check free disk space on the host.
- Windows: if Docker check fails, start Docker Desktop and enable WSL2 integration.
- Podman instead of Docker (Linux): enable `podman.socket` and set `DOCKER_HOST`.
- Traefik is disabled on purpose: its CRD chart clashes with the Gateway API CRDs that Linkerd needs.
