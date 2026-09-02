#!/bin/bash
# ============================================================================
#  TAILS TOOLKIT  — a bootable rescue & multitool TUI (bash)
#  Runs from a modified ARM64 ChromeOS recovery image (skywalker board).
#  Keyboard: UP/DOWN arrows + ENTER, or press a number key. Q to quit.
# ============================================================================
#
# This script is meant to be launched as init of a small live Linux. It assumes
# a handful of standard tools exist (coreutils, fdisk, ip, mount, parted...).
# Everything degrades gracefully if a tool is missing.

set -o pipefail
VERSION="0.1.0"
PROGNAME="TAILS TOOLKIT"

# ----------------------------------------------------------------------------
#  Terminal / color helpers
# ----------------------------------------------------------------------------
if [ -t 0 ] && [ -t 1 ]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_BLACK=$'\e[30m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
    C_BLUE=$'\e[34m'; C_MAG=$'\e[35m'; C_CYAN=$'\e[36m'; C_WHITE=$'\e[37m'
    C_BG_BLUE=$'\e[44m'; C_BG_GRAY=$'\e[100m'; C_BG_GREEN=$'\e[42m'
else
    C_RESET=; C_BOLD=; C_DIM=; C_BLACK=; C_RED=; C_GREEN=; C_YELLOW=
    C_BLUE=; C_MAG=; C_CYAN=; C_WHITE=; C_BG_BLUE=; C_BG_GRAY=; C_BG_GREEN=
fi

# Horizontal line using box-drawing chars (falls back to '-')
HL=$(printf '%*s' "$(tput cols 2>/dev/null || echo 60)" '' | tr ' ' '─')

# ----------------------------------------------------------------------------
#  Bootstrap: when launched directly as init the kernel gives us a bare root.
#  Mount the pseudo-filesystems most tools need.
# ----------------------------------------------------------------------------
bootstrap() {
    [ "$(id -u)" = "0" ] || return 0
    mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc 2>/dev/null
    mountpoint -q /sys  2>/dev/null || mount -t sysfs sysfs /sys 2>/dev/null
    mountpoint -q /dev  2>/dev/null || mount -t devtmpfs devtmpfs /dev 2>/dev/null
    mountpoint -q /dev/pts 2>/dev/null || mount -t devpts devpts /dev/pts 2>/dev/null

    # If the console isn't on a tty already, make sure stdin is usable.
    [ -c /dev/console ] && exec </dev/console >/dev/console 2>&1
}

