#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_ARGOCD_VERSION="v3.5.0"
readonly ARGOCD_NAMESPACE="argocd"
readonly DEFAULT_TARGET_NAMESPACE="test-argocd"
readonly DEFAULT_KUBE_CONTEXT="kind-gitops-thesis"
readonly DEFAULT_WAIT_TIMEOUT="10m"

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(CDPATH= cd -- "${script_dir}/.." && pwd)"
reconciliation_manifest="${repo_root}/gitops/argocd/reconciliation-config.yaml"
values_file="${repo_root}/helm/microservices-app/values.yaml"

argocd_version="${DEFAULT_ARGOCD_VERSION}"
target_namespace="${DEFAULT_TARGET_NAMESPACE}"
repo_url=""
revision=""
kube_context="${KUBE_CONTEXT:-${DEFAULT_KUBE_CONTEXT}}"
wait_timeout="${GITOPS_WAIT_TIMEOUT:-${DEFAULT_WAIT_TIMEOUT}}"

usage() {
  cat <<'EOF'
Usage: scripts/install-argocd.sh [options]

Install the pinned Argo CD release. If both repository options are supplied,
the script also renders and applies gitops/argocd/application.yaml.

Options:
  --repo-url URL              Git repository URL containing this project
  --revision REVISION         Git branch, tag, or commit for Argo CD to track
  --target-namespace NAME     Application namespace (default: test-argocd)
  --context NAME              kubeconfig context (default: kind-gitops-thesis)
  --timeout DURATION          Controller/Application wait timeout (default: 10m)
  --version VERSION           Argo CD version (default: v3.5.0)
  -h, --help                  Show this help

Environment equivalents: KUBE_CONTEXT, GITOPS_WAIT_TIMEOUT.
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

validate_namespace() {
  local namespace="$1"
  [[ "${namespace}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || fail "invalid Kubernetes namespace: ${namespace}"
  (( ${#namespace} <= 63 )) \
    || fail "namespace must contain at most 63 characters: ${namespace}"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

require_kube_context() {
  local configured_context=""
  local found=false

  while IFS= read -r configured_context; do
    if [[ "${configured_context}" == "${kube_context}" ]]; then
      found=true
      break
    fi
  done < <(kubectl --context "${kube_context}" config get-contexts -o name)

  [[ "${found}" == true ]] \
    || fail "kubeconfig context does not exist: ${kube_context}"
  kubectl --context "${kube_context}" cluster-info >/dev/null \
    || fail "cannot connect to Kubernetes context: ${kube_context}"
}

while (($# > 0)); do
  case "$1" in
    --repo-url)
      require_value "$1" "${2:-}"
      repo_url="$2"
      shift 2
      ;;
    --revision)
      require_value "$1" "${2:-}"
      revision="$2"
      shift 2
      ;;
    --target-namespace)
      require_value "$1" "${2:-}"
      target_namespace="$2"
      shift 2
      ;;
    --context)
      require_value "$1" "${2:-}"
      kube_context="$2"
      shift 2
      ;;
    --timeout)
      require_value "$1" "${2:-}"
      wait_timeout="$2"
      shift 2
      ;;
    --version)
      require_value "$1" "${2:-}"
      argocd_version="$2"
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
[[ "${argocd_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "Argo CD version must look like v3.5.0: ${argocd_version}"
validate_namespace "${target_namespace}"
require_kube_context

if [[ -n "${repo_url}" || -n "${revision}" ]]; then
  [[ -n "${repo_url}" && -n "${revision}" ]] \
    || fail "--repo-url and --revision must be supplied together"
fi
if [[ -n "${repo_url}" && "${repo_url}" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/]*@ ]]; then
  fail "repository URL must not contain embedded credentials; configure a Kubernetes Secret instead"
fi

if [[ -n "${repo_url}" ]]; then
  [[ -f "${values_file}" ]] || fail "Helm values not found: ${values_file}"
  if grep -q '<YOUR_' "${values_file}"; then
    fail "replace image placeholders in helm/microservices-app/values.yaml and push them before creating the Application"
  fi
fi

git_input="${repo_url}${revision}"
[[ "${git_input}" != *$'\n'* \
  && "${git_input}" != *$'\r'* \
  && "${git_input}" != *$'\t'* \
  && "${git_input}" != *' '* \
  && "${git_input}" != *'"'* \
  && "${git_input}" != *'\\'* ]] \
  || fail "repository URL and revision must not contain whitespace, quotes, or backslashes"
[[ -z "${revision}" || "${revision}" =~ ^[A-Za-z0-9._/-]+$ ]] \
  || fail "revision contains characters that are not valid in a Git ref"

readonly install_url="https://raw.githubusercontent.com/argoproj/argo-cd/${argocd_version}/manifests/install.yaml"
printf 'Installing Argo CD %s in namespace %s...\n' \
  "${argocd_version}" "${ARGOCD_NAMESPACE}"
kubectl --context "${kube_context}" create namespace "${ARGOCD_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl --context "${kube_context}" apply -f -
kubectl --context "${kube_context}" apply --server-side --force-conflicts \
  --namespace "${ARGOCD_NAMESPACE}" -f "${install_url}"
kubectl --context "${kube_context}" wait deployment --all \
  --namespace "${ARGOCD_NAMESPACE}" --for=condition=Available \
  --timeout="${wait_timeout}"
kubectl --context "${kube_context}" rollout status statefulset --all \
  --namespace "${ARGOCD_NAMESPACE}" --timeout="${wait_timeout}"

[[ -f "${reconciliation_manifest}" ]] \
  || fail "reconciliation configuration not found: ${reconciliation_manifest}"
printf '%s\n' 'Configuring a 60s Git reconciliation interval with no jitter...'
kubectl --context "${kube_context}" apply --server-side --force-conflicts \
  -f "${reconciliation_manifest}"
kubectl --context "${kube_context}" rollout restart \
  statefulset/argocd-application-controller \
  --namespace "${ARGOCD_NAMESPACE}"
kubectl --context "${kube_context}" rollout restart deployment/argocd-repo-server \
  --namespace "${ARGOCD_NAMESPACE}"
kubectl --context "${kube_context}" rollout status \
  statefulset/argocd-application-controller \
  --namespace "${ARGOCD_NAMESPACE}" --timeout="${wait_timeout}"
kubectl --context "${kube_context}" rollout status deployment/argocd-repo-server \
  --namespace "${ARGOCD_NAMESPACE}" --timeout="${wait_timeout}"

if [[ -z "${repo_url}" ]]; then
  printf '%s\n' \
    'Argo CD is installed. The Application was not applied.' \
    'Run this script again with --repo-url and --revision, or replace the' \
    'placeholders in gitops/argocd/application.yaml and apply it manually.'
  exit 0
fi

application_manifest="${repo_root}/gitops/argocd/application.yaml"
[[ -f "${application_manifest}" ]] \
  || fail "Application manifest not found: ${application_manifest}"

rendered_manifest="$(mktemp)"
trap 'rm -f -- "${rendered_manifest}"' EXIT
repo_url_escaped="$(escape_sed_replacement "${repo_url}")"
revision_escaped="$(escape_sed_replacement "${revision}")"
target_namespace_escaped="$(escape_sed_replacement "${target_namespace}")"

sed \
  -e "s|<YOUR_GIT_REPOSITORY_URL>|${repo_url_escaped}|g" \
  -e "s|<YOUR_GIT_REVISION>|${revision_escaped}|g" \
  -e "s|namespace: test-argocd|namespace: ${target_namespace_escaped}|g" \
  "${application_manifest}" > "${rendered_manifest}"

kubectl --context "${kube_context}" apply -f "${rendered_manifest}"
printf '%s\n' 'Waiting for Application/microservices-app to become Synced and Healthy...'
kubectl --context "${kube_context}" wait \
  --namespace "${ARGOCD_NAMESPACE}" \
  application.argoproj.io/microservices-app \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout="${wait_timeout}"
kubectl --context "${kube_context}" wait \
  --namespace "${ARGOCD_NAMESPACE}" \
  application.argoproj.io/microservices-app \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout="${wait_timeout}"
printf 'Argo CD Application installed for %s at revision %s.\n' \
  "${repo_url}" "${revision}"
