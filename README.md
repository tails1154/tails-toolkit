# TAILS TOOLKIT

A bootable ARM64 rescue/multitool built by modifying the stock **skywalker**
(Acer Chromebook R11, ARM64) ChromeOS recovery image. Instead of the locked-down
recovery UI it boots straight into a keyboard-driven **bash TUI** of handy tools.

![tui](toolkit.png "toolkit menu")

## What you get

- `toolkit/toolkit.sh` — the TUI (bash). Arrow keys / number keys / Enter; `q` quits.
  Sections: system info, disks, network, ssh helper, dd imaging, fsck, recovery tricks,
  drop-to-shell, reboot/power-off.
- `build.sh` — patches the image and installs the toolkit. Run as root.
- `tails-toolkit.img` — the output (flashable).

## How it works

The stock recovery image boots an RSA-signed + dm-verity-protected rootfs. We don't
fight that. We:

1. Keep the stock ARM64 kernel (KERN-A, p2).
2. Rewrite its boot **cmdline** in place to:
   - `root=PARTUUID=<ROOT-A> rw` — mount the raw ext4 rootfs directly, **dm-verity off**
   - `init=/toolkit/toolkit.sh` — boot straight into our TUI
3. Drop `toolkit/` into the rootfs (ROOT-A, p3).

## Build

```sh
cd ~/Documents/vibecoding/bootimg
sudo ./build.sh            # -> tails-toolkit.img   (original .bin untouched)
```

Edit `toolkit/toolkit.sh`, re-run `sudo ./build.sh` to refresh the image.
Iteration is cheap because we patch in place — no full rebuild.

## Flash & boot

```sh
sudo dd if=tails-toolkit.img of=/dev/sdX bs=4M status=progress   # X = your USB stick
sync
```

Then boot the target with **signature verification disabled** (dev mode / custom
firmware / legacy boot). The patched kernel cmdline is only honored when the
firmware isn't enforcing verified boot.

> NOTE: this assumes the firmware boots the KERN-A kernel from this image. If your
> boot path uses a different kernel partition (recovery/miniOS), say so and we'll
> patch that one too. Test on the device and report which boot mode works.

## Layout

```
bootimg/
  chromeos_..._recovery_stable...bin   # stock image (never modified)
  build.sh                             # patches + installs toolkit
  toolkit/
    toolkit.sh                         # the TUI
  README.md
```