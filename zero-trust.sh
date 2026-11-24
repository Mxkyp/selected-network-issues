#!/usr/bin/env bash
# Turns the Zero-Trust authorization policies on and off (Linux/macOS; Windows: zero-trust.ps1).
#
#   ./zero-trust.sh status     what is enabled right now
#   ./zero-trust.sh on         phase 1: per-service policies from policies/ + attacker test pods
#   ./zero-trust.sh off        back to the unprotected cluster (turns phase 2 off first if needed)
#   ./zero-trust.sh deny on    phase 2: namespace default-deny (restarts every pod, one at a time)
#   ./zero-trust.sh deny off   phase 2 off again (restarts every pod, one at a time)
#
# Details: policies/README.md and policies/namespace-default-deny/README.md.
set -euo pipefail
cd "$(dirname "$0")"
[ -d .tools ] && export PATH="$PWD/.tools:$PATH"

NS=default
PHASE1=app.kubernetes.io/part-of=zero-trust-policies
PHASE2=app.kubernetes.io/part-of=zero-trust-default-deny
ATTACKERS=app.kubernetes.io/part-of=attack-simulation
DENY_KEY=config.linkerd.io/default-inbound-policy

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; }

phase1_count() { kubectl get servers.policy.linkerd.io -n $NS -l $PHASE1 --no-headers 2>/dev/null | wc -l | tr -d ' '; }
phase1_total() { grep -l '^kind: Server' policies/*.yaml | wc -l | tr -d ' '; }
deny_value()   { kubectl get namespace $NS -o jsonpath="{.metadata.annotations.config\.linkerd\.io/default-inbound-policy}"; }

# Restart every deployment one at a time: restarting them all at once overloads a laptop.
restart_all() {
  local d
  for d in $(kubectl get deploy -n $NS -o name); do
    echo ">> Restarting $d"
    kubectl rollout restart -n $NS "$d" >/dev/null
    kubectl rollout status -n $NS "$d" --timeout=300s >/dev/null
  done
}

# The attacker pods are plain pods: they must be recreated to pick up a new default policy.
recreate_attackers() {
  kubectl delete pod -n $NS -l $ATTACKERS --ignore-not-found >/dev/null
  apply_attackers
}

apply_attackers() {
  echo ">> Attacker test pods"
  kubectl apply -f attack/attackers.yaml >/dev/null
  kubectl wait --for=condition=Ready pod -n $NS -l $ATTACKERS --timeout=180s >/dev/null
}

cmd_status() {
  local n total deny unmeshed attackers
  n=$(phase1_count); total=$(phase1_total); deny=$(deny_value)
  if [ "$n" -eq 0 ]; then echo "Phase 1 (per-service policies): OFF - the cluster is unprotected"
  elif [ "$n" -eq "$total" ]; then echo "Phase 1 (per-service policies): ON ($n/$total Servers)"
  else echo "Phase 1 (per-service policies): PARTIAL ($n/$total Servers) - run: ./zero-trust.sh on"; fi
  if [ "$deny" = deny ]; then echo "Phase 2 (namespace default-deny): ON"
  else echo "Phase 2 (namespace default-deny): OFF"; fi
  attackers=$(kubectl get pods -n $NS -l $ATTACKERS --no-headers 2>/dev/null | awk '{printf "%s(%s) ", $1, $2}')
  echo "Attacker test pods: ${attackers:-none (kubectl apply -f attack/attackers.yaml, or re-run ./setup.sh)}"
  unmeshed=$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.annotations.linkerd\.io/inject} {.spec.initContainers[*].name} {.spec.containers[*].name}{"\n"}{end}' \
    | awk '$2 == "enabled" && $0 !~ / linkerd-proxy( |$)/ {printf "%s ", $1}')
  [ -n "$unmeshed" ] && echo "WARNING: pods without the Linkerd proxy (re-run ./setup.sh to fix): $unmeshed"
  return 0
}

cmd_on() {
  echo ">> Applying the per-service policies (policies/)"
  kubectl apply -f policies/ >/dev/null
  apply_attackers
  echo ">> Done. Give the proxies a few seconds before testing: attack/verify.sh"
}

cmd_off() {
  [ "$(deny_value)" = deny ] && cmd_deny_off
  echo ">> Removing the per-service policies"
  # By label with Servers first: a Server whose authorizations are already gone denies everything.
  kubectl delete -n $NS server,grpcroute,authorizationpolicy,meshtlsauthentication,networkauthentication -l $PHASE1 >/dev/null
  apply_attackers
  echo ">> Done. The cluster is unprotected: attack/verify.sh --expect-open"
}

cmd_deny_on() {
  if [ "$(phase1_count)" -ne "$(phase1_total)" ]; then
    echo "Phase 1 is not fully on; default-deny without it blocks the whole shop. Run ./zero-trust.sh on first." >&2
    exit 1
  fi
  if [ -z "$(kubectl get deploy -n linkerd-viz prometheus --ignore-not-found -o name)" ]; then
    echo "NOTE: linkerd-viz is not installed, so after this nothing may scrape the proxy metrics. See policies/namespace-default-deny/README.md." >&2
  fi
  echo ">> Applying the proxy admin port policy"
  kubectl apply -f policies/namespace-default-deny/admin-port.yaml >/dev/null
  kubectl annotate namespace $NS $DENY_KEY=deny --overwrite >/dev/null
  restart_all
  recreate_attackers
  echo ">> Done. Phase 2 is on."
}

cmd_deny_off() {
  echo ">> Turning namespace default-deny off"
  kubectl annotate namespace $NS $DENY_KEY- >/dev/null 2>&1 || true
  restart_all
  kubectl delete -n $NS server,httproutes.policy.linkerd.io,authorizationpolicy,meshtlsauthentication -l $PHASE2 >/dev/null
  recreate_attackers
  echo ">> Done. Phase 2 is off."
}

case "${1:-status}:${2:-}" in
  status:)  cmd_status ;;
  on:)      cmd_on; cmd_status ;;
  off:)     cmd_off; cmd_status ;;
  deny:on)  cmd_deny_on; cmd_status ;;
  deny:off) cmd_deny_off; cmd_status ;;
  -h:|--help:|help:) usage ;;
  *) usage >&2; exit 2 ;;
esac
