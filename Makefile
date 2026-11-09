SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# Two roles, kept apart on purpose (see README.md, "Security model"):
#
#   user `gatus`  setup, check, validate, apply, up, down, restart, logs, ps,
#                 update, docker-install, docker-update
#                 → talks ONLY to its own rootless Docker daemon
#
#   admin         route-render, route-install, route-remove
#                 → talks to the rootful daemon that runs Traefik; run once
#                   per host from the admin's own checkout of this repository

VOLUME          := gatus-data
CONTAINER_UID   := 65534
DYNAMIC_VOLUME  := traefik-dynamic
ROUTE_FILE      := status.yml
HELPER_IMAGE    := alpine:3.20

# Loads .env into the recipe's shell. Parsed, never sourced: `. ./.env` would
# EXECUTE a line like `STATUS_TITLE=Status habibov.de` (runs `habibov.de`),
# which docker compose itself reads fine. KEY=VALUE per line, comments and
# blank lines skipped, one pair of surrounding quotes stripped. Nothing printed.
HASH := \#
LOAD_ENV := while IFS= read -r line || [ -n "$$line" ]; do \
		case "$$line" in ""|"$(HASH)"*) continue;; esac; \
		key=$${line%%=*}; val=$${line\#*=}; \
		case "$$key" in ""|*[!A-Za-z0-9_]*) continue;; esac; \
		case "$$val" in \"*\") val=$${val:1:-1};; \'*\') val=$${val:1:-1};; esac; \
		export "$$key=$$val"; \
	done < .env

.PHONY: setup check validate apply up down restart logs ps update \
        docker-install docker-update \
        route-render route-install route-remove \
        _require-env _require-rootless _require-rootful

# ── user `gatus` ─────────────────────────────────────────────────────────────

setup: _require-env _require-rootless
	@mkdir -p config endpoints secrets live
	@test -n "$$(find endpoints -maxdepth 1 -name '*.y*ml' -print -quit)" \
		|| echo "NOTE: endpoints/ has no *.yaml yet — copy endpoints/services.yaml.example"
	@docker volume inspect $(VOLUME) >/dev/null 2>&1 || docker volume create $(VOLUME) >/dev/null
	@# A fresh volume belongs to container-root. Gatus runs as $(CONTAINER_UID)
	@# and must own its data directory, nothing else.
	@docker run --rm -v $(VOLUME):/data $(HELPER_IMAGE) \
		chown $(CONTAINER_UID):$(CONTAINER_UID) /data
	@echo "setup: volume $(VOLUME) owned by uid $(CONTAINER_UID)"

