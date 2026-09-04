#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: experiments/smoke-test.sh --tool argocd|fluxcd [options]

Checks /health, /ready and /version through the Kubernetes Service proxy.
EOF
  common_options
}

parse_common_args "$@"
set -- "${COMMON_REMAINING_ARGS[@]}"
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
require_commands kubectl python3

service_name="$(kubectl -n "${NAMESPACE}" get service \
  -l "app.kubernetes.io/name=${SERVICE}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${service_name}" ]] || die "Cannot find Service for ${SERVICE} in ${NAMESPACE}"
service_port="$(kubectl -n "${NAMESPACE}" get service "${service_name}" -o jsonpath='{.spec.ports[0].port}')"

for endpoint in health ready version; do
  path="/api/v1/namespaces/${NAMESPACE}/services/http:${service_name}:${service_port}/proxy/${endpoint}"
  response="$(kubectl get --raw "${path}")" || die "GET /${endpoint} failed"
  python3 -c '
import json
import sys

endpoint, expected_service, raw = sys.argv[1:]
payload = json.loads(raw)
if not isinstance(payload, dict) or payload.get("service") != expected_service:
    raise SystemExit(1)
if endpoint == "health" and payload.get("status") != "healthy":
    raise SystemExit(1)
if endpoint == "ready" and payload.get("status") != "ready":
    raise SystemExit(1)
if endpoint == "version" and not str(payload.get("version", "")).strip():
    raise SystemExit(1)
if not str(payload.get("hostname", "")).strip():
    raise SystemExit(1)
' "${endpoint}" "${SERVICE}" "${response}" || \
    die "GET /${endpoint} returned an invalid payload for ${SERVICE}"
  printf '/%s: %s\n' "${endpoint}" "${response}"
done
