# arrStack Sandbox — Decisions Log

Append-only record of design choices and gotchas encountered during the rebuild.
Each entry has the *what* (decision), *why* (rationale), and any *alternative considered*.
Feeds the eventual `tutorial.md` "why" callouts.

---

## 2026-04-28 — Runtime: rootless Docker

**Decision:** Run the arrStack under a dedicated `arrstack` system user via rootless Docker, not the personal user's rootful Docker daemon.

**Why:** Threat model is "any container compromise must not be able to read/write/access anything outside the explicitly bind-mounted paths." With rootful Docker, a container escape lands at host root. With rootless, container UID 0 maps to the unprivileged `arrstack` user — a successful escape lands in arrstack's confined filesystem view, not on the real host.

**Alternatives considered:**
- *Docker group + same daemon as dev work* — rejected; docker-group membership is effectively root and the personal user already has it.
- *Podman rootless* — viable, but requires rewriting compose semantics or adopting quadlets; switching cost outweighs the marginal isolation gain over rootless Docker.
- *Docker with userns-remap* — daemon still root, weaker isolation; bind-mount UID mapping is awkward.

---

## 2026-04-28 — Networking: pasta for source-IP preservation

**Decision:** Configure rootlesskit to use `pasta` (from the `passt` Arch package) as the network driver. Plex stays on Docker's default bridge network with port mapping; we drop the previously-planned `network_mode: host` migration.

**Why:** Plex's "LAN Networks" detection (which decides whether the Nvidia Shield gets local-quality direct play vs remote-throttled) needs to see the client's *real* LAN IP. Rootless Docker's default `slirp4netns` driver masquerades source IPs to the bridge gateway — Plex would see all clients as "remote." `pasta` preserves source IPs end-to-end, so bridge networking + LAN-Networks subnet config achieves the same outcome as host networking would, while keeping the rootless privilege isolation intact.

**Alternative considered:** `network_mode: host` for Plex — rejected because it doesn't compose well with rootless (the "host" namespace is the user's, not the real host's) and pasta achieves the goal without it.

---

## 2026-04-28 — PUID/PGID = 0 in rootless containers

**Decision:** Set `PUID=0`/`PGID=0` (or `user: "0:0"`) for every service in the compose, inverting the typical lscr.io convention of `PUID=1000`.

**Why:** Under rootless Docker's userns mapping, container UID 0 maps to the host's `arrstack` user. Files written into bind mounts come out owned by `arrstack:arrstack` on the host — easy to read/manage. If we used PUID=1000, container UID 1000 would map to a host subuid like `100999`, and bind-mounted files would have an unmapped numeric owner from the host's perspective, awkward to work with.

---

## 2026-04-28 — Cloudflared deferred to Phase 2; Plex over CF Tunnel rejected

**Decision:** Phase 1 ships without Cloudflare Tunnel. When CF Tunnel comes back in Phase 2, it tunnels only the *arr admin UIs / Seerr — *not* Plex.

**Why:** Cloudflare's free TOS § 2.8 prohibits proxying non-HTML content, specifically video. Tunnels routinely get terminated for streaming Plex/Jellyfin. Seerr / Radarr / Sonarr are admin UIs / APIs — within TOS, fine to tunnel. Plex remote access goes through a different path (Plex Relay, Tailscale, or paid CF) — to be decided in Phase 2.

---

## 2026-04-28 — Drop `/imports` from compose

**Decision:** The new compose does not bind-mount `${IMPORTS}` into Radarr/Sonarr.

**Why:** User wanted simplification; the existing `/imports` directory was a legacy convenience that adds another path-mapping concern. Trade-off: any Radarr/Sonarr queue items that pointed at `/imports/...` at cutover will fail to import — drain or relocate them before stopping the old stack.

---

## 2026-04-28 — Subdir name on each drive: `mediaServer/`, not `arrstack/`

**Decision:** Both drives use `mediaServer/` as the per-drive arr-content subdir. The spec originally proposed `arrstack/` as a placeholder name.

**Why:** Drive 1 already had its content under `mediaServer/` from the user's previous setup. Renaming would require editing the SQLite-stored paths in every app's DB. Keeping the existing name means zero DB surgery — the migration is in-place chown.

**For drive 2:** the old (stale 2023) `mediaServer/` was renamed to `mediaServer.archive-2023/`, then a fresh empty `mediaServer/` was created to match the convention. This way both drives use the same name.

---

## 2026-04-28 — Drive 2 starts as a clean slate

**Decision:** Drive 2 has no migrated arr content; only the new `/movies2` Radarr root will populate it from new acquisitions.

**Why:** On inspection, drive 2 had no current arr media — only stale 2023 configs and unrelated personal content. The user's earlier framing of "drive 2 has a second movies dir" was an artefact of a prior plan that didn't materialise. Treating drive 2 as a clean slate avoids fabricating a phantom migration.

**Side benefit:** drive 1 is at 96% capacity, so directing new movies to drive 2 immediately offloads growth.

---

## 2026-04-28 — Tautulli config dir keeps the `tatulli` typo

**Decision:** Host directory remains `mediaServer/config/tatulli/` (with the typo). Container-side path is `/config` (correct).

**Why:** The existing typo is in the host filesystem only — the container sees `/config` regardless of what the host dir is called. Renaming the host dir would break nothing functional but adds risk for no gain. Documented in the compose with a comment.

---

## 2026-04-28 — `arrstack` shell: `/bin/bash`, not `/usr/sbin/nologin`