check: _require-env _require-rootless
	@$(LOAD_ENV); \
	case "$${GATUS_BIND:-}" in \
		""|0.0.0.0|"::"|"[::]") echo "REFUSING: GATUS_BIND must be one concrete host address, not '$${GATUS_BIND:-}'"; exit 1;; \
	esac
	@home_mode=$$(stat -c '%a' "$$HOME"); \
	case "$$home_mode" in 700|750|710) ;; \
		*) echo "REFUSING: $$HOME is mode $$home_mode — must not be world-readable (secrets/ lives below it): chmod 700 $$HOME"; exit 1;; \
	esac
	@if command -v yq >/dev/null; then \
		for f in config/*.yaml endpoints/*.yaml secrets/*.yaml; do \
			[ -e "$$f" ] || continue; \
			yq '.' "$$f" >/dev/null || { echo "YAML error in $$f"; exit 1; }; \
		done; echo "yaml: parses"; \
	else echo "yaml: yq not installed — skipped here, 'make validate' catches syntax errors too"; fi
	@docker compose config --quiet && echo "compose: valid"
	@if [ -x "$$HOME/bin/dockerd" ]; then \
		echo "rootless docker: $$("$$HOME/bin/dockerd" --version | cut -d, -f1) (static build — no apt updates, run 'make docker-update' regularly)"; \
	fi

# Gatus has no "check config" flag, so this starts it once, throwaway, with the
# exact config the service will read, and waits for the first of two log lines:
# "Listening on" (config accepted) or "panic:" (rejected). No port, no data
# volume (tmpfs), removed afterwards. Uses the image the service runs.
VALIDATOR := gatus-validate

validate: check
	@docker rm -f $(VALIDATOR) >/dev/null 2>&1 || true
	@$(LOAD_ENV); \
	docker run -d --name $(VALIDATOR) \
		--user 65534:65534 --read-only --cap-drop ALL --security-opt no-new-privileges:true \
		--tmpfs /data:uid=65534,gid=65534 --dns 1.1.1.1 \
		-e GATUS_CONFIG_PATH=/etc/gatus \
		-e STATUS_DOMAIN="$$STATUS_DOMAIN" -e STATUS_TITLE="$${STATUS_TITLE:-Status}" \
		-v "$(CURDIR)/config":/etc/gatus/core:ro \
		-v "$(CURDIR)/endpoints":/etc/gatus/endpoints:ro \
		-v "$(CURDIR)/secrets":/etc/gatus/secrets:ro \
		ghcr.io/twin/gatus:$${GATUS_VERSION:-v5.38.0} >/dev/null
	@# Process substitution, not a pipe: the result is in as soon as grep has
	@# its line, without waiting for `docker logs -f` to notice a closed pipe.
	@# `timeout` is a ceiling, not a wait: a start takes well under a second,
	@# and the ceiling only matters if Gatus ever prints neither line.
	@result=$$(grep -m1 -E 'Listening on|panic:' < <(timeout 60 docker logs -f $(VALIDATOR) 2>&1) || true); \
	docker rm -f $(VALIDATOR) >/dev/null 2>&1 || true; \
	case "$$result" in \
		*"Listening on"*) echo "config: valid";; \
		*) echo "config: INVALID"; echo "  $${result:-gatus exited without a reason}"; exit 1;; \
	esac

# Copies the validated sources into live/, the only directory Gatus reads.
# Per file: write to *.tmp (not a .yaml, so Gatus ignores it), then rename.
# Files gone from the source are deleted from live/. If anything changed,
# core.yaml is touched: Gatus reloads when the newest mtime moves, and a
# deletion alone would not move it.
apply: validate
	@changed=0; \
	for pair in config:core endpoints:endpoints secrets:secrets; do \
		src=$${pair%%:*}; dst=live/$${pair##*:}; mkdir -p "$$dst"; \
		for f in "$$src"/*.yaml "$$src"/*.yml; do \
			[ -e "$$f" ] || continue; t="$$dst/$${f##*/}"; \
			cmp -s "$$f" "$$t" && continue; \
			cp "$$f" "$$t.tmp" && mv "$$t.tmp" "$$t"; changed=1; echo "applied $$t"; \
		done; \
		for t in "$$dst"/*.yaml "$$dst"/*.yml; do \
			[ -e "$$t" ] || continue; [ -e "$$src/$${t##*/}" ] && continue; \
			unlink "$$t"; changed=1; echo "deleted $$t"; \
		done; \
	done; \
	if [ "$$changed" = 1 ]; then touch live/core/core.yaml; echo "live/ updated — Gatus reloads it"; \
	else echo "live/ unchanged"; fi

up: apply
	docker compose up -d
	@echo "Now: make logs"

down: _require-rootless
	docker compose down

restart: _require-rootless
	docker compose restart gatus

logs: _require-rootless
	docker compose logs -f --since 10m gatus

ps: _require-rootless
	docker compose ps

# Pull the repository and roll out. A pull changes config/, never live/: `up`
# validates first and applies only a config Gatus accepts. The container is
# recreated only if the compose file or the image version changed.
update: _require-rootless
	git pull --ff-only
	@$(MAKE) --no-print-directory up

# ── rootless Docker itself, on docker.io hosts (static build in ~/bin) ──────
#
# Ubuntu's docker.io has no rootless mode, so the service user installs Docker's
# own static rootless build into ~/bin with Docker's official installer. It
# touches nothing outside this user's home; the rootful daemon keeps running.
# On docker-ce hosts use `dockerd-rootless-setuptool.sh install` instead —
# updates then come with apt.
DOCKER_INSTALLER := https://get.docker.com/rootless

docker-install:
	@[ "$$(id -u)" != "0" ] || { echo "REFUSING: run as the service user, not root"; exit 1; }
	@! dpkg -s docker-ce-rootless-extras >/dev/null 2>&1 \
		|| { echo "docker-ce-rootless-extras is installed — use: dockerd-rootless-setuptool.sh install"; exit 1; }
	@tmp=$$(mktemp); trap 'unlink "$$tmp"' EXIT; \
	curl -fsSL $(DOCKER_INSTALLER) -o "$$tmp"; \
	echo "installer $$(grep -m1 '^SCRIPT_COMMIT_SHA=' "$$tmp"), $$(grep -m1 '^STABLE_LATEST=' "$$tmp")"; \
	sh "$$tmp"
	@echo
	@echo "Next: log out and back in (puts ~/bin on PATH), then:"
	@echo "  docker context use rootless && make check"

# Docker's documented upgrade path for this install: stop the daemon, move
# ~/bin/dockerd out of the way, run the installer again. The old dockerd is
# kept until the new one is in place, and put back if the install fails.
# Gatus is down for the length of the update.
docker-update:
	@[ "$$(id -u)" != "0" ] || { echo "REFUSING: run as the service user, not root"; exit 1; }
	@test -x "$$HOME/bin/dockerd" \
		|| { echo "no static rootless Docker in ~/bin — on docker-ce hosts, apt updates it"; exit 1; }
	@echo "current: $$("$$HOME/bin/dockerd" --version)"
	systemctl --user stop docker
	@mv "$$HOME/bin/dockerd" "$$HOME/bin/dockerd.previous"
	@if $(MAKE) --no-print-directory docker-install; then \
		unlink "$$HOME/bin/dockerd.previous"; \
	else \
		echo "install failed — restoring the previous dockerd"; \
		mv "$$HOME/bin/dockerd.previous" "$$HOME/bin/dockerd"; \
		systemctl --user start docker; exit 1; \
	fi
	systemctl --user start docker
	@echo "now: $$("$$HOME/bin/dockerd" --version)"
	@$(MAKE) --no-print-directory up

# ── admin (rootful daemon, where Traefik runs) ──────────────────────────────

route-render: _require-env
	@command -v envsubst >/dev/null || { echo "envsubst missing: sudo apt install gettext-base"; exit 1; }
	@$(LOAD_ENV); \
	: "$${STATUS_DOMAIN:?STATUS_DOMAIN not set in .env}"; \
	export GATUS_BIND="$${GATUS_BIND:-172.17.0.1}" GATUS_PORT="$${GATUS_PORT:-18080}"; \
	envsubst '$${STATUS_DOMAIN} $${GATUS_BIND} $${GATUS_PORT}' \
		< traefik/status.yml.tmpl > traefik/$(ROUTE_FILE)
	@echo "rendered traefik/$(ROUTE_FILE)"

# Written to a temporary name and RENAMED: Traefik watches this directory, and
# a reader that lands inside a `cp` sees a half-written file. `.tmp` is not a
# file-provider extension, so the partial file is never parsed.
route-install: _require-rootful route-render
	@docker volume inspect $(DYNAMIC_VOLUME) >/dev/null 2>&1 \
		|| { echo "volume $(DYNAMIC_VOLUME) missing — is this the proxy host?"; exit 1; }
	@docker run --rm \
		-v $(DYNAMIC_VOLUME):/target \
		-v "$(CURDIR)/traefik/$(ROUTE_FILE)":/source:ro \
		$(HELPER_IMAGE) sh -c 'cp /source /target/$(ROUTE_FILE).tmp && mv /target/$(ROUTE_FILE).tmp /target/$(ROUTE_FILE)'
	@echo "installed $(ROUTE_FILE) into $(DYNAMIC_VOLUME) — Traefik hot-reloads it"
	@echo "verify: docker logs --since 1m traefik 2>&1 | grep -i status || echo clean"

route-remove: _require-rootful
	@docker run --rm -v $(DYNAMIC_VOLUME):/target $(HELPER_IMAGE) rm -f /target/$(ROUTE_FILE)
	@echo "removed $(ROUTE_FILE) from $(DYNAMIC_VOLUME)"

# ── guards ──────────────────────────────────────────────────────────────────

_require-env:
	@test -f .env || { echo "missing .env — cp .env.example .env"; exit 1; }

# Refuses root, and refuses to deploy Gatus into the rootful daemon — the whole
# point is that the `gatus` user has no access to it.
_require-rootless:
	@[ "$$(id -u)" != "0" ] || { echo "REFUSING: do not run as root"; exit 1; }
	@docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q 'name=rootless' \
		|| { echo "REFUSING: docker is not the rootless daemon of $$(id -un)."; \
		     echo "  Log in with: sudo machinectl shell gatus@  (see README)"; exit 1; }

_require-rootful:
	@docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q 'name=rootless' \
		&& { echo "REFUSING: this is a rootless daemon. Run route-* as the admin, against the daemon that runs Traefik."; exit 1; } || true
	@docker inspect traefik >/dev/null 2>&1 || { echo "no container 'traefik' on this daemon"; exit 1; }
