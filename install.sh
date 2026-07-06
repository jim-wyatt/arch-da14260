#!/usr/bin/env bash
# =============================================================================
# install.sh — Automated Arch Linux installation for Dell XPS 14 (DA14260)
#
# Design: GPT > ESP(/efi) + LUKS2(argon2id) > Btrfs subvolumes,
#         mkinitcpio-built UKIs in /efi/EFI/Linux, systemd-boot,
#         sbctl + TPM2 prepared here, finalized post-boot by
#         secureboot-tpm2.sh (Secure Boot keys can only be enrolled from
#         firmware Setup Mode, and TPM2 binding to PCR 7 is only meaningful
#         once Secure Boot is actually enabled).
#
# Run from the Archboot live environment (root shell). Your install files
# live on the second (ext4) partition of the Archboot stick:
#
#     lsblk -f                         # stick is usually /dev/sda; ext4 part e.g. sda3
#     mkdir -p /mnt/usb && mount /dev/sdXn /mnt/usb
#     cd /mnt/usb && bash install.sh
#
# THIS SCRIPT WIPES THE TARGET DISK. Read install.conf first.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${SCRIPT_DIR}/install.conf"
LOG="/tmp/xps14-install.log"
MNT="/mnt/install"

say()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

exec > >(tee -a "$LOG") 2>&1
say "Logging to $LOG"

# ----------------------------------------------------------------------------
# Load configuration
# ----------------------------------------------------------------------------
[[ -f "$CONF" ]] || die "install.conf not found next to install.sh"
# shellcheck source=install.conf
source "$CONF"

: "${TARGET_DISK:?TARGET_DISK not set}"
: "${HOSTNAME:?HOSTNAME not set}"
: "${USERNAME:?USERNAME not set}"
: "${TIMEZONE:?}" "${LOCALE:?}" "${KEYMAP:?}"
: "${ROOT_FS:=btrfs}" "${ESP_SIZE_MIB:=1024}" "${ENCRYPT:=yes}"
: "${LUKS_ALLOW_DISCARDS:=yes}" "${SWAP_MODE:=zram}" "${SWAP_SIZE_GIB:=32}"
: "${DESKTOP:=gnome}" "${TPM2_PCRS:=7}" "${SB_ENROLL_MICROSOFT:=yes}"
: "${TPM2_WITH_PIN:=yes}" "${SNAPPER:=yes}" "${HARDENING:=yes}"
: "${SNAP_HOURLY:=12}" "${SNAP_DAILY:=7}" "${SNAP_WEEKLY:=4}"
: "${SNAP_MONTHLY:=6}" "${SNAP_YEARLY:=1}" "${SNAP_PACMAN:=30}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
say "Running pre-flight checks"

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -d /sys/firmware/efi/efivars ]] || \
    die "Not booted in UEFI mode. Reboot and boot the USB via the F12 UEFI menu."
[[ -b "$TARGET_DISK" ]] || die "Target disk $TARGET_DISK not found. Check 'lsblk'.
If the NVMe drive is missing, set BIOS > Storage to AHCI/NVMe (not RAID On)."

# Intel VMD (BIOS 'RAID On' mode): bootable, but the initramfs needs the
# vmd module or the installed system won't find its own disk.
VMD_MODULE=""
if lspci 2>/dev/null | grep -qi 'Volume Management Device'; then
    warn "Intel VMD detected (BIOS storage mode 'RAID On')."
    warn "Adding 'vmd' to initramfs MODULES so the installed system can boot."
    VMD_MODULE="vmd"
fi

# TPM2 presence (informational; enrollment happens post-boot)
if [[ -c /dev/tpmrm0 || -c /dev/tpm0 ]]; then
    say "TPM2 device present — TPM2 auto-unlock will be available post-install."
else
    warn "No TPM device visible. TPM2 auto-unlock will not work; check that"
    warn "the TPM/PTT is enabled in BIOS (Security > TPM 2.0 / Intel PTT)."
fi

say "Checking network connectivity"
if ! curl -s --max-time 8 https://archlinux.org > /dev/null; then
    warn "No internet connection detected."
    warn "Wi-Fi via iwd:            iwctl station wlan0 connect \"SSID\""
    warn "Wi-Fi via NetworkManager: nmcli device wifi connect \"SSID\" password \"PASS\""
    die "Connect to the internet, then re-run install.sh."
fi
timedatectl set-ntp true 2>/dev/null || true