**Decision:** The system user `arrstack` has `/bin/bash` as its login shell.

**Why:** `sudo -iu arrstack <cmd>` insists on running an interactive *login* shell that sources `~/.profile` (where we set `DOCKER_HOST` etc.). With `nologin`, that exits immediately with "This account is currently not available." Switching to `/bin/bash` was the simplest fix. Security gain from `nologin` is zero in this configuration: arrstack has no password and no SSH key, so login attempts fail regardless of the shell.

---

## 2026-04-28 — Drive root traversal: POSIX ACL, not chgrp

**Decision:** Grant arrstack execute-only (traverse) access to `/mnt/arr1` and `/mnt/arr2` via POSIX ACL (`setfacl -m u:arrstack:x /mnt/arrN`), not via chgrp + chmod 0750.

**Why:** The drive filesystem roots are mode `0700` owned by eduardo (used for personal storage outside arr). Without traversal, the rootless docker daemon can't reach `/mnt/arrN/mediaServer/...` to set up bind mounts. Two fixes:
- *ACL (chosen):* arrstack gets execute-only on the drive root — can pass through but cannot `ls` and discover what else is on the drive. Personal dirs at top level stay visually private from the arrstack identity. Survives reboots on ext4.
- *chgrp arrstack + chmod 0750:* simpler but slightly leaky — arrstack can `ls` the drive root and see the names of personal dirs (e.g. `SteamLibrary`, `Documents`). Their contents stay protected by per-dir 0700 perms, but their *existence* is visible.

ACL costs nothing extra and matches the "only the bind-mount subtrees are visible to arrstack" principle.

---

## 2026-04-28 — Arch packaging: AUR `docker-rootless-extras` is required

**Decision:** Install `docker-rootless-extras` from AUR (e.g. `yay -S docker-rootless-extras`) in addition to the official `docker` package.

**Why:** On Arch (as of `docker` 29.4.1), the official package does **not** bundle the rootless tooling — `pacman -Ql docker | grep rootless` returns empty. There is no separate official package. The AUR package fills the gap by shipping `dockerd-rootless.sh`, the systemd user unit at `/usr/lib/systemd/user/docker.service`, the socket unit, and the sysctl drop-in.

**Notable nuance:** the AUR package does **not** ship `dockerd-rootless-setuptool.sh` (the upstream "install" helper). It doesn't need to — its only job (drop a systemd user unit into place) is already done by the package. The plan's Task 7 enables+starts the pre-installed unit directly via `systemctl --user`, with no setuptool indirection.

---

## 2026-04-28 — Subuid/subgid not auto-allocated by Arch's `useradd`

