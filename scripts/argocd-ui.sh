#!/usr/bin/env bash

set -euo pipefail

namespace="argocd"
local_port="8081"
bind_address="127.0.0.1"
kube_context="${KUBE_CONTEXT:-kind-gitops-thesis}"

usage() {
  cat <<'EOF'
Usage: scripts/argocd-ui.sh [options]

Open a local port-forward to the Argo CD API server and web UI.

Options:
  --namespace NAMESPACE   Argo CD namespace (default: argocd)
  --port PORT             Local HTTPS forwarding port (default: 8081)
  --address ADDRESS       Local bind address (default: 127.0.0.1)
  --context NAME          kubeconfig context (default: kind-gitops-thesis)
  -h, --help              Show this help
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "${value}" && "${value}" != --* ]] \
    || fail "${option} requires a value"
}

while (($# > 0)); do
  case "$1" in
    --namespace)
      require_value "$1" "${2:-}"
      namespace="$2"
      shift 2
      ;;
    --port)
      require_value "$1" "${2:-}"
      local_port="$2"
      shift 2
      ;;
    --address)
      require_value "$1" "${2:-}"
      bind_address="$2"
      shift 2
      ;;
    --context)
      require_value "$1" "${2:-}"
      kube_context="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"
[[ "${local_port}" =~ ^[0-9]+$ ]] \
  || fail "port must be an integer: ${local_port}"
((local_port >= 1 && local_port <= 65535)) \
  || fail "port must be in the range 1-65535: ${local_port}"

kubectl --context "${kube_context}" get service argocd-server --namespace "${namespace}" >/dev/null \
  || fail "argocd-server service was not found in namespace ${namespace}"

printf 'Argo CD UI: https://%s:%s\n' "${bind_address}" "${local_port}"
printf '%s\n' \
  'Username: admin' \
  'Retrieve the initial password in another terminal with:' \
  "kubectl --context ${kube_context} --namespace ${namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode; echo"
printf 'Press Ctrl+C to stop forwarding.\n'

exec kubectl --context "${kube_context}" port-forward --namespace "${namespace}" \
  --address "${bind_address}" service/argocd-server "${local_port}:443"