# ----------------------------------------------------------------------------
# Passwords (prompt if not preseeded)
# ----------------------------------------------------------------------------
ask_password() {
    local prompt="$1" p1 p2
    while true; do
        read -rs -p "$prompt: " p1; echo >&2
        read -rs -p "$prompt (again): " p2; echo >&2
        [[ -n "$p1" && "$p1" == "$p2" ]] && { printf '%s' "$p1"; return; }
        echo "Passwords empty or mismatched, try again." >&2
    done
}
[[ -n "${ROOT_PASSWORD}" ]] || ROOT_PASSWORD="$(ask_password "root password")"
[[ -n "${USER_PASSWORD}" ]] || USER_PASSWORD="$(ask_password "password for user '${USERNAME}'")"

LUKS_PASSPHRASE=""
if [[ "$ENCRYPT" == "yes" ]]; then
    echo
    echo "This passphrase goes into LUKS2 keyslot 0. It remains your recovery"
    echo "credential forever, even after TPM2 auto-unlock is enrolled — do not"
    echo "lose it."
    LUKS_PASSPHRASE="$(ask_password "LUKS disk-encryption passphrase")"
fi

# ----------------------------------------------------------------------------
# Final confirmation
# ----------------------------------------------------------------------------
echo
lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL "$TARGET_DISK"
echo
warn "ALL DATA ON ${TARGET_DISK} WILL BE DESTROYED."
read -rp "Type WIPE to continue: " CONFIRM
[[ "$CONFIRM" == "WIPE" ]] || die "Aborted by user."

# ----------------------------------------------------------------------------
# Partitioning (GPT)
#   p1  ESP    FAT32, ESP_SIZE_MIB, type ef00, mounted at /efi
#   p2  SWAP   (only if SWAP_MODE=partition) type 8200
#   p2/3 ROOT  LUKS2 container (or bare fs), type 8304 (Linux x86-64 root)
# ----------------------------------------------------------------------------
say "Partitioning ${TARGET_DISK}"
umount -R "$MNT" 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true
swapoff -a 2>/dev/null || true

sgdisk --zap-all "$TARGET_DISK"
sgdisk -n "1:0:+${ESP_SIZE_MIB}MiB" -t 1:ef00 -c 1:"EFI" "$TARGET_DISK"
if [[ "$SWAP_MODE" == "partition" ]]; then
    warn "Note: a plain swap partition is NOT covered by LUKS. Prefer zram."
    sgdisk -n "2:0:+${SWAP_SIZE_GIB}GiB" -t 2:8200 -c 2:"SWAP" "$TARGET_DISK"
    sgdisk -n 3:0:0 -t 3:8304 -c 3:"ROOT" "$TARGET_DISK"
    ROOT_PART_NUM=3; SWAP_PART_NUM=2
else
    sgdisk -n 2:0:0 -t 2:8304 -c 2:"ROOT" "$TARGET_DISK"
    ROOT_PART_NUM=2; SWAP_PART_NUM=""
fi
partprobe "$TARGET_DISK"; udevadm settle; sleep 2

part() { local n=$1
         if [[ "$TARGET_DISK" == *nvme* || "$TARGET_DISK" == *mmcblk* ]]; then
             echo "${TARGET_DISK}p${n}"; else echo "${TARGET_DISK}${n}"; fi; }
ESP_PART="$(part 1)"
ROOT_PART="$(part "$ROOT_PART_NUM")"
if [[ -n "$SWAP_PART_NUM" ]]; then SWAP_PART="$(part "$SWAP_PART_NUM")"; else SWAP_PART=""; fi

# ----------------------------------------------------------------------------
# LUKS2 container
#   - LUKS2 header, argon2id memory-hard KDF (GPU/ASIC-resistant)
#   - cipher aes-xts-plain64, 512-bit key (256-bit effective AES-XTS strength;
#     hardware-accelerated by AES-NI on this CPU)
#   - passphrase -> keyslot 0 (recovery); TPM2 keyslot added post-boot
# ----------------------------------------------------------------------------
ROOT_DEV="$ROOT_PART"
if [[ "$ENCRYPT" == "yes" ]]; then
    say "Creating LUKS2 container on ${ROOT_PART}"
    printf '%s' "$LUKS_PASSPHRASE" | cryptsetup luksFormat \
        --type luks2 \
        --pbkdf argon2id \
        --cipher aes-xts-plain64 --key-size 512 \
        --label cryptroot \
        --batch-mode "$ROOT_PART" -
    OPEN_OPTS=()
    [[ "$LUKS_ALLOW_DISCARDS" == "yes" ]] && OPEN_OPTS+=(--allow-discards)
    printf '%s' "$LUKS_PASSPHRASE" | \
        cryptsetup open "${OPEN_OPTS[@]}" "$ROOT_PART" cryptroot -
    ROOT_DEV="/dev/mapper/cryptroot"
