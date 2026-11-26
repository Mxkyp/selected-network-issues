# AGENTS.md — Project Context & Conceptual Blueprint

> **Current Phase:** Implementation: steps 1–3 done (cluster, mTLS, authorization policies); steps 4–5 (monitoring dashboards, final before/after demo and evidence) in progress  
> **Project Scope:** 4-person university team project (2 ECTS)  
> **Primary Purpose of this File:** Align team members and AI assistants on the core problem, the Zero-Trust Service Mesh concept, and the incremental workflow for drafting the project documentation.

---

## 1. Project Overview

Modern microservice architectures generate massive internal (*East-West*) network traffic. By default, container orchestrators like Kubernetes operate on an **"implicit trust"** model within the cluster perimeter: services communicate via unencrypted protocols (plaintext HTTP/gRPC) and accept requests from any internal pod without verifying caller identity or permissions.

**Goal:** Design and prototype an infrastructure-level **Zero-Trust Architecture (ZTA)** using a **Service Mesh**. Instead of modifying application source code, security controls (encryption, cryptographic identity, and fine-grained authorization) are offloaded to the infrastructure layer.

---

## 2. The Problem

*   **Context:** Shift from monoliths to microservices increases internal (*East-West*) network communication.
*   **Root Cause:** Reliance on traditional perimeter security (*North-South* firewalls) while assuming the internal cluster network is inherently safe (*implicit trust*).
*   **Technical Vulnerabilities:**
    *   Plaintext communication (unencrypted HTTP/gRPC).
    *   Lack of cryptographic service identity verification.
    *   Lack of fine-grained access control (any service can call any other service).
*   **Impact:** If an attacker compromises a single minor service (e.g., an ad or recommendation service), they can perform **packet sniffing (eavesdropping)** and **lateral movement** to send unauthorized requests directly to critical services (e.g., payment processing).

---

## 3. Proposed Solution Concept & Workflow

The project uses an existing reference benchmark application as a **testbed** and focuses entirely on designing, applying, and verifying the Zero-Trust security and observability layers around it.

### Conceptual Execution Flow (5 Stages)
1.  **Baseline Deployment:** Deploy the unprotected microservice benchmark application on a local Kubernetes cluster.
2.  **Vulnerability Demonstration (Before Mesh):** Simulate an internal breach (e.g., from a compromised minor service or an attacker pod) to demonstrate successful unauthorized access / lateral movement to a critical service (e.g., `PaymentService`).
3.  **Service Mesh & Observability Integration:** Inject the Service Mesh across the application to enable automatic **mutual TLS (mTLS)** (solving encryption and cryptographic identity) and connect telemetry tools to visualize traffic. *(Note: At this stage, traffic is encrypted, but lateral movement is still possible without authorization policies).*
4.  **Zero-Trust Policy Enforcement:** Define and apply declarative **Authorization Policies** enforcing the Principle of Least Privilege (e.g., only `CheckoutService` is permitted to call `PaymentService`).
5.  **Verification & Proof (After Mesh):** Re-run the exact same attack simulation. Prove that unauthorized requests are rejected (`HTTP 403 / Permission Denied`) and visualize the blocked traffic on monitoring dashboards.

---

## 4. Candidate Technologies (Subject to Refinement)

> **Note for AI Agents:** These technologies represent the current working concept. Do not treat undecided details (such as specific attack simulation tools) as rigid constraints until finalized by the team.

| Component Role | Candidate Tool / Technology | Status | Justification / Role in Concept |
| :--- | :--- | :--- | :--- |
| **Testbed Application** | **Google Online Boutique** (*microservices-demo*) | Proposed | Realistic 11-microservice e-commerce app (gRPC/HTTP) deployed unsecured by default; allows focusing on security rather than app coding. |
| **Local Cluster** | **k3d** (K3s in Docker) | Proposed | Lightweight Kubernetes distribution suitable for running locally on student laptops. |
| **Service Mesh** | **Linkerd** (+ `linkerd-viz`) | Proposed | Lightweight, security-first service mesh providing automatic mTLS and declarative L4/L7 authorization policies without heavy resource overhead. |
| **Observability** | **Prometheus & Grafana** | Proposed | Collecting metrics from Service Mesh proxies and visualizing allowed vs. blocked requests in real time. |
| **Attack Simulation** | **Attacker pods + scripts in `attack/`** (outside the mesh, `adservice` and `frontend` identities) | Implemented | `attack/attack.sh` shows the lateral movement; `attack/verify.sh` checks every allowed and forbidden call. |

