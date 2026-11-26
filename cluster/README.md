# k3d cluster + Linkerd + Online Boutique

Only **Docker** must be installed and running (Windows: Docker Desktop with WSL2 backend). Give Docker 6–7 GB of memory: 4 GB is the bare minimum for the shop alone. On Windows, the test scripts in `attack/` also need **Git Bash**.
k3d, kubectl and the linkerd CLI are downloaded automatically (pinned versions) into `./.tools/` — no admin rights needed.

| OS | Run from the repo root | Protected: policies + namespace default-deny |
|----|-----|-----|
| Linux / macOS | `./setup.sh` | `./setup.sh --protect` |
| Windows (PowerShell) | `powershell -ExecutionPolicy Bypass -File .\setup.ps1` | add `-Protect` |

The script creates the cluster, installs Linkerd and deploys `app/kubernetes-manifests.yaml` (Online Boutique v0.10.7) with a Linkerd proxy in every pod.

With `--protect` on a new cluster, the per-service policies and the namespace default-deny are in place before the shop starts, so every pod starts protected and nothing restarts. On a cluster whose shop already runs without the default-deny, `--protect` turns it on with `./zero-trust.sh deny on`, which restarts every pod one at a time (about 5 minutes).

Without `--protect` the cluster has mTLS but **no authorization policies**: any pod can still call any service. That is the "before" state of the demo, and the cluster to use for a live before/after (`zero-trust.sh on` / `off` take seconds; on a protected cluster `off` first turns the default-deny off, which restarts every pod), and the script ends by printing which protections are on. To turn the policies on or off later, use `zero-trust.sh` (Windows: `zero-trust.ps1`, same commands):

| Command | Effect |
|---|---|
| `./zero-trust.sh status` | which phase is on, attacker test pods, pods without a proxy |
| `./zero-trust.sh on` | phase 1: per-service policies from `policies/` and the attacker test pods (seconds, no restarts) |
| `./zero-trust.sh off` | back to the unprotected cluster (turns phase 2 off first if needed) |
| `./zero-trust.sh deny on` / `deny off` | phase 2: namespace default-deny; restarts every pod one at a time (about 5 minutes) |

Check the result with `attack/verify.sh` (policies on) or `attack/verify.sh --expect-open` (policies off); on Windows run these from Git Bash. Details: [`policies/README.md`](../policies/README.md).

The setup script is idempotent: re-running reuses the existing cluster and Linkerd installation, and starts the cluster first if it is stopped. It never removes policies that are already on; use `./zero-trust.sh off` for that. It also creates the attacker test pods from `attack/`.

When it finishes, open http://localhost:8080.

Stop and start without losing anything (frees memory between sessions):

```bash
.tools/k3d cluster stop sina
./setup.sh          # starts a stopped cluster, waits for it and repairs pods that came up without the Linkerd proxy
```

Running `./setup.sh` again is the recommended way back after a stop or a Docker restart. A plain
`.tools/k3d cluster start sina` also works, but then some pods can come up before the Linkerd
proxy injector and run without a proxy (they show `1/1`). Plain pods without a deployment, such
as the attacker pods from `attack/`, are not recreated after a stop: apply `attack/attackers.yaml` again.

Tear down: `.tools/k3d cluster delete sina` (Windows: `.tools\k3d.exe cluster delete sina`).

## Checking the mesh
All traffic between services is encrypted and authenticated with mTLS. Without `--protect` the setup script stops there on purpose: no Authorization Policies are applied, so any caller is still allowed. The policies that close this gap are described in [`policies/README.md`](../policies/README.md).

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
