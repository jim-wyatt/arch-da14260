#!/usr/bin/env bash
# =============================================================================
# post-install.sh — Run ONCE after first boot into the installed system:
#     sudo bash /root/post-install.sh
# Firmware updates, hardware verification, and quality-of-life checks
# for the Dell XPS 14 (DA14260).
# =============================================================================
set -uo pipefail

say()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

say "Syncing packages"
pacman -Syu --noconfirm

say "Checking Dell firmware updates via LVFS (fwupd)"
fwupdmgr refresh --force || true
fwupdmgr get-updates || true
echo "If updates are listed above, apply them with:  fwupdmgr update"

say "Hardware verification"
echo "--- CPU ---"
lscpu | grep 'Model name' || true

echo "--- Graphics driver (expect 'xe' or 'i915' in use) ---"
lspci -k | grep -A3 -i 'vga\|display' || true

echo "--- Wi-Fi / Bluetooth ---"
lspci -k | grep -A3 -i 'network' || true
ip link show | grep -E 'wl|en' || true
if ! ip link show | grep -q wl; then
    warn "No wireless interface found. Check:  dmesg | grep -i iwlwifi"
    warn "Make sure linux-firmware is installed and up to date."
fi

echo "--- Audio (expect sof-firmware loaded) ---"
if dmesg | grep -qi 'sof-audio'; then
    echo "SOF audio firmware loaded."
else
    warn "SOF audio not detected in dmesg. Verify sof-firmware is installed,"
    warn "then reboot. Check:  dmesg | grep -i sof"
fi

echo "--- NVMe ---"
nvme list 2>/dev/null || lsblk -d -o NAME,MODEL,SIZE

echo "--- Suspend mode (expect s2idle in brackets) ---"
cat /sys/power/mem_sleep 2>/dev/null || true

echo "--- Secure Boot / TPM2 status ---"
command -v sbctl >/dev/null && sbctl status || true
[[ -c /dev/tpmrm0 || -c /dev/tpm0 ]] && echo "TPM2 device present." || \
    warn "No TPM device — enable TPM 2.0 / Intel PTT in BIOS for auto-unlock."
echo "Secure Boot + TPM2 unlock setup: sudo bash /root/secureboot-tpm2.sh"

echo "--- Unified Kernel Images on the ESP ---"
ls -lh /efi/EFI/Linux/ 2>/dev/null || warn "/efi/EFI/Linux missing?"

echo "--- Snapshots (snapper) ---"
command -v snapper >/dev/null && snapper list 2>/dev/null | tail -5 || \
    echo "snapper not installed (SNAPPER=no or ext4 root)."

echo "--- Firewall / AppArmor ---"
systemctl is-active nftables 2>/dev/null && nft list ruleset | head -5 || true
command -v aa-status >/dev/null && aa-status --summary 2>/dev/null || true

say "Notes specific to this laptop"
cat <<'EOF'
* Webcam: the XPS 14 uses an Intel MIPI (IPU) camera. Support in Linux is
  still maturing; if the camera does not appear, check the Arch Wiki page
  for your laptop and the 'libcamera' / IPU driver status before assuming
  a misconfiguration.
* Battery life: power-profiles-daemon is enabled. Switch profiles from the
  GNOME/KDE power menu, or:  powerprofilesctl set power-saver
* Fingerprint reader (if fitted): install 'fprintd' and enroll with
  'fprintd-enroll'. Goodix/Broadcom support varies by SKU.
* BIOS updates arrive through fwupd (LVFS) — no Windows needed.
EOF

say "Done. Reboot recommended if firmware was updated."
