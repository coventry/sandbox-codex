# sandbox-codex

Sandbox codex, start it in tmux and record all tmux activity

## Usage

```bash
./run_codex_container.sh
```

By default this:
- builds `codex-local:latest` from `Dockerfile.codex` if missing
- starts a container with the current git repo mounted at `/workspace/repo`
- starts a tmux session and runs Codex inside it

## Configuration

Environment variables you may want to set:
- `CODEX_IMAGE`: image name/tag (default `codex-local:latest`)
- `CODEX_DOCKERFILE`: path to Dockerfile (default `./Dockerfile.codex`)
- `CODEX_CONTAINER_NAME`: container name (default `codex-tmux-<repo>`)
- `CODEX_TMUX_SESSION`: tmux session name (default `codex`)
- `CODEX_CONTAINER_HOME`: home directory inside container (default `/home/node`)
- `CODEX_AUTH_HOST`: path to host auth file (default `~/.codex/auth.json`)
- `CODEX_RECORD_OUTPUT_DIR`: recordings output dir in the container (default `/workspace/repo/tmux-recordings`)
- `CODEX_RECORD_SNAPSHOT_INTERVAL`: seconds between readable pane snapshots (default unset/off)

## Rebuild the image

```bash
docker build -t codex-local:latest -f Dockerfile.codex .
```
