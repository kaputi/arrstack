# arrStack Sandbox — From-Scratch Tutorial

Build a self-hosted media stack (Radarr, Sonarr, Bazarr, Prowlarr, Seerr, Transmission, Plex, Tautulli, Homepage, Flaresolverr) on Arch Linux, sandboxed under a dedicated system user via rootless Docker. Bind-mount isolation, pasta source-IP preservation for LAN media clients, and a clean repo + deploy workflow.

## What you'll end up with

- A non-login system user (`arrstack`) running its own rootless Docker daemon — separate from your personal user's docker setup, with no access to your home or other parts of the host.
- 10 services on a single bridge network, addressable by service name internally.
- Two host directories (`/mnt/arr1`, `/mnt/arr2`) with arr data under a `mediaServer/` subdir on each, the rest of each drive free for personal use.
- Plex serving LAN clients (e.g. Nvidia Shield) at full LAN-detected quality through bridge networking — no `network_mode: host` required.
- Edit-and-deploy workflow: edit compose/env in your git checkout, `bash scripts/deploy.sh` to push to the runtime location.

## Audience and assumptions

You are setting up on a fresh-ish Arch Linux box. You have:

- Root via `sudo`.
- An AUR helper (`yay`, `paru`, or similar). If not, install one before starting — the rootless Docker tooling on Arch only ships in the AUR.
- One or two physical drives intended for arr data. Either fresh/unformatted, or already ext4-formatted with empty (or non-arr) content. Both cases are covered.
- A LAN with a stable subnet (e.g. `192.168.1.0/24`) and a router you can reach.
- Optional: Plex.tv account, Nvidia Shield (or similar Plex client) on the LAN to verify the source-IP preservation step.

This tutorial does **not** cover migration of an existing arr stack — see the implementation plan in `docs/superpowers/plans/` for that. It also does not cover Cloudflare Tunnel, Plex remote access, or Jellyfin with GPU passthrough — those are deliberate Phase 2 items.

## Conventions used here

- Commands you run as your personal user: shown plain.
- Commands needing root: prefixed with `sudo`.
- Commands run in the sandbox context: `sudo -iu arrstack ...` or `sudo systemctl --user --machine=arrstack@.host ...`.
- `<placeholders>` in code blocks are values you substitute. The tutorial captures those as you go.
- Every section ends with a verification step. Run it before moving on; it's faster to catch a mismatch early than three steps later.

> **Why a separate user instead of the docker group?** Membership in the system `docker` group is effectively root — anyone with the docker socket can mount `/` into a container as root. The whole point of this design is to confine a container compromise to the arrstack user's filesystem view. So a dedicated user, running its own rootless daemon, is the spine of the threat model.

---

## 1. Identify and prepare the drives

Two host directories drive every container's filesystem view:

- `/mnt/arr1` — primary drive. Holds configs, downloads, and the main media library (movies, series, etc.).
- `/mnt/arr2` — secondary drive. Holds an additional movies dir for capacity offload, kept as a separate library folder so containers see two roots.

Pick which physical drives you want to use. **Do not pick the disk holding `/`.**

```bash
lsblk -f
```

Note the device names and any existing UUIDs. If a drive is fresh (no filesystem yet), format it now:

```bash
# Replace /dev/sdX with the actual device. THIS WIPES THE DRIVE.
sudo mkfs.ext4 -L arr1 /dev/sdX
sudo mkfs.ext4 -L arr2 /dev/sdY
```

Re-run `lsblk -f` to capture the new UUIDs. Record them — you'll need them in the next step:

- `ARR1_UUID=<uuid of drive 1>`
- `ARR2_UUID=<uuid of drive 2>`

> **Why ext4?** Both `xfs` and `btrfs` work too, but ext4 is the simplest baseline for a media drive — well-understood failure modes, predictable behaviour, no compression/snapshot complexity. If you have a specific reason for btrfs/xfs, adapt; this tutorial uses ext4.

**Verify:** `lsblk -f` lists both drives with the right `FSTYPE`, `LABEL`, and `UUID`.

---

## 2. Mount the drives via fstab

```bash
sudo mkdir -p /mnt/arr1 /mnt/arr2
sudo cp /etc/fstab /etc/fstab.backup-$(date +%Y%m%d)
```

Edit `/etc/fstab` (`sudo $EDITOR /etc/fstab`) and append, substituting your UUIDs:

```
# arrStack data drives
UUID=<ARR1_UUID>  /mnt/arr1  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0 2
UUID=<ARR2_UUID>  /mnt/arr2  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10s  0 2
```

