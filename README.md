# x-full — offline Hyprland edition

`x-full` builds one install medium that carries a complete X system image:
base system, the **current equisdots org** desktop, `linux-x`, NVIDIA/DKMS and
the tools the desktop needs. **Installation does not contact any network and
does not resolve packages.**

Status: built and verified (2026-11-24). ISO `x-full-2026.11.24-x86_64.iso`
(4.17 GB). Offline QEMU installs measured **24-65 s** (UEFI/BIOS, depending on host load) and
**~48 s with LUKS2** (the single initramfs rebuild). Every variant boots to
`graphical.target`, accepts the user login, validates the installed Hyprland
configuration, and checks Firefox, the kitty shader assets and, with `NET=1`,
NetworkManager/DHCP/DNS in the installed system.
`tests/offline-install.sh` enforces a 90 s install budget.

## Scope

- One desktop: **Hyprland + the current equisdots org stack** (shell, plugins,
  timex, palettes, xturing, background, login theme, kitty cursor-trail shader).
- **Firefox** is included. NetworkManager, `wpa_supplicant`, `wireless-regdb`
  and the common `linux-firmware` sets are included, so wired and Wi-Fi use
  the same NetworkManager stack as Omarchy; the shell panel drives `nmcli` and
  `nmtui` is the terminal fallback.
- The kitty trail keeps the org `x-trail` shader with
  `shader-slang`/`slangc` and the precompiled pipeline. A small
  `/usr/local/bin/kitty` wrapper keeps the shader on hardware GPUs and uses a
  shader-free copy of the config only under llvmpipe/softpipe/swrast (VMs);
  `glxinfo`, `eglinfo` and `hyprctl` are tried without aborting the launcher;
  `systemd-detect-virt` also disables the shader in VMs. `KITTY_FORCE_SHADERS=1`
  overrides it. The start threshold is raised so typing does not trigger the
  shader on every key.
- One kernel: **linux-x** (+ headers for DKMS).
- NVIDIA drivers are prebuilt in the image; the installer only adds the
  `nvidia-drm` kernel parameters when an NVIDIA GPU is present.
- The user still chooses: disk, wipe/dualboot, ESP size, LUKS2 encryption,
  hostname, username/password, locale, keyboard, timezone, bootloader and
  optional kernel parameters.
- Not part of this edition: KDE, niri, the archiso releng package set, extra
  kernels, the virtualization stack and the AI agents bundle. They stay
  available online after install.
- The external AUR desktop extras (`mpvpaper`, `bibata-cursor-theme`,
  `networkmanager-dmenu-git`) are intentionally absent.

## What is packaged

1. `base` → clean Arch + X base packages (no kernel, no desktop) →
   `out/x-rootfs.tar.zst` (~1.1 GB).
2. `repo` → offline package repository for the edition (desktop, NVIDIA,
   `linux-x`, AUR binaries). Used only at build time.
3. `target` → extract the base, install the edition, build NVIDIA DKMS, run
   the **org `dots` installer offline** over the vendored org repos, install
   the org login/PAM/theme/font and the kitty shader assets, build a generic
   initramfs and pack `out/x-target.tar.zst` (~8.4 GB uncompressed → ~2.85 GB
   with zstd).
4. `iso` → `mkarchiso` makes the live ISO with the live environment, the
   target image and the installer (`out/x-full-*.iso`, ~4.2 GB).
5. The installer partitions, extracts the target, writes user/system settings
   and the bootloader, records generation `0001`. No package installs.

The speed comes from extracting one prebuilt image instead of resolving and
installing packages.

## Org vendoring (no personal configs)

Only scripts, manifests, the installer, the profile and small brand assets
live in this repo. The desktop is fetched at build time:

```bash
./build/x-full-build.sh fetch
```

`fetch` clones the **org** sources from GitHub at their current `main` tips:

- `equisdots/{dots,hyprland,shell,palettes,theme-sync,davinci,plugin-api,plugin-sdk,plugins,nyx,timex,xturing,login,background}` (the `timex` plugin repo is fetched separately from `REPOS`),
- `xscriptor-colors/terminal` (kitty + starship) and `xscriptor-colors/nvim`.

The resolved commits are written to `manifests/equisdots.lock` (a plain text
manifest you can commit) and the snapshot lands in the gitignored `vendor/`.
**The personal `~/.config`, `~/.local/share/equisdots`, `/etc/pam.d` or SDDM
files installed on this machine are never read or copied.**

