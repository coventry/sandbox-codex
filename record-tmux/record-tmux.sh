#!/usr/bin/env bash
set -euo pipefail

# Absolute paths for reuse (including when invoked from tmux hooks).
SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
AWK_PIPE_SCRIPT="$SCRIPT_DIR/record-pane.awk"
TMUX_SOCKET="${TMUX_SOCKET-}"

run_tmux() {
  if [[ -n "$TMUX_SOCKET" ]]; then
    tmux -S "$TMUX_SOCKET" "$@"
  else
    tmux "$@"
  fi
}

DEBUG_LOG="${RECORD_TMUX_DEBUG_LOG-}"
log_debug() {
  if [[ -n "$DEBUG_LOG" ]]; then
    printf '%s\n' "$*" >>"$DEBUG_LOG"
  fi
}

usage() {
  # Display CLI help text.
  cat <<'USAGE'
Usage: record-tmux.sh [-s session_name] [-o output_dir] [--no-attach]

Starts a tmux session and records all pane output to per-pane log files.
Logs are timestamped and named after the pane title when available.

Options:
  -s, --session NAME   Name for the tmux session to start (default: record)
  -o, --output-dir DIR Directory to place recordings (default: ./tmux-recordings)
      --no-attach      Do not attach after preparing the session
  -h, --help           Show this help
USAGE
}

