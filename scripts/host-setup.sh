#!/usr/bin/env bash
# One-time host preparation for the rootless Gatus deployment.
#
#   sudo ./scripts/host-setup.sh [username]      # default: gatus
#
# Run by an ADMIN, once per host. Idempotent: re-running changes nothing that
# is already in place. Afterwards the service user needs no root, no sudo and
# no membership in the `docker` group — ever.
#
# What it does:
#   1. installs the packages rootless Docker needs (Debian/Ubuntu)
#   2. creates the service user with a locked password and a 0700 home
#   3. checks it has subordinate uid/gid ranges (user namespaces)
#   4. on Ubuntu >= 23.10: allows rootlesskit to create user namespaces
#      (AppArmor restricts that for unprivileged programs by default)
#   5. enables lingering, so the user's daemon runs without a login session
#   6. delegates the cpu/cpuset/io cgroup controllers to user sessions, so the
#      container's CPU limit can be applied (systemd delegates only memory and
#      pids by default)
#   7. if UFW is active: lets the Docker bridges (Traefik) reach the port
#
# What it does NOT do: start anything as that user. That step is in README.md
# ("Install rootless Docker"), run as the user itself.

set -euo pipefail

SERVICE_USER="${1:-gatus}"
GATUS_BIND="${GATUS_BIND:-172.17.0.1}"
GATUS_PORT="${GATUS_PORT:-18080}"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail "run with sudo (this script prepares the host; the service itself never runs as root)"
command -v apt-get >/dev/null || fail "only Debian/Ubuntu are supported by this script"
[[ "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || fail "invalid user name: $SERVICE_USER"

# ── 1. packages ─────────────────────────────────────────────────────────────
say "packages"
# Rootless mode ships only with Docker's own packages (docker-ce +
# docker-ce-rootless-extras). Ubuntu's `docker.io` has no rootless setup tool,
# and mixing it with docker-ce-rootless-extras conflicts — so stop here and say
# so instead of half-installing.
if ! dpkg -s docker-ce >/dev/null 2>&1; then
	if dpkg -s docker.io >/dev/null 2>&1; then
		fail "this host runs Ubuntu's docker.io, which has no rootless mode. Switch to docker-ce from Docker's apt repository first (https://docs.docker.com/engine/install/) — that restarts every container on the host, so plan it."
	fi
	fail "docker-ce is not installed"
fi
apt-get update -qq
apt-get install -y -qq uidmap dbus-user-session systemd-container slirp4netns \
	docker-ce-rootless-extras gettext-base >/dev/null
command -v dockerd-rootless-setuptool.sh >/dev/null \
	|| fail "dockerd-rootless-setuptool.sh not found — is docker-ce from Docker's apt repo installed?"

# ── 2. service user ─────────────────────────────────────────────────────────
say "user $SERVICE_USER"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
	# A regular (not --system) user: useradd assigns subuid/subgid ranges only
	# to regular users. The shell is needed for `machinectl shell`.
	useradd --create-home --shell /bin/bash --comment "Gatus status page" "$SERVICE_USER"
	echo "created"
fi
passwd -l "$SERVICE_USER" >/dev/null   # no password login, ever
home="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
chmod 700 "$home"

for g in docker sudo adm; do
	if id -nG "$SERVICE_USER" | tr ' ' '\n' | grep -qx "$g"; then
		fail "$SERVICE_USER is in group '$g' — that defeats the purpose. Remove it: gpasswd -d $SERVICE_USER $g"
	fi
done
echo "password locked, home $home mode 700, not in docker/sudo/adm"

# ── 3. subordinate ids ──────────────────────────────────────────────────────
say "subuid/subgid"
grep -q "^$SERVICE_USER:" /etc/subuid || fail "no /etc/subuid range for $SERVICE_USER (add e.g. '$SERVICE_USER:231072:65536')"
grep -q "^$SERVICE_USER:" /etc/subgid || fail "no /etc/subgid range for $SERVICE_USER"
echo "present"

# ── 4. AppArmor (Ubuntu 23.10+) ─────────────────────────────────────────────
say "apparmor"
if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = 1 ]; then
	profile=/etc/apparmor.d/usr.bin.rootlesskit
	if [ ! -f "$profile" ]; then
		cat > "$profile" <<'EOF'
# Allows rootlesskit (rootless Docker) to create user namespaces.
abi <abi/4.0>,
include <tunables/global>

/usr/bin/rootlesskit flags=(unconfined) {
  userns,

  include if exists <local/usr.bin.rootlesskit>
}
EOF
		apparmor_parser -r "$profile"
		echo "profile installed"
	else
		echo "profile already present"
	fi
else
	echo "unprivileged userns not restricted — nothing to do"
fi

# ── 5. linger ───────────────────────────────────────────────────────────────
say "linger"
loginctl enable-linger "$SERVICE_USER"
echo "enabled — the user's systemd (and its Docker daemon) start at boot"

# ── 6. cgroup delegation ────────────────────────────────────────────────────
say "cgroup delegation"
[ -f /sys/fs/cgroup/cgroup.controllers ] || fail "cgroup v2 required for resource limits under rootless Docker"
delegate=/etc/systemd/system/user@.service.d/delegate.conf
if [ ! -f "$delegate" ]; then
	mkdir -p "$(dirname "$delegate")"
	printf '[Service]\nDelegate=cpu cpuset io memory pids\n' > "$delegate"
	systemctl daemon-reload
	# Linger (step 5) has already started the user's systemd; the drop-in only
	# applies to a fresh start. Only on first install, so a re-run never
	# restarts a running rootless daemon.
	uid="$(id -u "$SERVICE_USER")"
	if systemctl is-active --quiet "user@$uid.service"; then
		systemctl restart "user@$uid.service"
	fi
	echo "installed $delegate"
else
	echo "already present"
fi

# ── 7. firewall ─────────────────────────────────────────────────────────────
say "firewall"
ip -4 -o addr show | grep -qF " $GATUS_BIND/" \
	|| fail "no interface holds $GATUS_BIND — set GATUS_BIND to the rootful docker0 address (ip -4 -o addr show docker0)"
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
	# Traefik reaches the port from a Docker bridge (172.16.0.0/12). Nothing else
	# may: the port speaks plain HTTP.
	ufw allow proto tcp from 172.16.0.0/12 to "$GATUS_BIND" port "$GATUS_PORT" comment 'traefik -> gatus' >/dev/null
	echo "ufw: 172.16.0.0/12 -> $GATUS_BIND:$GATUS_PORT allowed"
else
	echo "ufw not active. $GATUS_BIND is a private address and is not routed from the internet,"
	echo "but keep a firewall (ufw or the provider's) that drops everything except 22/80/443/8443."
fi

say "done"
cat <<EOF
Next, as $SERVICE_USER (README.md, "Install rootless Docker"):

    sudo machinectl shell $SERVICE_USER@
    dockerd-rootless-setuptool.sh install
EOF
