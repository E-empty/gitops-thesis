#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_FLUX_VERSION="v2.9.3"
readonly FLUX_NAMESPACE="flux-system"
readonly DEFAULT_TARGET_NAMESPACE="test-fluxcd"
readonly DEFAULT_KUBE_CONTEXT="kind-gitops-thesis"
readonly DEFAULT_WAIT_TIMEOUT="10m"

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(CDPATH= cd -- "${script_dir}/.." && pwd)"
values_file="${repo_root}/helm/microservices-app/values.yaml"

flux_version="${DEFAULT_FLUX_VERSION}"
target_namespace="${DEFAULT_TARGET_NAMESPACE}"
repo_url=""
revision=""
kube_context="${KUBE_CONTEXT:-${DEFAULT_KUBE_CONTEXT}}"
wait_timeout="${GITOPS_WAIT_TIMEOUT:-${DEFAULT_WAIT_TIMEOUT}}"

usage() {
  cat <<'EOF'
Usage: scripts/install-fluxcd.sh [options]

Install the pinned Flux controllers. If both repository options are supplied,
the script also renders and applies the GitRepository and HelmRelease.

Options:
  --repo-url URL              Git repository URL containing this project
  --revision BRANCH           Git branch for Flux to track
  --target-namespace NAME     Application namespace (default: test-fluxcd)
  --context NAME              kubeconfig context (default: kind-gitops-thesis)
  --timeout DURATION          Controller/GitOps wait timeout (default: 10m)
  --version VERSION           Flux version (default: v2.9.3)
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

set_zero_interval_jitter() {
  local deployment="$1"
  local desired_argument="--interval-jitter-percentage=0"
  local argument=""
  local argument_index=0
  local matching_index=""
  local -a controller_arguments=()

  while IFS= read -r argument; do
    controller_arguments+=("${argument}")
  done < <(
    kubectl --context "${kube_context}" get deployment "${deployment}" \
      --namespace "${FLUX_NAMESPACE}" \
      -o go-template='{{range (index .spec.template.spec.containers 0).args}}{{printf "%s\n" .}}{{end}}'
  )

  for argument_index in "${!controller_arguments[@]}"; do
    argument="${controller_arguments[argument_index]}"
    if [[ "${argument}" == --interval-jitter-percentage=* ]]; then
      matching_index="${argument_index}"
      [[ "${argument}" == "${desired_argument}" ]] && return 0
      break
    fi
  done

  if [[ -n "${matching_index}" ]]; then
    kubectl --context "${kube_context}" patch deployment "${deployment}" \
      --namespace "${FLUX_NAMESPACE}" --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/${matching_index}\",\"value\":\"${desired_argument}\"}]"
  else
    kubectl --context "${kube_context}" patch deployment "${deployment}" \
      --namespace "${FLUX_NAMESPACE}" --type=json \
      -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"${desired_argument}\"}]"
  fi
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
      flux_version="$2"
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
[[ "${flux_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail "Flux version must look like v2.9.3: ${flux_version}"
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
    fail "replace image placeholders in helm/microservices-app/values.yaml and push them before creating GitOps resources"
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
  || fail "revision contains characters that are not valid in a Git branch"

readonly install_url="https://github.com/fluxcd/flux2/releases/download/${flux_version}/install.yaml"
printf 'Installing Flux CD %s in namespace %s...\n' \
  "${flux_version}" "${FLUX_NAMESPACE}"
kubectl --context "${kube_context}" apply --server-side -f "${install_url}"
kubectl --context "${kube_context}" wait --namespace "${FLUX_NAMESPACE}" \
  --for=condition=Available deployment --all --timeout="${wait_timeout}"

printf '%s\n' 'Disabling Flux reconciliation-interval jitter...'
set_zero_interval_jitter source-controller
set_zero_interval_jitter helm-controller
kubectl --context "${kube_context}" rollout restart deployment/source-controller \
  --namespace "${FLUX_NAMESPACE}"
kubectl --context "${kube_context}" rollout restart deployment/helm-controller \
  --namespace "${FLUX_NAMESPACE}"
kubectl --context "${kube_context}" rollout status deployment/source-controller \
  --namespace "${FLUX_NAMESPACE}" --timeout="${wait_timeout}"
kubectl --context "${kube_context}" rollout status deployment/helm-controller \
  --namespace "${FLUX_NAMESPACE}" --timeout="${wait_timeout}"

if [[ -z "${repo_url}" ]]; then
  printf '%s\n' \
    'Flux CD is installed. GitOps resources were not applied.' \
    'Run this script again with --repo-url and --revision, or replace the' \
    'placeholders in gitops/fluxcd and apply the manifests manually.'
  exit 0
fi

source_manifest="${repo_root}/gitops/fluxcd/gitrepository.yaml"
release_manifest="${repo_root}/gitops/fluxcd/helmrelease.yaml"
[[ -f "${source_manifest}" ]] \
  || fail "GitRepository manifest not found: ${source_manifest}"
[[ -f "${release_manifest}" ]] \
  || fail "HelmRelease manifest not found: ${release_manifest}"

render_dir="$(mktemp -d)"
trap 'rm -f -- "${render_dir}/gitrepository.yaml" "${render_dir}/helmrelease.yaml"; rmdir -- "${render_dir}" 2>/dev/null || true' EXIT
repo_url_escaped="$(escape_sed_replacement "${repo_url}")"
revision_escaped="$(escape_sed_replacement "${revision}")"
target_namespace_escaped="$(escape_sed_replacement "${target_namespace}")"

sed \
  -e "s|<YOUR_GIT_REPOSITORY_URL>|${repo_url_escaped}|g" \
  -e "s|<YOUR_GIT_REVISION>|${revision_escaped}|g" \
  "${source_manifest}" > "${render_dir}/gitrepository.yaml"
sed \
  -e "s|targetNamespace: test-fluxcd|targetNamespace: ${target_namespace_escaped}|g" \
  "${release_manifest}" > "${render_dir}/helmrelease.yaml"

kubectl --context "${kube_context}" apply -f "${render_dir}/gitrepository.yaml"
kubectl --context "${kube_context}" apply -f "${render_dir}/helmrelease.yaml"
printf '%s\n' 'Waiting for GitRepository and HelmRelease to become Ready...'
kubectl --context "${kube_context}" wait \
  --namespace "${FLUX_NAMESPACE}" \
  gitrepository.source.toolkit.fluxcd.io/microservices-app \
  --for=condition=Ready --timeout="${wait_timeout}"
kubectl --context "${kube_context}" wait \
  --namespace "${FLUX_NAMESPACE}" \
  helmrelease.helm.toolkit.fluxcd.io/microservices-app \
  --for=condition=Ready --timeout="${wait_timeout}"
printf 'Flux GitRepository and HelmRelease installed for %s branch %s.\n' \
  "${repo_url}" "${revision}"
