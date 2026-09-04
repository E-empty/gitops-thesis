#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: cleanup.sh [options]

Uninstalls the manually deployed application release. Namespace deletion is
opt-in because a namespace may contain resources outside this release.

Options:
  --release NAME       Helm release (default: microservices-app).
  --namespace NAME     Namespace (default: test-manual).
  --context NAME       Kubeconfig context (default: kind-gitops-thesis).
  --delete-namespace   Delete the namespace after uninstalling the release.
  --timeout DURATION   Uninstall/delete timeout (default: 2m).
  --help               Show this help.

Environment equivalents: HELM_RELEASE, APP_NAMESPACE, KUBE_CONTEXT,
KUBECTL_TIMEOUT, DELETE_APP_NAMESPACE.
USAGE
}

main() {
  local release_name="${HELM_RELEASE:-microservices-app}"
  local namespace="${APP_NAMESPACE:-test-manual}"
  local kube_context="${KUBE_CONTEXT:-kind-gitops-thesis}"
  local timeout="${KUBECTL_TIMEOUT:-2m}"
  local delete_namespace="${DELETE_APP_NAMESPACE:-false}"
  local -a helm_context_args=()
  local -a kubectl_context_args=()
  local releases="" namespaces="" candidate=""
  local release_exists=false namespace_exists=false

  while (($# > 0)); do
    case "$1" in
      --release)
        [[ $# -ge 2 ]] || { printf 'ERROR: --release requires a value.\n' >&2; exit 2; }
        release_name="$2"
        shift 2
        ;;
      --namespace)
        [[ $# -ge 2 ]] || { printf 'ERROR: --namespace requires a value.\n' >&2; exit 2; }
        namespace="$2"
        shift 2
        ;;
      --context)
        [[ $# -ge 2 ]] || { printf 'ERROR: --context requires a value.\n' >&2; exit 2; }
        kube_context="$2"
        shift 2
        ;;
      --delete-namespace)
        delete_namespace=true
        shift
        ;;
      --timeout)
        [[ $# -ge 2 ]] || { printf 'ERROR: --timeout requires a duration.\n' >&2; exit 2; }
        timeout="$2"
        shift 2
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

  if ! command -v helm >/dev/null 2>&1; then
    printf 'ERROR: required command is not installed: helm\n' >&2
    exit 1
  fi
  case "$delete_namespace" in
    true|false) ;;
    *)
      printf 'ERROR: DELETE_APP_NAMESPACE must be true or false.\n' >&2
      exit 2
      ;;
  esac
  helm_context_args=(--kube-context "$kube_context")
  kubectl_context_args=(--context "$kube_context")

  if ! releases="$(helm list --all --short --namespace "$namespace" "${helm_context_args[@]}" 2>&1)"; then
    printf 'ERROR: Helm could not query context %s: %s\n' "$kube_context" "$releases" >&2
    exit 1
  fi
  while IFS= read -r candidate; do
    [[ "$candidate" == "$release_name" ]] && release_exists=true
  done <<<"$releases"
  if [[ "$release_exists" == true ]]; then
    printf 'Uninstalling release %s from namespace %s...\n' "$release_name" "$namespace"
    helm uninstall "$release_name" --namespace "$namespace" --wait --timeout "$timeout" \
      "${helm_context_args[@]}"
  else
    printf 'Helm release %s was not found in namespace %s; nothing to uninstall.\n' \
      "$release_name" "$namespace"
  fi

  if [[ "$delete_namespace" == true ]]; then
    if ! command -v kubectl >/dev/null 2>&1; then
      printf 'ERROR: kubectl is required to delete the namespace.\n' >&2
      exit 1
    fi
    case "$namespace" in
      default|kube-system|kube-public|kube-node-lease)
        printf 'ERROR: refusing to delete protected namespace: %s\n' "$namespace" >&2
        exit 1
        ;;
    esac
    if ! namespaces="$(kubectl "${kubectl_context_args[@]}" get namespaces \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1)"; then
      printf 'ERROR: kubectl could not query namespaces in context %s: %s\n' \
        "$kube_context" "$namespaces" >&2
      exit 1
    fi
    while IFS= read -r candidate; do
      [[ "$candidate" == "$namespace" ]] && namespace_exists=true
    done <<<"$namespaces"
    if [[ "$namespace_exists" == true ]]; then
      printf 'Deleting namespace %s...\n' "$namespace"
      kubectl "${kubectl_context_args[@]}" delete namespace "$namespace" --wait=true --timeout="$timeout"
      printf 'Namespace %s was deleted and cannot be recovered from the cluster.\n' "$namespace"
    else
      printf 'Namespace %s does not exist; nothing to delete.\n' "$namespace"
    fi
  fi
}

main "$@"
