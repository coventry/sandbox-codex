# sandbox-codex

Sandbox codex, start it in tmux and record all tmux activity

## Installation

`./cron-job.sh` needs to be run on the host, at whatever frequency you
specify. For instance, run `crontab -e`, and put something like this
at the bottom of the crontab file:

```
* * * * * /home/ubuntu2/src/sandbox-codex/cron-job.sh
```

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

## Rebuild the image

```bash
docker build -t codex-local:latest -f Dockerfile.codex .
```

