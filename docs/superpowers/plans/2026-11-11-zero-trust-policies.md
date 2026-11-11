# Zero-Trust Authorization Policies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Online Boutique on the `sina` k3d cluster accepts only the callers and gRPC methods it needs, and a scripted attack that succeeds without policies is denied with them.

**Architecture:** One Linkerd `Server` per service port with `GRPCRoute`s per method group, each authorized by an `AuthorizationPolicy` against a `MeshTLSAuthentication` (callers) or `NetworkAuthentication` (kubelet probes, public frontend). A bash verification script drives three attacker pods and a real order through the frontend; it is written first and is the test for every policy task. Namespace default-deny is a second, separately gated phase.

**Tech Stack:** Linkerd edge-26.11.1 policy CRDs (`policy.linkerd.io`), Gateway API v1.2.1 `GRPCRoute`/`HTTPRoute`, kubectl, bash, `curlimages/curl`.

**Spec:** `docs/superpowers/specs/2026-11-11-zero-trust-policies-design.md` (read section 2 for what the spike proved and sections 4–5 for the matrix and resource shapes).

## Global Constraints

- All work happens on branch `step3-zero-trust-policies`, created from `master`. Before every commit run `git branch --show-current` and stop if it prints anything else.
- Every commit message references the issue it serves, in the repo's style (lowercase, past tense, issue in parentheses), e.g. `added attacker pods and verify script (#10)`. Issues: **#8** allow-matrix, **#9** policies and default-deny, **#10** attack script. Before the first commit re-check open issues (`gh issue list --state open`, or the public GitHub API if `gh` is not logged in) in case they changed.
- No `Co-Authored-By` or any other attribution trailer in commits.
- Stage files by explicit path. Never `git add -A` or `git add .`. The pending `.gitignore` change (latexmk build output) goes into the Task 0 commit, as Michał asked.
- Do not modify `app/kubernetes-manifests.yaml`, `setup.sh` or `setup.ps1`.
- All policy resources: namespace `default`, label `app.kubernetes.io/part-of: zero-trust-policies`. API versions: `Server` `policy.linkerd.io/v1beta3`; `AuthorizationPolicy`, `MeshTLSAuthentication`, `NetworkAuthentication` `policy.linkerd.io/v1alpha1`; `GRPCRoute` `gateway.networking.k8s.io/v1`.
- Run tools from the repo root with `export PATH="$PWD/.tools:$PATH"`.
- The cluster is shared state: tasks run strictly in order, one at a time.
- Bulk YAML generation (Task 4) is delegated to a Sonnet subagent (`model: sonnet`); the brief must repeat the branch, issue and no-co-author rules.

## Review Focus

1. **A pod restarted while policies are enforced** must become Ready again (probes pass from a cold start). Pinned in Task 6, step 5.
2. **Removing the policies** must return the cluster to the open state without restarts. Pinned in Task 6, step 6.
3. **Applying the policies twice** must be a no-op (no errors, nothing recreated). Pinned in Task 6, step 4.
4. **A cluster with a different node count** leaves pods on the extra node unready, because probe addresses are fixed. Pinned as a pre-flight check in `verify.sh` (Task 1) and documented in Task 8.
5. **Attacker pods missing or not Ready** must make `verify.sh` fail with a clear message, not report a pass. Pinned in Task 1, step 1.

---

### Task 0: Branch and design documents

**Files:**
- Commit: `docs/superpowers/specs/2026-11-11-zero-trust-policies-design.md`, `docs/superpowers/plans/2026-11-11-zero-trust-policies.md`

- [ ] **Step 1:** `git switch -c step3-zero-trust-policies master`; confirm with `git branch --show-current`.
- [ ] **Step 2:** Re-check open issues; confirm #8, #9, #10 are still open and assigned as described above.
- [ ] **Step 3:** Commit the two documents: `added design and plan for step 3 authorization policies (#9)`.

### Task 1: Attack tooling and verification script (issue #10)