---

## 5. Running the Environment

Requirements: Docker (on Windows: Docker Desktop with the WSL2 backend) with 6–7 GB of memory, and on Windows also **Git Bash** for the bash test scripts in `attack/`. The setup scripts download k3d, kubectl and the linkerd CLI into `.tools/`. Run everything from the repo root.

| Goal | Linux / macOS | Windows (PowerShell) |
|---|---|---|
| Cluster + Linkerd + Online Boutique, **with** the Zero-Trust policies and the namespace default-deny | `./setup.sh --protect` | `powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Protect` |
| A new cluster **without** policies (mTLS only, the "before" state of the demo) | `./setup.sh` | `powershell -ExecutionPolicy Bypass -File .\setup.ps1` |
| Show what is on | `./zero-trust.sh status` | `powershell -ExecutionPolicy Bypass -File .\zero-trust.ps1 status` |
| Policies on / off on a running cluster | `./zero-trust.sh on` / `off` | same with `zero-trust.ps1 on` / `off` |
| Namespace default-deny on a running cluster (already on with `--protect`; restarts all pods; see `policies/namespace-default-deny/README.md`) | `./zero-trust.sh deny on` / `deny off` | same with `zero-trust.ps1 deny on` / `deny off` |
| Show the attack (lateral movement from attacker pods) | `attack/attack.sh` | from Git Bash |
| Check the policies end to end | `attack/verify.sh` (policies on) or `attack/verify.sh --expect-open` (policies off) | from Git Bash |
| Pause / resume | `.tools/k3d cluster stop sina`, then `./setup.sh` | `.tools\k3d.exe cluster stop sina`, then `setup.ps1` again |

- Re-running `setup.sh` never removes policies that are already on; use `zero-trust.sh off` for the "before" state on an existing cluster.
- `setup.sh` is idempotent: re-run it after a Docker restart; it starts a stopped cluster and recreates pods that came up without the Linkerd proxy.
- `kubectl`, `k3d` and `linkerd` are in `.tools/` (when they were not already installed): add it to the PATH to use them by hand, `export PATH="$PWD/.tools:$PATH"` (PowerShell: `$env:PATH = "$PWD\.tools;$env:PATH"`).
- The shop is at http://localhost:8080. The setup scripts also install `linkerd-viz` and Grafana: the "Zero Trust: allowed vs denied" dashboard is at http://localhost:3000 (a cluster created before step 4 needs `.tools/k3d cluster edit sina --port-add 3000:3000@loadbalancer` once).
- The allow-matrix and how the policies work: `policies/README.md`. The dashboard, its panels and limits: `observability/README.md`. Cluster details and troubleshooting: `cluster/README.md`.
- Performance tests (no mesh vs mTLS vs mTLS with policies): what was tested, the results and how to repeat them are in `stage4/performance/README.md`.

## 6. Instructions for AI Assistants (Current Phase)

When assisting with this project during the **concept and specification phase**:
1.  **Focus on Conceptual Advice:** Help brainstorm, evaluate alternatives, and formulate sections of the academic project specification (`1.I` through `5`). Do not generate boilerplate infrastructure code or folder structures unless explicitly asked.
2.  **No Unverified Assumptions:** If a technical detail or project scope decision has not been agreed upon yet, ask clarifying questions instead of assuming a specific implementation.
3.  **Keep Scope Realistic (2 ECTS / 4 Students):** Ensure all proposed concepts, requirements, and schedules remain lightweight, achievable within ~50 hours per person, and focused on demonstrating Zero-Trust via Service Mesh.
4.  **Maintain Terminology Consistency:** Always distinguish between:
    *   *Authentication & Encryption* (provided automatically by **mTLS**), and
    *   *Authorization / Access Control* (provided by explicit **Authorization Policies** to stop lateral movement).