**Gotcha:** On Arch, `useradd` does not auto-populate `/etc/subuid` and `/etc/subgid` for new system users (default `SUB_UID_COUNT=0`). The range must be allocated manually:

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 arrstack
```

Without this, rootless Docker has no userns range to map container UIDs into and fails on first run. Catch it before starting the daemon, not after.

---

## 2026-04-28 — fstab + UDisks/auto-mount: don't run mount -a while the drive is mounted elsewhere

**Gotcha:** During inspection we mounted drive 2 read-only at `/mnt/inspect`. Forgot to unmount it before running `sudo mount -a`. The kernel ended up "sharing" the existing RO mount instead of opening a fresh RW one at `/mnt/arr2` — and `mount -a` printed `WARNING: source write-protected, mounted read-only`.

**Resolution:** unmount the stray inspect mount, retry mount -a. Worth flagging in the tutorial: any `-o ro` inspection mount should be removed before the persistent fstab mount comes up.

---

## 2026-04-28 — eduardo not in `docker` group (intentional)

**Decision:** Don't add eduardo to the rootful `docker` group. Use `sudo docker ...` for the rootful daemon when needed.

**Why:** Docker-group membership grants effective root (any user in the group can mount `/` into a container as root). That's exactly what we're trying to sandbox away from. Forcing `sudo` for every rootful command is friction by design — when `sudo` feels annoying, it's a reminder to consider whether the work belongs in arrstack's rootless stack instead.

---

## 2026-04-29 — Group membership only takes effect in new shells

**Gotcha:** After `sudo usermod -aG arrstack eduardo`, the *currently running* eduardo shell does NOT see the new group. Only new shells (or `newgrp arrstack` in the current shell) pick up the membership. Verification commands that rely on eduardo's group membership being effective will fail until a re-login.

**Where it bit us:** Task 6's verification step had `ls -la /mnt/arr1/mediaServer/config` running as eduardo. After chown to `arrstack:arrstack` mode `0750`, eduardo needed to be in group `arrstack` to read it. Their current shell wasn't, so the ls returned permission denied and `set -e` killed the rest of the script.

**Resolution:** Use `sudo -iu arrstack ls ...` in verification steps — that gives the runtime view (what the daemon will see) and doesn't depend on eduardo's group cache. Patched in `scripts/reorganize-drives.sh`.

**For the tutorial:** mention prominently that `usermod -aG` requires a new login to take effect, OR run `newgrp arrstack` in the current shell, OR use `sudo -iu arrstack` for any access checks before a re-login.

---

## 2026-04-29 — Use `systemctl --machine=arrstack@.host` for user units

**Decision:** Issue user-systemd commands for arrstack via `sudo systemctl --user --machine=arrstack@.host ...` rather than `sudo -iu arrstack systemctl --user ...`.

**Why:** `sudo -iu arrstack systemctl --user ...` failed with `Failed to connect to user scope bus via local transport: $DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined`. Even though `~/.profile` exports `XDG_RUNTIME_DIR`, sudo's `-i` doesn't always source profile reliably for one-shot commands, and the bus address isn't set by profile alone.

The `--machine=arrstack@.host` form routes through systemd-machined, which knows how to find the user's bus regardless of the calling shell's env. It works even from a totally bare `sudo` context.

**For the tutorial:** prefer `--machine` for any administrative `systemctl --user` operations against arrstack. For interactive use (the `lazyarr` workflow, debugging, etc.), `sudo -iu arrstack` followed by an interactive shell still works because the login shell does source profile.

---

## 2026-04-30 — UFW host firewall added (defense in depth; should have been Phase 1)

**Decision:** Activate UFW on the host with default-deny inbound, scoped allow rules per service. arrStack web UIs (Radarr, Sonarr, Bazarr, Prowlarr, Seerr, Transmission, Tautulli, Homepage, Flaresolverr) and Plex's web/companion ports allowed only from the LAN subnet `192.168.1.0/24`. Caddy's public port 8443 (TCP+UDP) allowed from anywhere — that's the public path.

**Why this is a real-but-small gain:** the rootless-Docker sandbox confines container compromise. UFW addresses a different layer — it stops *non-containerized* host processes from accidentally exposing a port on the LAN, and lets us scope the *arr UIs to LAN-only so they're not reachable from the public internet even if an external probe happens to hit our IP. Catches mistakes that the container sandbox wouldn't.

**Why it wasn't on from the start:** the original Phase 1 spec implicitly assumed the LAN was trusted and focused entirely on container escape paths. UFW is a complementary layer rather than a redesign — adding it as a follow-on hardening step has zero cost as long as the rule set matches what the stack actually exposes.

**Operational caveats:**
- *Order matters during enable*: queue all `ufw allow` rules first, *then* `ufw enable`. Otherwise you can lock out an active SSH session.
- *Rootful Docker bypasses UFW* (well-known iptables-FORWARD-chain ordering issue). Doesn't affect arrStack (rootless via pasta — UFW INPUT rules apply normally), but if rootful dev containers are ever exposed to the LAN, UFW won't filter them. Workaround if needed: rules in the `DOCKER-USER` chain.
- *LAN scope*: all arrStack UI rules use `from 192.168.1.0/24`. If the LAN subnet changes, the rules need updating.

**For the tutorial:** Section 16 covers full setup. Sequenced after Phase 1 verification (so the stack is known-working before firewall introduces a new variable) and before Section 17 (Caddy public HTTPS) so the firewall section doesn't need post-hoc updates when 8443 enters the picture.

---

## 2026-04-30 — Plex "Enable Remote Access" disabled; mobile app behavior validated the choice

**Decision:** Plex's "Enable Remote Access" stays **OFF** (matching the original spec). User had it briefly on during troubleshooting; turning it off resolved a "Decoder: init failed" error on the mobile Plex app.

**What likely happened:** with Remote Access ON, Plex publishes multiple connection paths to plex.tv: (a) Plex's own attempt at a directly-reachable WAN URL (which fails on this CGNAT-equivalent ISP setup but Plex doesn't know that), (b) Plex Relay, and (c) the Custom server access URLs (`plex.vasher.eu:8443`). The mobile app picked the failed direct path first, got partial/inconsistent responses, and threw a decoder error. Disabling Remote Access removed the failing path from advertisement; the app then used the Caddy URL cleanly.

**For the tutorial:** when running with the public URL going through a self-hosted reverse proxy (rather than Plex's native remote), **disable Plex's Enable Remote Access toggle**. Otherwise the mobile/desktop apps see conflicting connection options and may pick the broken one. The "Custom server access URLs" field is sufficient on its own for client discovery via plex.tv.

**Trade-off accepted:** no Plex Relay fallback. If a shared user can't reach `plex.vasher.eu:8443` directly, they can't stream remotely. Acceptable given the user's primary remote use is themselves; shared users either reach Caddy or wait for a different solution.

---

## 2026-04-30 — Static-IP gotcha: NetworkManager GUI requires a reconnect to apply

**Gotcha:** Setting a static IP via NetworkManager's GUI (the connection editor → IPv4 → Manual) does *not* immediately switch the active interface to the new IP. The change is saved to the connection profile but only takes effect on the next connect. If you don't `nmcli con down ... && nmcli con up ...` (or just toggle WiFi off/on), you keep using the old DHCP lease and the new "static" IP is purely theoretical.

**Where it bit us:** during Phase 2.1 troubleshooting, we spent ~30 minutes diagnosing why port 8443 was closed from outside despite Caddy running, the cert being valid, and router rules looking correct. Cause: the host was still on `192.168.1.8` (old DHCP lease), but the router's port-forwards target `192.168.1.88` (the intended static). External packets reached the router, got forwarded to `192.168.1.88`, and dropped — no host listening there. yougetsignal.com correctly reported "closed." Looked exactly like an ISP block.

**Resolution:** disconnect + reconnect WiFi (NM GUI → click connection name → toggle off/on, or `nmcli con down <name> && nmcli con up <name>`). Verify with `ip -4 addr show <iface> | grep inet` — should show the intended static IP.

**For the tutorial:** in the static-IP section, add an explicit "verify the IP actually changed" step right after the configuration step. The static IP doesn't take effect until reconnect; a forgotten reconnect breaks every downstream test for opaque reasons.

---

## 2026-04-29 — Switched to DNS-01 challenge (port 80 blocked from outside)

**Decision:** Phase 2.1 uses ACME **DNS-01** for cert issuance, not HTTP-01. Caddy is built from a custom Dockerfile that includes the `caddy-dns/cloudflare` plugin. Port 80 on the host stays free; no router rule needed for it.

**Why:** Inbound port 80 is blocked between the public internet and the host. Local `curl http://localhost/` works (after the `ip_unprivileged_port_start=80` sysctl fix), but external probes time out. Phone on cellular fails to reach `http://plex.vasher.eu`. Likely culprit is the ISP (Vodafone Ireland is known to block residential port 80) or the router's Medium-level firewall — but it doesn't matter which, because DNS-01 sidesteps both.