> **Why each option:**
> - `noatime` — skip access-time writes on a drive full of media files.
> - `nofail` — boot continues if the drive is missing rather than dropping into emergency mode.
> - `x-systemd.device-timeout=10s` — caps how long systemd waits before giving up on a missing device.
> - `0 2` — no dump backup, fsck order 2 (after `/`).

Activate:

```bash
sudo systemctl daemon-reload
sudo mount -a
```

**Verify:**

```bash
df -h /mnt/arr1 /mnt/arr2
mount | grep -E "/mnt/arr[12]"
```

Both should show as ext4 with the options you set, mounted RW.

> **Gotcha — already mounted somewhere else?** If you previously mounted either drive at a temp location (e.g. `/mnt/inspect`) and didn't unmount, `mount -a` may "share" that mount and inherit its options (often read-only after `mount -o ro`). If you see `WARNING: source write-protected, mounted read-only`, run `mount | grep <UUID>` to find stray mounts, `sudo umount <stray-path>`, then retry `mount -a`.

---

## 3. Create the `arrstack` system user

```bash
sudo useradd \
  --system \
  --create-home \
  --home-dir /home/arrstack \
  --shell /bin/bash \
  --user-group \
  arrstack

sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 arrstack
sudo loginctl enable-linger arrstack
```

> **Why `/bin/bash` and not `/usr/sbin/nologin`:** later steps use `sudo -iu arrstack` to enter an interactive login shell that sources `~/.profile`. The `-i` flag insists on a login shell; `nologin` aborts with "This account is currently not available." `arrstack` has no password and no SSH key, so the security gain from `nologin` is zero in this configuration — login attempts fail regardless of the shell.

> **Why subuid/subgid manually:** Arch's `useradd` does **not** auto-allocate subuid/subgid ranges (default `SUB_UID_COUNT=0`). Without a range, rootless Docker has no userns mapping space and fails on first run. The `100000-165535` range is conventional; if a previous user holds it, pick another non-overlapping 65536-wide range.

> **Why lingering:** without `enable-linger`, the user's systemd manager only runs while there's an active login session. With it, `arrstack`'s daemon is started at boot and survives logouts.

Add yourself to the `arrstack` group so you can edit deploy artifacts without `sudo`:

```bash
sudo usermod -aG arrstack <your-username>
```

> **Gotcha:** group membership is **only effective in new shell sessions**. Your *current* shell still doesn't see the new group until you log out and back in (or run `newgrp arrstack` in the current shell). Until then, file access checks that rely on group membership will fail. The simplest workaround: `sudo -u arrstack <cmd>` for anything that hits arrstack-owned files before you re-login.

**Verify:**

```bash
id arrstack
grep arrstack /etc/subuid /etc/subgid
loginctl show-user arrstack | grep Linger
sudo -iu arrstack id
```

You should see: a uid/gid pair, two `arrstack:100000:65536` lines, `Linger=yes`, and the same uid/gid output again from inside the sudo'd shell.

---

## 4. Set up the directory layout and ownership

```bash
ARR1_ROOT=/mnt/arr1/mediaServer
ARR2_ROOT=/mnt/arr2/mediaServer

sudo mkdir -p "$ARR1_ROOT/config"
sudo mkdir -p "$ARR1_ROOT/downloads"
sudo mkdir -p "$ARR1_ROOT/media/movies"
sudo mkdir -p "$ARR1_ROOT/media/movies_4k"
sudo mkdir -p "$ARR1_ROOT/media/series"
sudo mkdir -p "$ARR2_ROOT/media/movies"

sudo chown -R arrstack:arrstack "$ARR1_ROOT" "$ARR2_ROOT"
sudo chmod 0750 "$ARR1_ROOT" "$ARR2_ROOT"
```

> **Why a `mediaServer/` subdir per drive instead of using the drive root?** Most users want to keep the rest of the drive free for personal content (Steam libraries, documents, VM disks, etc.). Putting all arr data under a single subdir makes it easy to bind-mount only the arr subtree into containers — anything outside `mediaServer/` is invisible to the sandbox. The name itself isn't load-bearing; pick whatever you like and substitute throughout.

If you don't intend to use `movies_4k`, omit that mkdir — the compose file later in this tutorial assumes it exists, but you can just remove that volume mount.

**Verify:**

```bash
ls -ld "$ARR1_ROOT" "$ARR2_ROOT"
ls -la "$ARR1_ROOT"
ls -la "$ARR2_ROOT/media"
```

Should show `drwxr-x--- arrstack arrstack` on each `mediaServer/`, with the expected children.

