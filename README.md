# x-full — offline Hyprland edition

`x-full` builds one install medium that carries everything the target needs:
a prebuilt root filesystem image (tar.zst), the X kernel, firmware/drivers,
the virtualization stack, the NVIDIA packages and the equisdots desktop.
**Installation does not contact any network.**

Status: **first ISO built and boot-tested** (2026-11-21).

- `x-full-2026.11.21-x86_64.iso` (5.2 GiB, signed) in `~/Downloads`.
- Offline QEMU UEFI install with no NIC: ~45 s, then boots to SDDM/Hyprland
  with `linux-x 7.3.4-arch1-1-x`.
- Not included yet: `xtop-git`, `mpvpaper`, `bibata-cursor-theme` and
  `networkmanager-dmenu-git`.

## Scope

- x86_64 first (BIOS + UEFI). aarch64 stays in `x-arm`.
- One desktop: Hyprland + equisdots.
- One kernel: `linux-x` (+ headers for DKMS).
- Offline install; updates after install keep their normal channels:
  `xpm -Syu` (Arch), `xpm-aur` (AUR), `dots update` (equisdots) and `[x]`
  (X packages).
- No KDE and no niri in this edition.

## Principles

- **xpm is the preferred package manager.** `archiso`/`mkarchiso` builds the
  live ISO; that path uses pacman internally.
- **Git holds recipes, manifests and scripts only.** No binaries, no ISOs and
  no keys are committed.
- **Keys live outside every git worktree**, in `<workspace>/keys`, restored
  from the offline backup.
- **No code or naming from other distributions.** Paths and scripts are X
  specific.
- **Reproducible builds**: pin `x`, `archiso`, the package versions and the
  AUR revisions in `manifests/`.

## Build flow

1. Fetch `x`, `scripts`, the AUR recipes and the published `linux-x` packages
   at the revisions in `manifests/`.
2. Build the AUR packages and the equisdots config snapshot.
3. Build the root filesystem with `xpm bootstrap` (Arch + `[x]` + AUR +
   NVIDIA + the X kernel).
4. Pack the root filesystem as `x-rootfs.tar.zst`.
5. Build the live ISO with the root image and the X installer.
6. Test the install offline in QEMU, sign the ISO and leave it in
   `~/Downloads`; the SourceForge upload is manual.

## Layout

```
x-full/
├── build/            # x-full-build.sh (fetch, aur, smoke, rootfs, iso)
├── configs/          # pacman build config
├── manifests/        # pinned x/scripts/AUR commits, kernel and package lists
├── overlay/          # installer image mode, hyprland offline patch, airootfs
└── tests/            # offline install and boot assertions
```

## Prerequisites

- `archiso`, `devtools`, `pacman-contrib`, `erofs-utils` and `shellcheck`
  installed with xpm.
- A populated pacman keyring for `mkarchiso`/`pacstrap`; `prepare` creates it
  with `pacman-key --init` and `pacman-key --populate archlinux` when missing.
- Workspace keys restored (`<workspace>/keys`) and the SourceForge SSH key in
  `~/.ssh/id_ed25519_sourceforge`.
- The narrow sudo rules installed with
  `utils/bin/equislinux-sudo --apply`.

## Usage

```bash
# Host readiness report (no changes)
./build/x-full-build.sh doctor

# Create the pacman keyring if missing (root)
./build/x-full-build.sh prepare

# Build steps (root; self-elevate through the sudo rules)
./build/x-full-build.sh fetch
./build/x-full-build.sh aur
./build/x-full-build.sh smoke
./build/x-full-build.sh rootfs
./build/x-full-build.sh iso

# Everything, then copy the signed ISO to ~/Downloads
./build/x-full-build.sh all
```

## License

GPL-3.0-or-later. See `LICENSE`.