**Files:**
- Create: `attack/attackers.yaml`, `attack/lib.sh`, `attack/attack.sh`, `attack/verify.sh`
- Create: `stage3/evidence/03-verify-before.txt`

**Interfaces:**
- Produces: pods `attacker-outside` (not meshed), `attacker-as-adservice` (annotation `linkerd.io/inject: enabled`, ServiceAccount `adservice`), `attacker-as-frontend` (same, ServiceAccount `frontend`); all `curlimages/curl:8.11.1`, container name `curl`, command `sleep infinity`, label `app.kubernetes.io/part-of: attack-simulation`.
- Produces: `attack/lib.sh` function `grpc_call <pod> <host:port/Service/Method>` printing one line `<http_code> <grpc_status|none> <grpc_message>`. It sends an empty gRPC frame exactly as in `stage2/evidence/09-attack-no-policies.txt` (HTTP/2 prior knowledge, 8 s timeout).
- Produces: `attack/attack.sh` (no arguments): applies nothing, runs `attacker-outside` and `attacker-as-adservice` against `paymentservice:50051/hipstershop.PaymentService/Charge` and `cartservice:7070/hipstershop.CartService/GetCart`, one line per call. This is the issue #10 deliverable.
- Produces: `attack/verify.sh [--expect-open]`: prints `PASS`/`FAIL <case>: expected X, got Y` per case, exits 1 if any case fails.

- [ ] **Step 1: Write `verify.sh` with these cases.** Pre-flight (fail fast with a message): the three attacker pods exist and are Ready; the cluster has exactly 3 nodes. Then, default mode:

| Case | From | Assertion |
|---|---|---|
| each method row of spec section 4 (14 methods) | `attacker-outside`, `attacker-as-adservice` | `grpc_status == 7` |
| `PaymentService/Charge`, `ShippingService/ShipOrder`, `EmailService/SendOrderConfirmation` | `attacker-as-frontend` | `grpc_status == 7` |
| `ShippingService/GetQuote` | `attacker-as-frontend` | status is a number other than 5 and 7 |
| `ProductCatalogService/SearchProducts` | all three | `grpc_status == 5` |
| `grpc.health.v1.Health/Check` on `paymentservice:50051` | all three | `grpc_status == 7` |
| `PING` to `redis-cart:6379` via `curl -m 5 telnet://` | all three | output has no `PONG` |
| order flow from the host against `http://localhost:8080` with a cookie jar: `GET /`, `POST /cart` (`product_id=OLJCESPC7Z`, `quantity=1`), `POST /cart/checkout` (the form fields the checkout page submits, test card `4432801561520454`) | host | every step HTTP 200 after redirects; final body contains the order-confirmation text |
| application pods | cluster | all `2/2`; restart counts equal before and after the run |

  `--expect-open` inverts the attack cases: every gRPC case must return a numeric status other than 7 (the application's own errors, including its own `NOT_FOUND`, count as reached); Redis must answer `PONG`; order flow and pod checks are unchanged.

- [ ] **Step 2:** `kubectl apply -f attack/attackers.yaml` and wait for Ready.
- [ ] **Step 3: Run `attack/verify.sh --expect-open`.** Expected: exit 0. Take the exact order-confirmation string from the live page here.
- [ ] **Step 4: Run `attack/verify.sh`.** Expected: exit 1, every attack case `FAIL`, order flow and pod cases `PASS`. This is the failing test for Tasks 3–5.
- [ ] **Step 5:** Run `attack/attack.sh`; output must match the four lines of `stage2/evidence/09-attack-no-policies.txt` in status codes.
- [ ] **Step 6:** Save the `--expect-open` output to `stage3/evidence/03-verify-before.txt`; commit `attack/` and that file: `added attacker pods, attack script and verify script (#10)`.

### Task 2: Allow-matrix from observed traffic (issue #8)

**Files:**
- Create: `policies/README.md`, `stage3/evidence/01-edges.txt`, `stage3/evidence/02-methods.txt`

**Interfaces:**
- Produces: the confirmed matrix in `policies/README.md`, the single source for Tasks 3–5.

- [ ] **Step 1:** Install the viz extension for observation only: `linkerd viz install | kubectl apply -f -`, then `linkerd viz check`. Do not add it to the setup scripts (step 4 owns that).
- [ ] **Step 2:** `linkerd viz edges deploy -n default > stage3/evidence/01-edges.txt`. Expected: the same 16 application edges as `stage2/evidence/04-edges.txt`.
- [ ] **Step 3:** For each of the nine gRPC deployments run `linkerd viz tap deploy/<svc> -n default` for about 90 s while placing one order in the browser, and reduce the output to distinct `(client ServiceAccount, :path)` pairs. Save all nine lists to `stage3/evidence/02-methods.txt`.
- [ ] **Step 4:** Compare with spec section 4. Expected: identical. If any pair differs, stop and report the difference to Michał before continuing; the matrix and the spec are then corrected first.
- [ ] **Step 5:** Write `policies/README.md` with the matrix (service, port, method, allowed identities) and the non-service traffic list issue #8 asks for: load balancer and `loadgenerator` to `frontend`, kubelet probes, Prometheus scrapes on port 4191.
- [ ] **Step 6:** Commit the three files: `added allow-matrix and observed call evidence (#8)`.

### Task 3: Shared authentications and `paymentservice` (issue #9)

**Files:**
- Create: `policies/00-authentications.yaml`, `policies/paymentservice.yaml`

**Interfaces:**
- Produces: `MeshTLSAuthentication` objects `callers-frontend`, `callers-checkout`, `callers-frontend-checkout`, `callers-frontend-recommendation`, `callers-cart` (each lists ServiceAccounts via `identityRefs`); `NetworkAuthentication` `kubelet-probes` (`10.42.0.1/32`, `10.42.1.1/32`, `10.42.2.1/32`, with a comment tying them to `cluster/k3d-config.yaml`) and `any-network` (`0.0.0.0/0`, `::/0`).
- Produces the per-service naming pattern every later file follows: `Server` `<svc>`; `GRPCRoute` `<svc>-health` and `<svc>-<group>`; each `AuthorizationPolicy` named after the route it targets.

- [ ] **Step 1:** Write both files. `paymentservice.yaml`: `Server` `paymentservice` (port 50051, `proxyProtocol: gRPC`, selector `app: paymentservice`); route `paymentservice-health` (`grpc.health.v1.Health`/`Check`) authorized by `kubelet-probes`; route `paymentservice-charge` (`hipstershop.PaymentService`/`Charge`) authorized by `callers-checkout`.
- [ ] **Step 2:** `kubectl apply -f policies/00-authentications.yaml -f policies/paymentservice.yaml`; wait 60 s.
- [ ] **Step 3: Verify.** `kubectl get pod -l app=paymentservice` shows `2/2` with an unchanged restart count; `attack/verify.sh` now prints `PASS` for all `paymentservice` cases and the order flow; `linkerd viz authz deploy/paymentservice` lists `checkoutservice` as the only authorized mesh identity (save to `stage3/evidence/06-authz-paymentservice.txt`).
- [ ] **Step 4:** Commit: `added shared authentications and paymentservice policy (#9)`.

### Task 4: Remaining eight gRPC services (issue #9)

**Files:**
- Create: `policies/adservice.yaml`, `cartservice.yaml`, `checkoutservice.yaml`, `currencyservice.yaml`, `emailservice.yaml`, `productcatalogservice.yaml`, `recommendationservice.yaml`, `shippingservice.yaml`

**Interfaces:**
- Consumes: the pattern and shared authentications from Task 3; the matrix in `policies/README.md`.

Delegate the writing to a Sonnet subagent, giving it `policies/paymentservice.yaml` as the template and the matrix. Route groups (methods with the same callers share a route):

| File | Port | Route: methods → authentication |
|---|---|---|
| `adservice` | 9555 | `getads`: `GetAds` → `callers-frontend` |
| `recommendationservice` | 8080 | `list`: `ListRecommendations` → `callers-frontend` |
| `checkoutservice` | 5050 | `placeorder`: `PlaceOrder` → `callers-frontend` |
| `emailservice` | 8080 | `send`: `SendOrderConfirmation` → `callers-checkout` |
| `cartservice` | 7070 | `read`: `GetCart`, `EmptyCart` → `callers-frontend-checkout`; `additem`: `AddItem` → `callers-frontend` |
| `currencyservice` | 7000 | `convert`: `Convert` → `callers-frontend-checkout`; `supported`: `GetSupportedCurrencies` → `callers-frontend` |
| `shippingservice` | 50051 | `quote`: `GetQuote` → `callers-frontend-checkout`; `shiporder`: `ShipOrder` → `callers-checkout` |
| `productcatalogservice` | 3550 | `getproduct`: `GetProduct` → `callers-frontend-checkout`; `list`: `ListProducts` → `callers-frontend-recommendation`; no route for `SearchProducts` |

Every file also has the `<svc>-health` route authorized by `kubelet-probes`.

- [ ] **Step 1:** Generate the eight files; review each against the table (ports, gRPC service names `hipstershop.<Name>`, authentication names).
- [ ] **Step 2:** `kubectl apply --dry-run=server -f policies/`. Expected: every object accepted.
- [ ] **Step 3:** Apply one file at a time. After each, wait 45 s and check that the service's pod is `2/2` with an unchanged restart count and `curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/` prints `200`. If a pod goes unready, `kubectl delete -f` that file and fix it before moving on.
- [ ] **Step 4: Run `attack/verify.sh`.** Expected: every gRPC case and the order flow `PASS`; only the three Redis cases still `FAIL`.
- [ ] **Step 5:** Commit the eight files: `added per-method policies for the remaining gRPC services (#9)`.

### Task 5: `frontend` and `redis-cart` (issue #9)

**Files:**
- Create: `policies/frontend.yaml`, `policies/redis-cart.yaml`

- [ ] **Step 1:** `frontend.yaml`: `Server` `frontend` (port 8080, `proxyProtocol: HTTP/1`), one `AuthorizationPolicy` on the `Server` requiring `any-network`; no routes. `redis-cart.yaml`: `Server` `redis-cart` (port 6379, `proxyProtocol: opaque`), two `AuthorizationPolicy` objects on the `Server`, requiring `callers-cart` and `kubelet-probes`.
- [ ] **Step 2:** Apply `frontend.yaml` first (unverified by the spike). Within 60 s check: frontend pod `2/2`, restart count unchanged, `http://localhost:8080/` returns 200 from the host, `loadgenerator` pod still Running and its log shows successful requests. If any check fails, delete the file and report before trying alternatives.
- [ ] **Step 3:** Apply `redis-cart.yaml`; after 60 s `linkerd diagnostics proxy-metrics deploy/redis-cart | grep inbound_tcp_authz_deny_total` shows no growing `no_identity` counter (probes are authorized).
- [ ] **Step 4: Run `attack/verify.sh`.** Expected: exit 0, all cases `PASS`.
- [ ] **Step 5:** Commit: `added frontend and redis-cart policies (#9)`.

### Task 6: Full rollout rehearsal and evidence (issue #9)

**Files:**
- Create: `stage3/evidence/04-audit.txt`, `stage3/evidence/05-verify-after.txt`

- [ ] **Step 1:** `kubectl delete -f policies/`; run `attack/verify.sh --expect-open`. Expected: exit 0.
- [ ] **Step 2: Audit pass.** Apply the policies with `accessPolicy: audit` added to every `Server` (generate with `sed` into the scratch directory, not into the repo). Place one order and run `attack/attack.sh`. Record in `04-audit.txt` how audited requests show up (proxy log lines and the `inbound_http_authz_*` series) and confirm no legitimate identity appears among them. If audit mode turns out not to apply to route-bound requests, record that finding in the file instead; Task 4 step 3 already served as the incremental check.
- [ ] **Step 3:** `kubectl apply -f policies/` (enforcing). Run `attack/verify.sh | tee stage3/evidence/05-verify-after.txt`. Expected: exit 0.
- [ ] **Step 4: Idempotency.** `kubectl apply -f policies/` again. Expected: every line ends in `unchanged`.
- [ ] **Step 5: Cold start under enforcement.** `kubectl rollout restart deploy/paymentservice deploy/frontend deploy/redis-cart` then `kubectl rollout status` for each (timeout 180 s). Expected: all complete; `attack/verify.sh` exits 0 (ignore its restart-count case for this one run by starting the script after the rollout finishes).
- [ ] **Step 6: Clean removal.** `kubectl delete -f policies/`, then `attack/verify.sh --expect-open` exits 0 with no pod restarted; finally `kubectl apply -f policies/` to leave the cluster protected.
- [ ] **Step 7:** Commit the two evidence files: `added audit and after-policy verification evidence (#9)`.

### Task 7: Namespace default-deny (issue #9) — gated

**Do not start until Michał confirms the scraper identity with Kacper** (issue #12). The default below assumes the `prometheus` ServiceAccount in namespace `linkerd-viz`.

**Files:**
- Create: `policies/namespace-default-deny/admin-port.yaml`, `stage3/evidence/07-verify-default-deny.txt`

- [ ] **Step 1:** Write `admin-port.yaml`: `Server` `proxy-admin` (all pods in `default`, port name `linkerd-admin`, `proxyProtocol: HTTP/1`); `HTTPRoute` `proxy-admin-probes` (paths `/live`, `/ready`) authorized by `kubelet-probes`; `HTTPRoute` `proxy-admin-metrics` (path `/metrics`) authorized by a new `MeshTLSAuthentication` `metrics-scraper` for the confirmed identity.
- [ ] **Step 2:** `kubectl apply -f policies/namespace-default-deny/`; `kubectl annotate ns default config.linkerd.io/default-inbound-policy=deny`; `kubectl rollout restart deploy -n default`; wait for every rollout (timeout 600 s). If any pod stays unready for more than 3 minutes, roll back (`kubectl annotate ns default config.linkerd.io/default-inbound-policy-`, delete the directory's resources, restart) and report.
- [ ] **Step 3: Verify.** All pods `2/2`; `attack/verify.sh` exits 0 (save to `07-verify-default-deny.txt`); after 2 minutes `linkerd viz stat deploy -n default` shows a success rate for every deployment and `linkerd viz edges deploy -n default` still lists the 16 edges; from `attacker-as-adservice`, `curl -s -o /dev/null -w '%{http_code}' http://<paymentservice pod IP>:4191/metrics` prints `403`.
- [ ] **Step 4:** If `linkerd viz tap deploy/paymentservice` no longer returns requests, add a `Server` for the proxy tap port (4190) to `admin-port.yaml` authorized for the `tap` ServiceAccount in `linkerd-viz`, re-apply and re-check.
- [ ] **Step 5:** Commit: `added namespace default-deny and proxy admin port policy (#9)`.

### Task 8: Documentation (issue #9)

**Files:**
- Modify: `policies/README.md`, `cluster/README.md`

- [ ] **Step 1:** Extend `policies/README.md`: how to apply and remove phase 1, how to enable and roll back phase 2, how to run `attack/verify.sh` in both modes (Windows: Git Bash or WSL), the three-node assumption behind `kubelet-probes`, and why attackers see status 7 on real methods but 5 on unrouted ones.
- [ ] **Step 2:** In `cluster/README.md` replace the sentence "There are no Authorization Policies yet, so any caller is still allowed." with a short pointer: the setup script leaves the cluster unprotected on purpose; policies live in `policies/`.
- [ ] **Step 3:** Follow every command in `policies/README.md` on the running cluster once; each must work as written.
- [ ] **Step 4:** Commit: `documented how to apply and verify the authorization policies (#9)`.
