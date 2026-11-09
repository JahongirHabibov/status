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
#   1. installs the packages rootless Docker needs (Debian/Ubuntu); on a
#      docker.io host the rootless daemon itself comes later, from Docker's
#      static build, installed by the service user (`make docker-install`)
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
# Two ways to get rootless Docker, picked by what the host already runs. The
# rootful daemon (Traefik and the sites) is touched by neither.
#
#   docker-ce (Docker's apt repo) → docker-ce-rootless-extras from apt;
#       updates come with apt.
#   docker.io (Ubuntu's package)  → it has no rootless mode, and adding
#       docker-ce-rootless-extras would conflict with it. The service user
#       installs Docker's static rootless build into ~/bin instead
#       (`make docker-install`, README step 5). Updates are manual:
#       `make docker-update`.
if dpkg -s docker-ce >/dev/null 2>&1; then
	MODE=package
elif dpkg -s docker.io >/dev/null 2>&1; then
	MODE=static
else
	fail "neither docker-ce nor docker.io is installed — this script prepares a host that already runs the Traefik proxy"
fi
echo "rootless via: $MODE install"

apt-get update -qq
common=(uidmap dbus-user-session systemd-container slirp4netns iptables gettext-base curl)
if [ "$MODE" = package ]; then
	apt-get install -y -qq "${common[@]}" docker-ce-rootless-extras >/dev/null
	command -v dockerd-rootless-setuptool.sh >/dev/null \
		|| fail "dockerd-rootless-setuptool.sh not found after installing docker-ce-rootless-extras"
else
	apt-get install -y -qq "${common[@]}" >/dev/null
	# The static build brings its own docker CLI but no compose plugin; the CLI
	# also looks in the system plugin directories.
	if ! [ -x /usr/libexec/docker/cli-plugins/docker-compose ] \
		&& ! [ -x /usr/lib/docker/cli-plugins/docker-compose ]; then
		apt-get install -y -qq docker-compose-v2 >/dev/null
	fi
fi
echo "installed: ${common[*]}"

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
if [ "$MODE" = package ]; then ROOTLESSKIT=/usr/bin/rootlesskit; else ROOTLESSKIT="$home/bin/rootlesskit"; fi

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
	# One profile for exactly the rootlesskit binary this mode uses — Docker's
	# documented approach for Ubuntu 24.04. Named after the path:
	# /home/gatus/bin/rootlesskit → home.gatus.bin.rootlesskit. Path-based, so it
	# may exist before the binary does.
	name="$(printf '%s' "$ROOTLESSKIT" | sed -e 's@^/@@' -e 's@/@.@g')"
	profile="/etc/apparmor.d/$name"
	if [ ! -f "$profile" ]; then
		cat > "$profile" <<EOF
# Allows rootlesskit (rootless Docker) to create user namespaces.
abi <abi/4.0>,
include <tunables/global>

"$ROOTLESSKIT" flags=(unconfined) {
  userns,

  include if exists <local/$name>
}
EOF
		apparmor_parser -r "$profile"
		echo "profile installed: $profile"
	else
		echo "profile already present: $profile"
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
if [ "$MODE" = package ]; then
	install_cmd="dockerd-rootless-setuptool.sh install"
else
	install_cmd="make docker-install"
fi
cat <<EOF
Next, as $SERVICE_USER (README.md, step 5):

    sudo machinectl shell $SERVICE_USER@
    git clone https://github.com/JahongirHabibov/status.git ~/status && cd ~/status
    $install_cmd
EOF