sanitize_label() {
  # Collapse anything other than alnum/._- into underscores for safe filenames.
  local raw="$1"
  local cleaned
  cleaned=$(printf '%s' "$raw" | tr -cs '[:alnum:]._-' '_')
  cleaned=${cleaned#_}
  cleaned=${cleaned%_}
  printf '%s' "${cleaned}"
}

pipe_pane() {
  # Start piping a specific pane's output to its labeled log file.
  local pane_id="$1"
  local session_name="$2"
  local window_id="${3-}"
  if [[ -z "$session_name" ]]; then
    session_name=$(run_tmux display-message -p -t "$pane_id" '#{session_name}' 2>/dev/null || true)
  fi
  if [[ -z "$window_id" ]]; then
    window_id=$(run_tmux display-message -p -t "$pane_id" '#{window_id}' 2>/dev/null || true)
  fi
  if [[ -z "$DEBUG_LOG" && -n "$session_name" ]]; then
    DEBUG_LOG=$(run_tmux show-option -qv -t "$session_name" @record_debug_log 2>/dev/null || true)
  fi
  log_debug "[pipe_pane] pane=${pane_id} session=${session_name} window=${window_id} tmux_socket=${TMUX_SOCKET}"

  local log_dir
  log_dir=$(run_tmux show-option -qv -t "$session_name" @record_log_dir 2>/dev/null || true)
  if [[ -z "$log_dir" ]]; then
    log_debug "[pipe_pane] record log dir not set for session '${session_name}'; skipping ${pane_id}"
    return 0
  fi

  mkdir -p "$log_dir"

  local window_index pane_index pane_title window_name
  if ! window_index=$(run_tmux display-message -p -t "$pane_id" '#{window_index}' 2>/dev/null); then
    return 0
  fi
  pane_index=$(run_tmux display-message -p -t "$pane_id" '#{pane_index}')
  pane_title=$(run_tmux display-message -p -t "$pane_id" '#{pane_title}')
  window_name=$(run_tmux display-message -p -t "$pane_id" '#{window_name}')

  # Label priority: pane title (set via select-pane -T), then window name, then pane index.
  local label_source="$pane_title"
  [[ -n "$label_source" ]] || label_source="$window_name"
  [[ -n "$label_source" ]] || label_source="pane${pane_index}"
  local safe_label
  safe_label=$(sanitize_label "$label_source")
  [[ -n "$safe_label" ]] || safe_label="pane${pane_index}"

  local log_file
  log_file="$log_dir/${session_name}-w${window_index}-p${pane_index}-${safe_label}.log"
  local escaped_log
  escaped_log=$(printf '%q' "$log_file")
  local escaped_awk
  escaped_awk=$(printf '%q' "$AWK_PIPE_SCRIPT")

  # If the label changed, move the existing log so the path matches.
  local previous_log_file
  previous_log_file=$(run_tmux show-option -pqv -t "$pane_id" @record_log_file 2>/dev/null || true)
  if [[ -n "$previous_log_file" && "$previous_log_file" != "$log_file" && -e "$previous_log_file" ]]; then
    log_debug "[pipe_pane] moving log ${previous_log_file} -> ${log_file}"
    mv -f -- "$previous_log_file" "$log_file"
  fi

  run_tmux set-option -pt "$pane_id" -q @record_log_file "$log_file"

  local pipe_cmd
  # Add a timestamp header once per minute, then pass through pane output as-is; use interactive mode for live flushing.
  pipe_cmd="awk -W interactive -f ${escaped_awk} >> ${escaped_log}"
  log_debug "[pipe_pane] piping pane ${pane_id} to ${log_file}"

  # Replace any existing pipe so renames retarget the log file.
  if ! run_tmux pipe-pane -t "$pane_id" "$pipe_cmd"; then
    log_debug "[pipe_pane] failed to pipe pane ${pane_id}"
    return 0
  fi

  # Ensure pane-local hook is present for future title changes.
  run_tmux set-hook -p -t "$pane_id" pane-title-changed "run-shell -b 'TMUX_SOCKET=#{socket_path} \"${SCRIPT_PATH}\" --pipe-pane #{hook_pane} #{hook_session_name} #{hook_window}'"
}

ensure_tmux() {
  # Hard fail if tmux is missing.
  command -v tmux >/dev/null 2>&1 || { echo "tmux is required" >&2; exit 1; }
}

refresh_window() {
  # Re-run piping for every pane in a window (used after window rename).
  local window_id="$1"
  local session_name="$2"
  if [[ -z "$session_name" ]]; then
    session_name=$(run_tmux display-message -p -t "$window_id" '#{session_name}' 2>/dev/null || true)
  fi
  local panes
  if ! panes=$(run_tmux list-panes -t "$window_id" -F '#{pane_id}' 2>/dev/null); then
    log_debug "[refresh_window] window not found for ${window_id}"
    return 0
  fi
  while IFS= read -r pane_id; do
    if ! "$SCRIPT_PATH" --pipe-pane "$pane_id" "$session_name" "$window_id"; then
      log_debug "[refresh_window] failed to pipe ${pane_id} in ${window_id}"
    fi
  done <<<"$panes"
}

setup_window_hooks() {
  # Attach hooks to a window so retitles/renames repoint logs.
  local window_id="$1"
  local session_name="$2"
  if [[ -z "$session_name" ]]; then
    session_name=$(run_tmux display-message -p -t "$window_id" '#{session_name}' 2>/dev/null || true)
  fi
  log_debug "[setup_window_hooks] window=${window_id} session=${session_name} tmux_socket=${TMUX_SOCKET}"
  run_tmux set-hook -w -t "$window_id" pane-title-changed "run-shell -b 'TMUX_SOCKET=#{socket_path} \"${SCRIPT_PATH}\" --pipe-pane #{hook_pane} #{hook_session_name} #{hook_window}'"
  run_tmux set-hook -w -t "$window_id" window-renamed "run-shell -b 'TMUX_SOCKET=#{socket_path} \"${SCRIPT_PATH}\" --refresh-window #{hook_window} #{hook_session_name}'"

  # Ensure any existing panes in the window are piped immediately.
  while IFS= read -r pane_id; do
    "$SCRIPT_PATH" --pipe-pane "$pane_id" "$session_name" "$window_id"
  done < <(run_tmux list-panes -t "$window_id" -F '#{pane_id}')
}

main() {
  if [[ "${1-}" == "--pipe-pane" ]]; then
    shift
    [[ $# -ge 1 ]] || { echo "--pipe-pane requires <pane_id> [session_name] [window_id]" >&2; exit 1; }
    pipe_pane "$1" "${2-}" "${3-}"
    exit 0
  fi

  if [[ "${1-}" == "--refresh-window" ]]; then
    shift
    [[ $# -ge 1 ]] || { echo "--refresh-window requires <window_id> [session_name]" >&2; exit 1; }
    refresh_window "$1" "${2-}"
    exit 0
  fi

  if [[ "${1-}" == "--setup-window" ]]; then
    shift
    [[ $# -ge 2 ]] || { echo "--setup-window requires <window_id> <session_name>" >&2; exit 1; }
    setup_window_hooks "$1" "$2"
    exit 0
  fi

  local session_name="record"
  local output_root="$PWD/tmux-recordings"
  local attach=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--session)
        [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 1; }
        session_name="$2"
        shift 2
        ;;
      -o|--output-dir)
        [[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 1; }
        output_root="$2"
        shift 2
        ;;
      --no-attach)
        attach=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  ensure_tmux

  if run_tmux has-session -t "$session_name" 2>/dev/null; then
    echo "tmux session '$session_name' already exists; choose another name or kill it first." >&2
    exit 1
  fi

  # Build absolute output and log directories.
  mkdir -p "$output_root"
  output_root=$(cd "$output_root" && pwd -P)
  local log_dir_timestamp
  log_dir_timestamp=$(date +%Y%m%d-%H%M%S)
  local log_dir="$output_root/${session_name}-${log_dir_timestamp}"
  mkdir -p "$log_dir"

  # Create a detached session and stash the log dir as a session option for hooks.
  run_tmux new-session -d -s "$session_name"
  TMUX_SOCKET=$(run_tmux display-message -p -t "$session_name" '#{socket_path}')
  export TMUX_SOCKET
  log_debug "[main] started session=${session_name} socket=${TMUX_SOCKET} log_dir=${log_dir}"
  run_tmux set-option -t "$session_name" -q @record_log_dir "$log_dir"
  if [[ -n "$DEBUG_LOG" ]]; then
    run_tmux set-option -t "$session_name" -q @record_debug_log "$DEBUG_LOG"
  fi

  # Hooks to auto-pipe new panes and refresh on retitles/renames.
  run_tmux set-hook -t "$session_name" after-new-window "run-shell -b 'TMUX_SOCKET=#{socket_path} \"${SCRIPT_PATH}\" --setup-window #{window_id} #{session_name}'"
  run_tmux set-hook -t "$session_name" after-split-window "run-shell -b 'TMUX_SOCKET=#{socket_path} \"${SCRIPT_PATH}\" --pipe-pane #{pane_id} #{session_name} #{window_id}'"
  run_tmux set-hook -t "$session_name" after-rename-window "run-shell -b 'TMUX_SOCKET=#{socket_path} \"${SCRIPT_PATH}\" --refresh-window #{window_id} #{session_name}'"
  run_tmux set-hook -t "$session_name" pane-title-changed "run-shell -b 'TMUX_SOCKET=#{socket_path} \"${SCRIPT_PATH}\" --pipe-pane #{hook_pane} #{hook_session_name} #{hook_window}'"
  run_tmux set-hook -t "$session_name" window-renamed "run-shell -b 'TMUX_SOCKET=#{socket_path} \"${SCRIPT_PATH}\" --refresh-window #{hook_window} #{hook_session_name}'"
  run_tmux set-hook -t "$session_name" window-linked "run-shell -b 'TMUX_SOCKET=#{socket_path} \"${SCRIPT_PATH}\" --setup-window #{hook_window} #{hook_session_name}'"

  # Pipe any panes that already exist (the initial session window) and set window hooks.
  while IFS= read -r window_id; do
    "$SCRIPT_PATH" --setup-window "$window_id" "$session_name"
    while IFS= read -r pane_id; do
      "$SCRIPT_PATH" --pipe-pane "$pane_id" "$session_name" "$window_id"
    done < <(run_tmux list-panes -t "$window_id" -F '#{pane_id}')
  done < <(run_tmux list-windows -t "$session_name" -F '#{window_id}')

  echo "Recording tmux session '$session_name' to $log_dir"

  if [[ "$attach" -eq 1 ]]; then
    tmux attach -t "$session_name"
  else
    echo "Session started detached. Attach with: tmux attach -t $session_name"
  fi
}

main "$@"
