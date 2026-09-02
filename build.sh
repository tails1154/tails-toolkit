#!/bin/bash
# ============================================================================
#  TAILS TOOLKIT — build script
#
#  Takes a stock ChromeOS ARM64 recovery image and produces a bootable
#  "toolkit" image that boots straight into our bash TUI instead of the
#  locked-down ChromeOS recovery UI.
#
#  What it does:
#    1. Copy the stock image (COW if possible) -> <out>.img  (original kept!)
#    2. Patch the ARM64 kernel cmdline (KERN-A) to:
#         - boot ROOT-A directly (no dm-verity, rw)
#         - run init=/toolkit/toolkit.sh (our TUI)
#    3. Reformat ROOT-A as clean, writable ext4 (the stock fs refuses rw due
#       to ChromeOS ro-compat ext4 features like fs-verity) and seed it from
#       the stock rootfs, then install /toolkit.
#
#  REQUIRES signature verification to be OFF on the target device
#  (dev mode / custom firmware), otherwise the patched kernel won't boot.
# ============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
SRC="${1:-chromeos_16503.76.0_skywalker_recovery_stable-channel_SkywalkerMPKeys-v9.bin}"
OUT="${2:-tails-toolkit.img}"
TOOLKIT_DIR="$(cd "$(dirname "$0")" && pwd)/toolkit"

# Partition geometry (from `fdisk -l` / GPT) — sectors * 512 = byte offset
SECTOR=512
KERN_A_START=$((405504))              # p2 ChromeOS kernel (KERN-A)
ROOT_A_START=$((1454080))             # p3 ChromeOS rootfs (ROOT-A)
ROOT_A_END=$((9842687))               # exclusive span -> size
KERN_A_OFF=$((KERN_A_START * SECTOR))
ROOT_A_OFF=$((ROOT_A_START * SECTOR))
ROOT_A_SIZE=$(((ROOT_A_END - ROOT_A_START + 1) * SECTOR))

# Offset of the kernel cmdline *inside* the KERN-A blob (found via inspection)
CMDLINE_IN_KERN=42799104
CMDLINE_ABS=$((KERN_A_OFF + CMDLINE_IN_KERN))

# Our live boot args. root=PARTUUID is device-agnostic (works on eMMC or USB).
ROOTFS_PARTUUID="AF13DF12-F6DC-5E4A-AD36-92C4713DC261"
NEW_CMDLINE="console=tty0 loglevel=7 init=/toolkit/toolkit.sh root=PARTUUID=${ROOTFS_PARTUUID} rootwait panic=60"

# ---- helpers ----------------------------------------------------------------
info(){ printf '\033[1;36m[+] %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die(){  printf '\033[1;31m[x] %s\033[0m\n' "$*"; exit 1; }

need(){ command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
for t in cp mount umount losetup python3 mkfs.ext4 rsync e2fsck; do need "$t"; done

[ -f "$SRC" ] || die "source image not found: $SRC"
id -u | grep -q '^0$' || die "run as root (need loop mounts) — try: sudo ./build.sh"

cleanup(){ umount "$MNT_NEW" 2>/dev/null || true; umount "$MNT_SRC" 2>/dev/null || true; \
           losetup -d "$LOOP_NEW" 2>/dev/null || true; losetup -d "$LOOP_SRC" 2>/dev/null || true; \
           rmdir "$MNT_NEW" "$MNT_SRC" 2>/dev/null || true; }
trap cleanup EXIT

# ---- 1. copy ----------------------------------------------------------------
if [ -e "$OUT" ]; then warn "overwriting existing $OUT"; rm -f "$OUT"; fi
info "Copying $SRC -> $OUT (COW when supported)..."
if ! cp --reflink=auto "$SRC" "$OUT" 2>/dev/null; then cp "$SRC" "$OUT"; fi
sync

# ---- 2. patch kernel cmdline ------------------------------------------------
info "Patching KERN-A cmdline at byte $CMDLINE_ABS ..."
python3 - "$OUT" "$CMDLINE_ABS" "$NEW_CMDLINE" <<'PY'
import sys
img, off, cmd = sys.argv[1], int(sys.argv[2]), sys.argv[3]
b = cmd.encode('ascii')
assert len(b) <= 600
with open(img, 'r+b') as f:
    f.seek(off); f.write(b); f.write(b'\x00' * (600 - len(b)))
print('  -> ' + cmd)
PY

# ---- 3. reformat ROOT-A as clean ext4 + seed + install toolkit --------------
MNT_SRC=$(mktemp -d); MNT_NEW=$(mktemp -d)

info "Preparing clean ext4 for ROOT-A (${ROOT_A_SIZE} bytes)..."
LOOP_NEW=$(losetup -f --show -o "$ROOT_A_OFF" --sizelimit "$ROOT_A_SIZE" "$OUT")
mkfs.ext4 -q -F -L ROOT-A "$LOOP_NEW"

info "Mounting stock ROOT-A (ro) and new ROOT-A (rw) ..."
LOOP_SRC=$(losetup -f --show -o "$ROOT_A_OFF" --sizelimit "$ROOT_A_SIZE" "$SRC")
mount -o ro "$LOOP_SRC" "$MNT_SRC"
mount -o rw "$LOOP_NEW" "$MNT_NEW"

info "Seeding toolkit rootfs from stock ChromeOS userland (this takes a bit)..."
rsync -aHAX \
    --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' \
    --exclude='/tmp/*'  --exclude='/mnt/*' --exclude='/media/*' --exclude='/lost+found' \
    "$MNT_SRC/" "$MNT_NEW/"
mkdir -p "$MNT_NEW"/{proc,sys,dev/pts,run,tmp,mnt,media}

info "Installing toolkit into rootfs..."
rm -rf "$MNT_NEW/toolkit"
cp -a "$TOOLKIT_DIR" "$MNT_NEW/toolkit"
chmod 755 "$MNT_NEW/toolkit/toolkit.sh"
chmod -R a+rX "$MNT_NEW/toolkit"
[ -x "$MNT_NEW/bin/bash" ] || die "rootfs has no /bin/bash!"

sync
umount "$MNT_NEW"; umount "$MNT_SRC"
losetup -d "$LOOP_NEW"; losetup -d "$LOOP_SRC"
rmdir "$MNT_NEW" "$MNT_SRC"
trap - EXIT

echo
info "Done. Wrote: $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "  To use:"
echo "   1. Flash to target:   sudo dd if=$OUT of=/dev/sdX bs=4M status=progress"
echo "   2. Boot with verified-boot OFF (dev / legacy / custom firmware)."
echo "   3. It should drop into the TAILS TOOLKIT TUI."
echo
echo "  Rebuild after editing toolkit/:   sudo ./build.sh"