---

## 5. Grant arrstack ACL traversal on the drive roots

The filesystem root of each drive is whatever ownership/mode the FS was created with — often `0700` if the drive was previously used as personal storage, or `0755` if fresh. Either way, the rootless Docker daemon (running as `arrstack`) needs to *traverse* `/mnt/arr1/` and `/mnt/arr2/` to reach the bind-mount sources under `mediaServer/`. With `0700` user ownership, arrstack can't even pass through.

The fix that gives the minimum needed access — and **only** that — is a POSIX ACL granting execute (traverse) on the drive root:

```bash
sudo setfacl -m u:arrstack:x /mnt/arr1
sudo setfacl -m u:arrstack:x /mnt/arr2
```

> **Why ACL and not `chgrp arrstack` + `chmod 0750`?** Both grant traversal. The `chgrp` approach also gives arrstack `read` (the `r` bit), so arrstack can `ls /mnt/arr1` and see the names of your personal directories at top level. Their *contents* stay protected by per-dir perms, but their *existence* leaks. The ACL grants execute-only — arrstack can pass through but can't enumerate. Closer match for "the sandbox identity should not see things outside its bind mounts."

**Verify:**

```bash
getfacl /mnt/arr1 | grep -E "^(# file|user|mask)"
sudo -iu arrstack ls "$ARR1_ROOT"          # should succeed
sudo -iu arrstack ls /mnt/arr1 2>&1        # should fail: Permission denied
```

Both checks must behave as commented above. The `ls` of `mediaServer/` works (arrstack owns it). The `ls` of the drive root fails (arrstack has only execute, not read, via the ACL).

---

## 6. Install the Docker packages

```bash
sudo pacman -Sy
sudo pacman -S --needed docker docker-buildx docker-compose passt fuse-overlayfs slirp4netns
yay -S docker-rootless-extras    # or paru / your preferred AUR helper
```

> **Why so many packages:**
> - `docker` (Arch official) — the rootful daemon and CLI. We'll keep this enabled for any other docker work, but the arrStack will not use it.
> - `docker-buildx` and `docker-compose` — modern docker plugins.
> - `passt` — provides the `pasta` binary (used in the next section for source-IP-preserving rootless networking).
> - `fuse-overlayfs` — storage driver rootless Docker uses on most filesystems.
> - `slirp4netns` — fallback network driver. We won't use it (we're switching to pasta), but the package needs to be present.
> - **`docker-rootless-extras` (AUR)** — *required*. Arch's official `docker` package does not bundle the rootless tooling. There's no separate official package; AUR is canonical. The AUR package ships `dockerd-rootless.sh`, the systemd user unit at `/usr/lib/systemd/user/docker.service`, the socket unit, and a sysctl drop-in for `kernel.unprivileged_userns_clone=1`.

> **Note on `dockerd-rootless-setuptool.sh`:** the AUR package does **not** ship the upstream "setuptool" install script. You don't need it — the package pre-installs the systemd user unit, which is the only thing the setuptool would have set up. Skipping the setuptool entirely simplifies the next section.