# ----------------------------------------------------------------------------
#  Small UI primitives
# ----------------------------------------------------------------------------
say()     { printf '%s\n' "$*"; }
banner()  { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }
warn()    { printf '%s[!] %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()     { printf '%s[x] %s%s\n' "$C_RED" "$*" "$C_RESET"; }
ok()      { printf '%s[+] %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }

pause() {
    printf '%s%s  [press Enter to continue]%s' "$C_DIM" "$1" "$C_RESET"
    read -r _ 2>/dev/null
}

# Ask a yes/no question. First arg = prompt, returns 0 (yes) / 1 (no).
confirm() {
    local a
    printf '%s%s%s [y/N] ' "$C_YELLOW" "$1" "$C_RESET"
    read -r a 2>/dev/null
    [[ "$a" == "y" || "$a" == "Y" ]]
}

# Run a command in a fullscreen-ish way: clear, run, then pause.
run_full() {
    clear
    banner "$*"
    printf '%s\n' "$HL"
    echo
    "$@"
    echo
    pause "Returning to menu"
}

# ----------------------------------------------------------------------------
#  Data / data providers
# ----------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

distro_line() {
    local line=""
    [ -f /etc/os-release ] && line=$(grep -m1 PRETTY_NAME /etc/os-release | cut -d= -f2- | tr -d '"')
    [ -z "$line" ] && [ -f /etc/lsb-release ] && line=$(grep -m1 DESCRIPTION /etc/lsb-release | cut -d= -f2-)
    echo "${line:-unknown}"
}

addr_lines() {
    local h m
    for line in $(ip -o addr show 2>/dev/null | awk '$2!="lo"{print $2" "$4}'); do
        echo "$line"
    done
}

# ----------------------------------------------------------------------------
#  ACTIONS — each menu entry maps to one of these
# ----------------------------------------------------------------------------
act_info() {
    local cpu mems freefs
    cpu=$(grep -m1 "^model name" /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')
    [ -z "$cpu" ] && cpu=$(grep -m1 "^Hardware" /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')
    cpu="${cpu:-$(uname -m)}"
    mems=$(free -h 2>/dev/null | awk '/Mem:/{print $2}')
    clear
    banner "SYSTEM INFORMATION"
    printf '%s\n' "$HL"
    cat <<EOF
  Host          : $(hostname)
  Kernel        : $(uname -srm)
  Distro        : $(distro_line)
  CPU           : ${cpu}
  Memory        : ${mems:-?}
  TTY           : ${TTY:-$(tty 2>/dev/null || echo '?')}
  Time          : $(date '+%F %T %Z')
EOF
    echo
    banner "NETWORK INTERFACES"
    printf '%s\n' "$HL"
    ip -brief addr 2>/dev/null || ip addr show 2>/dev/null
    echo
    banner "MOUNTED FILESYSTEMS"
    printf '%s\n' "$HL"
    df -h 2>/dev/null | awk 'NR==1 || $NF ~ /^\//'
    echo
    pause
}

act_disks() {
    clear
    banner "STORAGE / PARTITIONS"
    printf '%s\n' "$HL"
    if have lsblk; then
        lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS 2>/dev/null
    else
        fdisk -l 2>/dev/null
    fi
    echo
    banner "BLOCK DEVICES (raw)"
    printf '%s\n' "$HL"
    ls -l /dev/sd* /dev/mmcblk* /dev/nvme* 2>/dev/null || warn "no classic block devices found (this is fine in QEMU)"
    echo
    pause "Press Enter to return"
}

act_net() {
    clear
    banner "NETWORK"
    printf '%s\n' "$HL"
    echo "-- interfaces --";    ip -brief addr 2>/dev/null || ifconfig 2>/dev/null
    echo "-- routes --";        ip route show 2>/dev/null || route -n 2>/dev/null
    echo "-- connectivity --"
    if ping -c2 -W2 1.1.1.1 >/dev/null 2>&1; then
        ok "Internet reachable (1.1.1.1)"
    else
        warn "no direct Internet via 1.1.1.1"
    fi
    if ip -o addr show 2>/dev/null | grep -q 'inet '; then
        ok "This device has an IPv4 address"
    else
        warn "no IPv4 address assigned yet"
    fi
    echo
    banner "DHCP quick-up"
    printf '%s\n' "$HL"
    if confirm "Run DHCP client on the first ethernet/wifi iface now?"; then
        iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
        if [ -n "$iface" ]; then
            ok "Attempting DHCP on $iface ..."
            (udhcpc -i "$iface" 2>/dev/null || dhclient "$iface" 2>/dev/null || busybox udhcpc -i "$iface" 2>/dev/null) || err "no DHCP client available"
        else
            err "no usable interface"
        fi
    fi
    echo
    pause
}

act_ssh() {
    clear
    banner "SSH (drop-in shell in a container/rootfs)"
    printf '%s\n' "$HL"
    if ! have ssh; then err "openssh client not present"; pause; return; fi
    printf 'Connect from another machine to this one with something like:\n\n'
    printf '    ssh -l root <thisIP>    # (if a server is running)\n\n'
    printf 'Or use the toolbox-style escape from a live image dish:\n'
    printf '    ssh you@host  "run a remote command"\n\n'
    pause "Just a helper — press Enter (no server is auto-started)"
}

act_img() {
    clear
    banner "IMAGE / DD UTILITY"
    printf '%s\n' "$HL"
    if ! have dd; then err "dd missing"; pause; return; fi
    echo "Targets below are the *whole* block devices."
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS 2>/dev/null
    echo
    local src="" dst=""
    printf 'Source device or file (e.g. /dev/sda or /tmp/foo.img): '
    read -r src
    [ -z "$src" ] && { err "aborted"; pause; return; }
    printf 'Destination device or file (e.g. /dev/sdb or /tmp/out.img): '
    read -r dst
    [ -z "$dst" ] && { err "aborted"; pause; return; }
    if confirm "Wipe $dst and write $src (dd bs=4M status=progress)? This is DESTRUCTIVE."; then
        if [ -b "$src" ] || [ -f "$src" ]; then
            (dd if="$src" of="$dst" bs=4M status=progress conv=fsync 2>&1 | tail -5) || err "dd failed"
            sync
            ok "dd finished"
        else
            err "source not found: $src"
        fi
    fi
    echo
    pause
}

act_fs() {
    clear
    banner "FILESYSTEM CHECKS (fsck) + MOUNT"
    printf '%s\n' "$HL"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS 2>/dev/null
    echo
    if confirm "Open a mount helper (mount/unmount a partition)? Partitions shown above."; then
        echo "This image boots read/write by design; / is already usable."
    fi
    echo
    if [ "$(id -u)" = "0" ]; then
        banner "Quick fsck of unmounted ext filesystems"
        echo "Not auto-running to avoid surprises. Drop to shell for manual fsck."
    fi
    pause
}

act_recover() {
    clear
    banner "RECOVERY SCRIPTS / FUN TRICKS"
    printf '%s\n' "$HL"
    echo
    say " 1) Reset a lost root password (chroot-ish edit)"
    say " 2) Dump partition table to /tmp (backup GPT)"
    say " 3) Show boot + kernel cmdline as seen by this kernel"
    echo
    local c
    read -r -p "Pick 1-3, or Enter to cancel: " c
    case "$c" in
        1)
            if confirm "This opens the passwd file in an editor. Continue?"; then
                ${EDITOR:-vi} /etc/passwd 2>/dev/null && ok "reviewed passwd" || err "no editor"
            fi
            ;;
        2)
            fdisk -l > /tmp/partdump.txt 2>/dev/null && { ok "Saved to /tmp/partdump.txt"; cat /tmp/partdump.txt; } || err "failed"
            ;;
        3)
            cat /proc/cmdline 2>/dev/null; echo
            ;;
    esac
    echo
    pause
}

act_shell() {
    clear
    banner "DROP TO SHELL (type 'exit' to return)"
    printf '%s\n' "$HL"
    echo "  This is a full bash on the live toolkit root. Have fun. 😎"
    echo
    ${SHELL:-/bin/bash} 2>/dev/null || /bin/bash || /bin/sh
    echo
    ok "Back in the menu."
}

act_reboot() {
    if confirm "Reboot this machine?"; then
        sync
        reboot -f 2>/dev/null || echo b > /proc/sysrq-trigger 2>/dev/null || err "reboot failed"
    fi
}

act_poweroff() {
    if confirm "Power off this machine?"; then
        sync
        poweroff -f 2>/dev/null || echo o > /proc/sysrq-trigger 2>/dev/null || err "poweroff failed"
    fi
}

# ----------------------------------------------------------------------------
#  MENU
# ----------------------------------------------------------------------------
declare -a MENU_LABEL MENU_FN
MENU_LABEL=(
    "System information"
    "Storage / partitions"
    "Network"
    "SSH helper"
    "Image / dd"
    "Filesystem + fsck"
    "Recovery & tricks"
    "Drop to shell"
    "Reboot"
    "Power off"
)
MENU_FN=(act_info act_disks act_net act_ssh act_img act_fs act_recover act_shell act_reboot act_poweroff)
MENU_TOTAL=${#MENU_LABEL[@]}

draw_header() {
    printf '%s\n' "$HL"
    printf '%s%*s%s  %s%s v%s%s  %s%*s%s\n' \
        "$C_BG_BLUE$C_BOLD" 0 "" "$C_RESET" \
        "$C_BG_BLUE$C_BOLD$PROGNAME" "$C_RESET" "$C_BOLD$VERSION" "$C_RESET" \
        "$C_BG_BLUE$C_BOLD" 0 "" "$C_RESET"
    printf '%s\n' "$HL"
    printf '%s%s%s\n' "$C_DIM" "$(distro_line) · $(uname -m) · $(date '+%F %T')" "$C_RESET"
    printf '%s\n' "$HL"
}

draw_menu() {
    local i
    for ((i=0;i<MENU_TOTAL;i++)); do
        if [ "$i" -eq "$cur" ]; then
            printf '  %s➤ %-28s%s%s%s\n' "$C_BOLD$C_BG_GREEN$C_BLACK" "${MENU_LABEL[$i]}" "$C_RESET" "$C_DIM" "  (${i})" 
        else
            printf '    %-28s%s%s\n' "${MENU_LABEL[$i]}" "$C_DIM" "  (${i})"
        fi
    done
    printf '%s\n' "$HL"
    printf '%s ↑/↓ navigate · Enter run · 0-9 jump · q quit %s\n' "$C_DIM" "$C_RESET"
}

# ----------------------------------------------------------------------------
#  MAIN LOOP
# ----------------------------------------------------------------------------
bootstrap
clear
cur=0
stty -echo 2>/dev/null
while :; do
    draw_header
    draw_menu
    IFS= read -r -s -n1 key 2>/dev/null
    case "$key" in
        $'\x1b') # ESC: check for [A / [B
            read -r -s -n1 -t 0.05 k2 2>/dev/null
            if [ "$k2" = "[" ]; then
                read -r -s -n1 -t 0.05 k3 2>/dev/null
                case "$k3" in
                    A) cur=$(( (cur - 1 + MENU_TOTAL) % MENU_TOTAL )) ;;
                    B) cur=$(( (cur + 1) % MENU_TOTAL )) ;;
                esac
            fi
            ;;
        $'\n'|$'\r') clear; "${MENU_FN[$cur]}"; clear ;;
        [0-9]) [[ "$key" -lt "$MENU_TOTAL" ]] && { cur=$key; clear; "${MENU_FN[$cur]}"; clear; } ;;
        q|Q) break ;;
    esac
done
stty echo 2>/dev/null
clear
say "Bye from ${PROGNAME}. 🐾"
exit 0