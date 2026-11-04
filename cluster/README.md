# Step 1: k3d cluster + Online Boutique

Only **Docker** must be installed and running (Windows: Docker Desktop with WSL2 backend; >= 4 GB RAM).
k3d and kubectl are downloaded automatically (pinned versions) into `./.tools/` — no admin rights needed.

| OS | Run from the repo root |
|----|-----|
| Linux / macOS | `./setup.sh` |
| Windows (PowerShell) | `powershell -ExecutionPolicy Bypass -File .\setup.ps1` |

The script is idempotent: re-running reuses the existing cluster. When it finishes, open http://localhost:8081.

Tear down: `.tools/k3d cluster delete sina` (Windows: `.tools\k3d.exe cluster delete sina`).

## Troubleshooting
- Pods `Pending`/`OOMKilled`: raise Docker memory.
- Windows: if Docker check fails, start Docker Desktop and enable WSL2 integration.
- Podman instead of Docker (Linux): enable `podman.socket` and set `DOCKER_HOST`.
