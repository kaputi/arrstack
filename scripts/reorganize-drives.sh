#!/usr/bin/env bash
#
# reorganize-drives.sh
#
# Task 6 of the arrStack sandbox plan:
#   - Archive dropped-service config dirs on drive 1
#     (jellyfin*, overseerr, plex.bak → config/_archived/).
#   - Set up drive 2 from a clean slate
#     (rename stale 2023 mediaServer/ → mediaServer.archive-2023/,
#      create fresh empty mediaServer/media/movies/).
#   - Chown the bind-mount subtrees to arrstack:arrstack at mode 0750.
#   - Grant arrstack traversal-only ACL on each drive root so the rootless
#     daemon can pass through to bind-mount sources without being able to
#     enumerate the drives' top-level personal content.
#
# Idempotent: re-running after a successful first run is a no-op.
#
# Usage:
#   bash scripts/reorganize-drives.sh

set -euo pipefail

ARR1_ROOT=/mnt/arr1/mediaServer
ARR2_ROOT=/mnt/arr2/mediaServer
ARR2_ARCHIVE=/mnt/arr2/mediaServer.archive-2023

# ---------- Step 1: Verify drive 1 layout matches expectations ---------------

echo "==> Step 1: Verify drive 1 layout"
for d in config downloads media media/movies media/movies_4k media/series; do
  if [ ! -d "$ARR1_ROOT/$d" ]; then
    echo "ERROR: missing $ARR1_ROOT/$d" >&2
    echo "       Drive 1 layout doesn't match what the spec expects." >&2
    exit 1
  fi
done
echo "    All expected drive-1 dirs present."

# ---------- Step 2: Archive dropped-service config dirs on drive 1 -----------

echo
echo "==> Step 2: Archive dropped-service config dirs on drive 1"
sudo mkdir -p "$ARR1_ROOT/config/_archived"
for d in jellyfin jellyfin-cache jellyfin-transcodes overseerr plex.bak; do
  src="$ARR1_ROOT/config/$d"
  dst="$ARR1_ROOT/config/_archived/$d"
  if [ -d "$src" ] && [ ! -e "$dst" ]; then
    sudo mv "$src" "$dst"
    echo "    archived $d"
  elif [ -e "$dst" ]; then
    echo "    $d already archived (skipping)"
  else
    echo "    $d not present (skipping)"
  fi
done

# ---------- Step 3: Set up drive 2 from a clean slate ------------------------

echo
echo "==> Step 3: Set up drive 2 from a clean slate"
if [ -d "$ARR2_ROOT" ] && [ ! -e "$ARR2_ARCHIVE" ]; then
  sudo mv "$ARR2_ROOT" "$ARR2_ARCHIVE"
  echo "    moved old mediaServer/ → mediaServer.archive-2023/"
elif [ -e "$ARR2_ARCHIVE" ]; then
  echo "    $ARR2_ARCHIVE already exists — old mediaServer was already archived"
fi
if [ ! -d "$ARR2_ROOT" ]; then
  sudo mkdir -p "$ARR2_ROOT/media/movies"
  echo "    created $ARR2_ROOT/media/movies/ (empty, ready for new content)"
else
  echo "    $ARR2_ROOT already exists — leaving alone"
fi

# ---------- Step 4: Chown bind-mount subtrees to arrstack --------------------

echo
echo "==> Step 4: Chown bind-mount subtrees to arrstack:arrstack"
sudo chown -R arrstack:arrstack "$ARR1_ROOT" "$ARR2_ROOT"
sudo chmod 0750 "$ARR1_ROOT" "$ARR2_ROOT"
echo "    done."

# ---------- Step 5: Grant arrstack traversal-only ACL on drive roots ---------

echo
echo "==> Step 5: Grant arrstack traversal-only ACL on each drive root"
sudo setfacl -m u:arrstack:x /mnt/arr1
sudo setfacl -m u:arrstack:x /mnt/arr2
echo "    done."

# ---------- Verification ----------------------------------------------------

echo
echo "==> Verification (run as arrstack — eduardo's current shell may not yet"
echo "    have the new group membership active until logout/login or 'newgrp arrstack')"
echo
echo "    Bind-mount roots (should be drwxr-x--- arrstack arrstack):"
ls -ld "$ARR1_ROOT" "$ARR2_ROOT"
echo
echo "    First few entries of $ARR1_ROOT/config (as arrstack):"
sudo -iu arrstack ls -la "$ARR1_ROOT/config" | head -10 || true
echo
echo "    ACL on /mnt/arr1 (look for user:arrstack:--x):"
getfacl /mnt/arr1 2>/dev/null | grep -E "^(# file|user|mask)" || true
echo
echo "    ACL on /mnt/arr2:"
getfacl /mnt/arr2 2>/dev/null | grep -E "^(# file|user|mask)" || true
echo
echo "    Sandbox check: arrstack should be able to ls its subtree..."
if sudo -iu arrstack ls "$ARR1_ROOT" >/dev/null 2>&1; then
  echo "    OK: arrstack can ls $ARR1_ROOT"
else
  echo "    WARN: arrstack cannot ls $ARR1_ROOT — chown may not have taken"
fi
echo
echo "    Sandbox check: arrstack should NOT be able to ls drive root..."
if sudo -iu arrstack ls /mnt/arr1 >/dev/null 2>&1; then
  echo "    WARN: arrstack CAN ls /mnt/arr1 — privacy guarantee broken"
else
  echo "    OK: arrstack cannot ls /mnt/arr1 (permission denied as expected)"
fi

echo
echo "==> Done."
