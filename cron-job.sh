#!/usr/bin/bash
set -euo pipefail
set -x

# This is run once a minute by a cron job.

# Finds all the running docker containers started from the
# codex-local:latest image, and runs
# docker-assets/tmux-snapshot-panes.sh in them.

# Image to match
IMAGE="codex-local:latest"

# Command to run inside each container.
# Use sh -lc so PATH and shell semantics behave consistently.
INNER_CMD="/usr/local/bin/tmux-snapshot-panes.sh"

# Optional: limit runtime per container (prevents pileups if something hangs).
# If 'timeout' isn't available on your host, remove it.
TIMEOUT_SECS=50

# Discover running containers whose ancestor image matches IMAGE.
# --no-trunc avoids ambiguity if you later log IDs.
mapfile -t CIDS < <(docker ps --filter "ancestor=${IMAGE}" --format '{{.ID}}')

echo ${CIDS[@]}

if ((${#CIDS[@]} == 0)); then
  exit 0
fi

for cid in "${CIDS[@]}"; do
  # Run command inside container. Remove --user if you want default container user.
  # Use -t only if your inner command requires a TTY; otherwise omit it.
  if command -v timeout >/dev/null 2>&1; then
    timeout "${TIMEOUT_SECS}" docker exec "${cid}" "${INNER_CMD}" "${cid}" || true
  else
    docker exec "${cid}" "${INNER_CMD}" "${cid}" || true
  fi
done