fi

# ----------------------------------------------------------------------------
# Filesystems + Btrfs subvolume scheme
#   @          -> /                        (snapshot/rollback unit)
#   @home      -> /home
#   @log       -> /var/log                 (survives root rollbacks)
#   @pkg       -> /var/cache/pacman/pkg    (excluded from snapshots)
#   @snapshots -> /.snapshots              (snapper/btrbk target)
# ----------------------------------------------------------------------------
say "Creating filesystems"
mkfs.fat -F32 -n EFI "$ESP_PART"
[[ -n "$SWAP_PART" ]] && mkswap -L swap "$SWAP_PART"

mkdir -p "$MNT"
if [[ "$ROOT_FS" == "btrfs" ]]; then
    mkfs.btrfs -f -L archroot "$ROOT_DEV"
    mount "$ROOT_DEV" "$MNT"
    for sv in @ @home @log @pkg @snapshots; do
        btrfs subvolume create "$MNT/$sv"
    done
    umount "$MNT"
    BTRFS_OPTS="noatime,compress=zstd:1"
    mount -o "$BTRFS_OPTS,subvol=@" "$ROOT_DEV" "$MNT"
    mkdir -p "$MNT"/{home,var/log,var/cache/pacman/pkg,.snapshots,efi}
    mount -o "$BTRFS_OPTS,subvol=@home"      "$ROOT_DEV" "$MNT/home"
    mount -o "$BTRFS_OPTS,subvol=@log"       "$ROOT_DEV" "$MNT/var/log"
    mount -o "$BTRFS_OPTS,subvol=@pkg"       "$ROOT_DEV" "$MNT/var/cache/pacman/pkg"
    mount -o "$BTRFS_OPTS,subvol=@snapshots" "$ROOT_DEV" "$MNT/.snapshots"
else
    mkfs.ext4 -F -L archroot "$ROOT_DEV"
    mount "$ROOT_DEV" "$MNT"
    mkdir -p "$MNT/efi"
fi
mount "$ESP_PART" "$MNT/efi"
[[ -n "$SWAP_PART" ]] && swapon "$SWAP_PART"

# ----------------------------------------------------------------------------
# Package selection
# ----------------------------------------------------------------------------
PKGS=(
    base linux linux-firmware intel-ucode
    btrfs-progs dosfstools e2fsprogs
    networkmanager bluez bluez-utils
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
    sof-firmware                       # audio DSP firmware (required here)
    thermald power-profiles-daemon fwupd
    sbctl efibootmgr tpm2-tools        # Secure Boot + TPM2 workflow
    sudo vim nano bash-completion
    terminus-font
)
[[ "$ENCRYPT" == "yes" ]]    && PKGS+=(cryptsetup)
[[ "$SWAP_MODE" == "zram" ]] && PKGS+=(zram-generator)
[[ "$SNAPPER" == "yes" && "$ROOT_FS" == "btrfs" ]] && PKGS+=(snapper snap-pac)
[[ "$HARDENING" == "yes" ]]  && PKGS+=(nftables apparmor)
case "$DESKTOP" in
    gnome) PKGS+=(gnome gnome-tweaks) ;;
    kde)   PKGS+=(plasma konsole dolphin sddm) ;;
    none)  : ;;
    *)     warn "Unknown DESKTOP='$DESKTOP', skipping desktop install" ;;
esac
# shellcheck disable=SC2206
PKGS+=($EXTRA_PACKAGES)

# ----------------------------------------------------------------------------
# Install base system (pacstrap if available, else pacman --root)
# ----------------------------------------------------------------------------
say "Installing packages"
if ! grep -q '^Server' /etc/pacman.d/mirrorlist 2>/dev/null; then
    mkdir -p /etc/pacman.d
    echo "Server = ${FALLBACK_MIRROR}" > /etc/pacman.d/mirrorlist
fi

if command -v pacstrap >/dev/null 2>&1; then
    pacstrap -K "$MNT" "${PKGS[@]}"
