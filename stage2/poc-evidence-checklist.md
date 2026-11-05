# PoC evidence checklist (Jędrzej)

Nothing from step 2 is on record yet, and both the slides and the report need it. Run these against the meshed cluster and drop the outputs/screenshots into `stage2/evidence/`. Plan on 30–45 minutes, most of it the before/after capture.

Write down the Linkerd version you installed (`linkerd version`) and how you installed it (CLI or Helm). The report asks for both.

## 1. The mesh is healthy

```bash
linkerd check            > stage2/evidence/01-check.txt
linkerd check --proxy    > stage2/evidence/02-check-proxy.txt
kubectl get pods         > stage2/evidence/03-pods.txt   # every app pod should show 2/2
```

## 2. Every edge is mTLS

```bash
linkerd viz edges deploy -n default > stage2/evidence/04-edges.txt
```

Screenshot it too, since the `SECURED` column full of checkmarks is the slide.

## 3. Live requests carry TLS

```bash
linkerd viz tap deploy/checkoutservice --to deploy/paymentservice | head -20 \
  > stage2/evidence/05-tap.txt
```

Each line should contain `tls=true`. Place an order in the shop if the loadgenerator hasn't hit checkout in a while.

## 4. Before/after packet capture (the important one)

You can't run tcpdump inside the app pods: the images are distroless, and the pods set `runAsNonRoot: true`, so a root debug container gets rejected. Capture from the node instead, which has the side benefit of only seeing traffic as it leaves the pod (the app→proxy hop on loopback stays plaintext even when mTLS works, and that would confuse the picture).

```bash
# which node runs paymentservice, and its pod IP
kubectl get pod -l app=paymentservice -o wide
```

**Before (take paymentservice out of the mesh):**

```bash
kubectl patch deploy paymentservice -p \
  '{"spec":{"template":{"metadata":{"annotations":{"linkerd.io/inject":"disabled"}}}}}'
kubectl rollout status deploy/paymentservice
kubectl get pod -l app=paymentservice -o wide      # new IP, should be 1/1

kubectl debug node/<NODE> -it --profile=sysadmin --image=nicolaka/netshoot -- \
  tcpdump -i any -A -s0 -c 300 'host <POD_IP> and tcp port 50051'
```

Save the output as `06-before.txt`. Look for readable strings in the payload (card data from the loadgenerator's checkout calls should show up). Screenshot the juiciest part.

**After (put it back):**

The setup scripts add `linkerd.io/inject: enabled` to the pod template and the namespace has no annotation, so set it back to `enabled` instead of removing it.

```bash
kubectl patch deploy paymentservice -p \
  '{"spec":{"template":{"metadata":{"annotations":{"linkerd.io/inject":"enabled"}}}}}'
kubectl rollout status deploy/paymentservice
kubectl get pod -l app=paymentservice -o wide      # 2/2 again, note the new IP/node
```

Run the same tcpdump against the new pod IP and node and save it as `07-after.txt`. It should be unreadable TLS. If you see no packets at all, drop the port filter and keep only `host <POD_IP>`: the proxies may talk on the inbound proxy port (4143) instead of 50051.

## 5. Resource cost (for the report)

k3s ships metrics-server, so this works out of the box:

```bash
kubectl top pods --containers > stage2/evidence/08-top-meshed.txt
kubectl top pods -n linkerd   >> stage2/evidence/08-top-meshed.txt
```

That gives us a real number for the proxies' memory instead of a guess.

## 6. Commit your setup

Add whatever you ran to install Linkerd to the repo (ideally as a step in `setup.sh`/`setup.ps1` with a pinned version, like k3d and kubectl already are), so the others can reproduce it before the demo.
