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
#         - boot ROOT-A directly (no dm-verity, rw  — clears the stock
#           ro-compat ext4 features, which is why we rebuild the fs)
#         - run init=/toolkit/toolkit.sh (our TUI)
#    3. Rebuild ROOT-A as clean, writable ext4: extract the stock userland,
#       add /toolkit, and write it back into the partition image.
#
#  NO loop devices and NO mounting required — pure userspace (e2fsprogs +
#  python3), so it builds even in containers/Crostini that have no /dev/loop*.
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
ROOT_A_BLOCKS=$((ROOT_A_END - ROOT_A_START + 1))     # in 512-byte sectors
ROOT_A_SIZE=$((ROOT_A_BLOCKS * SECTOR))

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
for t in cp dd truncate mkfs.ext4 debugfs python3 rm mkdir; do need "$t"; done

[ -f "$SRC" ] || die "source image not found: $SRC"
# root is NOT required (we don't mount), but warn if loop tools are missing
id -u | grep -q '^0$' || warn "not root (fine: we don't mount, only write files)"

OUTDIR="$(dirname "$OUT")"; [ "$OUTDIR" = "." ] && OUTDIR="$PWD"
WORK="$(mktemp -d "$OUTDIR/.build-tmp.XXXXXX" 2>/dev/null || mktemp -d)"
cleanup(){ rm -rf "$WORK"; }
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

# ---- 3. rebuild ROOT-A as clean writable ext4 (loop-free) -------------------
STOCK_FS="$WORK/stock-rootfs.img"
NEW_FS="$WORK/rootfs-new.img"
STAGE="$WORK/rootfs"

info "Extracting stock ROOT-A partition (${ROOT_A_SIZE} bytes) to a standalone image..."
dd if="$OUT" of="$STOCK_FS" bs=${SECTOR} skip=$((ROOT_A_OFF / SECTOR)) count="$ROOT_A_BLOCKS" status=none

info "Unpacking the entire stock userland to a staging dir (debugfs rdump)..."
mkdir -p "$STAGE"
debugfs -R 'rdump /' "$STOCK_FS" "$STAGE" 2>/dev/null

info "Installing toolkit into rootfs..."
rm -rf "$STAGE/toolkit"
cp -a "$TOOLKIT_DIR" "$STAGE/toolkit"
chmod 755 "$STAGE/toolkit/toolkit.sh"
chmod -R a+rX "$STAGE/toolkit"
[ -x "$STAGE/bin/bash" ] || die "rootfs has no /bin/bash!"

info "Creating clean writable ext4 for ROOT-A and populating it (-d staging dir)..."
truncate -s "$ROOT_A_SIZE" "$NEW_FS"
mkfs.ext4 -q -F -L ROOT-A -d "$STAGE" "$NEW_FS"

info "Splicing new ROOT-A into the output image at byte $ROOT_A_OFF..."
dd if="$NEW_FS" of="$OUT" bs=${SECTOR} seek=$((ROOT_A_OFF / SECTOR)) conv=notrunc status=none
sync

rm -rf "$WORK"; trap - EXIT

echo
info "Done. Wrote: $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "  To use:"
echo "   1. Flash to target:   sudo dd if=$OUT of=/dev/sdX bs=4M status=progress"
echo "   2. Boot with verified-boot OFF (dev / legacy / custom firmware)."
echo "   3. It should drop into the TAILS TOOLKIT TUI."
echo
echo "  Rebuild after editing toolkit/:   sudo ./build.sh"