#!/bin/bash

set -euo pipefail

EXTRA_PORTS=()
while [[ $# -gt 0 ]] ; do # Parse CL args; c.f. configurable env vars below
    case $1 in
	# Expose the port which codex uses for auth callbacks. This
	# does not actually work because `codex login` only binds to
	# localhost in the container; use `codex login --device-auth`
	# instead. But perhaps CL args like this should be the way to
	# adjust the script going forward.
	-p|--expose-auth-port)
	    EXTRA_PORTS+=("-p" "1455:1455")
	    shift # Remove this from CL args
	    ;;
	-ep|--expose-port)
	    EXTRA_PORTS+=("-p" "$2:$2")
	    shift; shift # Remove these two args from CL args
	    ;;
    esac
done

# EXTRA_PORTS+=("-p" "8000:8000") # Expose 8000 by default


################################################################################
# Configurable environment variables
CONTAINER_ROOT="/workspace/repo"
IMAGE="${CODEX_IMAGE:-codex-local:latest}"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "This script must be run from inside a git repo." >&2
  exit 1
}
DOCKERFILE="${CODEX_DOCKERFILE:-$ROOT/Dockerfile.codex}"
REPO_NAME="$(basename "$ROOT")"
# ",," lower-cases the name
CONTAINER_NAME="${CODEX_CONTAINER_NAME:-codex-tmux-${REPO_NAME,,}}" 
SESSION_NAME="${CODEX_TMUX_SESSION:-codex}"
REL_PATH="$(realpath --relative-to="$ROOT" "$PWD")"

CONTAINER_UID="$(id -u)"
CONTAINER_GID="$(id -g)"
CONTAINER_USER="${CODEX_CONTAINER_USER:-$CONTAINER_UID:$CONTAINER_GID}"
CONTAINER_HOME="${CODEX_CONTAINER_HOME:-/home/ubuntu}"

CODEX_AUTH_HOST="${CODEX_AUTH_HOST:-$HOME/.codex/auth.json}"
CODEX_CONFIG_CONTAINER="${CODEX_CONFIG_CONTAINER:-$CONTAINER_HOME/.codex}"
CODEX_LOCALE="${CODEX_LOCALE:-C.UTF-8}"
CODEX_LANG="${CODEX_LANG:-$CODEX_LOCALE}"
CODEX_LC_ALL="${CODEX_LC_ALL:-$CODEX_LOCALE}"
CODEX_LC_CTYPE="${CODEX_LC_CTYPE:-$CODEX_LOCALE}"
################################################################################

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to run this script." >&2
  exit 1
fi

if [[ "$REL_PATH" == "." ]]; then
  WORKDIR_IN_CONTAINER="$CONTAINER_ROOT"
else
  WORKDIR_IN_CONTAINER="$CONTAINER_ROOT/$REL_PATH"
fi

EXTRA_MOUNTS=()
HARDENED_FLAGS=(
  --cap-drop=ALL
  --security-opt no-new-privileges:true
  --pids-limit=512
)

add_mount() {
  local host_path="$1"
  local container_path="$2"
  local mode="${3-}"
  if [[ -e "$host_path" ]]; then
    if [[ -n "$mode" ]]; then
      EXTRA_MOUNTS+=("-v" "$host_path:$container_path:$mode")
    else
      EXTRA_MOUNTS+=("-v" "$host_path:$container_path")
    fi
  fi
}

ensure_image() {
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    return
  fi

  if [[ ! -f "$DOCKERFILE" ]]; then
    echo "Dockerfile not found at $DOCKERFILE. Set CODEX_DOCKERFILE to the correct path." >&2
    exit 1
  fi

  echo "Building Codex image '$IMAGE' from $DOCKERFILE ..."
  docker build -t "$IMAGE" -f "$DOCKERFILE" "$ROOT"
}

start_container() {
  add_mount "$ROOT" "$CONTAINER_ROOT"
  docker run -d \
    --name "$CONTAINER_NAME" \
    --rm \
    --runtime=runsc \
    --gpus=all \
    --user "$CONTAINER_USER" \
    "${EXTRA_MOUNTS[@]}" \
    "${HARDENED_FLAGS[@]}" \
    "${EXTRA_PORTS[@]}" \
    -w "$WORKDIR_IN_CONTAINER" \
    -e CODEX_WORKDIR="$WORKDIR_IN_CONTAINER" \
    -e HOME="$CONTAINER_HOME" \
    -e LANG="$CODEX_LANG" \
    -e LC_ALL="$CODEX_LC_ALL" \
    -e LC_CTYPE="$CODEX_LC_CTYPE" \
    "$IMAGE" \
    bash -lc 'set -euo pipefail
      waited=0
      until tmux info >/dev/null 2>&1; do
        sleep 0.5
        waited=$((waited+1))
        if [ "$waited" -ge 120 ]; then
          echo "tmux did not start within 60s; exiting" >&2
          exit 1
        fi
      done
      while tmux info >/dev/null 2>&1; do sleep 1; done'
}

ensure_container() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    if ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
      docker start "$CONTAINER_NAME" >/dev/null
    fi
  else
    start_container
  fi

  if ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    echo "Container $CONTAINER_NAME failed to start. Logs:" >&2
    docker logs "$CONTAINER_NAME" >&2 || true
    exit 1
  fi
}

ensure_session() {
  if docker exec "$CONTAINER_NAME" tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    return
  fi

  docker exec \
    -e CODEX_WORKDIR="$WORKDIR_IN_CONTAINER" \
    -e CODEX_WORKDIR_DEFAULT="$WORKDIR_IN_CONTAINER" \
    -e CODEX_TMUX_SESSION="$SESSION_NAME" \
    -e NVIDIA_VISIBLE_DEVICES=all \
    -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    -e HOME="$CONTAINER_HOME" \
    -e LANG="$CODEX_LANG" \
    -e LC_ALL="$CODEX_LC_ALL" \
    -e LC_CTYPE="$CODEX_LC_CTYPE" \
    -e EDITOR=emacs \
    --user "$CONTAINER_USER" \
    "$CONTAINER_NAME" \
    bash -lc 'set -euo pipefail
      CODEX_WORKDIR="${CODEX_WORKDIR:-${CODEX_WORKDIR_DEFAULT:-/workspace/repo}}"
      SESSION="${CODEX_TMUX_SESSION:-codex}"
      SET_UP_CODEX="cd \"$CODEX_WORKDIR\""
      RUN_CODEX="codex --dangerously-bypass-approvals-and-sandbox"

      tmux new-session -d -s "$SESSION"

      tmux rename-window -t "${SESSION}:0" codex
      tmux select-pane -t "${SESSION}:0.0" -T codex
      tmux send-keys -t "${SESSION}:0.0" "$SET_UP_CODEX && $RUN_CODEX" C-m
    '
}

ensure_image
ensure_container

# Copy ~/.codex/auth.json in late, to avoid polluting the repo with secrets
AUTH_DESTINATION="$CONTAINER_NAME":"$CODEX_CONFIG_CONTAINER"
docker cp --archive "$CODEX_AUTH_HOST" $AUTH_DESTINATION

ensure_session
docker exec -it "$CONTAINER_NAME" tmux attach -t "$SESSION_NAME"