At build time the target runs the org's own `dots install` with `fetch_repo`
disabled: every repo is already staged, so deployment is offline. The org
app configs, theme-sync, login theme, PAM and services are applied from the
vendored sources.

## Principles

- **Offline install.** Everything the edition needs is inside the image.
- **Scripts and manifests only in git.** `vendor/`, `out/`, `work/` and
  `.cache/` are ignored; the org repos are cloned by `fetch`.
- **No AUR dotfiles.** The equisdots stack is vendored as source, not packaged
  or uploaded to AUR.
- **Keys live outside every git worktree**, in `<workspace>/keys`.
- **Pinned inputs.** `manifests/equisdots.lock`, `manifests/kernel.sha` and
  `manifests/aur.lock` record the sources; `manifests/*.x86_64` the packages.

## Build flow

```bash
./build/x-full-build.sh doctor        # host readiness report (no changes)
./build/x-full-build.sh prepare       # create the mkarchiso pacman keyring
./build/x-full-build.sh fetch         # clone the org desktop + AUR recipes + font/key
./build/x-full-build.sh aur           # build the AUR binary recipes
# optional: kernel-chroot + kernel-build if vendor/x-kernel has no packages
./build/x-full-build.sh base
./build/x-full-build.sh repo
./build/x-full-build.sh target        # runs the org dots installer offline
./build/x-full-build.sh iso
./build/x-full-build.sh finalize      # copy + sha256 + sign to ~/Downloads

# Everything in one run:
./build/x-full-build.sh all           # fetch + aur (+kernel if needed) + base + repo + target + iso + finalize
```

`all` and the build steps that need root self-elevate through the narrow sudo
rules installed once with `utils/bin/equislinux-sudo --apply`.

## Layout

```
x-full/
├── build/            # x-full-build.sh (fetch, aur, base, repo, target, iso)
├── configs/          # pacman build config
├── installer/        # xfull-install (TUI + auto mode)
├── manifests/        # base/hyprland/nvidia packages, org lock, kernel pin
├── profile/          # mkarchiso profile, live boot, installer autostart
├── tests/            # offline-install.sh (QEMU, no network, login/config)
├── assets/           # logo/locales; font and public key are fetched into vendor/
└── vendor/           # generated by fetch (gitignored)
```

## Testing

`tests/offline-install.sh` boots the ISO, performs a fully automatic install
on a fresh virtio disk with no NIC, checks the `XFULL_DONE` time against a
90 s budget, boots the installed system until `graphical.target`, logs in as
the created user over the serial console, runs `Hyprland --verify-config`
and checks Firefox plus the kitty shader pipeline/slangc:

```bash
tests/offline-install.sh                         # newest out/*.iso (UEFI, GRUB)
LUKS=1 tests/offline-install.sh                  # LUKS2, passphrase injected
NET=1 tests/offline-install.sh                   # add a virtio NIC; verify DHCP/nmcli
BOOT=systemd-boot tests/offline-install.sh       # UEFI systemd-boot
BIOS=1 tests/offline-install.sh                  # SeaBIOS + GRUB
LOGIN_CHECK=0 tests/offline-install.sh           # skip the login/config check
```

Measured on this host with QEMU/KVM: UEFI/BIOS 24-39 s, LUKS2 ~48 s, and the
`NET=1` variant verifies NetworkManager/DHCP/DNS. Real hardware will vary.

## Known issues / WIP

- **Kitty:** the org `x-trail` shader, `shader-slang`/`slangc`, the precompiled
  pipeline and the VM/software-renderer fallback are in the image. The test
  verifies the assets; full typing/input validation inside a logged-in
  Hyprland session is still the remaining check.
- **Network:** Ethernet/NetworkManager/DHCP/DNS is verified with `NET=1` in
  QEMU. NetworkManager is forced to write `/etc/resolv.conf` from DHCP
  (`rc-manager=file`), avoiding a dangling systemd-resolved stub, and a
  dispatcher adds public DNS only if DHCP provided none. Real Wi-Fi
  hardware has not been tested (the common firmware, regulatory database and
  modules are included). The installer itself stays offline by design.
- **Release:** the full ISO destined for the SourceForge `full` folder has not
  been uploaded. Publication happens in a later session; only the repository
  changes are pushed now.


## License

GPL-3.0-or-later. See `LICENSE`.
