# Zero-Trust service mesh for Online Boutique

Project resources of group 4, *Selected Issues of Network Applications* 2026/2027, Lodz
University of Technology: Jędrzej Bartoszewski, Michał Domagała, Kacper Maziarz, Mikołaj
Pawłoś. Topic: *Modern Service Mesh: a better way to secure communication between
microservices*.

The scripts build a local Kubernetes cluster (k3d) running Google's Online Boutique shop
inside the Linkerd service mesh. Every connection between the services is encrypted with
mutual TLS, and Zero-Trust authorization policies allow each service to call only the
services and gRPC methods it needs. Attacker pods and scripts show the same attack
with and without the policies, and a Grafana dashboard shows the refused calls.

## What is in this archive

| Path | Contents |
|---|---|
| `setup.sh`, `setup.ps1` | build the whole environment with one command (Linux/macOS, Windows) |
| `zero-trust.sh`, `zero-trust.ps1` | switch the authorization policies on and off on a running cluster |
| `cluster/` | k3d cluster configuration; [`cluster/README.md`](cluster/README.md) covers stopping, restarting and troubleshooting |
| `app/` | the Online Boutique v0.10.7 manifest, unmodified (by Google, Apache License 2.0) |
| `policies/` | the Linkerd authorization policies, one file per service; [`policies/README.md`](policies/README.md) has the allow-matrix and explains how they work |
| `policies/namespace-default-deny/` | the namespace default-deny and the policy for the proxy admin port ([README](policies/namespace-default-deny/README.md)) |
| `attack/` | attacker test pods (`attackers.yaml`), `attack.sh` (the attack), `verify.sh` (checks every allowed and forbidden call) and `lib.sh` (helpers they share) |
| `observability/` | Grafana with the "Zero Trust: allowed vs denied" dashboard ([README](observability/README.md)) |
| `stage4/performance/` | the script and results of the performance tests: mesh and policy overhead ([README](stage4/performance/README.md)) |

The READMEs in the subdirectories use the project's step numbers: step 1 is the cluster and
the shop, step 2 mTLS, step 3 the authorization policies, step 4 Grafana and step 5 the
attack. "Phase 1" means the per-service policies in `policies/`, "phase 2" the namespace
default-deny.

## Requirements

- Docker with 6–7 GB of memory (on Windows: Docker Desktop with the WSL2 backend).
- Internet access on the first run. The setup script downloads pinned versions of k3d,
  kubectl and the Linkerd CLI into `.tools/`, without admin rights, and the cluster pulls
  the container images.
- On Windows, Git Bash for the test scripts in `attack/`, which are written in bash.
- Free ports 8080 and 3000 on the host. The setup script creates a k3d cluster named
  `sina` and switches the current `kubectl` context to it.
- Python 3, only for the performance tests in `stage4/performance/`.

Run every command from this directory. If `./setup.sh` fails with "Permission denied"
because the unpacking tool dropped the executable bits, run `bash setup.sh` instead (the
same works for the other `.sh` scripts).

## Build the environment

| | Linux / macOS | Windows (PowerShell) |
|---|---|---|
| Without policies (mTLS only, the "before" state) | `./setup.sh` | `powershell -ExecutionPolicy Bypass -File .\setup.ps1` |
| With the policies and the namespace default-deny | `./setup.sh --protect` | `powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Protect` |

The first run takes about 10 minutes, mostly for downloading images. When it finishes:

- the shop is at http://localhost:8080;
- the Grafana dashboard is at http://localhost:3000 (no login needed);
- `./zero-trust.sh status` shows which protections are on (Windows:
  `powershell -ExecutionPolicy Bypass -File .\zero-trust.ps1 status`).

Running the script again is safe. It reuses the cluster, starts it if it is stopped, and
never removes policies that are already on.

## The attack, before and after

Use a cluster built **without** `--protect`. On it, the policies switch on and off in seconds
and no pod restarts. On a cluster built with `--protect`, the first `off` also turns the
namespace default-deny off, which restarts every pod and takes about 5 minutes.

```bash
./zero-trust.sh off    # mTLS only, no authorization policies
attack/attack.sh       # the calls reach paymentservice and cartservice

./zero-trust.sh on     # authorization policies on
attack/attack.sh       # every call ends with gRPC status 7, PERMISSION_DENIED
```

On Windows, run `zero-trust.ps1 off` and `on` in PowerShell (as above, with
`powershell -ExecutionPolicy Bypass -File`) and `attack/attack.sh` in Git Bash.

The output, shortened (status 2 is the payment service's own error about the missing card,
status 0 a successful call, status 7 a refusal by the proxy):

```
# policies off
attacker-outside       -> paymentservice  Charge   grpc-status: 2  ... (reading 'credit_card_number')
attacker-outside       -> cartservice     GetCart  grpc-status: 0
# policies on
attacker-outside       -> paymentservice  Charge   grpc-status: 7
attacker-outside       -> cartservice     GetCart  grpc-status: 7
```

`attack/attack.sh` makes four calls: from a pod outside the mesh and from a pod that uses the
`adservice` identity, to `PaymentService/Charge` and `CartService/GetCart`. Without the
policies, the payment service itself answers and fails only on the missing card data; with
them, the Linkerd proxy refuses the call before it reaches the application. Run the attack
two or three times about 15 seconds apart and the refusals appear on the Grafana dashboard.

To check the whole allow-matrix, run `attack/verify.sh` with the policies on (47 checks), or
`attack/verify.sh --expect-open` with them off (43 checks). It prints one line per check and
ends with "All cases passed" or a non-zero exit code.

## The namespace default-deny

`setup.sh --protect` also sets the default inbound policy of the namespace to `deny`. That
closes the one port the per-service policies leave open, the proxy admin port 4191, where
any pod could read another service's traffic metrics. Switching it on or off on a running
cluster restarts every pod, which takes about 5 minutes:

```bash
./zero-trust.sh deny on
./zero-trust.sh deny off
```

## Stop or remove the cluster

```bash
.tools/k3d cluster stop sina      # pause; ./setup.sh starts it again
.tools/k3d cluster delete sina    # remove it completely
```

On Windows use `.tools\k3d.exe` instead of `.tools/k3d`. The tools in `.tools/` are only
there after the first run of the setup script. To use `kubectl` or `linkerd` directly, add
them to the path: `export PATH="$PWD/.tools:$PATH"` (PowerShell:
`$env:PATH = "$PWD\.tools;$env:PATH"`).

## Tested versions

k3d v5.9.0 · kubectl v1.37.2 · Linkerd edge-26.11.1 · Gateway API v1.2.1 · Online Boutique
v0.10.7 · Grafana 11.3.0, on Linux and Windows laptops. macOS is supported by the scripts
but was not tested. The policies assume the three-node cluster that `cluster/k3d-config.yaml`
creates.
