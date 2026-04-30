# Custom Caddy build that includes the caddy-dns/cloudflare plugin so we
# can use the DNS-01 ACME challenge for cert issuance. Required because:
#   - HTTP-01 needs port 80 reachable from the public internet, which is
#     blocked here (likely ISP-level on residential Vodafone IE, possibly
#     the router firewall too).
#   - DNS-01 only needs outbound HTTPS to the Cloudflare API, which always
#     works.
#
# Multi-stage build: compile a custom Caddy binary in the builder image,
# then drop it into the standard runtime image. Rebuild on Caddy version
# upgrades by running `docker compose build caddy`.

FROM caddy:builder AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

FROM caddy:latest
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