**How DNS-01 works here:**
- Caddy gets the LE challenge token, calls Cloudflare's API, sets a TXT record at `_acme-challenge.plex.vasher.eu`.
- LE's CA queries that TXT record via DNS (no inbound connection needed).
- Cert is issued; Caddy serves it on port 8443 (host).

**Required pieces:**
- `caddy/Dockerfile`: 4-line multi-stage build using `caddy:builder` to compile a Caddy binary with the `caddy-dns/cloudflare` plugin.
- `caddy/Caddyfile`: adds a `tls { dns cloudflare {env.CF_API_TOKEN} }` block.
- compose: `build: ./caddy` (instead of `image: caddy:latest`); injects `CF_API_TOKEN` into the container environment.
- The same CF API token used by the DDNS container — already provisioned with "Edit zone DNS" scope, which is exactly what DNS-01 needs.

**Trade-off:** Caddy version upgrades require `arrcompose build caddy` to rebuild the custom image. ~1 minute. Acceptable.

**Side effect:** port 80 is no longer mapped on Caddy's container (`80:80` removed from `ports:`). The router's `caddy-http` port-forward rule becomes a no-op but doesn't hurt — leave it or delete it.

---

## 2026-04-29 — pasta requires `PORT_DRIVER=implicit`, not `builtin`

**Decision:** When `DOCKERD_ROOTLESS_ROOTLESSKIT_NET=pasta`, `DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER` must be `implicit` (or `none`, but that disables port forwarding entirely). `builtin` is incompatible.

**Why:** rootlesskit 3.0 errors out at start with: `error: network "pasta" requires port driver "none" or "implicit"`. The `implicit` driver lets pasta handle host-to-container port forwarding transparently, which is also the path that preserves source IPs end-to-end (the whole reason we adopted pasta).

**For the tutorial:** call this out explicitly in the "configure rootless networking" step. It's not in the user-facing docs prominently — only in upstream `docs/network.md` — and the error only surfaces at restart time.

**Side note:** rootlesskit logs `"pasta" network driver is experimental. Needs very recent version of pasta` at startup. In practice pasta has been stable for the workloads we care about (Plex direct play, *arr UIs, Transmission); the warning is upstream's caution about API churn rather than runtime reliability. We accept it.

---

## 2026-04-29 — Plex UDP/1900 dropped (Spotify conflict)

**Decision:** Plex's port list does not bind UDP 1900 (SSDP). Comment in the compose explains why.

**Why:** Spotify's desktop client holds UDP 1900 for Spotify Connect's LAN-device discovery. On `docker compose up -d`, Plex's container failed to bind 1900 — host port already in use. Spotify takes the port whenever it's running, so quitting it isn't a durable fix.

**Trade-off:** Plex's DLNA discovery (used by SSDP-only "dumb" clients) won't work without UDP 1900. We accept this because:
- The user's primary client is an Nvidia Shield, which uses Plex's native protocol (via Plex.tv account), not DLNA.
- Plex's DLNA server is *off by default* in modern Plex anyway.
- Plex's GDM ports (UDP 32410–32414) are still bound and handle LAN discovery for un-signed-in Plex clients.

**For the tutorial:** mention that UDP 1900 is widely contested by other LAN apps (Spotify Connect, Sonos, Chromecast discovery, KDE/GNOME network discovery agents). Not binding it is the safe default unless you specifically need DLNA.

---

## 2026-04-29 — Phase 1 validated end-to-end

**Milestone:** All Phase 1 design goals reached. Pasta source-IP preservation validated empirically by checking Plex's "Now Playing" session view: Nvidia Shield connection shows the client address as `192.168.1.x` (the Shield's real LAN IP), not `172.x` (docker bridge gateway). This proves the rootless + bridge-networking + pasta combination delivers the same Plex LAN-detection behavior that host networking would have, while keeping the rootless privilege isolation intact.

**For the tutorial:** include "Now Playing → check client address" as the canonical verification step for pasta source-IP preservation. Tutorial readers can confirm in seconds, no log-grep dance.

---

## 2026-04-29 — Phase 2.1: Plex remote access via Caddy reverse proxy

**Decision:** Plex is reached remotely at `https://plex.vasher.eu` via a self-hosted Caddy container that terminates TLS and reverse-proxies to `plex:32400` over the bridge network. Cloudflare manages DNS only (gray cloud, *not* proxied). A `cloudflare-ddns` container keeps the A record pointed at the home dynamic IP.

