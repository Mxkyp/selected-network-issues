---
marp: true
paginate: true
title: Modern Service Mesh - Stage 2
---

<!-- Marp-compatible. Speaker notes sit in HTML comments under each slide. Export: `npx @marp-team/marp-cli stage2/presentation.md --pptx` (or --pdf). Target: ~15 min, 4 speakers. -->

# Modern Service Mesh
## A better way to secure communication between microservices

Jędrzej Bartoszewski · Michał Domagała · Kacper Maziarz · Mikołaj Pawłoś

Selected Issues of Network Applications, 2026/2027 · Stage 2: Proof of Concept

<!-- Kacper. Just names and the topic, ten seconds, move on. -->

---

# Inside the cluster, everyone trusts everyone

- Online Boutique: 11 services talking gRPC and HTTP, all plaintext by default
- Any pod can call any other pod; nobody checks who's asking
- Firewalls guard the edge (North-South), and East-West traffic gets no checks at all

[DIAGRAM: compromised `adservice` → sniffs traffic, then calls `paymentservice` directly]

<!-- Kacper. Kubernetes doesn't encrypt pod-to-pod traffic and doesn't authenticate callers. So if someone gets into one small, boring service like the ad service, they can read traffic passing by and send requests straight to payments, because payments has no way of telling a legitimate checkout call from an attacker's. That's the scenario we're building the whole project around. -->

---

# What an attacker gets from one weak pod

| Attack | Why it works today |
|---|---|
| Eavesdropping | Traffic between pods is plaintext |
| Impersonation | Services have no cryptographic identity |
| Lateral movement | Nothing restricts who may call whom |

<!-- Kacper. Three separate gaps, and they need separate fixes. Keep that in mind, because our stage-2 result closes the first two and leaves the third wide open on purpose. -->

---

# Our idea: Zero Trust, enforced by the infrastructure

- A small proxy sits next to every service (a sidecar) and handles all its traffic
- Proxies encrypt with mutual TLS and prove identity with certificates
- Policies decide which identity may call which service
- No change to application code

[DIAGRAM: pod = app container + linkerd-proxy; proxy ↔ proxy over mTLS]

<!-- Kacper. The application keeps talking plain gRPC to localhost; the proxy picks the traffic up and wraps it in TLS on the way out, and the receiving proxy unwraps it. Because the mesh hands out certificates per Kubernetes ServiceAccount, each service gets its own identity, and that identity is what the policies in step 3 will refer to. -->

---

# Why not the alternatives?

| Option | Problem for us |
|---|---|
| TLS inside each app | Code changes in 5 languages, certificates managed by hand |
| Kubernetes NetworkPolicies | IP/port rules only: no encryption, no identity |
| Istio | Does everything, but heavier to run and to learn on a laptop cluster |
| **Linkerd** | Automatic mTLS, Rust micro-proxy, small enough for k3d |

<!-- Kacper. Online Boutique is written in Go, C#, Node.js, Python and Java, so doing TLS in the apps means five implementations. NetworkPolicies are good at "this pod may reach that port", but they work on IPs, so they don't encrypt anything and can't tell who is really on the other end. Istio could do this job too; we went with Linkerd because it's lighter and simpler, which matters when four of us run it on our own machines. -->

---

# The stack

[DIAGRAM: Docker → k3d cluster `sina` (1 server, 2 agents) → Online Boutique → Linkerd control plane + proxies → Prometheus → Grafana]

- **k3d**: Kubernetes in Docker containers, free and local
- **Online Boutique** v0.10.7: a realistic shop we attack instead of writing our own
- **Linkerd**: mTLS, identity, authorization policies
- **Prometheus + Grafana**: metrics from the proxies, dashboards for allowed vs. denied traffic

<!-- Mikołaj. Walk the diagram bottom to top. Only Docker is a prerequisite; everything else is pulled in by our scripts. Prometheus and Grafana come in at step 4, mention that they're planned, not done. -->

---

# Where we are

