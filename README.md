# Automated Arch Linux Installation — Dell XPS 14 (DA14260)

This kit installs Arch Linux on the 2026 Dell XPS 14 (model DA14260) from the
Archboot live image:

```
https://release.archboot.com/x86_64/latest/iso/archboot-2026.07.05-01.02-7.1.2-arch3-1-x86_64.iso
```

You've already written that ISO to a USB stick and added a second read-write
ext4 partition — put the contents of this folder on that ext4 partition and
you're ready.

## Files

`install.conf` — every tunable (disk, identity, encryption, PCR policy, swap,
desktop). `install.sh` — the automated installer run from the Archboot shell.
`secureboot-tpm2.sh` — two-phase post-boot script: sbctl key enrollment +
signing, then TPM2 unlock enrollment. `post-install.sh` — firmware updates via
fwupd and a hardware sanity check. `prepare-usb.sh` — media prep helper (you
can ignore it; your stick is already made).

---

# System design

## 1. Partitioning layout

GPT on the internal NVMe SSD (`/dev/nvme0n1`):

```
nvme0n1
├─ p1  EFI System Partition   1 GiB   FAT32, type ef00, mounted /efi
└─ p2  ROOT                   rest    type 8304, LUKS2 container
        └─ cryptroot (dm-crypt)
            └─ Btrfs "archroot" (subvolumes below)
```

The ESP is 1 GiB because the UKI pipeline stores whole kernels+initrds on it:
the fallback UKI alone can exceed 100 MiB (no `autodetect`), and you want
headroom for a second kernel (e.g. `linux-lts`) later. The ESP mounts at
`/efi`, not `/boot` — `/boot` stays inside the encrypted root, so the only
plaintext on disk is the signed UKIs and systemd-boot itself. If you set
`SWAP_MODE="partition"`, an unencrypted swap partition is inserted as p2 and
root becomes p3, but zram (the default) is the better fit for this design
since a plain swap partition would leak memory contents around the encryption.

## 2. LUKS2 design