else
    mkdir -p "$MNT/var/lib/pacman"
    pacman --root "$MNT" --cachedir "$MNT/var/cache/pacman/pkg" \
           --noconfirm -Sy "${PKGS[@]}"
    mkdir -p "$MNT/etc/pacman.d"
    cp /etc/pacman.d/mirrorlist "$MNT/etc/pacman.d/mirrorlist"
    chroot "$MNT" /bin/bash -c \
        "pacman-key --init && pacman-key --populate archlinux" || \
        warn "pacman-key init failed; run it manually after first boot."
fi

# ----------------------------------------------------------------------------
# fstab
# ----------------------------------------------------------------------------
say "Writing fstab"
if command -v genfstab >/dev/null 2>&1; then
    genfstab -U "$MNT" >> "$MNT/etc/fstab"
else
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
    ESP_UUID=$(blkid -s UUID -o value "$ESP_PART")
    {
        if [[ "$ROOT_FS" == "btrfs" ]]; then
            echo "UUID=$ROOT_UUID /                     btrfs $BTRFS_OPTS,subvol=@          0 0"
            echo "UUID=$ROOT_UUID /home                 btrfs $BTRFS_OPTS,subvol=@home      0 0"
            echo "UUID=$ROOT_UUID /var/log              btrfs $BTRFS_OPTS,subvol=@log       0 0"
            echo "UUID=$ROOT_UUID /var/cache/pacman/pkg btrfs $BTRFS_OPTS,subvol=@pkg       0 0"
            echo "UUID=$ROOT_UUID /.snapshots           btrfs $BTRFS_OPTS,subvol=@snapshots 0 0"
        else
            echo "UUID=$ROOT_UUID / ext4 defaults,noatime 0 1"
        fi
        echo "UUID=$ESP_UUID /efi vfat defaults,umask=0077 0 2"
        if [[ -n "$SWAP_PART" ]]; then
            echo "UUID=$(blkid -s UUID -o value "$SWAP_PART") none swap defaults 0 0"
        fi
    } >> "$MNT/etc/fstab"
fi

# ----------------------------------------------------------------------------
# Chroot helper
# ----------------------------------------------------------------------------
CHROOT() { if command -v arch-chroot >/dev/null 2>&1; then arch-chroot "$MNT" "$@";
           else for d in sys dev dev/pts run; do
                    mountpoint -q "$MNT/$d" || mount --bind "/$d" "$MNT/$d" 2>/dev/null || true
                done
                mountpoint -q "$MNT/proc" || mount -t proc proc "$MNT/proc"
                mountpoint -q "$MNT/sys/firmware/efi/efivars" || \
                    mount -t efivarfs efivarfs "$MNT/sys/firmware/efi/efivars" 2>/dev/null || true
                chroot "$MNT" "$@"; fi; }

# ----------------------------------------------------------------------------
# Base system configuration
# ----------------------------------------------------------------------------
say "Configuring the installed system"
CHROOT ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
CHROOT hwclock --systohc
sed -i "s/^#\s*${LOCALE}/${LOCALE}/" "$MNT/etc/locale.gen"
CHROOT locale-gen
echo "LANG=${LOCALE}" > "$MNT/etc/locale.conf"
{ echo "KEYMAP=${KEYMAP}"; echo "FONT=ter-v16n"; } > "$MNT/etc/vconsole.conf"
echo "$HOSTNAME" > "$MNT/etc/hostname"
cat > "$MNT/etc/hosts" <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}
EOF

if [[ "$SWAP_MODE" == "zram" ]]; then
    mkdir -p "$MNT/etc/systemd"
    cat > "$MNT/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF
fi

# ----------------------------------------------------------------------------
# Kernel command line  (/etc/kernel/cmdline — consumed by the UKI build)
#   Encrypted:  systemd-cryptsetup in the initrd (sd-encrypt hook) opens the
#   LUKS volume named by rd.luks.name. tpm2-device=auto is present from day
#   one: before enrollment it is a no-op and systemd falls back to asking for
#   the passphrase; after secureboot-tpm2.sh enrolls the TPM2 keyslot, boots
#   unlock automatically.
# ----------------------------------------------------------------------------
say "Writing kernel command line"
ROOTFLAGS=""
[[ "$ROOT_FS" == "btrfs" ]] && ROOTFLAGS=" rootflags=subvol=@"
if [[ "$ENCRYPT" == "yes" ]]; then
    LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
    LUKS_OPTS="tpm2-device=auto"
    [[ "$LUKS_ALLOW_DISCARDS" == "yes" ]] && LUKS_OPTS="discard,${LUKS_OPTS}"
    CMDLINE="rd.luks.name=${LUKS_UUID}=cryptroot rd.luks.options=${LUKS_UUID}=${LUKS_OPTS} root=/dev/mapper/cryptroot${ROOTFLAGS} rw quiet mem_sleep_default=s2idle"
