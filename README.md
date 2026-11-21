# x-full — offline Hyprland edition

`x-full` builds one install medium that carries everything the target needs:
a prebuilt btrfs root image, the local package set for per-machine deltas,
the X kernels, firmware/drivers, the virtualization stack and the equisdots
desktop. **Installation does not contact any network.**

Status: **scaffolding**. `build/x-full-build.sh doctor` checks the host;
the build steps land next.

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

1. Fetch `x` and `archiso` at pinned revisions.
2. Apply the `x-full` overlay: package lists, installer offline mode and
   image-write phase.
3. Build the local package set: Arch packages, prebuilt AUR packages and
   X packages.
4. Build the root image (btrfs, zstd).
5. Build the live ISO with the root image and the local delta repository.
6. Test the install offline in QEMU, sign the ISO and publish it to
   SourceForge.

## Layout

```
x-full/
├── build/            # fetch, overlay, repo, image, ISO, release
├── configs/          # pacman build config, mirrorlists, profile deltas
├── manifests/        # pinned x/archiso commits and package versions
├── overlay/          # package lists, airootfs, installer patches
├── recipes/          # PKGBUILD/XBUILD for X-specific and AUR packages
└── tests/            # offline install and boot assertions
```

## Prerequisites

- `archiso`, `devtools`, `pacman-contrib`, `erofs-utils` and `shellcheck`
  installed with xpm.
- A populated pacman keyring (`pacman-key --init`, `pacman-key --populate
  archlinux`) for `mkarchiso`/`pacstrap`.
- Workspace keys restored (`<workspace>/keys`) and the SourceForge SSH key in
  `~/.ssh/id_ed25519_sourceforge`.
- The narrow sudo rules installed with
  `utils/bin/equislinux-sudo --apply`.

## Usage

```bash
# Host readiness report (no changes)
./build/x-full-build.sh doctor

# Build steps (root; self-elevates through the sudo rules)
./build/x-full-build.sh repo
./build/x-full-build.sh image
./build/x-full-build.sh iso
./build/x-full-build.sh all
```

## License

GPL-3.0-or-later. See `LICENSE`.
