all:
	docker build --progress=plain -t codex-local -f Dockerfile.codex .


# Copy auth token from top codex-local container to host. To
# be used after running `codex login --device-auth` in the
# container, if the current auth token fails.
FA := "ancestor=codex-local:latest"
CID := $(shell docker ps --latest --filter $(FA) --format '{{.ID}}' | head -n1)
ERRMSG := "No running codex-local:latest container found"
copy-auth:
	@test -n "$(CID)" || (echo $(ERRMSG) >&2; exit 1)
	@mkdir -p "$(HOME)/.codex"
	docker cp "$(CID)":/home/ubuntu/.codex/auth.json "$(HOME)/.codex/auth.json"
