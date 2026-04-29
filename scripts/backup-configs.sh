#!/usr/bin/env bash
#
# backup-configs.sh
#
# Tarball-backup the arrStack /config dirs from drive 1 before doing any
# destructive reorg work in Task 6. Drops one zstd-compressed tarball per
# service in ~/arrstack-backups/<timestamp>/ by default.
#
# Usage:
#   bash scripts/backup-configs.sh
#
#   # Override defaults via env vars:
#   CONFIG_SRC=/some/other/path bash scripts/backup-configs.sh
#   BACKUP_ROOT=/mnt/arr2/arrstack-backups bash scripts/backup-configs.sh
#
# What it backs up:
#   Only the services kept in the new compose (radarr, sonarr, bazarr,
#   prowlarr, transmission, plex, plex-transcode, tatulli, seerr, homepage).
#   Dropped services (jellyfin*, overseerr, plex.bak) are NOT backed up here
#   — they get archived in-place during Task 6.
#
# Safety:
#   - Idempotent: each run drops a new timestamped subdir; existing backups
#     are never touched.
#   - Calls `sudo tar` so it works regardless of ownership/perms inside
#     individual config dirs.

set -euo pipefail

# ---------- config -----------------------------------------------------------

CONFIG_SRC="${CONFIG_SRC:-/mnt/arr1/mediaServer/config}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/arrstack-backups}"
SERVICES=(radarr sonarr bazarr prowlarr transmission plex plex-transcode tatulli seerr homepage)

TS="$(date +%Y%m%d-%H%M)"
BACKUP_DIR="$BACKUP_ROOT/$TS"

# ---------- pre-flight -------------------------------------------------------

echo "==> Pre-flight"
echo "    Source:      $CONFIG_SRC"
echo "    Destination: $BACKUP_DIR"
echo

if ! command -v zstd >/dev/null 2>&1; then
  echo "ERROR: zstd not found in PATH. Install with: sudo pacman -S zstd" >&2
  exit 1
fi

if [ ! -d "$CONFIG_SRC" ]; then
  echo "ERROR: source dir not found: $CONFIG_SRC" >&2
  echo "       Set CONFIG_SRC to override." >&2
  exit 1
fi

echo "==> Free space at destination filesystem:"
mkdir -p "$BACKUP_ROOT"
df -h "$BACKUP_ROOT"
echo

mkdir -p "$BACKUP_DIR"

# ---------- backup loop ------------------------------------------------------

echo "==> Backing up config dirs"
cd "$CONFIG_SRC"

for svc in "${SERVICES[@]}"; do
  if [ -d "$svc" ]; then
    printf "    %-18s ... " "$svc"
    sudo tar --use-compress-program=zstd -cf "$BACKUP_DIR/$svc.tar.zst" "$svc"
    size="$(du -h "$BACKUP_DIR/$svc.tar.zst" | cut -f1)"
    echo "$size"
  else
    printf "    %-18s skipped (not present)\n" "$svc"
  fi
done

# ---------- summary ----------------------------------------------------------

echo
echo "==> Done."
ls -lh "$BACKUP_DIR"
echo
echo "Backup dir:  $BACKUP_DIR"
echo "Total size:  $(du -sh "$BACKUP_DIR" | cut -f1)"
