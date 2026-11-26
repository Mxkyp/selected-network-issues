#!/usr/bin/env python3
"""Overhead of the service mesh and the authorization policies on a running k3d cluster.

Variants: A = no mesh, B = mesh (mTLS), C = mesh + policies/.
Run from anywhere: python stage4/performance/run.py   (finished runs in raw/ are skipped).
The cluster is left in variant C, with the load generator running again.
"""
import ctypes
import json
import os
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
RAW = HERE / "raw"
os.environ["PATH"] = str(ROOT / ".tools") + os.pathsep + os.environ["PATH"]

ROUNDS = 3
DURATION = 60
RATE = 20
CONNECTIONS = 8
POLICY_LABEL = "app.kubernetes.io/part-of=zero-trust-policies"
GRPC = ["-h2", "-content-type", "application/grpc", "-H", "te:trailers",
        "-payload-file", "/payload/grpc-empty"]
# Standard Go client: the fast fortio client truncated some chunked product pages without the mesh.
HTTP = ["-stdclient"]
# name -> (client pod, extra fortio flags, URL)
TARGETS = {
    "home": ("perf-outside", HTTP, "http://frontend:80/"),
    "product": ("perf-outside", HTTP, "http://frontend:80/product/OLJCESPC7Z"),
    "grpc": ("perf-frontend-id", GRPC,
             "http://productcatalogservice:3550/hipstershop.ProductCatalogService/ListProducts"),
}
VARIANTS = {"A": "no mesh", "B": "mesh (mTLS)", "C": "mesh + policies"}


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def sh(*args, stdin=None, check=True, timeout=900):
    for attempt in range(3):
        p = subprocess.run(args, input=stdin, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", cwd=ROOT, timeout=timeout)
        if p.returncode == 0 or not check:
            return p.stdout
        log(f"retry {attempt + 1}: {' '.join(args)}: {p.stderr.strip()[-300:]}")
        time.sleep(10)
    raise RuntimeError(f"failed: {' '.join(args)}")


def kj(*args):
    return json.loads(sh("kubectl", *args, "-o", "json"))


def deployments():
    return [d["metadata"]["name"] for d in kj("get", "deploy", "-n", "default")["items"]]


def policies(on):
    if on:
        sh("kubectl", "apply", "-f", "policies/")
    else:
        sh("kubectl", "delete", "-n", "default",
           "server,grpcroute,authorizationpolicy,meshtlsauthentication,networkauthentication",
           "-l", POLICY_LABEL)


def app_pods():
    return [p for p in kj("get", "pods", "-n", "default")["items"]
            if p["metadata"].get("labels", {}).get("app") not in (None, "perf-client", "loadgenerator")
            and p["metadata"].get("ownerReferences")]


def has_proxy(pod):
    spec = pod["spec"]
    return any(c["name"] == "linkerd-proxy"
               for c in spec["containers"] + spec.get("initContainers", []))


def wait_settled():
    for name in deployments():
        if name != "loadgenerator":
            sh("kubectl", "rollout", "status", f"deploy/{name}", "-n", "default", "--timeout=600s")
    for _ in range(60):
        pods = kj("get", "pods", "-n", "default")["items"]
        if not any(p["metadata"].get("deletionTimestamp") for p in pods):
            return
        time.sleep(5)
    raise RuntimeError("old pods did not terminate")


def clients(meshed):
    existing = kj("get", "pods", "-n", "default", "-l", "app=perf-client")["items"]
    for p in existing:
        if p["metadata"]["name"] == "perf-frontend-id" and has_proxy(p) != meshed:
            sh("kubectl", "delete", "pod", "perf-frontend-id", "-n", "default", "--wait=true")
    manifest = (HERE / "clients.yaml").read_text(encoding="utf-8")
    manifest = manifest.replace("INJECT", "enabled" if meshed else "disabled")
    sh("kubectl", "apply", "-f", "-", stdin=manifest)
    sh("kubectl", "wait", "--for=condition=Ready", "pod", "-l", "app=perf-client",
       "-n", "default", "--timeout=300s")


def switch(variant):
    log(f"switching to variant {variant} ({VARIANTS[variant]})")
    meshed = variant != "A"
    policies(False)
    current = [has_proxy(p) for p in app_pods()]
    if not current or any(c != meshed for c in current):
        if meshed:
            manifest = sh("linkerd", "inject", "--native-sidecar", "app/kubernetes-manifests.yaml")
            sh("kubectl", "apply", "-f", "-", stdin=manifest)
        else:
            sh("kubectl", "apply", "-f", "app/kubernetes-manifests.yaml")
    sh("kubectl", "scale", "deploy/loadgenerator", "-n", "default", "--replicas=0")
    wait_settled()
    if variant == "C":
        policies(True)
    clients(meshed)
    time.sleep(20)
    wrong = [p["metadata"]["name"] for p in app_pods() if has_proxy(p) != meshed]
    servers = len(kj("get", "servers.policy.linkerd.io", "-n", "default", "-l", POLICY_LABEL)["items"])
    if wrong or (servers > 0) != (variant == "C"):
        raise RuntimeError(f"variant {variant} not in place: wrong={wrong} servers={servers}")
    log(f"variant {variant} ready: {len(app_pods())} app pods, {servers} policy Servers; warming up")
    for name in TARGETS:
        load(name, 10, 20)


def load_command(target, qps, seconds):
    pod, flags, url = TARGETS[target]
    return ["kubectl", "exec", "-n", "default", pod, "-c", "fortio", "--", "fortio", "load", *flags,
            "-qps", str(qps), "-c", str(CONNECTIONS), "-t", f"{seconds}s", "-uniform",
            "-timeout", "10s", "-p", "50,90,99", "-allow-initial-errors", "-quiet", "-json", "-", url]


def load(target, qps, seconds):
    return sh(*load_command(target, qps, seconds), check=False, timeout=seconds + 120)


def measure(variant, rnd, target, mode):
    out = RAW / f"{variant}-r{rnd}-{target}-{mode}.json"
    if out.exists():
        return
    qps = RATE if mode == "fixed" else 0
    for attempt in range(2):
        proc = subprocess.Popen(load_command(target, qps, DURATION), stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True, encoding="utf-8", cwd=ROOT)
        time.sleep(DURATION * 0.75)
        top = sh("kubectl", "top", "pods", "-n", "default", "--containers", "--no-headers", check=False)
        stdout, _ = proc.communicate(timeout=DURATION + 120)
        try:
            result = json.loads(stdout[stdout.index("{\n"):])
            break
        except ValueError:
            log(f"no result for {out.name}, attempt {attempt + 1}")
            time.sleep(20)
    else:
        raise RuntimeError(f"no result for {out.name}")
    result["Top"] = top
    out.write_text(json.dumps(result), encoding="utf-8")
    pct = {p["Percentile"]: p["Value"] * 1000 for p in result["DurationHistogram"]["Percentiles"]}
    log(f"{out.stem}: {result['ActualQPS']:.1f} rps, p50 {pct[50]:.1f} / p90 {pct[90]:.1f} / "
        f"p99 {pct[99]:.1f} ms, codes {result['RetCodes']}, body {result['Sizes']['Min']:.0f}-"
        f"{result['Sizes']['Max']:.0f}")
    time.sleep(5)


def usage(top):
    """CPU (millicores) and memory (MiB) of the shop pods, split into proxies and the rest."""
    total = {"app_cpu": 0, "app_mem": 0, "proxy_cpu": 0, "proxy_mem": 0}
    for line in top.splitlines():
        parts = line.split()
        if len(parts) != 4 or parts[0].startswith(("perf-", "attacker-", "loadgenerator")):
            continue
        kind = "proxy" if parts[1] == "linkerd-proxy" else "app"
        total[kind + "_cpu"] += int(re.sub(r"\D", "", parts[2]))
        total[kind + "_mem"] += int(re.sub(r"\D", "", parts[3]))
    return total


def summarize():
    rows = {}
    for path in sorted(RAW.glob("*.json")):
        variant, _, target, mode = path.stem.split("-")
        r = json.loads(path.read_text(encoding="utf-8"))
        pct = {p["Percentile"]: p["Value"] * 1000 for p in r["DurationHistogram"]["Percentiles"]}
        count = sum(r["RetCodes"].values())
        errors = count - r["RetCodes"].get("200", 0)
        row = {"rps": r["ActualQPS"], "p50": pct[50], "p90": pct[90], "p99": pct[99],
               "errors": errors, "body_min": r["Sizes"]["Min"], **usage(r["Top"])}
        rows.setdefault((target, mode, variant), []).append(row)
    lines = ["# Overhead of the mesh and the authorization policies", "",
             f"Median of {ROUNDS} runs of {DURATION} s, {CONNECTIONS} connections; fixed rate = {RATE} rps.",
             "A = no mesh, B = mesh (mTLS), C = mesh + policies. CPU and memory: all shop pods, "
             "from one `kubectl top` sample per run.", ""]
    for mode in ("fixed", "max"):
        lines += [f"## {'Fixed rate' if mode == 'fixed' else 'Maximum throughput'}", "",
                  "| Target | Variant | Runs | rps | p50 ms | p90 ms | p99 ms | p99 range | Errors | "
                  "App CPU m | Proxy CPU m | App MiB | Proxy MiB | Min body B |",
                  "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for target in TARGETS:
            for variant in VARIANTS:
                runs = rows.get((target, mode, variant))
                if not runs:
                    continue
                med = lambda k: statistics.median(x[k] for x in runs)
                p99 = [x["p99"] for x in runs]
                lines.append(
                    f"| {target} | {variant} | {len(runs)} | {med('rps'):.1f} | {med('p50'):.1f} | "
                    f"{med('p90'):.1f} | {med('p99'):.1f} | {min(p99):.0f}-{max(p99):.0f} | "
                    f"{sum(x['errors'] for x in runs)} | {med('app_cpu'):.0f} | {med('proxy_cpu'):.0f} | "
                    f"{med('app_mem'):.0f} | {med('proxy_mem'):.0f} | {min(x['body_min'] for x in runs):.0f} |")
        lines.append("")
    (HERE / "summary.md").write_text("\n".join(lines), encoding="utf-8")


def pin():
    """Keep every deployment on its current node, so all variants have the same placement."""
    for p in app_pods():
        name = p["metadata"]["labels"]["app"]
        d = kj("get", "deploy", name, "-n", "default")
        if not d["spec"]["template"]["spec"].get("nodeSelector"):
            patch = {"spec": {"template": {"spec": {"nodeSelector":
                     {"kubernetes.io/hostname": p["spec"]["nodeName"]}}}}}
            sh("kubectl", "patch", "deploy", name, "-n", "default", "-p", json.dumps(patch))
            log(f"pinned {name} to {p['spec']['nodeName']}")
    wait_settled()


def restore():
    log("restoring the cluster")
    switch("C")
    for name in deployments():
        d = kj("get", "deploy", name, "-n", "default")
        if d["spec"]["template"]["spec"].get("nodeSelector"):
            sh("kubectl", "patch", "deploy", name, "-n", "default", "--type=json", "-p",
               '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]')
    sh("kubectl", "delete", "pod", "-n", "default", "-l", "app=perf-client", "--wait=true")
    sh("kubectl", "delete", "configmap", "perf-payload", "-n", "default", "--ignore-not-found")
    wait_settled()
    sh("kubectl", "scale", "deploy/loadgenerator", "-n", "default", "--replicas=1")
    sh("kubectl", "rollout", "status", "deploy/loadgenerator", "-n", "default", "--timeout=600s")
    log("restored: variant C, load generator running, pins and test pods removed")


def main():
    if os.name == "nt":  # no idle sleep while this process runs; settings stay unchanged
        ctypes.windll.kernel32.SetThreadExecutionState(0x80000001)
    if sh("kubectl", "config", "current-context").strip() != "k3d-sina":
        sys.exit("kubectl context is not k3d-sina")
    RAW.mkdir(exist_ok=True)
    try:
        sh("kubectl", "scale", "deploy/loadgenerator", "-n", "default", "--replicas=0")
        pin()
        for rnd in range(1, ROUNDS + 1):
            for variant in VARIANTS:
                todo = [(t, m) for t in TARGETS for m in ("fixed", "max")
                        if not (RAW / f"{variant}-r{rnd}-{t}-{m}.json").exists()]
                if not todo:
                    continue
                switch(variant)
                for target, mode in todo:
                    measure(variant, rnd, target, mode)
                summarize()
                log(f"round {rnd} variant {variant} done")
    finally:
        summarize()
        restore()
    log("ALL DONE")


if __name__ == "__main__":
    main()
