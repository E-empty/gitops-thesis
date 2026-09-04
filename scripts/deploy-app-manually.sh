#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<USAGE
Usage: deploy-app-manually.sh [options]

Installs or upgrades the shared application Helm chart.

Options:
  --release NAME        Helm release (default: microservices-app).
  --namespace NAME      Target namespace (default: test-manual).
  --chart PATH          Chart directory (default: helm/microservices-app).
  --context NAME        Kubeconfig context (default: kind-gitops-thesis).
  --values FILE         Additional values file (repeatable).
  --set KEY=VALUE       Helm value override (repeatable).
  --set-string K=VALUE  String Helm value override (repeatable).
  --registry HOST       Set global.imageRegistry; requires --image-owner.
  --image-owner OWNER   Set global.imageOwner; requires --registry.
  --tag TAG             Set all three image tags.
  --app-version VERSION Set APP_VERSION for all three services.
  --timeout DURATION    Helm timeout (default: 5m).
  --atomic              Roll back a failed upgrade/install.
  --help                Show this help.

The default chart contains explicit GHCR owner placeholders. Override them via
--registry and --image-owner, --values, or three per-service --set options.

Environment equivalents: HELM_RELEASE, APP_NAMESPACE, CHART_PATH, KUBE_CONTEXT,
HELM_TIMEOUT, HELM_ATOMIC.
USAGE
}

main() {
  local release_name="${HELM_RELEASE:-microservices-app}"
  local namespace="${APP_NAMESPACE:-test-manual}"
  local chart_path="${CHART_PATH:-${REPOSITORY_ROOT}/helm/microservices-app}"
  local kube_context="${KUBE_CONTEXT:-kind-gitops-thesis}"
  local timeout="${HELM_TIMEOUT:-5m}"
  local atomic="${HELM_ATOMIC:-false}"
  local registry=""
  local image_owner=""
  local common_tag=""
  local app_version=""
  local rendered=""
  local values_file=""
  local key_value=""
  local -a value_args=()
  local -a set_args=()
  local -a kube_args=()
  local -a helm_args=()

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
      --chart)
        [[ $# -ge 2 ]] || { printf 'ERROR: --chart requires a path.\n' >&2; exit 2; }
        chart_path="$2"
        shift 2
        ;;
      --context)
        [[ $# -ge 2 ]] || { printf 'ERROR: --context requires a value.\n' >&2; exit 2; }
        kube_context="$2"
        shift 2
        ;;
      --values|-f)
        [[ $# -ge 2 ]] || { printf 'ERROR: --values requires a file.\n' >&2; exit 2; }
        values_file="$2"
        if [[ ! -f "$values_file" ]]; then
          printf 'ERROR: values file does not exist: %s\n' "$values_file" >&2
          exit 1
        fi
        value_args+=(--values "$values_file")
        shift 2
        ;;
      --set)
        [[ $# -ge 2 ]] || { printf 'ERROR: --set requires KEY=VALUE.\n' >&2; exit 2; }
        key_value="$2"
        set_args+=(--set "$key_value")
        shift 2
        ;;
      --set-string)
        [[ $# -ge 2 ]] || { printf 'ERROR: --set-string requires KEY=VALUE.\n' >&2; exit 2; }
        key_value="$2"
        set_args+=(--set-string "$key_value")
        shift 2
        ;;
      --registry)
        [[ $# -ge 2 ]] || { printf 'ERROR: --registry requires a value.\n' >&2; exit 2; }
        registry="$2"
        shift 2
        ;;
      --image-owner)
        [[ $# -ge 2 ]] || { printf 'ERROR: --image-owner requires a value.\n' >&2; exit 2; }
        image_owner="$2"
        shift 2
        ;;
      --tag)
        [[ $# -ge 2 ]] || { printf 'ERROR: --tag requires a value.\n' >&2; exit 2; }
        common_tag="$2"
        shift 2
        ;;
      --app-version)
        [[ $# -ge 2 ]] || { printf 'ERROR: --app-version requires a value.\n' >&2; exit 2; }
        app_version="$2"
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || { printf 'ERROR: --timeout requires a duration.\n' >&2; exit 2; }
        timeout="$2"
        shift 2
        ;;
      --atomic)
        atomic=true
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

  if ! command -v helm >/dev/null 2>&1; then
    printf 'ERROR: required command is not installed: helm\n' >&2
    exit 1
  fi
  if ! command -v kubectl >/dev/null 2>&1; then
    printf 'ERROR: required command is not installed: kubectl\n' >&2
    exit 1
  fi
  if [[ ! -f "${chart_path}/Chart.yaml" ]]; then
    printf 'ERROR: Helm chart was not found at: %s\n' "$chart_path" >&2
    exit 1
  fi
  case "$atomic" in
    true|false) ;;
    *)
      printf 'ERROR: HELM_ATOMIC must be true or false.\n' >&2
      exit 2
      ;;
  esac
  if [[ -n "$registry" || -n "$image_owner" ]]; then
    if [[ -z "$registry" || -z "$image_owner" ]]; then
      printf 'ERROR: --registry and --image-owner must be provided together.\n' >&2
      exit 2
    fi
    set_args+=(--set-string "global.imageRegistry=${registry}" --set-string "global.imageOwner=${image_owner}")
  fi
  if [[ -n "$common_tag" ]]; then
    set_args+=(
      --set-string "services.gateway.image.tag=${common_tag}"
      --set-string "services.users.image.tag=${common_tag}"
      --set-string "services.orders.image.tag=${common_tag}"
    )
  fi
  if [[ -n "$app_version" ]]; then
    set_args+=(
      --set-string "services.gateway.env.APP_VERSION=${app_version}"
      --set-string "services.users.env.APP_VERSION=${app_version}"
      --set-string "services.orders.env.APP_VERSION=${app_version}"
    )
  fi
  kube_args=(--kube-context "$kube_context")
  if ! kubectl --context "$kube_context" cluster-info >/dev/null 2>&1; then
    printf 'ERROR: Kubernetes context is not reachable: %s\n' "$kube_context" >&2
    exit 1
  fi

  printf 'Validating chart %s...\n' "$chart_path"
  helm lint "$chart_path" "${value_args[@]}" "${set_args[@]}"
  rendered="$(helm template "$release_name" "$chart_path" --namespace "$namespace" "${value_args[@]}" "${set_args[@]}")"
  if [[ "$rendered" == *"<YOUR_"* ]]; then
    printf 'ERROR: rendered image references still contain a <YOUR_...> placeholder.\n' >&2
    printf 'Provide registry/owner or explicit per-service image repositories.\n' >&2
    exit 1
  fi

  helm_args=(
    upgrade --install "$release_name" "$chart_path"
    --namespace "$namespace"
    --create-namespace
    --wait
    --timeout "$timeout"
  )
  if [[ "$atomic" == true ]]; then
    helm_args+=(--atomic)
  fi
  helm_args+=("${kube_args[@]}" "${value_args[@]}" "${set_args[@]}")

  printf 'Installing release %s in namespace %s...\n' "$release_name" "$namespace"
  helm "${helm_args[@]}"

  kubectl --context "$kube_context" --namespace "$namespace" get deployments,pods \
    -l "app.kubernetes.io/instance=${release_name}"
  printf 'Release %s is ready.\n' "$release_name"
}

main "$@"