`cryptsetup luksFormat --type luks2 --pbkdf argon2id --cipher aes-xts-plain64
--key-size 512 --label cryptroot` gives you a LUKS2 header with the
memory-hard argon2id KDF (resists GPU/ASIC passphrase cracking) and AES-XTS
with a 512-bit key (256-bit effective strength, hardware-accelerated by the
CPU's AES instructions, so throughput impact on the NVMe drive is minimal).

Keyslot layout: **keyslot 0 = your passphrase**, created at install time; it
is the permanent recovery credential. **A TPM2-sealed keyslot** is added later
by `secureboot-tpm2.sh` phase 2. Never wipe keyslot 0 — if the TPM ever
refuses to unseal (BIOS update, board replacement, PCR change), the passphrase
is your way back in.

With `LUKS_ALLOW_DISCARDS="yes"` (default) the mapping passes TRIM through
(`discard` in `rd.luks.options`, `--allow-discards` during install), which
keeps the SSD healthy at the cost of revealing which blocks are unused — the
standard trade-off accepted on personal machines.

## 3. Btrfs subvolume scheme

```
subvolume    mountpoint              purpose
@            /                       the snapshot/rollback unit
@home        /home                   user data — versioned separately from /
@log         /var/log                logs survive a root rollback (debugging)
@pkg         /var/cache/pacman/pkg   package cache — excluded from snapshots
@snapshots   /.snapshots             target for snapper/btrbk
```

All mounted `noatime,compress=zstd:1`. Splitting `@home`, `@log`, and `@pkg`
out of `@` means a snapshot-rollback of the OS never rewinds your files, your
logs, or churns gigabytes of cached packages. The layout is snapper-ready:
`pacman -S snapper snap-pac` after install and point it at `/.snapshots`.

## 4. UKI pipeline

A Unified Kernel Image is a single PE/EFI binary bundling the kernel, initrd,
microcode, embedded kernel command line (from `/etc/kernel/cmdline`), and
os-release. One file = one signature = the whole boot payload is covered by
Secure Boot, and the baked-in cmdline can't be edited from the boot menu
(`editor no` in loader.conf closes the classic `init=/bin/bash` hole).

The pipeline, end to end:

```
/etc/kernel/cmdline ─┐
kernel + microcode ──┼─> mkinitcpio -P ──> /efi/EFI/Linux/arch-linux.efi
initrd (systemd,     │                     /efi/EFI/Linux/arch-linux-fallback.efi
 sd-encrypt hooks) ──┘                            │
                                                  └─> sbctl pacman hook signs
                                                      └─> systemd-boot auto-lists
```

`install.sh` switches `/etc/mkinitcpio.d/linux.preset` from split
kernel/initramfs to `default_uki`/`fallback_uki`. On every kernel,
linux-firmware, or microcode update, pacman's mkinitcpio hook rebuilds both
UKIs in place and sbctl's hook re-signs them — zero manual steps for the life
of the system. The fallback UKI is built without `autodetect` (all modules) as
the rescue option if the default image won't boot.

mkinitcpio hooks used:
`base systemd autodetect microcode modconf kms keyboard sd-vconsole block
sd-encrypt filesystems fsck` — the systemd initrd plus `sd-encrypt`, which
reads `rd.luks.*` from the cmdline and also implements the TPM2 unlock. If the
installer detects Intel VMD (BIOS storage "RAID On"), it adds `vmd` to
`MODULES=` so the initrd can see the NVMe drive.

Kernel command line (encrypted default):

```
rd.luks.name=<luks-uuid>=cryptroot
rd.luks.options=<luks-uuid>=discard,tpm2-device=auto
root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet mem_sleep_default=s2idle
```

`tpm2-device=auto` is present from day one: before enrollment it's a no-op
and systemd falls back to the passphrase prompt; after phase 2 it unlocks
silently.

## 5. systemd-boot configuration

`bootctl install` places systemd-boot on the ESP. There are **no loader
entry files** — systemd-boot discovers UKIs in `EFI/Linux/` by itself
(Boot Loader Specification type 2). `loader.conf`:

```
default arch-linux.efi
timeout 3
console-mode auto
editor no
```

`systemd-boot-update.service` is enabled so the loader binary on the ESP is
refreshed after systemd upgrades (sbctl re-signs it via its hook). Hold the
space bar during boot if the 3-second menu is too quick; the fallback UKI is
selectable there.

## 6. sbctl key workflow (Secure Boot)

Secure Boot enrollment can't happen inside the installer — the firmware must
be in Setup Mode, which requires a trip through BIOS setup. So it's a
post-first-boot procedure driven by `secureboot-tpm2.sh`, which detects the
firmware state and runs the right phase:

**Enter Setup Mode:** F2 → Security → Secure Boot → Expert Key Management →
enable custom mode → delete the Platform Key (PK). Deleting PK is what puts
the firmware in Setup Mode. Leave Secure Boot itself OFF, save, boot Arch.

**Phase 1** (script detects Setup Mode): `sbctl create-keys` generates your
PK/KEK/db keypairs under `/var/lib/sbctl`; `sbctl enroll-keys -m` writes them
to the firmware **together with Microsoft's vendor certificates** — the `-m`
matters on this laptop, because Thunderbolt/GPU option ROMs are signed only by
Microsoft and firmware that can't verify them may fail in ugly ways;
`sbctl sign -s` signs both UKIs, `systemd-bootx64.efi`, and `BOOTX64.EFI`, and
`-s` registers each path in sbctl's database so its pacman hook re-signs them
automatically on every future update. `sbctl verify` confirms.

**Enable Secure Boot:** reboot to BIOS, switch Secure Boot on, boot Arch. It
must boot cleanly — the entire chain (loader + UKI) is now signature-checked
by the firmware against your db.

## 7. TPM2 auto-unlock

**Phase 2** (script detects Secure Boot enabled) runs:

```
systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto \
    --tpm2-pcrs=7 --tpm2-with-pin=yes /dev/nvme0n1p2
```

This seals a random key into the TPM, released only while **PCR 7** (the
Secure Boot policy measurement) matches its state at enrollment, **and** only
after you enter the TPM2 PIN you choose during enrollment. The security
property: the disk unlocks only when *your* signed boot chain is running *and*
you supply the PIN. Someone who disables Secure Boot, enrolls their own keys,
or boots other media gets no key from the TPM regardless of PIN; someone who
boots your unmodified machine hits the PIN prompt, and the TPM's built-in
anti-hammering (dictionary-attack lockout) rate-limits guesses — which is why
a fairly short PIN is acceptable where a short LUKS passphrase wouldn't be.
Too many bad PINs trips the lockout: recover with the LUKS passphrase, then
`tpm2_dictionarylockout --clear-lockout` (or wait).

Deliberately enrolled **after** Secure Boot is enabled — sealing against PCR 7
while SB is off would bind the key to the "off" state and break the moment you
turned it on. PCR 7 (the default in `install.conf`) survives routine kernel
and BIOS updates; the stricter `0+7` binding also pins firmware measurements
but must be re-enrolled after every BIOS update. If auto-unlock ever stops
(Dell BIOS update changed measurements), type the passphrase and re-run the
script — `--wipe-slot=tpm2` makes re-enrollment idempotent. The LUKS
passphrase in keyslot 0 remains the recovery path forever; DMA and cold-boot
attacks remain out of scope, as on any general-purpose laptop.

## 8. Snapshots: snapper with logarithmic retention

With `SNAPPER="yes"` (default, Btrfs only) the installer sets up snapper on
the root subvolume plus `snap-pac`, which wraps every pacman transaction in
pre/post snapshots — so any bad update can be diffed or rolled back.

Timeline retention is logarithmic: snapshot density decays geometrically with
age, giving fine-grained recovery for recent mistakes and coarse checkpoints
for archaeology, at a near-constant total count (~30 timeline snapshots):

```
TIMELINE_LIMIT_HOURLY  = 12    last 12 hours, hourly
TIMELINE_LIMIT_DAILY   = 7     last week, daily
TIMELINE_LIMIT_WEEKLY  = 4     last month, weekly
TIMELINE_LIMIT_MONTHLY = 6     last half-year, monthly
TIMELINE_LIMIT_YEARLY  = 1     one yearly
NUMBER_LIMIT           = 30    cap on snap-pac pre/post pairs
```

Tune the counts in `install.conf` (`SNAP_*`). `snapper-timeline.timer` takes
the snapshots, `snapper-cleanup.timer` prunes to these limits, and your user
is in `ALLOW_USERS` so `snapper list` / `snapper diff` work without sudo.
Because `@home`, `@log`, and `@pkg` are separate subvolumes, root snapshots
stay small and rolling back the OS never rewinds your code or data. Remember
snapshots share the disk with the system: **they are versioning, not backup**
(see Hardening below).

## 9. Hardening baseline (HARDENING="yes")

Three low-friction measures are applied by the installer:

**nftables** with default-deny inbound (established/related, loopback, ICMP,
and IPv6 neighbor discovery allowed; outbound open). When you need a dev
server reachable from the LAN, add a `tcp dport ... accept` line to
`/etc/nftables.conf` and `systemctl reload nftables` — there's a commented
example in the file.

**AppArmor** enabled as the major LSM via `lsm=landlock,lockdown,yama,
integrity,apparmor,bpf` on the kernel command line — which lives inside the
signed UKI, so the LSM stack can't be stripped from the boot menu. Arch ships
relatively few enforcing profiles by default, so day-to-day friction is
near zero; add profiles (`apparmor.d` project, or your own for risky tools)
as you go. Check state with `aa-status`.

**sysctl** attack-surface trims in `/etc/sysctl.d/99-hardening.conf`:
kernel pointer and dmesg restriction, Yama `ptrace_scope=1` (debugging your
own child processes — `gdb ./prog`, `strace prog` — still works; attaching to
arbitrary running processes needs sudo, same as Ubuntu's default),
unprivileged BPF disabled, kexec disabled, `perf_event_paranoid=2` (use
`sudo perf` for system-wide profiling), plus standard network hygiene
(rp_filter, no redirects, syncookies). Every choice was screened for
developer-friendliness; if one bites (e.g. you need unprivileged eBPF for
tooling), comment out that single line and `sysctl --system`.

Also free with this design: kernel **lockdown** enters integrity mode
automatically when Secure Boot is on, and `editor no` in systemd-boot blocks
cmdline tampering at the menu.

---

# Installation walkthrough

## Step 0 — Firmware (BIOS) preparation

F2 at the Dell logo:

1. **Storage → SATA/NVMe Operation → AHCI/NVMe** (not "RAID On") — otherwise
   the SSD is invisible to the installer. (The installer detects VMD and can
   cope with RAID On, but AHCI/NVMe is the clean choice for Linux.)
2. **Secure Boot → OFF** for the install. Don't delete keys yet; the Setup
   Mode dance comes later via `secureboot-tpm2.sh`.
3. **Security → TPM 2.0 / Intel PTT → enabled** (usually already on).
4. Save and exit.

## Step 1 — Boot the Archboot stick

The DA14260 only has USB-C/Thunderbolt ports, so use a USB-C stick or hub.
Tap **F12** at power-on and pick the stick under "UEFI Boot Devices". Let
Archboot start; when you reach a root shell (quit the interactive setup dialog
if it launches), continue.

## Step 2 — Connect to the internet

```
iwctl station wlan0 connect "YourSSID"        # or:
nmcli device wifi connect "YourSSID" password "YourPassword"
ping -c2 archlinux.org
```

## Step 3 — Mount your ext4 partition and run the installer

Your stick shows up as e.g. `/dev/sda`, with the ISO occupying the first
partition(s) and your ext4 partition after them:

```
lsblk -f                          # identify the ext4 partition, e.g. /dev/sda3
mkdir -p /mnt/usb
mount /dev/sda3 /mnt/usb
cd /mnt/usb
bash install.sh
```

Check `TARGET_DISK` in `install.conf` against `lsblk` first (default
`/dev/nvme0n1` is correct for the stock single-SSD machine — and note your USB
stick will never be nvme). The script verifies UEFI/disk/network/TPM, prompts
for the root, user, and LUKS passwords, then requires you to type `WIPE`.
After that it runs unattended: partition → LUKS2 → Btrfs subvolumes →
packages → fstab → UKIs → systemd-boot → users → services. 5–15 minutes.

## Step 4 — First boot

`reboot`, pull the stick when the screen blanks. You'll be asked for the LUKS
passphrase (TPM2 isn't enrolled yet), then land in GNOME/KDE. Run:

```
sudo bash /root/post-install.sh
```

for fwupd firmware updates and a hardware check (Wi-Fi, SOF audio, graphics).

## Step 5 — Secure Boot (phase 1)

Reboot to BIOS → Secure Boot → Expert Key Management → custom mode → **delete
PK** (enters Setup Mode; keep Secure Boot OFF) → save → boot Arch →

```
sudo bash /root/secureboot-tpm2.sh      # detects Setup Mode, runs phase 1
```

It creates keys, enrolls them with Microsoft certs, signs the UKIs and
systemd-boot, and verifies.

## Step 6 — Enable Secure Boot, enroll TPM2 (phase 2)

Reboot to BIOS → Secure Boot → ON → save → Arch must boot cleanly → 

```
sudo bash /root/secureboot-tpm2.sh      # detects SB enabled, runs phase 2
```

Enter the LUKS passphrase once, then choose your TPM2 PIN. Reboot to confirm:
you should now get a short PIN prompt at boot instead of the full passphrase.

---

# Further hardening worth considering (not automated)

These are judgment calls that depend on your workflow, so the kit documents
rather than imposes them.

**Firmware:** set a BIOS admin password (F2 → Security) so nobody can flip
Secure Boot, storage mode, or boot order behind your back, and consider
disabling USB boot once the system is stable — together with the signed boot
chain this closes most evil-maid angles. Keep BIOS current via
`fwupdmgr update` (re-run TPM2 phase 2 afterwards if PCR 7 moved).

**Backups:** snapshots die with the disk. Pair snapper with an off-machine
copy — `btrbk` or `btrfs send` to an external/NAS Btrfs target preserves the
snapshot structure; `restic`/`borg` to any storage (both encrypt at rest) is
filesystem-agnostic. Automate it; a backup that requires remembering isn't one.

**Development containment:** the biggest practical risk on a dev laptop is
running other people's code — `npm install`, `pip install`, `make` from a
cloned repo — with full access to your `$HOME`, SSH keys, and tokens. Rootless
`podman` (or Docker + rootless mode) for builds, `direnv`+per-project
credentials instead of long-lived global tokens, and keeping SSH keys on
hardware (see below) do more for real-world safety than any kernel knob.

**Keys and secrets:** generate `ed25519` SSH keys with a passphrase, or better,
keep SSH/GPG/FIDO2 keys on a hardware token (YubiKey et al.) so a compromised
userland can use but never exfiltrate them. Sign your git commits. Use a real
password manager rather than browser-stored passwords.

**USB attack surface:** `usbguard` whitelists USB devices — genuinely useful
against malicious peripherals, but it will interrupt you every time you plug
in a new hub/dock, which on a USB-C-only laptop is often. Try it; keep it only
if the friction suits you. Thunderbolt security ("user authorization" level)
is handled by `boltctl`/GNOME automatically — leave it enabled in BIOS.

**Auditing:** `auditd` gives you a syscall-level trail (file access, execs) —
valuable for after-the-fact forensics, noisy otherwise. Consider it if you
handle sensitive client code. Lighter: check `journalctl -p warning` and
`sbctl verify` occasionally, and let `arch-audit` (package) flag installed
packages with known CVEs.

**DNS:** systemd-resolved supports DNS-over-TLS
(`DNS=9.9.9.9#dns.quad9.net` + `DNSOverTLS=yes` in `/etc/systemd/resolved.conf`)
if you don't want networks you roam onto seeing/spoofing your lookups.
NetworkManager already randomizes the MAC while *scanning*; per-connection
randomization is a config away if you care about tracking across networks.

**The linux-hardened kernel** exists and drops in easily (it's just another
UKI once installed), but its trade-offs — no unprivileged user namespaces by
default (breaks rootless containers and some browser/Flatpak sandboxes,
ironically), performance costs — usually make it a net negative *for a
development machine*. The mainline kernel plus the sysctl set here is the
pragmatic middle.

**What deliberately isn't here:** SELinux (poorly supported on Arch; AppArmor
is the realistic choice), grsecurity (not publicly available), and
fs-verity/dm-verity system integrity (fights the mutable nature of Arch).

---

# Hardware notes (DA14260)

Graphics (Intel Xe3): in-kernel `xe`/`i915`; add `vulkan-intel
intel-media-driver` to `EXTRA_PACKAGES` for Vulkan/VA-API. Audio needs
`sof-firmware` (installed). Wi-Fi/BT: Intel `iwlwifi` + `linux-firmware`
(installed). Webcam: Intel MIPI/IPU — Linux support still uneven; a missing
camera is a platform limitation, not an install error. Suspend: s2idle only
(set on the cmdline). Fingerprint reader: try `fprintd`, support varies by
SKU. BIOS updates: delivered through fwupd/LVFS, no Windows required — but
remember a BIOS update may change PCR 7 → re-run phase 2 afterwards.

# Troubleshooting

SSD missing in `lsblk` → BIOS storage is RAID On; switch to AHCI/NVMe.
Package signature errors in the live env → clock skew: `timedatectl set-ntp
true`, retry. Black screen after install → hold space at boot, pick the
fallback UKI; or boot the USB, `cryptsetup open /dev/nvme0n1p2 cryptroot`,
mount `subvol=@`, read `/root/xps14-install.log`. System won't boot after
enabling Secure Boot → disable SB in BIOS, boot, `sbctl verify` to find the
unsigned file, sign it, re-enable. TPM prompt returned after a BIOS update →
expected (PCR 7 changed); re-run `secureboot-tpm2.sh`. Re-running a failed
install is safe — it re-partitions from scratch.
