> Lodz University of Technology
> Faculty of Technical Physics, Information Technology and Applied Mathematics
> Institute of Information Technology

> Selected Issues of Network Applications
> 2026/2027

# Modern Service Mesh: a better way to secure communication between microservices

## Stage 2 report: Proof of Concept

```
Jędrzej Bartoszewski, 251482
Michał Domagała, 251505
Kacper Maziarz, 251586
Mikołaj Pawłoś, 258681
```

The problem definition, the choice of tools and the functional requirements are unchanged from the stage 1 report. This report covers what we built during the Proof of Concept stage and what we learned while doing it.

## 1. Work progress to date

| # | Step | Planned | Status |
|---|------|---------|--------|
| 1 | k3d cluster and Online Boutique | Weeks 3–4 | Done |
| 2 | Linkerd with mTLS (Proof of Concept) | Weeks 5–6, deadline 6.11.2026 | Done |
| 3 | Zero-Trust authorization policies | Week 7 | Next |
| 4 | Prometheus and Grafana | Week 8 | Planned |
| 5 | Attack simulation | Week 9, deadline 27.11.2026 | Planned |

We met the 6.11 deadline for both Proof of Concept steps, and the plan for steps 3–5 stays as it was.

### Step 1: cluster and test application

The whole environment comes up with one script: `setup.sh` on Linux and macOS, `setup.ps1` on Windows. Docker is the only thing a team member has to install. The script downloads pinned versions of k3d (v5.9.0) and kubectl (v1.37.2) into a local `.tools/` directory, so it needs no admin rights and ignores whatever versions happen to be installed system-wide. It then creates a k3d cluster named `sina` with one server and two agent nodes (`cluster/k3d-config.yaml`), applies the Online Boutique v0.10.7 release manifest, waits up to ten minutes for every deployment to become available and port-forwards the shop to `http://localhost:8081`.

Re-running the script reuses the existing cluster, which means anyone can run it again after a failed attempt without cleaning up first. We also mapped host port 8080 to the k3d load balancer, unused for now, so a later Ingress needs no cluster rebuild. `cluster/README.md` lists the failures we expect people to hit: pods stuck in `Pending` or `OOMKilled` when Docker has too little memory, Docker Desktop without WSL2 integration on Windows, and Podman in place of Docker on Linux.

### Step 2: Linkerd and mutual TLS

[TODO Kacper: Linkerd version (`linkerd version`), install method (CLI or Helm), the exact commands, and where they live in the repo.]

We installed the Linkerd CRDs and control plane, confirmed the installation with `linkerd check`, and enabled automatic proxy injection for the `default` namespace with the `linkerd.io/inject: enabled` annotation. Restarting the deployments then gave every Online Boutique pod a second container, the `linkerd-proxy` sidecar, which takes over the pod's inbound and outbound traffic. The application code and the manifests stayed untouched; the only change was one annotation on the namespace.

We checked the result three ways.

1. `linkerd viz edges` lists every connection between deployments and whether it's secured. [TODO: Figure 1, edges output. State whether every edge showed as secured; if some didn't, say which ones and why.]
2. `linkerd viz tap` streams individual live requests. Requests from `checkoutservice` to `paymentservice` carry `tls=true`. [TODO: Figure 2, tap output.]
3. A packet capture of `paymentservice` traffic, taken once with the service out of the mesh and once inside it. Without the proxy, [TODO: what was readable in the payload]. With the proxy, the same capture shows only TLS records. [TODO: Figures 3 and 4.]

The third check is the one we'll reuse in the final demo, because it shows the difference to anyone, Kubernetes background or not.

## 2. Insights and challenges

### Encryption isn't access control

This is the most important thing we learned in the PoC stage, and it changes how we present the project. After step 2, every connection between meshed services runs over mutual TLS, and each proxy knows the identity of its caller, derived from the caller's Kubernetes ServiceAccount (Online Boutique gives each of its 11 services its own). That stops eavesdropping and impersonation.

It doesn't stop lateral movement. Linkerd's default inbound policy is `all-unauthenticated`, so a meshed service still accepts requests from any other meshed service and even from a pod outside the mesh speaking plaintext. An attacker who controls `adservice` can't read the traffic between checkout and payments anymore, but can still call `paymentservice` directly and get an answer. [TODO: confirm with a quick test from a plain `kubectl run` pod, if time allows.] Closing that gap is exactly what step 3 is for, and the schedule already has it in the right order; we just hadn't appreciated how big that gap would look on a slide until we had mTLS running.

### Injection happens at pod start

The namespace annotation only affects pods created after it's set. Pods that were already running keep working without a proxy until their deployment restarts, and the app works fine either way, so nothing tells you that half the mesh is missing. `kubectl get pods` (2/2 containers instead of 1/1) and `linkerd check --proxy` both catch it. [TODO: say whether we actually ran into this, or drop the subsection.]

### Proving encryption took more effort than enabling it

Turning on mTLS took a few commands. Showing it to someone else took longer. Online Boutique images are distroless, with no shell and no tcpdump, and the pods set `runAsNonRoot: true`, which blocks the usual trick of attaching a root debug container. We captured from the node instead, using `kubectl debug node/... --profile=sysadmin`.

That route has a second advantage. Inside a meshed pod, the hop from the application to its own proxy goes over loopback and stays plaintext; a capture there would show readable traffic and look as if mTLS had failed. From the node you only see what leaves the pod, which is the traffic an attacker could reach.

### Linkerd's release model

Since Linkerd 2.15 (February 2024), the open-source project publishes only edge releases, and stable builds come from Buoyant, the company behind Linkerd. We used edge release [TODO: version]. For a student project that's fine, but edge releases can change behaviour between versions, so we'll pin the version in our setup scripts the same way we pinned k3d and kubectl.

### Resource cost

Each of the [TODO: number] application pods now runs an extra proxy container, plus the Linkerd control plane and the viz extension. [TODO: memory used by the proxies and the control plane, from `kubectl top pods --containers` and `kubectl top pods -n linkerd`.] [TODO: did anyone's laptop struggle? If yes, how much memory did Docker need?]

[TODO: any other real problem from the team's notes, e.g. something specific to Windows or Podman. Drop this line if there's nothing.]

## 3. Impact on the next steps

**Step 3 (Michał).** We'll switch the namespace to a default-deny inbound policy and then allow only the calls Online Boutique actually makes, written as Linkerd `Server`, `AuthorizationPolicy` and `MeshTLSAuthentication` resources against the per-service identities. `paymentservice`, for example, will accept only the `checkoutservice` identity. Two things have to keep working: the frontend receives traffic from outside the mesh, and the loadgenerator must still reach it.

**Step 4 (Kacper).** `linkerd-viz` comes with its own Prometheus, but that instance is meant for short-term data, and Linkerd no longer bundles Grafana. We need to decide whether to run a separate Prometheus that scrapes the proxies or to build on the bundled one. [TODO Kacper: decision.] Either way, the goal is one Grafana dashboard where the step 5 attack shows up as denied requests.

**Step 5 (Michał).** We'll run the same attack twice, once from a pod outside the mesh and once from inside a compromised `adservice`, both calling `paymentservice`. Before step 3 both calls succeed; afterwards both should fail with gRPC `PermissionDenied`.
