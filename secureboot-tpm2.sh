#!/usr/bin/env bash
# =============================================================================
# secureboot-tpm2.sh — Secure Boot (sbctl) key workflow + TPM2 LUKS auto-unlock
# Dell XPS 14 (DA14260). Run ON THE INSTALLED SYSTEM:  sudo bash /root/secureboot-tpm2.sh
#
# The script auto-detects which phase applies:
#
#   PHASE 1 (firmware in Setup Mode, Secure Boot off):
#     - sbctl create-keys        : generate PK/KEK/db keypairs in /var/lib/sbctl
#     - sbctl enroll-keys -m     : enroll them (+ Microsoft vendor certs) into
#                                  the firmware's PK/KEK/db variables
#     - sbctl sign -s ...        : sign both UKIs and systemd-boot; -s saves
#                                  them to sbctl's database so its pacman hook
#                                  re-signs automatically on every update
#     -> then you reboot, ENABLE Secure Boot in BIOS, and run the script again
#
#   PHASE 2 (Secure Boot enabled):
#     - systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=<PCRS> <luks-part>
#       seals a new LUKS2 keyslot against the TPM. With PCR 7 the key is only
#       released while the Secure Boot configuration matches today's state, so
#       an attacker who disables Secure Boot or enrolls their own keys cannot
#       auto-unlock the disk. Your passphrase (keyslot 0) remains as recovery.
# =============================================================================
set -euo pipefail

say()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo."
command -v sbctl >/dev/null || die "sbctl not installed (pacman -S sbctl)."

CONF="/root/secureboot-tpm2.conf"
SB_ENROLL_MICROSOFT="yes"; TPM2_PCRS="7"; TPM2_WITH_PIN="yes"
# shellcheck source=/dev/null
[[ -f "$CONF" ]] && source "$CONF"

sb_state() {   # prints: setup-mode | enabled | disabled
    local status; status="$(sbctl status 2>/dev/null || true)"
    if   grep -qi 'Setup Mode:.*Enabled'  <<<"$status"; then echo setup-mode
    elif grep -qi 'Secure Boot:.*Enabled' <<<"$status"; then echo enabled
    else echo disabled; fi
}

find_luks_part() {
    lsblk -rpno NAME,FSTYPE | awk '$2=="crypto_LUKS"{print $1; exit}'
}

STATE="$(sb_state)"
say "Firmware state: $STATE"
sbctl status || true

case "$STATE" in
# -----------------------------------------------------------------------------
setup-mode)
    say "PHASE 1: creating and enrolling Secure Boot keys"

    if [[ ! -d /var/lib/sbctl/keys ]] && ! sbctl list-keys 2>/dev/null | grep -q .; then
        sbctl create-keys
    else
        warn "sbctl keys already exist — reusing them."
    fi

    if [[ "$SB_ENROLL_MICROSOFT" == "yes" ]]; then
        say "Enrolling your keys + Microsoft vendor certificates"
        sbctl enroll-keys -m
    else
        warn "Enrolling WITHOUT Microsoft certs. If Thunderbolt/GPU option ROMs"
        warn "fail after enabling Secure Boot, re-run with SB_ENROLL_MICROSOFT=yes."
        sbctl enroll-keys
    fi

    say "Signing boot chain (saved to sbctl DB for automatic re-signing)"
    sbctl sign -s /efi/EFI/Linux/arch-linux.efi
    sbctl sign -s /efi/EFI/Linux/arch-linux-fallback.efi
    sbctl sign -s /efi/EFI/systemd/systemd-bootx64.efi
    sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI

    say "Verification"
    sbctl verify

    cat <<'EOF'

PHASE 1 complete. Now:
  1. reboot into BIOS setup (F2)
  2. Security > Secure Boot > ENABLE (leave mode on 'Deployed'/standard)
  3. boot back into Arch — it must boot cleanly with Secure Boot on
  4. run this script again to enroll TPM2 auto-unlock (phase 2)
EOF
    ;;
# -----------------------------------------------------------------------------
enabled)
    say "PHASE 2: Secure Boot is active — verifying, then enrolling TPM2"
    sbctl verify || warn "Some files unsigned — investigate before relying on SB."

    LUKS_PART="$(find_luks_part)"
    if [[ -z "$LUKS_PART" ]]; then
        warn "No LUKS partition found. Nothing to enroll (unencrypted install?)."
        exit 0
    fi
    say "LUKS2 partition: $LUKS_PART"
    [[ -c /dev/tpmrm0 || -c /dev/tpm0 ]] || \
        die "No TPM device. Enable TPM 2.0 / Intel PTT in BIOS (Security menu)."

    echo "You will be asked for the existing LUKS passphrase (keyslot 0)."
    PIN_ARGS=()
    if [[ "$TPM2_WITH_PIN" == "yes" ]]; then
        PIN_ARGS=(--tpm2-with-pin=yes)
        echo "You will then choose a TPM2 PIN, required at every boot."
        echo "The TPM rate-limits guesses (dictionary-attack lockout), so a"
        echo "short numeric/alphanumeric PIN is acceptable — but it must not"
        echo "be guessable in the handful of tries the lockout allows."
    fi
    # Wipe any previous TPM2 slot so re-runs (e.g. after PCR changes) are clean
    systemd-cryptenroll --wipe-slot=tpm2 \
                        --tpm2-device=auto \
                        --tpm2-pcrs="$TPM2_PCRS" \
                        "${PIN_ARGS[@]}" \
                        "$LUKS_PART"

    say "TPM2 keyslot enrolled (PCRs: $TPM2_PCRS, PIN: ${TPM2_WITH_PIN})"
    cryptsetup luksDump "$LUKS_PART" | grep -A2 'systemd-tpm2' || true

    cat <<'EOF'

PHASE 2 complete. Reboot to test: you should get the TPM2 PIN prompt (if
enabled) instead of the full LUKS passphrase; with the PIN off, the disk
unlocks with no interaction.

Keep in mind:
  * Your passphrase still works and is your recovery path. NEVER remove it.
    Too many wrong PINs trips the TPM lockout — recover by entering the
    passphrase at the prompt (press ESC if needed), then wait or clear the
    lockout with:  tpm2_dictionarylockout --clear-lockout
  * If a BIOS update or Secure Boot key change alters PCR 7, auto-unlock stops
    and you'll be prompted for the passphrase — just re-run this script to
    re-enroll (you can pick a new PIN then).
  * To remove auto-unlock later:
      systemd-cryptenroll --wipe-slot=tpm2 <partition>
EOF
    ;;
# -----------------------------------------------------------------------------
disabled)
    cat <<'EOF'
Secure Boot is DISABLED and the firmware is NOT in Setup Mode.
To start phase 1, put the firmware into Setup Mode first:

  1. reboot into BIOS setup (F2)
  2. Security > Secure Boot: keep/enable the feature page, then choose
     "Delete all Secure Boot keys" / "Reset to Setup Mode"
     (on Dell firmware this is under Secure Boot > Expert Key Management:
      enable custom mode, then delete PK — deleting the Platform Key is what
      enters Setup Mode)
  3. keep Secure Boot itself OFF for now, save, and boot back into Arch
  4. run this script again — it will detect Setup Mode and run phase 1
EOF
    exit 1
    ;;
esac
