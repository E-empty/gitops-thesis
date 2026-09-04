#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: install-metrics-server.sh [options]

Installs a pinned Metrics Server release and waits until its APIService is
available. Kind normally requires --kubelet-insecure-tls; this script adds that
argument by default.

Options:
  --context NAME       kubectl context (default: kind-$KIND_CLUSTER_NAME).
  --version VERSION    Metrics Server tag (default: v0.7.2).
  --manifest-url URL   Override the upstream manifest URL.
  --timeout DURATION   Rollout/APIService timeout (default: 180s).
  --secure-kubelet-tls Do not add --kubelet-insecure-tls.
  --help               Show this help.

Environment equivalents: KUBE_CONTEXT, METRICS_SERVER_VERSION,
METRICS_SERVER_MANIFEST_URL, KUBECTL_TIMEOUT, ALLOW_INSECURE_KUBELET_TLS.
USAGE
}

main() {
  local cluster_name="${KIND_CLUSTER_NAME:-gitops-thesis}"
  local kube_context="${KUBE_CONTEXT:-kind-${cluster_name}}"
  local version="${METRICS_SERVER_VERSION:-v0.7.2}"
  local manifest_url="${METRICS_SERVER_MANIFEST_URL:-}"
  local timeout="${KUBECTL_TIMEOUT:-180s}"
  local allow_insecure_tls="${ALLOW_INSECURE_KUBELET_TLS:-true}"
  local current_args=""
  local -a kubectl_args=()

  while (($# > 0)); do
    case "$1" in
      --context)
        [[ $# -ge 2 ]] || { printf 'ERROR: --context requires a value.\n' >&2; exit 2; }
        kube_context="$2"
        shift 2
        ;;
      --version)
        [[ $# -ge 2 ]] || { printf 'ERROR: --version requires a value.\n' >&2; exit 2; }
        version="$2"
        shift 2
        ;;
      --manifest-url)
        [[ $# -ge 2 ]] || { printf 'ERROR: --manifest-url requires a URL.\n' >&2; exit 2; }
        manifest_url="$2"
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || { printf 'ERROR: --timeout requires a duration.\n' >&2; exit 2; }
        timeout="$2"
        shift 2
        ;;
      --secure-kubelet-tls)
        allow_insecure_tls=false
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        printf 'ERROR: unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if ! command -v kubectl >/dev/null 2>&1; then
    printf 'ERROR: required command is not installed: kubectl\n' >&2
    exit 1
  fi
  case "$allow_insecure_tls" in
    true|false) ;;
    *)
      printf 'ERROR: ALLOW_INSECURE_KUBELET_TLS must be true or false.\n' >&2
      exit 2
      ;;
  esac
  if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'ERROR: Metrics Server version must look like v0.7.2: %s\n' "$version" >&2
    exit 2
  fi
  if [[ -z "$manifest_url" ]]; then
    manifest_url="https://github.com/kubernetes-sigs/metrics-server/releases/download/${version}/components.yaml"
  fi
  if [[ "$manifest_url" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/]*@ ]]; then
    printf 'ERROR: manifest URL must not contain embedded credentials.\n' >&2
    exit 2
  fi

  kubectl_args=(--context "$kube_context")
  if ! kubectl "${kubectl_args[@]}" cluster-info >/dev/null 2>&1; then
    printf 'ERROR: Kubernetes context is not reachable: %s\n' "$kube_context" >&2
    exit 1
  fi

  printf 'Applying Metrics Server %s from %s...\n' "$version" "$manifest_url"
  kubectl "${kubectl_args[@]}" apply -f "$manifest_url"

  if [[ "$allow_insecure_tls" == true ]]; then
    current_args="$(kubectl "${kubectl_args[@]}" -n kube-system get deployment metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}')"
    if [[ "$current_args" != *"--kubelet-insecure-tls"* ]]; then
      kubectl "${kubectl_args[@]}" -n kube-system patch deployment metrics-server \
        --type=json \
        --patch='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
    fi
  fi

  kubectl "${kubectl_args[@]}" -n kube-system rollout status deployment/metrics-server --timeout="$timeout"
  kubectl "${kubectl_args[@]}" wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout="$timeout"
  printf 'Metrics Server is available in context %s.\n' "$kube_context"
}

main "$@"
