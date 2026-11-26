# Performance overhead of the mesh and the authorization policies

Measured on 2026-11-26 on the local k3d cluster `sina` (one laptop, Docker with 8 CPUs).
Numbers are in [`summary.md`](summary.md), per-run results in `raw/`, the run log in `run.log`.

## What was tested

How much the service mesh and the Zero-Trust policies slow the shop down and how much CPU and
memory they use. These are performance tests only; whether the attack is blocked is checked by
`attack/attack.sh` and `attack/verify.sh`.

## What was done

1. Wrote `run.py` (switches the cluster between variants, runs the load, writes the tables) and
   `clients.yaml` (the two load generator pods).
2. Ran trial loads to check that 20 rps is sustainable and that the direct gRPC call returns data.
3. Ran 54 measurements: 3 targets x 2 load modes x 3 variants x 3 rounds. Before each variant the
   script checked that the shop pods did or did not have a proxy and that the policies were on only in C.
4. Restored the cluster to its state before the tests (variant C, load generator running, test
   pods and node pinning removed).

## Method

| Variant | State |
|---|---|
| A | no Linkerd proxies in the shop, no policies |
| B | meshed (mTLS), no policies |
| C | meshed, `policies/` applied (phase 1) |

- `fortio` 1.69.5, 8 connections, 60 s per run, 3 rounds in the order A, B, C; tables show the median.
- Fixed rate (20 rps) for latency, unlimited rate for maximum throughput.
- `home` and `product`: the `frontend`, called from a pod outside the mesh (standard Go client).
- `grpc`: `ProductCatalogService/ListProducts` called directly from a pod with the `frontend`
  ServiceAccount, meshed in B and C, because the policies deny unknown callers.
- The Linkerd control plane and `linkerd-viz` stayed installed in every variant, also in A;
  the tables count only the shop pods.
- `loadgenerator` scaled to 0; every deployment pinned to the same node in all variants;
  20 s warm-up per target after each switch.
- Repeat with `python3 stage4/performance/run.py` (finished runs in `raw/` are skipped).

## Findings

- **mTLS adds latency (A to B, median p50 at 20 rps):** direct gRPC 0.8 to 1.7 ms, product page
  10.9 to 22.7 ms, home page 16.4 to 28.3 ms.
- **Policies add no measurable latency (B to C):** p50 differs by less than 1 ms on all targets.
- **Page throughput is about the same** in all variants (home 45-47 rps, product 56-58 rps).
- **CPU:** at 20 rps on the pages the proxies used about 270-290 millicores in total; all shop pods
  together used roughly 50 % more than without the mesh (home about 40-50 %, product about 55 %).
- **Memory:** about 40 MiB for all proxies, about 3.6 MiB each.

## Limits

- Laptop k3d numbers only support relative comparisons between the variants.
- The shop containers have low CPU limits (mostly 200m), so maximum throughput and tail latency
  mostly reflect CPU throttling.
- p99 is noisy (for example product, max, B: 246-999 ms). Differences in p90 and p99 between B
  and C are not evidence of a policy effect.
- Direct gRPC maximum throughput was higher with the mesh (about 1150 vs 970 rps). The cause was
  not investigated.
- CPU and memory come from a single `kubectl top` sample per run.
- The cost of denied requests was not measured.
- A first attempt used fortio's fast HTTP client, which reported truncated product pages without
  the mesh (`run-aborted-fastclient.log`). Its results were discarded; with the standard client
  no run had errors.
