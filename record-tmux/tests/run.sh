#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SCRIPT="$ROOT_DIR/record-tmux.sh"
OUTPUT_ROOT="$ROOT_DIR/tmp-test-records"
TMUX_TMPDIR="$ROOT_DIR/tmp-tmux"
SESSION="rec-test"
TMUX_SOCKET="$TMUX_TMPDIR/rec-test.sock"
RECORD_TMUX_DEBUG_LOG="$OUTPUT_ROOT/debug.log"
TMUX_CMD=(tmux -S "$TMUX_SOCKET")

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

wait_for() {
  local seconds="$1"
  shift
  local cmd=("$@")
  local end=$((SECONDS + seconds))
  while (( SECONDS <= end )); do
    if "${cmd[@]}"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

cleanup() {
  if [[ "${KEEP_TEST_OUTPUT:-0}" != "1" ]]; then
    "${TMUX_CMD[@]}" kill-session -t "$SESSION" >/dev/null 2>&1 || true
    rm -rf "$OUTPUT_ROOT" "$TMUX_TMPDIR"
  else
    echo "Preserving test artifacts in $OUTPUT_ROOT and $TMUX_TMPDIR; leaving session $SESSION running."
  fi
}
trap cleanup EXIT

mkdir -p "$OUTPUT_ROOT" "$TMUX_TMPDIR"
export TMUX_TMPDIR
export RECORD_TMUX_DEBUG_LOG
export TMUX_SOCKET
unset TMUX

# Clean up any prior run using the same fixed session/socket.
"${TMUX_CMD[@]}" kill-session -t "$SESSION" >/dev/null 2>&1 || true
rm -f "$RECORD_TMUX_DEBUG_LOG"

echo "Starting recording session..."
"$SCRIPT" -s "$SESSION" -o "$OUTPUT_ROOT" --no-attach

log_dir=$(ls -td "$OUTPUT_ROOT"/${SESSION}-* 2>/dev/null | head -n1)
[[ -n "$log_dir" && -d "$log_dir" ]] || fail "Log directory not created"

PANE_ID=$("${TMUX_CMD[@]}" list-panes -t "$SESSION" -F '#{pane_id}' | head -n1)
WINDOW_ID=$("${TMUX_CMD[@]}" display-message -p -t "$PANE_ID" '#{window_id}')
initial_log=$(ls "$log_dir"/*.log 2>/dev/null | head -n1)
[[ -n "$initial_log" && -f "$initial_log" ]] || fail "Initial pane log not found"

echo "Emitting output to initial pane..."
"${TMUX_CMD[@]}" send-keys -t "$PANE_ID" 'echo first-line' Enter
wait_for 5 grep -q first-line "$initial_log" || fail "Initial log missing pane output"
wait_for 5 grep -q '^--- ' "$initial_log" || fail "Initial log missing timestamp header"

echo "Renaming pane title..."
"${TMUX_CMD[@]}" select-pane -t "$SESSION":0.0 -T newtitle
"$SCRIPT" --pipe-pane "$PANE_ID" "$SESSION" "$WINDOW_ID"
newtitle_log="$log_dir/${SESSION}-w0-p0-newtitle.log"
wait_for 5 test -f "$newtitle_log" || fail "Log not moved to newtitle file"
grep -q first-line "$newtitle_log" || fail "Preserved content missing after pane rename"

echo "Clearing pane title and renaming window..."
"${TMUX_CMD[@]}" select-pane -t "$SESSION":0.0 -T ""
"${TMUX_CMD[@]}" rename-window -t "$SESSION":0 wrenamed
"$SCRIPT" --refresh-window "$WINDOW_ID" "$SESSION"
renamed_log="$log_dir/${SESSION}-w0-p0-wrenamed.log"
wait_for 5 test -f "$renamed_log" || fail "Log not moved to window-named file"
grep -q first-line "$renamed_log" || fail "Preserved content missing after window rename"

echo "Creating a new window and ensuring it records..."
new_window_id=$("${TMUX_CMD[@]}" new-window -t "$SESSION" -n win2 -P -F '#{window_id}')
new_pane_id=$("${TMUX_CMD[@]}" list-panes -t "$new_window_id" -F '#{pane_id}' | head -n1)
new_window_index=$("${TMUX_CMD[@]}" display-message -p -t "$new_pane_id" '#{window_index}')
new_pane_index=$("${TMUX_CMD[@]}" display-message -p -t "$new_pane_id" '#{pane_index}')
"${TMUX_CMD[@]}" select-pane -t "$new_pane_id" -T win2pane
new_log="$log_dir/${SESSION}-w${new_window_index}-p${new_pane_index}-win2pane.log"
"${TMUX_CMD[@]}" send-keys -t "$new_pane_id" 'echo win2-line' Enter
wait_for 5 test -f "$new_log" || fail "New window log not created"
wait_for 5 grep -q win2-line "$new_log" || fail "New window log missing pane output"
wait_for 5 grep -q '^--- ' "$new_log" || fail "New window log missing timestamp header"

echo "All tests passed."
