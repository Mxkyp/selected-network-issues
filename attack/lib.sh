# Shared helpers for attack.sh and verify.sh. Source this file, do not run it.

# Use the pinned tools downloaded by setup.sh when they exist.
_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -d "$_repo_root/.tools" ] && export PATH="$_repo_root/.tools:$PATH"

# grpc_call <pod> <host:port/package.Service/Method>
# Sends one gRPC request from the given pod. The message is empty, which is enough to tell
# "denied by the proxy" from "reached the application".
# Prints one line: "<http_code> <grpc_status> <grpc_message>", using "none" for a missing value.
grpc_call() {
  local pod=$1 target=$2 out http status msg frame='\000\000\000\000\000'
  # shippingservice dereferences the address without a nil check and crashes on an empty
  # ShipOrder message, so that one call carries an empty Address (field 1, length 0).
  case "$target" in */ShipOrder) frame='\000\000\000\000\002\012\000' ;; esac
  out=$(kubectl exec "$pod" -c curl -- sh -c \
    "printf '$frame' | curl -s -m 8 -o /dev/null -D - --http2-prior-knowledge -X POST \
       -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @- http://$target" \
    2>/dev/null | tr -d '\r')
  http=$(printf '%s\n' "$out" | awk 'NR==1 && /^HTTP/ {print $2}')
  status=$(printf '%s\n' "$out" | awk 'tolower($1)=="grpc-status:" {s=$2} END {print s}')
  msg=$(printf '%s\n' "$out" | awk 'tolower($1)=="grpc-message:" {sub(/^[^ ]+ /,""); m=$0} END {print m}')
  echo "${http:-none} ${status:-none} ${msg}"
}

# redis_ping <pod>: prints what redis-cart answers to PING (empty when the connection is refused).
redis_ping() {
  kubectl exec "$1" -c curl -- sh -c "printf 'PING\r\n' | curl -s -m 5 telnet://redis-cart:6379" 2>/dev/null | tr -d '\r\n'
}
