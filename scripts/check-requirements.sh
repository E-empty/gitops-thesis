#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: check-requirements.sh [options]

Checks the command-line tools used by the local Kubernetes workflow.

Options:
  --tool NAME             Check an additional command (repeatable).
  --skip-docker-daemon    Do not verify access to the Docker daemon.
  --help                  Show this help.

Environment:
  REQUIRED_TOOLS          Space-separated replacement for the default list
                          "docker kind kubectl helm git bash python".
                          The logical "python" entry accepts Python 3.12+ as
                          python3, python, or through the Windows py launcher.
  CHECK_DOCKER_DAEMON     true (default) or false.
USAGE
}

command_version() {
  local command_name="$1"
  local output=""

  case "$command_name" in
    docker) output="$(docker --version 2>&1 || true)" ;;
    kind) output="$(kind --version 2>&1 || true)" ;;
    kubectl) output="$(kubectl version --client 2>&1 || true)" ;;
    helm) output="$(helm version --short 2>&1 || true)" ;;
    *) output="$("$command_name" --version 2>&1 || true)" ;;
  esac

  output="${output%%$'\n'*}"
  if [[ -n "$output" ]]; then
    printf '%s' "$output"
  else
    printf 'version unavailable'
  fi
}

resolve_python_command() {
  local python3_path="" python_path=""
  python3_path="$(command -v python3 2>/dev/null || true)"
  python_path="$(command -v python 2>/dev/null || true)"
  if [[ -n "${python3_path}" && "${python3_path}" != */WindowsApps/python* ]] \
    && python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' \
      >/dev/null 2>&1; then
    printf '%s' python3
  elif [[ -n "${python_path}" && "${python_path}" != */WindowsApps/python* ]] \
    && python -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' \
      >/dev/null 2>&1; then
    printf '%s' python
  elif command -v py >/dev/null 2>&1 \
    && py -3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' \
      >/dev/null 2>&1; then
    printf '%s' py
  else
    return 1
  fi
}

main() {
  local check_docker_daemon="${CHECK_DOCKER_DAEMON:-true}"
  local configured_tools="${REQUIRED_TOOLS:-docker kind kubectl helm git bash python}"
  local -a required_tools=()
  local -a missing_tools=()
  local tool=""
  local resolved_tool=""
  local docker_requested=false

  read -r -a required_tools <<<"$configured_tools"

  while (($# > 0)); do
    case "$1" in
      --tool)
        if (($# < 2)) || [[ -z "$2" ]]; then
          printf 'ERROR: --tool requires a command name.\n' >&2
          exit 2
        fi
        required_tools+=("$2")
        shift 2
        ;;
      --skip-docker-daemon)
        check_docker_daemon=false
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

  case "$check_docker_daemon" in
    true|false) ;;
    *)
      printf 'ERROR: CHECK_DOCKER_DAEMON must be true or false.\n' >&2
      exit 2
      ;;
  esac

  if ((${#required_tools[@]} == 0)); then
    printf 'ERROR: no tools were selected for checking.\n' >&2
    exit 2
  fi

  for tool in "${required_tools[@]}"; do
    if [[ "$tool" == "docker" ]]; then
      docker_requested=true
    fi

    resolved_tool="$tool"
    if [[ "$tool" == "python" ]]; then
      resolved_tool="$(resolve_python_command || true)"
    fi

    if [[ -n "$resolved_tool" ]] && command -v "$resolved_tool" >/dev/null 2>&1; then
      if [[ "$tool" == "python" ]]; then
        printf 'OK: %-10s %s (%s)\n' "$tool" \
          "$(command_version "$resolved_tool")" "$resolved_tool"
      else
        printf 'OK: %-10s %s\n' "$tool" "$(command_version "$resolved_tool")"
      fi
    else
      if [[ "$tool" == "python" ]]; then
        printf 'MISSING: Python 3.12+ as python3, python, or py\n' >&2
        missing_tools+=("python3/python/py")
      else
        printf 'MISSING: %s\n' "$tool" >&2
        missing_tools+=("$tool")
      fi
    fi
  done

  if ((${#missing_tools[@]} > 0)); then
    printf 'ERROR: install the missing tools before continuing: %s\n' "${missing_tools[*]}" >&2
    exit 1
  fi

  if [[ "$docker_requested" == true ]]; then
    if ! docker compose version >/dev/null 2>&1; then
      printf 'ERROR: Docker Compose v2 (docker compose) is not available.\n' >&2
      exit 1
    fi
    printf 'OK: %-10s %s\n' "compose" "$(docker compose version 2>&1)"
  fi

  if [[ "$check_docker_daemon" == true && "$docker_requested" == true ]]; then
    if ! docker info >/dev/null 2>&1; then
      printf 'ERROR: Docker is installed, but its daemon is not reachable.\n' >&2
      exit 1
    fi
    printf 'OK: Docker daemon is reachable.\n'
  fi

  printf 'All selected requirements are available.\n'
}

main "$@"