**Why over alternatives:**
- *Cloudflare Tunnel free* — rejected because TOS § 2.8 prohibits proxying video. Same reason cloudflared isn't being re-used for Plex.
- *Cloudflare Tunnel paid* — works, but ~$20/mo for what self-hosting handles for free, and CF would see decrypted traffic.
- *Tailscale Funnel* — custom-domain support is brittle and Funnel has bandwidth caps. Misfit for "fixed `plex.vasher.eu`" goal.
- *Caddy + DDNS + open 443/80* — no third party, full bandwidth, real Let's Encrypt cert, well-trodden self-hosted pattern. Chosen.

**TLS challenge: HTTP-01 (port 80 open).** DNS-01 is the more isolation-respecting choice (no port 80) but requires a custom Caddy build with the `caddy-dns/cloudflare` plugin. Since 443 is already open, the marginal exposure of opening 80 is small (Caddy redirects 80 → 443 automatically). User chose simplicity. If wildcard certs become useful later (`*.vasher.eu` for shared *arr UI hostnames), revisiting DNS-01 is a small migration.

**Critical: Cloudflare DNS must stay "DNS only" (gray cloud), not proxied.** Proxied mode would route traffic through CF's edge, decrypt + re-encrypt TLS (defeating end-to-end), and re-introduce the TOS § 2.8 problem.

**Tailscale deferred.** User opted to keep Phase 2.1 scoped to public reverse proxy. Tailscale would add a no-open-ports path for the user's own access at full quality, parallel to (not replacing) Caddy. Revisit later if exposure becomes a concern.

---

## 2026-04-29 — Public Plex port is 8443 (router-imposed, temporary)

**Decision:** Plex's public URL is `https://plex.vasher.eu:8443` rather than the bare hostname. Router rules: external 8443 (TCP+UDP) → host 8443. Compose maps host 8443 → container 443 inside Caddy.

