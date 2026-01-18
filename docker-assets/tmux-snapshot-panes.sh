#!/usr/bin/env bash
set -euo pipefail

ROOT="/workspace/repo/tmux-recordings"
mkdir -p "$ROOT"

# Exit quietly if tmux server isn't running (cron-friendly).
tmux list-panes -a -F '' >/dev/null 2>&1 || exit 0

tmux list-panes -a -F '#{pane_id}|#{session_name}|#{window_index}|#{pane_index}' \
| while IFS='|' read -r pane_id session window pane; do
    dir="$ROOT/$session-$1/w$window"
    mkdir -p "$dir"
    out="$dir/p${pane}-${pane_id}.txt"
    tmp="${out}.tmp"

    # Full history -> flat text snapshot.
    # -S -   : start from top of history
    # -J     : join wrapped lines (remove if you want visual line-wrap preserved)
    tmux capture-pane -p -t "$pane_id" -S - -J >"$tmp"

    # Reduce disk churn if unchanged.
    if [[ -f "$out" ]] && cmp -s "$tmp" "$out"; then
      rm -f "$tmp"
    else
      mv -f "$tmp" "$out"
    fi
  done
