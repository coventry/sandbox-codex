record-tmux
============

Script to start a tmux session and record every pane's output to disk. Each pane gets its own log file with a minute-level timestamp header and a filename label derived from the pane title (or window/pane indexes when no title is set).

Usage
-----
- Start a new recorded session and attach:
  - `./record-tmux.sh -s demo`
- Choose a different output root (default is `./tmux-recordings`):
  - `./record-tmux.sh -s demo -o ./logs`
- Prepare without attaching (useful in automation) and attach later with `tmux attach -t demo`:
  - `./record-tmux.sh -s demo --no-attach`
- Capture readable pane snapshots every 5 seconds (plain text of the current screen):
  - `./record-tmux.sh -s demo --snapshot-interval 5`

Details
-------
- Logs land under `<output-dir>/<session>-<timestamp>/` with files like `demo-w0-p0-api.log`.
- New panes, splits, and respawns are auto-recorded via tmux hooks; `pipe-pane -o` keeps the hook idempotent.
- Pane labels use the pane title when available. Set a friendly one with `tmux select-pane -T "api"` from inside tmux; otherwise the window name or pane index is used.
- Logs include a timestamp header once per minute; lines are otherwise the raw pane output. The label is in the filename, not repeated on every line. The per-line processing lives in `record-pane.awk`.
- Pane retitles (`pane-title-changed`) and window renames (`after-rename-window`) cause the script to repoint and rename the log file so recording continues under the updated filename.
- Optional snapshots land under `<output-dir>/<session>-<timestamp>/snapshots/` with files like `demo-w0-p0-api.txt`. Each snapshot file is overwritten at the configured interval with the current pane view.
- Use `RECORD_TMUX_SNAPSHOT_INTERVAL` to enable snapshots without passing `--snapshot-interval`.