Enable the rootful daemon for any non-arrStack work you might do (your call — skip if you don't use docker outside the arrStack):

```bash
sudo systemctl enable --now docker
```

> **Note:** by default your personal user can't talk to the rootful daemon — that requires being in the `docker` group, which we explicitly *don't* recommend (it's effectively root). Use `sudo docker ...` for the rootful daemon. The arrStack runs entirely under the rootless daemon and doesn't need this.

**Verify:**

```bash
which dockerd-rootless.sh
which pasta
ls /usr/lib/systemd/user/docker.service
sysctl kernel.unprivileged_userns_clone
```

Should print `/usr/bin/dockerd-rootless.sh`, `/usr/bin/pasta`, the unit-file path, and `kernel.unprivileged_userns_clone = 1`. If the sysctl reads `0`, run `sudo sysctl --system` to apply the package's drop-in (no reboot needed).

---

## 7. Configure arrstack's environment for rootless Docker

Two profile files: `~/.profile` for the env vars, `~/.bash_profile` to ensure bash sources it on login.

```bash
sudo -u arrstack tee /home/arrstack/.bash_profile > /dev/null <<'EOF'
# Source .profile in login shells (sudo -i, su -, ssh)
[ -r ~/.profile ] && . ~/.profile
EOF

sudo -u arrstack tee /home/arrstack/.profile > /dev/null <<'EOF'
export PATH=/usr/bin:$PATH
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
export XDG_RUNTIME_DIR=/run/user/$(id -u)
EOF
```

> **Why both files:** bash's login-shell rules read the first of `~/.bash_profile`, `~/.bash_login`, `~/.profile` that exists. If `~/.bash_profile` exists but doesn't source `~/.profile`, the env vars never get set. Writing both — with `.bash_profile` sourcing `.profile` — is the portable way to ensure `sudo -i arrstack` picks up the env reliably.

---

## 8. Configure rootless networking (pasta) and mount-dependency

Drop a systemd-user override for arrstack's docker.service:

```bash
sudo -u arrstack mkdir -p /home/arrstack/.config/systemd/user/docker.service.d
sudo -u arrstack tee /home/arrstack/.config/systemd/user/docker.service.d/override.conf > /dev/null <<'EOF'
[Unit]
RequiresMountsFor=/mnt/arr1 /mnt/arr2

[Service]
Environment="DOCKERD_ROOTLESS_ROOTLESSKIT_NET=pasta"
Environment="DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=implicit"
EOF
```

> **Why `RequiresMountsFor`:** if either data drive fails to mount at boot, the docker daemon waits in `inactive` state rather than starting and crash-looping every container with permission errors. Cleaner than letting it start, fail, and restart in a loop.

> **Why `pasta` for the network driver:** the default `slirp4netns` driver masquerades source IPs through the bridge gateway. Plex's "LAN Networks" detection — which decides whether a LAN client gets local-quality direct play vs. throttled remote-streaming quality — relies on seeing the *real* client IP. With slirp4netns, every LAN client looks remote. With pasta, source IPs are preserved end-to-end and Plex correctly classifies the connection.

> **Why `PORT_DRIVER=implicit`:** pasta is incompatible with `builtin` (the default) and rootlesskit refuses to start with `network "pasta" requires port driver "none" or "implicit"`. The `implicit` driver lets pasta handle port forwarding transparently — also the path that completes the source-IP-preservation chain.

> **Note:** rootlesskit logs `"pasta" network driver is experimental` at startup. In practice it's stable for the workloads here (Plex, *arr UIs, Transmission); the warning is upstream's caution about API churn rather than runtime reliability.

---

## 9. Enable and start arrstack's rootless Docker

```bash
sudo systemctl --user --machine=arrstack@.host enable --now docker.service
sudo systemctl --user --machine=arrstack@.host status docker --no-pager | head -15
```

> **Why `--machine=arrstack@.host` instead of `sudo -iu arrstack systemctl --user`:** the latter typically fails on bus-discovery (`Failed to connect to user scope bus via local transport: $DBUS_SESSION_BUS_ADDRESS not defined`) because sudo's `-i` doesn't reliably set up the user's DBUS environment for one-shot commands. The `--machine` form routes through systemd-machined and finds the user's bus regardless of the calling shell. **Use it for any administrative `systemctl --user` operations against arrstack.** Interactive use (entering an arrstack shell, debugging) still works fine via `sudo -iu arrstack`.

The status block should show `Active: active (running)`. The cgroup tree should include a rootlesskit process whose args contain `--net=pasta` and `--port-driver=implicit`, plus a child `pasta` process. If you see `--net=slirp4netns` instead, the override env vars didn't take effect — re-check the override file, then `daemon-reload` and `restart`.

**Verify:**

```bash
sudo -iu arrstack docker run --rm hello-world
sudo -iu arrstack docker ps
```

`hello-world` prints the standard greeting (after pulling the image). `docker ps` lists no containers — clean state. Confirms the daemon is reachable, env vars are flowing through, and image pulls work.

---

## 10. Set up the repo and the deploy workflow

This tutorial uses a **two-location** layout:

- **Source-of-truth (your home)**: where you edit and version-control. Example: `~/code/arrStack/`.
- **Runtime (`/srv/arrstack/stack/`)**: where the rootless daemon actually reads from. Owned by arrstack, gitignored from your perspective.

A small `deploy.sh` script syncs source → runtime. The `.env` lives only in the runtime location and never gets committed.

> **Why two locations:** the runtime location needs to be readable by `arrstack`, but `/home/<you>/` is typically `0700` and not traversable by other users. You could grant arrstack ACL traversal into your home, but then arrstack's threat-model footprint widens. Two locations + sync keeps the boundary clean while preserving your normal editing workflow (no `cd /srv/...`, no `sudo $EDITOR`).

### 10a. Create the repo

```bash
mkdir -p ~/code/arrStack/scripts
cd ~/code/arrStack
```

Write `~/code/arrStack/docker-compose.yaml`:

```yaml
# arrStack — rootless Docker sandbox
#
# IMPORTANT (PUID/PGID convention):
# Under rootless Docker, container UID 0 maps to the host `arrstack` user via
# the userns mapping. We set PUID=0 / PGID=0 (or `user: "0:0"` / PLEX_UID=0)
# in every service so that files written into bind mounts come out owned by
# `arrstack:arrstack` on the host. This *inverts* the usual lscr.io
# convention of PUID=1000 — do not change without understanding the userns
# implications.

networks:
  arrstack_network:
    external: false

services:
  transmission:
    image: lscr.io/linuxserver/transmission:latest
    container_name: transmission
    environment:
      - PUID=0
      - PGID=0
      - TZ=${TZ}
    volumes:
      - ${ARR1_ROOT}/config/transmission:/config
      - ${ARR1_ROOT}/downloads:/downloads
    networks:
      - arrstack_network
    ports:
      - ${TRANSMISSION_PORT}:9091
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=0
      - PGID=0
      - TZ=${TZ}
    volumes:
      - ${ARR1_ROOT}/config/radarr:/config
      - ${ARR1_ROOT}/media/movies:/movies
      - ${ARR1_ROOT}/media/movies_4k:/movies_4k
      - ${ARR2_ROOT}/media/movies:/movies2
      - ${ARR1_ROOT}/downloads:/downloads
    networks:
      - arrstack_network
    ports:
      - ${RADARR_PORT}:7878
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=0
      - PGID=0
      - TZ=${TZ}
    volumes:
      - ${ARR1_ROOT}/config/sonarr:/config
      - ${ARR1_ROOT}/media/series:/series
      - ${ARR1_ROOT}/downloads:/downloads
    networks:
      - arrstack_network
    ports:
      - ${SONARR_PORT}:8989
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    environment:
      - PUID=0
      - PGID=0
      - TZ=${TZ}
    volumes:
      - ${ARR1_ROOT}/config/bazarr:/config
      - ${ARR1_ROOT}/media:/media
      - ${ARR2_ROOT}/media:/media2
    networks:
      - arrstack_network
    ports:
      - ${BAZARR_PORT}:6767
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment:
      - PUID=0
      - PGID=0
      - TZ=${TZ}
    volumes:
      - ${ARR1_ROOT}/config/prowlarr:/config
    networks:
      - arrstack_network
    ports:
      - ${PROWLARR_PORT}:9696
    restart: unless-stopped

  seerr:
    image: ghcr.io/seerr-team/seerr:latest
    init: true
    container_name: seerr
    user: "0:0"
    environment:
      - LOG_LEVEL=debug
      - TZ=${TZ}
    volumes:
      - ${ARR1_ROOT}/config/seerr:/app/config
    networks:
      - arrstack_network
    ports:
      - ${SEERR_PORT}:5055
    healthcheck:
      test: wget --no-verbose --tries=1 --spider http://localhost:5055/api/v1/status || exit 1
      start_period: 20s
      timeout: 3s
      interval: 15s
      retries: 3
    restart: unless-stopped

  plex:
    image: plexinc/pms-docker
    container_name: plex
    environment:
      - TZ=${TZ}
      - PLEX_UID=0
      - PLEX_GID=0
    volumes:
      - ${ARR1_ROOT}/config/plex:/config
      - ${ARR1_ROOT}/config/plex-transcode:/transcode
      - ${ARR1_ROOT}/media:/media
      - ${ARR2_ROOT}/media/movies:/movies2
    networks:
      - arrstack_network
    ports:
      - 32400:32400/tcp     # Plex Web / API (required)
      - 3005:3005/tcp       # Plex Companion (legacy)
      - 8324:8324/tcp       # Plex for Roku (legacy)
      - 32469:32469/tcp     # DLNA server (kept for completeness)
      - 32410:32410/udp     # Plex GDM discovery
      - 32412:32412/udp
      - 32413:32413/udp
      - 32414:32414/udp
      # 1900/udp (DLNA SSDP) intentionally NOT bound — Spotify's desktop
      # client and many other LAN apps hold this port. Plex's DLNA feature
      # is rarely used; your LAN clients (Shield, Plex apps) discover Plex
      # via the GDM protocol on 32410-32414/udp anyway.
    restart: unless-stopped

  tautulli:
    image: lscr.io/linuxserver/tautulli:latest
    container_name: tautulli
    environment:
      - PUID=0
      - PGID=0
      - TZ=${TZ}
    volumes:
      - ${ARR1_ROOT}/config/tautulli:/config
    networks:
      - arrstack_network
    ports:
      - ${TAUTULLI_PORT}:8181
    restart: unless-stopped

  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    environment:
      - HOMEPAGE_ALLOWED_HOSTS=*
      - PUID=0
      - PGID=0
      - TZ=${TZ}
    volumes:
      - ${ARR1_ROOT}/config/homepage:/app/config
    networks:
      - arrstack_network
    ports:
      - ${HOMEPAGE_PORT}:3000
    restart: unless-stopped

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    environment:
      - LOG_LEVEL=info
      - TZ=${TZ}
    networks:
      - arrstack_network
    ports:
      - ${FLARESOLVERR_PORT}:8191
    restart: unless-stopped
```

Write `~/code/arrStack/env.example`:

```dotenv
# arrStack environment
# Copy this to /srv/arrstack/stack/.env and fill in values for your host.

ARR1_ROOT=/mnt/arr1/mediaServer
ARR2_ROOT=/mnt/arr2/mediaServer

# Timezone — see /usr/share/zoneinfo/, e.g. Europe/Dublin, America/New_York
TZ=UTC

# Ports — host side
RADARR_PORT=7878
SONARR_PORT=8989
BAZARR_PORT=6767
PROWLARR_PORT=9696
SEERR_PORT=5055
TRANSMISSION_PORT=9091
TAUTULLI_PORT=8181
HOMEPAGE_PORT=3000
FLARESOLVERR_PORT=8191
```

Write `~/code/arrStack/.gitignore`:

```
.env
```

### 10b. Write the deploy script

Save as `~/code/arrStack/scripts/deploy.sh`:

```bash
#!/usr/bin/env bash
#
# deploy.sh — Sync repo's compose + env.example to /srv/arrstack/stack/
#
# Bootstraps the runtime location on first run; idempotent on subsequent runs.
# Never touches .env in the runtime location.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR=/srv/arrstack/stack
COMPOSE_SRC="$REPO_DIR/docker-compose.yaml"
ENVEX_SRC="$REPO_DIR/env.example"

[ -f "$COMPOSE_SRC" ] || { echo "ERROR: $COMPOSE_SRC not found" >&2; exit 1; }
[ -f "$ENVEX_SRC" ]   || { echo "ERROR: $ENVEX_SRC not found"   >&2; exit 1; }

if [ ! -d "$DEPLOY_DIR" ]; then
  echo "==> Bootstrapping $DEPLOY_DIR (first deploy)"
  sudo mkdir -p "$DEPLOY_DIR"
  sudo chown arrstack:arrstack /srv/arrstack "$DEPLOY_DIR"
  sudo chmod 2775 /srv/arrstack "$DEPLOY_DIR"
else
  echo "==> $DEPLOY_DIR exists; syncing"
fi

echo "==> Syncing docker-compose.yaml + env.example"
sudo rsync -a --chown=arrstack:arrstack \
  "$COMPOSE_SRC" "$ENVEX_SRC" \
  "$DEPLOY_DIR/"

echo
ls -la "$DEPLOY_DIR"
echo

if [ -f "$DEPLOY_DIR/.env" ]; then
  if sudo -u arrstack docker compose \
        -f "$DEPLOY_DIR/docker-compose.yaml" \
        --env-file "$DEPLOY_DIR/.env" \
        config >/dev/null 2>&1; then
    echo "compose parse: OK"
  else
    echo "compose parse: FAILED — run:"
    echo "  sudo -u arrstack docker compose -f $DEPLOY_DIR/docker-compose.yaml --env-file $DEPLOY_DIR/.env config"
  fi
else
  echo ".env: MISSING — create it before bringing up the stack:"
  echo "  sudo cp $DEPLOY_DIR/env.example $DEPLOY_DIR/.env"
  echo "  sudo chown arrstack:arrstack $DEPLOY_DIR/.env"
  echo "  sudo chmod 0640 $DEPLOY_DIR/.env"
  echo "  sudo \$EDITOR $DEPLOY_DIR/.env"
fi
```

### 10c. Run the first deploy

```bash
bash ~/code/arrStack/scripts/deploy.sh
```

The first run bootstraps `/srv/arrstack/stack/` (owned `arrstack:arrstack` mode `2775`), syncs the compose + env.example, and reports `.env: MISSING`.

Create the runtime `.env`:

```bash
sudo cp /srv/arrstack/stack/env.example /srv/arrstack/stack/.env
sudo chown arrstack:arrstack /srv/arrstack/stack/.env
sudo chmod 0640 /srv/arrstack/stack/.env
sudo $EDITOR /srv/arrstack/stack/.env
```

In your editor, set `TZ` to your zone (`timedatectl | grep "Time zone"` if unsure). The other defaults are sensible; only change ports if they collide with something else on the host.

Re-run:

```bash
bash ~/code/arrStack/scripts/deploy.sh
```

Should now report `compose parse: OK`.

---

## 11. First boot

```bash
sudo -iu arrstack docker compose -f /srv/arrstack/stack/docker-compose.yaml pull
sudo -iu arrstack docker compose -f /srv/arrstack/stack/docker-compose.yaml up -d
sudo -iu arrstack docker compose -f /srv/arrstack/stack/docker-compose.yaml ps
```

Image pulls take a few minutes; Plex's image is the slowest. After `up -d`, `ps` should list 10 containers all `running`. Seerr, Plex, and Homepage will additionally show `(healthy)` once their healthchecks pass (~30s).

**Verify**:

```bash
sudo -iu arrstack docker compose -f /srv/arrstack/stack/docker-compose.yaml logs --tail=20 2>&1 | grep -iE "error|fail" | head
```

Expected: nothing of significance. If you see lines about missing/inaccessible bind-mount paths, recheck Section 4 (paths) and Section 5 (ACL traversal).

> **Gotcha — `address already in use` on Plex:** if you have something else on the host bound to a port Plex wants (most common: Spotify's desktop client holds UDP/1900 for Spotify Connect), Plex fails with `failed to bind host port`. The compose above already avoids 1900 (we don't bind it). If a different port collides, edit the Plex `ports` block and remove or remap the offending entry, then `docker compose up -d`.

---

## 12. Configure Plex for LAN direct-play

Open `http://localhost:32400/web` (or substitute your host IP). Step through Plex's first-run wizard, sign in, name the server.

Add libraries:

- **Movies**: add `/movies`. Optionally `/movies_4k` as a separate library or `/movies2` to merge drive 2's content into the same library.
- **TV Shows**: add `/series`.

Once libraries scan, configure the network settings — these are what make pasta source-IP preservation pay off:

- **Settings → Server → Network → LAN Networks**: enter your LAN subnet (e.g. `192.168.1.0/24`).
- **Settings → Server → Network → Custom server access URLs**: `http://<your-host-ip>:32400` (use your machine's static LAN IP, not `localhost`).

Save.

> **Why this matters:** without `LAN Networks` set, Plex defaults to "if not bound to host networking, treat all clients as remote" — even if pasta correctly preserves the source IP. With both pasta + LAN Networks configured, Plex sees the real client IP, matches it against your subnet, classifies it as local, and serves at full LAN quality.

---

## 13. Verify the design end-to-end

This is the canonical validation step. The full chain works if and only if Plex sees a LAN client's real IP through the rootless+pasta stack.

From any LAN client (Nvidia Shield, Plex iOS app on the same WiFi, etc.) signed into the same Plex account, start playing any media file.

While it's playing, browse to **Plex Web → Settings → Status → Now Playing**. Look at the client's **address** in the session row.

- **`192.168.x.x` (or whatever your LAN subnet is)** — pasta is preserving source IPs, design validated.
- **`172.x.x.x` or `10.x.x.x`** — pasta isn't working as expected; the daemon may have fallen back to slirp4netns. Recheck the rootlesskit cgroup line:
  ```bash
  sudo systemctl --user --machine=arrstack@.host status docker --no-pager | grep -E "rootlesskit|--net"
  ```
  Must show `--net=pasta --port-driver=implicit`.

If that's wrong, your override.conf didn't take effect or the env names changed in a newer rootlesskit. Re-check Section 8.

---

## 14. Operational ergonomics

Add aliases to your shell rc (`~/.zshrc` or `~/.bashrc`):

```bash
{
  echo ""
  echo "# arrStack: inspect rootless docker as the arrstack user"
  echo "alias lazyarr='sudo -iu arrstack lazydocker'"
  echo "alias arrcompose='sudo -iu arrstack docker compose -f /srv/arrstack/stack/docker-compose.yaml'"
} >> ~/.zshrc

source ~/.zshrc
```

Now:

- `lazyarr` — opens `lazydocker` connected to arrstack's rootless daemon (your existing `lazydocker` for any other docker work continues to work as today).
- `arrcompose ps`, `arrcompose logs -f radarr`, `arrcompose restart plex` — saves typing the full `-f` path.

---

## 15. Final verification checklist

Run these as a sanity sweep:

```bash
# arrstack runs as a real, non-root host user
sudo -iu arrstack id

# Containers run rootless and isolated
sudo -iu arrstack docker ps

# Files written by containers come out owned by arrstack:arrstack
sudo -iu arrstack docker exec radarr touch /config/.tutorial-test
ls -la /mnt/arr1/mediaServer/config/radarr/.tutorial-test
sudo -iu arrstack docker exec radarr rm /config/.tutorial-test

# Sandbox can't ls outside its bind mounts
sudo -iu arrstack docker exec radarr ls /mnt 2>&1 || true     # /mnt empty / absent
sudo -iu arrstack docker exec radarr ls /home 2>&1 || true    # /home empty / absent

# Even --privileged in rootless can't read host root files
sudo -iu arrstack docker run --rm --privileged -v /:/host alpine sh -c "cat /host/etc/shadow 2>&1 | head -1"
# Expected: cat: can't open '/host/etc/shadow': Permission denied

# ACL on drive root grants arrstack only traverse, not read
sudo -iu arrstack ls /mnt/arr1 2>&1 || echo "OK: arrstack cannot ls drive root"
```

If all of those behave as commented, the sandbox is in shape.

---

## Phase 2 (deferred, intentionally not covered here)

The following are out of scope for this tutorial. Each is doable but introduces its own design trade-offs:

- **Cloudflare Tunnel for *arr admin UIs / Seerr**: straightforward addition. Add a `cloudflared` service to the compose, set `CF_TOKEN` in `.env`, configure your tunnel's public hostnames to forward to `http://radarr:7878` etc. **Do NOT tunnel Plex via the free Cloudflare plan** — Cloudflare's TOS § 2.8 prohibits proxying video, and tunnels regularly get terminated for streaming.
- **Plex remote access**: separate path from the *arr UIs. Options include Plex's own remote access (NAT-PMP / port-forward), Tailscale, ZeroTier, or paid CF plans. Each has its own trade-offs around latency, NAT, mobile-data behaviour, and authentication. Decide based on your needs.
- **Jellyfin with GPU passthrough**: rootless Docker can pass through `/dev/dri` devices, but the `arrstack` user needs membership in the host's `render` and `video` groups. Add the Jellyfin service to the compose with `group_add` + `devices` blocks once you've confirmed your hardware path.
- **Homepage configuration**: dashboard YAML at `/mnt/arr1/mediaServer/config/homepage/services.yaml`. Use service names (`radarr`, `sonarr`, etc.) as hostnames in widget configs — they survive any future host IP changes.

---

## Troubleshooting cheat sheet

| Symptom | Likely cause | Fix |
|---|---|---|
| `sudo -iu arrstack systemctl --user ...` fails with bus errors | `-i` doesn't reliably set DBUS env | Use `sudo systemctl --user --machine=arrstack@.host ...` |
| `mount -a` shows drive RO with `WARNING: source write-protected` | Drive already mounted elsewhere with `-o ro` | `umount` the stray mount, retry |
| Container fails with `permission denied` on bind mount | `arrstack` doesn't own the path / can't traverse | `chown -R arrstack:arrstack <path>`; `setfacl -m u:arrstack:x` on parent |
| `docker compose up` errors with `address already in use` on UDP/1900 | Another LAN app (Spotify, KDE, etc.) holds SSDP | Drop `1900:1900/udp` from Plex's port list |
| `docker.service` won't start: `network "pasta" requires port driver "none" or "implicit"` | Wrong `PORT_DRIVER` value | Set `DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=implicit` |
| `arrstack` group membership not visible in current shell | New group memberships only apply to new sessions | `newgrp arrstack` in current shell, or log out and back in |
| Plex shows clients with bridge gateway IPs (172.x or 10.x) | pasta not engaged | Re-check `override.conf`; verify rootlesskit args contain `--net=pasta` |
| `docker-rootless-extras` doesn't exist via `pacman` | It's only in AUR on Arch | `yay -S docker-rootless-extras` |
| `dockerd-rootless-setuptool.sh: command not found` | AUR package doesn't ship it | You don't need it — the systemd user unit is pre-installed |

---

## What you have now

A media stack confined to a dedicated host user, with an explicit traversal-only ACL on the drive roots, automatic source-IP preservation through the bridge network, a clean edit-and-deploy workflow, and a verified validation point (Plex Now Playing showing real LAN IPs). A container compromise lands inside a non-privileged user namespace with access only to its declared bind mounts — your home, other Docker workloads, and host-level files all remain off-limits.

For deeper context on individual decisions and trade-offs, see `docs/decisions.md`. For the migration path from an existing arr stack, see `docs/superpowers/plans/2026-04-28-arrstack-sandbox.md`.
