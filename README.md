# status

A self-hosted status page for the services on a VPS, built on
[Gatus](https://github.com/TwiN/gatus) and run **without root**: a dedicated
user with its own rootless Docker daemon, no `sudo`, no `docker` group.

The page is public and read-only. There is no admin UI. Everything is
configured in YAML files in this repository, and a change is a `git pull`.

## Security model

| Layer | What it means |
|---|---|
| **Service user `gatus`** | Password locked, home `0700`, **not** in `docker`, `sudo` or `adm`. Reached only through `sudo machinectl shell gatus@` from an admin account. |
| **Rootless Docker** | `gatus` runs its own Docker daemon. Membership in the `docker` group equals root on the host, and this user has none. A compromised account or a container escape ends at an unprivileged uid. |
| **Container user `65534`** | The upstream image (`FROM scratch`) has no `USER` line and would run as uid 0. `user: 65534:65534` overrides that. Under rootless Docker this maps to a subordinate uid of `gatus`, so the process sits two steps away from root. |
| **Read-only everything** | `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`. Config and secrets are mounted read-only, so a compromised Gatus cannot rewrite its checks or redirect its alerts. The only writable path is the SQLite volume. |
| **No public port** | Gatus listens on one private host address (`172.17.0.1:18080`, plain HTTP). TLS, security headers and rate limiting come from the Traefik proxy in front. |
| **Secrets as files** | Alerting credentials live in `secrets/alerting.yaml` (git-ignored) and are merged into the config. They are never environment variables, which `docker inspect` would show. |
| **Nothing to log into** | Gatus has no admin UI. Its API (`/api/v1/...`) is read-only. Per-endpoint `ui.hide-*` flags keep URLs, hosts, ports and raw errors off the page. |

What this does **not** protect against: a kernel exploit from inside the
container, or someone with root or `docker` group access to the host. Both are
outside the reach of any user-level deployment.

## Layout

```
status/
├── docker-compose.yml           # the Gatus service, hardened
├── .env.example                 # domain, bind address, version (nothing secret)
├── config/core.yaml             # storage, UI, connectivity check, self-check
├── endpoints/                   # the monitored services of THIS host (git-ignored)
│   └── services.yaml.example
├── secrets/                     # alerting credentials (git-ignored)
│   └── alerting.yaml.example
├── live/                        # what Gatus actually reads (git-ignored, written by `make apply`)
├── traefik/status.yml.tmpl      # file-provider route for the proxy
├── scripts/host-setup.sh        # one-time host preparation (admin, sudo)
└── Makefile                     # `gatus` targets + admin route-* targets
```

Gatus reads **every** `*.yaml` under `/etc/gatus` and merges them: maps
deep-merge, lists append, and a scalar may be set only once. To add a group of
services, add a file to `endpoints/`.

### Why `live/` exists

Gatus hot-reloads its config, and an invalid file takes the page down. We
measured both settings on v5.38.0:

- **`skip-invalid-config-update: false`** (the default): Gatus panics and
  restarts into the same broken file. The page stays down until the file is
  fixed.
- **`true`**: worse. Gatus stops its web server and every check, rejects the
  file, and never starts them again. The container still shows as running, but
  serves no page, runs no checks and sends no alerts.

So Gatus never reads the files you edit. It reads `live/`, and only
`make apply` writes there, after `make validate` has started a throwaway Gatus
with the new files and seen it accept them. Editing `endpoints/` or running
`git pull` therefore cannot break the running page.

## Requirements

- Debian or Ubuntu with `docker-ce` from Docker's apt repository. Ubuntu's own
  `docker.io` package has no rootless mode, and `host-setup.sh` stops on it.
- The Traefik proxy on the same host: the `proxy-network` network, the
  `traefik-dynamic` file-provider volume, the `letsencrypt` resolver, and the
  middlewares `security-headers@file`, `compress@file` and `rate-limit@file`
- A DNS zone you control

## Setup

### 1. DNS (admin)

Create an `A` record for the page, pointing at the VPS's **public** IP. Add an
`AAAA` record too if the proxy listens on IPv6. Let's Encrypt validates
HTTP-01 against this record.

```
status.example.com.  300  IN  A  <public IPv4 of the VPS>
```

Check: `dig +short status.example.com` returns the public IP.

### 2. Prepare the host (admin, once)

```bash
git clone https://github.com/JahongirHabibov/status.git /tmp/status-setup
sudo /tmp/status-setup/scripts/host-setup.sh gatus
```

The script installs the rootless prerequisites and creates the locked user
`gatus`. On Ubuntu 23.10 and later it adds an AppArmor profile for
`rootlesskit`. It also enables lingering, delegates the cgroup controllers the
container's CPU limit needs, and, if UFW is active, allows the Docker bridges to
reach `172.17.0.1:18080`. Read it before you run it. It is idempotent.

If the rootful daemon's `docker0` does not use `172.17.0.1`
(`ip -4 -o addr show docker0`), pass the real address through sudo:
`sudo GATUS_BIND=<addr> /tmp/status-setup/scripts/host-setup.sh gatus`, and use
the same value in `.env` in steps 4 and 6.

### 3. Install rootless Docker (as `gatus`)

```bash
sudo machinectl shell gatus@          # a real login session (systemd --user, XDG_RUNTIME_DIR)
dockerd-rootless-setuptool.sh install
systemctl --user enable --now docker
docker context use rootless
docker info --format '{{.SecurityOptions}}'   # must contain name=rootless
```

Use `machinectl shell`, not `sudo -iu gatus`: the latter starts no systemd user
session, and the rootless daemon cannot start without one.

### 4. Deploy (as `gatus`)

```bash
git clone https://github.com/JahongirHabibov/status.git ~/status
cd ~/status
cp .env.example .env                                 # set STATUS_DOMAIN, check GATUS_BIND
cp endpoints/services.yaml.example endpoints/services.yaml   # list your services
make setup                                           # data volume, owned by uid 65534
make up                                              # check → validate → apply → start
make logs                                            # "Validated N endpoints", no errors
```

Each `make` target refuses to run as root or against a daemon that is not
rootless.

### 5. Alerts (as `gatus`, optional)

```bash
cp secrets/alerting.yaml.example secrets/alerting.yaml
chmod 644 secrets/alerting.yaml      # read by uid 65534; the 0700 home keeps others out
nano secrets/alerting.yaml           # Telegram bot token + chat id
```

Then `make apply`. Gatus reloads on its own, and `make logs` shows
`configuredProviders=[telegram]`. Endpoints carrying `alerts: [{type: telegram}]`
alert only once a provider is configured. Until then they are silently ignored.

### 6. Route through Traefik (admin, once)

Traefik reads container labels only from the rootful daemon, so the route is a
file in its file-provider directory. Run this from the **admin's** checkout,
with an `.env` carrying the same `STATUS_DOMAIN`, `GATUS_BIND` and `GATUS_PORT`:

```bash
cd ~/projects/proxy/external_repos/status   # the admin's checkout
cp .env.example .env && nano .env
make route-install
```

The file is written atomically (temporary name, then rename), and Traefik
hot-reloads it. To take the page off the air, run `make route-remove`.

> The `traefik-dynamic` volume is shared with the customer-website stack, which
> writes `site-*.yml` files into it. After its next `reconcile`, check that
> `status.yml` is still there:
> `docker run --rm -v traefik-dynamic:/c alpine:3.20 ls /c`

### 7. Verify

```bash
# admin
curl -s http://172.17.0.1:18080/health                 # {"status":"UP"}  (Traefik → Gatus hop)
curl -sI https://status.example.com | head -1          # HTTP/2 200
docker logs --since 5m traefik 2>&1 | grep -iE "status|error" || echo clean

# as gatus
docker top gatus -o user,cmd                           # nobody  /gatus
docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}}' gatus   # true [ALL]
```

The page also checks itself (`config/core.yaml`, group `status`) the way a
visitor reaches it: public DNS, Traefik, certificate validity.

## Day to day

| Task | As | Command |
|---|---|---|
| Add or change a service | `gatus` | edit `endpoints/*.yaml`, then `make apply` (validated, then hot-reloaded) |
| Only check a change | `gatus` | `make validate` |
| Pull repository changes | `gatus` | `make update` |
| Upgrade Gatus | `gatus` | set `GATUS_VERSION` in `.env`, `make up` |
| Post an incident notice | `gatus` | `announcements:` in a file under `endpoints/` |
| Silence alerts during work | `gatus` | `maintenance:` or per-endpoint `maintenance-windows:` |
| Stop / start | `gatus` | `make down` / `make up` |

Edits take effect only through `make apply`. An invalid change is rejected
there, with Gatus's own error message, and the running page is not touched. See
"Why `live/` exists" above.

### Writing checks

```yaml
- name: API
  group: example.com
  url: "https://api.example.com/health"
  interval: 1m
  conditions:
    - "[STATUS] == 200"
    - "[BODY].status == ok"              # JSONPath into the response
    - "[RESPONSE_TIME] < 1000"           # ms
    - "[CERTIFICATE_EXPIRATION] > 240h"
```

- **Supported:** `https://`, `tcp://`, `udp://`, `tls://`, `starttls://`,
  `ws://`/`wss://`, `ssh://` and `dns` checks. See the
  [Gatus README](https://github.com/TwiN/gatus#conditions).
- **A service behind BasicAuth** is "up" when it answers `401`.
- **`[DOMAIN_EXPIRATION]`** needs an interval of at least `5m`; use `12h`.
- **Prefer TCP over ICMP:** ping from rootless networking needs extra host
  sysctls (`net.ipv4.ping_group_range`). `tcp://host:port` works without them.
- **YAML anchors** work only within one file.

## Limits

- **A check from the same host cannot report that host's own outage.** If the
  VPS goes down, the page goes down with it. Run a second Gatus somewhere else
  (another server, or a free scheduled runner) that checks
  `https://status.example.com/health`.
- **Without persistent storage, history is lost on restart.** This setup uses
  SQLite on the `gatus-data` volume, so history survives restarts.
- **The rootless port binds to the rootful daemon's `docker0` address.** If
  that interface is missing when the `gatus` daemon starts (for example, the
  rootful daemon has not started yet), the container fails to start. Check with
  `make ps`, then `make up`.