else
    ROOT_FS_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
    CMDLINE="root=UUID=${ROOT_FS_UUID}${ROOTFLAGS} rw quiet mem_sleep_default=s2idle"
fi
# AppArmor must be selected on the kernel command line (baked into the UKI,
# so it's covered by the Secure Boot signature and not editable at boot).
[[ "$HARDENING" == "yes" ]] && \
    CMDLINE="${CMDLINE} lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
# User-supplied extras (e.g. graphics workarounds like xe.force_probe=*)
[[ -n "${EXTRA_CMDLINE:-}" ]] && CMDLINE="${CMDLINE} ${EXTRA_CMDLINE}"
mkdir -p "$MNT/etc/kernel"
echo "$CMDLINE" > "$MNT/etc/kernel/cmdline"

# ----------------------------------------------------------------------------
# UKI pipeline (mkinitcpio)
#   - systemd-based hook set; sd-encrypt handles LUKS in the initrd
#   - the 'linux' preset is switched from split kernel+initramfs to UKIs:
#       /efi/EFI/Linux/arch-linux.efi          (default)
#       /efi/EFI/Linux/arch-linux-fallback.efi (no-autodetect rescue image)
#   - each UKI bundles: kernel + initrd + microcode + /etc/kernel/cmdline
#     + os-release, so the whole boot payload is one signable PE binary
#   - pacman's mkinitcpio hooks rebuild the UKIs on every kernel/firmware
#     update automatically; sbctl's pacman hook then re-signs them
# ----------------------------------------------------------------------------
say "Configuring mkinitcpio for Unified Kernel Images"
HOOKS="base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck"
[[ "$ENCRYPT" == "yes" ]] && \
    HOOKS="base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck"
sed -i "s/^HOOKS=.*/HOOKS=(${HOOKS})/" "$MNT/etc/mkinitcpio.conf"
[[ -n "$VMD_MODULE" ]] && \
    sed -i "s/^MODULES=.*/MODULES=(${VMD_MODULE})/" "$MNT/etc/mkinitcpio.conf"

mkdir -p "$MNT/efi/EFI/Linux"
cat > "$MNT/etc/mkinitcpio.d/linux.preset" <<'EOF'
# mkinitcpio preset: build UKIs instead of split kernel/initramfs
ALL_kver="/boot/vmlinuz-linux"

PRESETS=('default' 'fallback')

default_uki="/efi/EFI/Linux/arch-linux.efi"
default_options="--splash=/usr/share/systemd/bootctl/splash-arch.bmp"

fallback_uki="/efi/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
EOF

say "Building Unified Kernel Images"
CHROOT mkinitcpio -P

# ----------------------------------------------------------------------------
# systemd-boot
#   Installed to the ESP; no loader entries are written because systemd-boot
#   auto-discovers UKIs in EFI/Linux/. loader.conf only sets menu behavior.
# ----------------------------------------------------------------------------
say "Installing systemd-boot"
CHROOT bootctl install

cat > "$MNT/efi/loader/loader.conf" <<'EOF'
default arch-linux.efi
timeout 3
console-mode auto
editor no
EOF

# Enable automatic systemd-boot updates on package upgrades
CHROOT systemctl enable systemd-boot-update.service || true

# ----------------------------------------------------------------------------
# Users, sudo, services
# ----------------------------------------------------------------------------
say "Creating users"
CHROOT useradd -mG wheel -s /bin/bash "$USERNAME"
printf 'root:%s\n' "$ROOT_PASSWORD" | CHROOT chpasswd
printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | CHROOT chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > "$MNT/etc/sudoers.d/10-wheel"
chmod 440 "$MNT/etc/sudoers.d/10-wheel"