**Why:** the user's ISP-supplied router (a) hardcodes its HTTPS admin to port 443 and (b) outright rejects port 443 in either field of the port-forward UI. We can't move the admin port (Maintenance tab doesn't expose it). Cleanest workaround: shift everything off port 443 at the host/router boundary while keeping Caddy listening on container 443 (so the cert and config stay standard).

**Trade-off:** uglier public URL with explicit `:8443`. Cert issuance (HTTP-01 on port 80) is unaffected — that port forwarded fine.

**Future:** the user plans to switch to a proper (non-ISP) router. When that happens:
1. Add new port-forward rules: external 443 (TCP+UDP) → host 443 (or simply drop the 8443 mapping if the new router lets 443 through).
2. In `docker-compose.yaml`, change Caddy's `ports:` from `8443:443` to `443:443` (and `8443:443/udp` → `443:443/udp`).
3. In Plex's "Custom server access URLs", replace `https://plex.vasher.eu:8443` with `https://plex.vasher.eu` (no port suffix).
4. Optionally delete the 8443 router rules.

The Caddyfile, DNS, and DDNS configuration are unchanged in either scenario — only the host port mapping and Plex's advertised URL move.

---

## 2026-04-29 — Rootless Docker + privileged ports require sysctl tweak

**Gotcha:** Rootless Docker runs as an unprivileged user (`arrstack`), and Linux kernels by default reserve ports 0-1023 for root only (`net.ipv4.ip_unprivileged_port_start=1024`). When Caddy tried to bind host port 80 for ACME HTTP-01, the bind failed silently — `ss -tlnp` showed nothing listening, `curl http://localhost/` got connection refused, and Let's Encrypt's HTTP-01 challenge timed out fetching `http://plex.vasher.eu/.well-known/acme-challenge/...`.

**Fix:** lower the unprivileged-port threshold via sysctl:

```
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-arrstack-rootless.conf
sudo sysctl --system
```

This persists across reboots and lets `arrstack` (and any unprivileged user) bind ports 80 and above. Doesn't expose any extra attack surface — root could already bind these; we're just letting unprivileged users do it too. Common rootless-Docker setup step that the AUR `docker-rootless-extras` package's sysctl drop-in *doesn't* set (it only sets `kernel.unprivileged_userns_clone=1`).

**Why this didn't surface in Phase 1:** every Phase 1 service used ports ≥ 1024 (transmission 9091, plex 32400, radarr 7878, etc.). Port 80 (Caddy ACME) is the first sub-1024 port the stack has ever tried to bind.

**For the tutorial:** include this sysctl drop-in as part of the "rootless Docker setup" section, alongside the existing `unprivileged_userns_clone` requirement. It's the difference between "everything works" and "Caddy silently fails to bind 80."

---

## 2026-04-30 — Phase 2.2: Tailscale for Radarr/Sonarr admin access

**Decision:** Radarr and Sonarr are reachable remotely only via Tailscale (cryptographic identity at the network layer). No public DNS records, no CF Tunnel, no reverse proxy. Access requires being on the tailnet.

**Why:** Single-user admin access needed ~a few times a month. Tailscale gives a zero-config encrypted overlay with device-level identity — no port forwarding, no public DNS, no auth middleware to maintain. Overkill to build a public-facing auth layer (Authelia, CF Access) for something only one person uses from their own devices.

**Alternative considered:** CF Access in front of Radarr/Sonarr. Rejected — adds a dependency (CF Access policy) and a second auth path to maintain for ~2 uses/year from non-personal devices. Revisit if that frequency changes.

**Implementation:** Tailscale installed as a host service (not containerized — needs kernel-level WireGuard access). Radarr/Sonarr already listen on host ports via pasta port mappings, so they're automatically reachable on the host's tailnet IP. Two UFW rules allow `100.64.0.0/10` to ports 7878 and 8989.

---

## 2026-04-30 — Phase 2.2: Cloudflare Tunnel for public Seerr access

**Decision:** Seerr is publicly reachable at `https://seerr.vasher.eu` via a Cloudflare Tunnel. Auth is Seerr's built-in Plex SSO (no CF Access policy in front).

**Why:** Seerr is the "request media" UI — shared Plex users need to reach it from anywhere without installing Tailscale. CF Tunnel gives a public HTTPS endpoint with a valid cert, no port forwarding needed (outbound-only from cloudflared). Plex SSO gates access: only users who have access to the Plex server can sign in. Admin settings are gated by Seerr's role system.

**Why no CF Access:** Seerr already has robust auth via Plex SSO. Adding CF Access would create a double-login (CF Access challenge → Seerr Plex login) with no meaningful security gain — Seerr's login page doesn't leak data, and the Plex OAuth flow is the real gatekeeper.

**Implementation:** Reused existing CF tunnel. Token stored as `CF_TUNNEL_TOKEN` in `.env` (separate from `CF_API_TOKEN` used for DDNS). Tunnel's public hostname mapping: `seerr.vasher.eu` → `http://seerr:5055` (Docker service name, same bridge network).

---

## 2026-04-30 — Tailscale breaks rootless Docker DNS resolution

**Gotcha:** Tailscale overwrites `/etc/resolv.conf` with its own MagicDNS resolver (`nameserver 100.100.100.100`). The rootless Docker daemon (running as `arrstack`) cannot reach this resolver, causing all DNS lookups — including image pulls from Docker Hub — to fail with `Temporary failure in name resolution`.

**Fix:** Configure the rootless daemon with explicit public DNS by writing `/home/arrstack/.config/docker/daemon.json`:

```json
{
  "dns": ["1.1.1.1", "8.8.8.8"]
}
```

Then restart the daemon: `sudo systemctl --user --machine=arrstack@.host restart docker.service`.

**Why this only affects rootless:** The rootful daemon (root's dockerd) can reach Tailscale's resolver at `100.100.100.100` because it runs in the host's network namespace. The rootless daemon runs in arrstack's user namespace, which may not have routing to the Tailscale interface. The fix sidesteps the issue entirely by pointing at public DNS.

**For the tutorial:** this step must come *after* Tailscale install and *before* any `arrcompose` image pull. Section 18d covers it.

---

## 2026-05-16 — passt 2026_05_07 regression: pinned to 2026_01_20 in pacman.conf

**Gotcha:** After a routine `pacman -Syu` + reboot, the rootless Docker daemon refused to start. `systemctl --user status docker` showed `Active: failed (start-limit-hit)` and the journal contained, on every retry:

```
pasta[…]: No interfaces with usable IPv4 routes
pasta[…]: IPv4: no external interface as template, use local mode
pasta[…]: Dual stack forward, but IPv6 not enabled
pasta[…]: Unable to add rule TCP [*]:1-32767  =>  1-32767  (best effort) (auto-scan)
[rootlesskit:parent] error: failed to setup network ...: pasta failed with exit code 1
```

The host had a perfectly valid IPv4 default route (`default via 192.168.1.254 dev wlp7s0`) and `net.ipv6.conf.all.disable_ipv6=0`, so pasta's complaints were internal to the new binary, not a real environment problem. The same failure repeated whether systemd started the unit at boot or we triggered it manually hours later — ruling out a network-not-yet-ready race.

The pacman log pinned the cause: the upgrade touched only two packages, and one of them was a four-month jump of `passt`:

```
2026-05-16T09:33:59  docker  1:29.4.2-1 -> 1:29.4.3-1         (patch bump)
2026-05-16T09:34:13  passt   2026_01_20.386b5f5-1 -> 2026_05_07.1afd4ed-1
```

The previous decision ("Networking: pasta for source-IP preservation", 2026-04-28) makes reverting to slirp4netns a non-option — Plex's LAN-detection of the Nvidia Shield depends on pasta.

**Decision:** Downgrade `passt` to `2026_01_20.386b5f5-1` from the Arch archive (`https://archive.archlinux.org/packages/p/passt/`) and pin it with `IgnorePkg = passt` in `/etc/pacman.conf`. Add a dated comment above the pin so future-us knows why it's there and when to revisit.

**Why pin and not just downgrade:** without the pin, the next `pacman -Syu` silently re-installs the broken version and rootless Docker fails again at the next reboot — exactly the symptom we just spent an afternoon debugging.

**Alternatives considered:**
- *Switch rootlesskit back to slirp4netns* — rejected per the 2026-04-28 pasta decision; would regress Plex Shield direct play.
- *Pass explicit `-i wlp7s0` to pasta via a wrapper script* — possible but invasive (rootlesskit has no first-class flag-pass-through to pasta), and doesn't address the underlying regression. Reserve as a fallback if pinning becomes untenable.
- *Wait for upstream passt fix in the rolling release* — same outcome eventually, but leaves the box broken in the meantime.

**For the tutorial:** the rootless-Docker section should warn that `passt` is a rolling-release package and that newer versions have intermittently broken rootlesskit's pasta integration. Recommend documenting the known-good version range and showing the `IgnorePkg`/downgrade recipe in a "if pasta fails to start" troubleshooting box rather than baking the pin into the happy path.

**Open follow-up:** see the "Open / pending decisions" entry below for the conditions under which to remove the pin.

---

## 2026-06-03 — Tailscale `--accept-dns=false` as the reboot DNS-breakage workaround

**Gotcha:** After a host restart, Tailscale rewrote `/etc/resolv.conf` to its MagicDNS resolver (`nameserver 100.100.100.100`) before that resolver was actually reachable, so the host went offline for DNS — every name lookup failed while `ping 1.1.1.1` (raw IP) still worked. This is the host-level cousin of the 2026-04-30 "Tailscale breaks rootless Docker DNS resolution" entry.

**Decision:** Run `sudo tailscale set --accept-dns=false`. This tells Tailscale to stop managing `/etc/resolv.conf`, so the host reverts to its normal router DNS. The setting is persisted, so it also covers subsequent reboots. Chosen over re-enabling MagicDNS because we don't rely on tailnet (`*.ts.net`) hostnames anywhere.

**Why the arrStack is unaffected:** container DNS does not read `/etc/resolv.conf` and does not depend on Tailscale's MagicDNS. The rootless daemon pins resolvers directly via `/home/arrstack/.config/docker/daemon.json` (`"dns": ["1.1.1.1","8.8.8.8"]`, from the 2026-04-30 fix), so every container resolves through public DNS regardless of host-level resolv.conf or `--accept-dns` state. Remote Radarr/Sonarr admin access is by **Tailscale IP** (`100.x:7878`/`:8989`), not MagicDNS name, so it survives `--accept-dns=false` — only tailnet hostname resolution is lost, which we don't use. Cloudflared (Seerr tunnel) is outbound-only and uses container DNS, also unaffected.

**Keep the `daemon.json` dns override regardless.** It's what insulates the stack here. If MagicDNS is ever re-enabled (`--accept-dns=true`), that override is what prevents the rootless-daemon DNS failure from recurring.

**Verification (run 2026-06-03, confirmed healthy):** `sudo -iu arrstack docker exec radarr cat /etc/resolv.conf` shows `nameserver 127.0.0.11` (Docker's embedded resolver — expected on the user-defined bridge, it provides inter-container service-name resolution) with a `# ExtServers: [1.1.1.1 8.8.8.8]` line. The ExtServers values are the `daemon.json` upstreams; the absence of `100.100.100.100` is the thing to confirm. (Running containers use plain names, e.g. `radarr` — the `-test` suffix from the staging working tree is not applied to the live stack.)

**For the tutorial:** in the Tailscale section, note that MagicDNS can race host networking at boot and take DNS offline; `--accept-dns=false` is the durable fix when you address tailnet hosts by IP rather than name. The container-DNS override from Section 18d is independent and should stay.

**If you want MagicDNS back later (revisit checklist):** the only reason to re-enable is name-based access to *multiple* tailnet devices, or split-DNS for internal hostnames. Until then, leave it off. When/if you do re-enable:
1. **Don't just flip `--accept-dns=true` and hope** — that reproduces the boot race. Instead, make Tailscale integrate with `systemd-resolved` so it installs split-DNS per-interface rather than clobbering `/etc/resolv.conf` wholesale. On this host that means `resolv.conf` should be the `systemd-resolved` stub (`ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf`) and `systemd-resolved.service` enabled *before* re-enabling accept-dns. Tailscale auto-detects resolved and uses the cleaner path.
2. **Leave the container `daemon.json` dns override in place** (`["1.1.1.1","8.8.8.8"]`). It's what keeps the rootless daemon from inheriting an unreachable MagicDNS resolver — the 2026-04-30 failure mode — and it's harmless when MagicDNS works.
3. **Re-verify after reboot**, not just immediately: `dig` a tailnet name from the host, and re-run the container check (`docker exec radarr cat /etc/resolv.conf` → ExtServers must stay `1.1.1.1 8.8.8.8`, never `100.100.100.100`).
4. **Cheaper middle ground if you only need a name or two:** skip MagicDNS entirely and add static `100.x  <name>` lines to the host `/etc/hosts`. Stable (Tailscale IPs persist per device), survives reboots, zero resolv.conf management.

---

## 2026-10-10 — ISP router → OPNsense: what the arrStack needs from the router

**Context:** the eir ISP router is being replaced by an OPNsense box (old Acer, router-on-a-stick behind a GS308E switch, EAP610 AP). The LAN keeps `192.168.1.0/24` with the gateway on `.254`, and the host keeps `192.168.1.88`, so UFW rules, Plex "LAN Networks" and every fixed-IP setting carry over untouched. Full router plan lives outside this repo (`~/claudeProjects/homelab/README.md`, section 5).

**Unaffected by the router swap (verified with the house on OPNsense):** Seerr via CF Tunnel (outbound-only), DDNS (WAN gets a public eir IP by DHCP, no CGNAT; favonia updates the A record as usual), container DNS (`daemon.json` resolvers) and host DNS (static `1.1.1.1`), so router DNS problems can't break the stack itself.

**Three router settings the stack depends on** (the eir router did the first and third implicitly; OPNsense does none of them by default):
1. **Port forward WAN TCP+UDP 8443 → `192.168.1.88:8443`** for Plex remote via Caddy. On current OPNsense this lives under Firewall → NAT → **Destination NAT** (the old "Port Forward" page was renamed); use "Single port or range" for the ports, Firewall rule = Pass.
2. **Unbound private domain `plex.direct`.** Unbound's DNS rebind protection strips private-address answers, so `192-168-1-88.<id>.plex.direct` came back empty and LAN Plex clients lost the secure local connection (risking the "remote, throttled" Shield behaviour that the pasta decision exists to prevent). Services → Unbound DNS → Advanced → Private Domains.
3. **Unbound host override `plex.vasher.eu` → `192.168.1.88`** (split DNS). OPNsense doesn't hairpin by default, so the public URL timed out from the LAN. Chosen over NAT reflection: LAN traffic goes straight to Caddy, no extra NAT path, and the cert stays valid because it's DNS-01 issued. Gotcha: Dnsmasq (which does DHCP here) also has a "Hosts" page; an entry there does nothing for these DNS answers — it must be under Unbound → Overrides.

**Also added: Caddy `http_redirect` listener wrapper.** Typing `plex.vasher.eu:8443` without a scheme sent plain HTTP to the TLS port and got an error. The wrapper answers with a 308 to `https://` on the same port (Location is built from the Host header, so `:8443` is kept). Router-independent, but found during this test.

**Tailscale static port (rule added, verify at next router boot):** OPNsense's outbound NAT randomizes source ports per destination (`MappingVariesByDestIP: true`), which pushes remote Radarr/Sonarr onto the DERP relay. Fix: a Source NAT rule (the new name for Outbound NAT) for `192.168.1.88` UDP port 41641 with Static-port, translation = WAN address. Gotchas: existing NAT states keep their random ports and Tailscale's keepalives stop them expiring; `pfctl -k <LAN host>` doesn't match them on FreeBSD (it matches the post-NAT address), so a router reboot is the reliable reset. `tailscale netcheck` can't verify the fix (the CLI probes from a random port); check `tailscale status --json` Self.Addrs or the router's `pfctl -s state` for `<WAN IP>:41641` instead. With the eir router gone, the "Public Plex port is 8443" workaround can also be retired (see that entry's Future list).

**For the tutorial:** a "replacing the ISP router" checklist: port forward, `plex.direct` private domain, split-DNS override for the public hostname. Verify the first from a phone on mobile data (not from the LAN), the other two by querying the router's DNS directly.

---

## 2026-10-20 — MagicDNS back on, via `systemd-resolved` (reverses 2026-06-03)

**Why now:** the host needs to reach several tailnet devices by name (`chromebook-langoliers`, `debian`), which is the re-enable reason the 2026-06-03 checklist names. We followed that checklist.

**Decision:** enable `systemd-resolved`, point `/etc/resolv.conf` at the stub, restart NetworkManager and tailscaled, then run `sudo tailscale set --accept-dns=true`. Tailscale detects resolved and configures split DNS on `tailscale0` instead of rewriting `/etc/resolv.conf`. `100.100.100.100` only answers `~ts.net`, the tailnet domain and the `100.x` reverse zones (`Default Route: no`). All other names still go to the `wlp7s0` resolvers (`1.1.1.1 8.8.8.8 8.8.4.4`). The tailnet has no global nameservers, so the 2026-06-03 failure, where every lookup went through a 100.100.100.100 that wasn't reachable yet, can't happen this way.

**Why the arrStack is unaffected:** the `daemon.json` dns override (2026-04-30) stays, so containers still resolve through `1.1.1.1 8.8.8.8`. The rootless daemon's own lookups (image pulls) now go through the host's resolved stub.

**Gotcha: start order.** We started resolved while `/etc/resolv.conf` was still NetworkManager's file. resolved read it as outside config and kept those servers as its Global DNS list, so the old values (`1.1.1.1 8.8.8.8 4.4.4.4`) stuck around even after the symlink was switched. `systemctl restart systemd-resolved` cleared it. Swap the symlink before starting resolved, or restart resolved afterwards.

**Verification (after a reboot, 2026-10-20):** `resolvectl dns` lists `100.100.100.100` on `tailscale0` only and an empty Global list. `getent hosts chromebook-langoliers` / `debian` return their `100.x` addresses, and public names resolve. `docker exec radarr cat /etc/resolv.conf` still shows `ExtServers: [1.1.1.1 8.8.8.8]` with no `100.100.100.100`. `docker pull hello-world` works.

**Rollback:** `sudo tailscale set --accept-dns=false`, `sudo rm /etc/resolv.conf`, `sudo systemctl disable --now systemd-resolved`, `sudo systemctl restart NetworkManager` (NM writes a fresh resolv.conf).

**For the tutorial:** if MagicDNS is wanted, set up resolved and the stub symlink *before* enabling `--accept-dns`, and keep the Section 18d container override in place either way.

---

## Open / pending decisions

- **Static IP** (`192.168.1.88` on `wlp7s0`): user to choose router DHCP reservation vs NetworkManager static. Either works; setup happens before Plex first-boot config (Task 13 step 0).
- **Phase 2 Jellyfin reintroduction**: with or without GPU passthrough; the existing GPU device paths `/dev/dri/renderD128`, `/dev/dri/card1` are likely still valid; group memberships will need re-checking under rootless.
- **Remove `passt` pin in `/etc/pacman.conf`** (added 2026-05-16): periodically check upstream `passt` changelog and rootlesskit issues. When a newer `passt` release ships that successfully passes rootlesskit's pasta startup on this host, remove the `IgnorePkg = passt` line, run `pacman -Syu`, restart `docker.service`, and re-verify Plex source-IP preservation via the "Now Playing" check.