| Step | When | Status |
|---|---|---|
| 1. k3d cluster + Online Boutique | weeks 3–4 | x done |
| 2. Linkerd + mTLS proof of concept | weeks 5–6 (6.11) | x done |
| 3. Zero-Trust authorization policies | week 7 | next |
| 4. Prometheus + Grafana | week 8 | planned |
| 5. Attack simulation | week 9 (27.11) | planned |

<!-- Mikołaj. We're on schedule: both PoC steps are done by the 6.11 deadline. -->

---

# Step 1: one command, any laptop

```
./setup.sh                      # Linux / macOS
powershell -File .\setup.ps1    # Windows
```

- Only Docker needed; k3d v5.9.0 and kubectl v1.37.2 get downloaded into `./.tools/`
- Creates cluster `sina`, deploys Online Boutique, waits for every deployment
- Safe to re-run; shop at `localhost:8081`

[SCREENSHOT: terminal finishing + the shop in a browser]

<!-- Mikołaj. We pinned every version so all four of us run exactly the same thing, no matter what's installed locally. No admin rights needed either. The README also covers the failures we expect: pods stuck Pending when Docker has too little memory, WSL2 on Windows, and running with Podman instead of Docker on Linux. -->

---

# Step 2: is the traffic encrypted?

[SCREENSHOT: `linkerd viz edges` with every row SECURED]

[SCREENSHOT: `linkerd viz tap` checkout → payment, `tls=true`]

<!-- Jędrzej. Linkerd [TODO: version] installed with [TODO: CLI/Helm], injected into the default namespace, deployments restarted so every pod picks up its proxy. Edges shows every service-to-service connection as secured; tap shows individual live requests from checkout to payment, each one marked tls=true. -->

---

# Same request, before and after

| Without mesh | With mesh |
|---|---|
| [SCREENSHOT: tcpdump, readable payload] | [SCREENSHOT: tcpdump, TLS noise] |

<!-- Jędrzej. We took paymentservice out of the mesh and captured its traffic from the node. Without the proxy you can read the request contents straight off the wire [TODO: say what you actually saw]. Put it back in the mesh, run the same capture, and it's just TLS. No code changed between the two screenshots, only one annotation. -->

---

# What surprised us

- **Encrypted ≠ protected.** Any pod can still call `paymentservice`; Linkerd's default policy lets even unmeshed, plaintext clients in
- Injection only happens when a pod starts, so existing deployments need a restart
- Showing encryption took more work than turning it on
- [TODO: one more real issue from the team]

<!-- Jędrzej. The first point is the big one. After step 2 an attacker can't read the traffic anymore, but they can still send requests to payments, because the default inbound policy is all-unauthenticated. So we fixed eavesdropping and impersonation, and lateral movement is still open. On proving it: the app images have no shell, and they refuse root containers, so we had to capture from the node. Capture inside the pod and you'd see plaintext anyway on loopback, between the app and its own proxy. -->

---

# Next: close the door (steps 3 and 5)

- Default-deny for the namespace, then allow only the calls the app really makes
- Example: only the `checkoutservice` identity may call `paymentservice`
- Attack, run twice: an outside pod, then a hijacked `adservice`, both calling payments
  - before policies: the call goes through
  - after: `PermissionDenied`

[DIAGRAM: Online Boutique call graph, allowed edges only]

<!-- Michał. Each Online Boutique service already runs under its own ServiceAccount, so each one gets its own mesh identity, and that's what we write the policies against. Two things we have to keep working: the frontend accepts traffic from outside the mesh, and the loadgenerator has to keep reaching it. -->

---

# Next: make it visible (step 4)

- Prometheus scrapes every proxy: request counts, latency, TLS status, denials
- Grafana dashboard showing allowed vs. denied requests per service
- The attack from step 5 should show up on it live

[TODO Kacper: our own Prometheus or the one bundled with linkerd-viz?]

<!-- Kacper. linkerd-viz ships its own Prometheus, but it's meant for demos and keeps only a few hours of data, and Grafana stopped being bundled with Linkerd a while ago. So step 4 is mostly a decision about where metrics live, plus building one dashboard that makes the attack obvious. -->

---

# Questions?

Repo: [TODO: link]

<!-- Everyone. Backup: have the cluster running on one laptop in case someone asks to see tap live. -->