# ----------------------------------------------------------------------------
# Snapper: logarithmic timeline retention + pacman pre/post snapshots
#   snapper's create-config insists on creating its own .snapshots subvolume
#   inside @, so: unmount ours -> create config -> delete snapper's subvolume
#   -> remount our @snapshots. Retention is geometric: 12h/7d/4w/6m/1y.
# ----------------------------------------------------------------------------
if [[ "$SNAPPER" == "yes" && "$ROOT_FS" == "btrfs" ]]; then
    say "Configuring snapper (logarithmic retention)"
    umount "$MNT/.snapshots"
    rmdir "$MNT/.snapshots"
    CHROOT snapper --no-dbus -c root create-config /
    CHROOT btrfs subvolume delete /.snapshots
    mkdir -p "$MNT/.snapshots"
    mount -o "$BTRFS_OPTS,subvol=@snapshots" "$ROOT_DEV" "$MNT/.snapshots"
    chmod 750 "$MNT/.snapshots"

    SNAPCFG="$MNT/etc/snapper/configs/root"
    set_snap() { sed -i "s|^${1}=.*|${1}=\"${2}\"|" "$SNAPCFG"; }
    set_snap TIMELINE_CREATE        yes
    set_snap TIMELINE_MIN_AGE       1800
    set_snap TIMELINE_LIMIT_HOURLY  "$SNAP_HOURLY"
    set_snap TIMELINE_LIMIT_DAILY   "$SNAP_DAILY"
    set_snap TIMELINE_LIMIT_WEEKLY  "$SNAP_WEEKLY"
    set_snap TIMELINE_LIMIT_MONTHLY "$SNAP_MONTHLY"
    set_snap TIMELINE_LIMIT_YEARLY  "$SNAP_YEARLY"
    set_snap NUMBER_CLEANUP         yes
    set_snap NUMBER_LIMIT           "$SNAP_PACMAN"
    set_snap NUMBER_LIMIT_IMPORTANT 10
    set_snap EMPTY_PRE_POST_CLEANUP yes
    set_snap ALLOW_USERS            "$USERNAME"

    CHROOT systemctl enable snapper-timeline.timer snapper-cleanup.timer
fi

# ----------------------------------------------------------------------------
# Hardening baseline (firewall, sysctl, AppArmor)
# ----------------------------------------------------------------------------
if [[ "$HARDENING" == "yes" ]]; then
    say "Applying hardening baseline"

    # nftables: default-deny inbound; established/related, loopback, ICMP,
    # IPv6 neighbor discovery allowed. Outbound unrestricted (dev laptop).
    cat > "$MNT/etc/nftables.conf" <<'EOF'
#!/usr/bin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iif lo accept
        ip protocol icmp accept
        meta l4proto ipv6-icmp accept
        # To run a dev server reachable from the LAN, add e.g.:
        # tcp dport 8080 accept
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF

    # sysctl: kernel attack-surface reduction, developer-friendly choices.
    # ptrace_scope=1 still allows debugging your own child processes
    # (gdb ./prog, strace prog); attaching to an unrelated running process
    # needs sudo — same default as Ubuntu.
    cat > "$MNT/etc/sysctl.d/99-hardening.conf" <<'EOF'
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.kexec_load_disabled = 1
kernel.perf_event_paranoid = 2
fs.protected_fifos = 1
fs.protected_regular = 2
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF

    CHROOT systemctl enable nftables apparmor
fi

say "Enabling services"
CHROOT systemctl enable NetworkManager bluetooth fstrim.timer \
       systemd-timesyncd thermald power-profiles-daemon
case "$DESKTOP" in
    gnome) CHROOT systemctl enable gdm ;;
    kde)   CHROOT systemctl enable sddm ;;
esac

# ----------------------------------------------------------------------------
# Hand-off: copy log + post-boot scripts into the new system
# ----------------------------------------------------------------------------
cp "$LOG" "$MNT/root/xps14-install.log" || true
for f in post-install.sh secureboot-tpm2.sh; do
    [[ -f "$SCRIPT_DIR/$f" ]] && install -m 755 "$SCRIPT_DIR/$f" "$MNT/root/$f"
done
# secureboot-tpm2.sh needs two settings from this config
cat > "$MNT/root/secureboot-tpm2.conf" <<EOF
SB_ENROLL_MICROSOFT="${SB_ENROLL_MICROSOFT}"
TPM2_PCRS="${TPM2_PCRS}"
TPM2_WITH_PIN="${TPM2_WITH_PIN}"
EOF

sync
say "Installation finished successfully."
cat <<EOF

Next steps:
  1. reboot — remove the USB stick when the screen blanks.
     (Secure Boot is still OFF; the system boots unsigned UKIs for now.
      You'll be asked for the LUKS passphrase at boot.)
  2. Log in, then:              sudo bash /root/post-install.sh
  3. Secure Boot + TPM2 unlock: sudo bash /root/secureboot-tpm2.sh
     and follow its two-phase instructions (Setup Mode -> sign -> enable SB
     -> enroll TPM2). See README.md for the full walkthrough.
EOF
