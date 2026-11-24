#!/usr/bin/env bash
# x-full build entrypoint.
#
#   doctor         host readiness report (no changes)
#   prepare        create the pacman keyring used by mkarchiso
#   kernel-chroot  create the clean chroot used to build linux-x
#   kernel-build   build linux-x stable locally from vendor/x-kernel
#   fetch          clone the org desktop + AUR recipes + font/key into vendor/
#   aur            build the AUR recipes in vendor/aur
#   base           build the base rootfs (no kernel, no desktop)
#   repo           build the offline package repository for the edition
#   target         build the single preinstalled edition image
#   iso            build the live ISO (target image + TUI)
#   all            base + repo + target + iso + copy to ~/Downloads
#   finalize       copy and sign the newest ISO
#   stop           stop a running build
#   repair-host    repair /run/user/* permissions (emergency)
#
# The edition is fixed: Hyprland (equisdots) + linux-x + NVIDIA. The ISO ships
# one prebuilt root image; the installer never contacts the network and never
# resolves packages. Build steps need root (mounts, mkarchiso) and re-exec
# through sudo. All sources and artifacts stay inside x-full; no other
# repository is modified.
set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SELF_DIR/.." && pwd)"
WS="${X_WORKSPACE:-$(cd -- "$ROOT/.." && pwd)}"
KEYS="${X_KEYS_DIR:-$WS/keys}"
VENDOR="$ROOT/vendor"
WORK="$ROOT/work"
OUT="$ROOT/out"
CACHE="$ROOT/.cache"
ASSETS="$ROOT/assets"
BASE_ROOTFS="$WORK/base-rootfs"
BASE_IMAGE="$OUT/x-rootfs.tar.zst"
TARGET_ROOTFS="$WORK/target-rootfs"
TARGET_IMAGE="$OUT/x-target.tar.zst"
REPO_DIR="$OUT/offline-repo/x86_64"
PROFILE_SRC="$ROOT/profile"
PROFILE_WORK="$WORK/profile"
BUILD_USER="${SUDO_USER:-$(id -nu 1000 2>/dev/null || id -un)}"
BUILD_HOME="$(getent passwd "$BUILD_USER" | cut -d: -f6)"
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
EDITION_MANIFESTS=(hyprland nvidia)
EDITION_KERNELS=(linux-x linux-x-headers)
EDITION_TOOLS=(mkinitcpio)

log() { printf '[x-full] %s\n' "$*"; }
warn() { printf '[x-full] warning: %s\n' "$*" >&2; }
die() { printf '[x-full] error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
require_root() { (( EUID == 0 )) || exec sudo -- "$0" "$@"; }

as_build_user_bash() {
    if (( EUID == 0 )); then
        runuser -u "$BUILD_USER" -- bash "$SELF_PATH" "$@"
    else
        bash "$SELF_PATH" "$@"
    fi
}

git_clone_at() {
    local url=$1 sha=$2 dir=$3
    install -d "$(dirname "$dir")"
    if [[ -d $dir/.git ]]; then
        git -C "$dir" fetch -q origin "$sha" 2>/dev/null || true
        git -C "$dir" checkout -q "$sha" 2>/dev/null || true
    else
        rm -rf "$dir"
        git clone -q --filter=blob:none "$url" "$dir" || die "could not clone $url"
        git -C "$dir" checkout -q "$sha" || die "$dir: commit $sha not found"
    fi
}

ok=0; fail=0
check_cmd() {
    if command -v "$1" >/dev/null 2>&1; then
        printf 'OK   %-22s %s\n' "$1" "$(command -v "$1")"; ok=$((ok + 1))
    else
        printf 'MISS %-22s\n' "$1"; fail=$((fail + 1))
    fi
}

doctor() {
    printf '== workspace ==\n%s\n\n== tools ==\n' "$ROOT"
    for c in xpm xpm-aur mkarchiso mkarchroot makepkg repo-add mksquashfs \
             xorriso zstd gpg git rsync qemu-system-x86_64 qemu-img \
             shellcheck pacman-key tar arch-chroot genfstab python3; do check_cmd "$c"; done
    printf '\n== keys ==\n'
    for f in "$KEYS/env.sh" "$KEYS/signing.pub" "$BUILD_HOME/.ssh/id_ed25519_sourceforge"; do
        if [[ -e $f ]]; then printf 'OK   %s\n' "$f"; ok=$((ok + 1)); else printf 'MISS %s\n' "$f"; fail=$((fail + 1)); fi
    done
    printf '\n== host ==\n'
    if [[ -d /etc/pacman.d/gnupg ]]; then printf 'OK   pacman keyring\n'; ok=$((ok + 1)); else printf 'MISS pacman keyring\n'; fail=$((fail + 1)); fi
    if [[ -c /dev/kvm ]]; then printf 'OK   kvm\n'; ok=$((ok + 1)); else printf 'MISS kvm\n'; fail=$((fail + 1)); fi
    local avail
    avail=$(df -Pk "$ROOT" | awk 'NR==2{print int($4/1024/1024)}')
    if (( avail >= 40 )); then
        printf 'OK   disk %s GiB free\n' "$avail"; ok=$((ok + 1))
    else
        printf 'MISS disk %s GiB free (need >= 40)\n' "$avail"; fail=$((fail + 1))
    fi
    printf '\n== result ==\nok=%d missing=%d\n' "$ok" "$fail"
    (( fail == 0 ))
}

prepare_host() {
    require_root "$@"
    if [[ ! -d /etc/pacman.d/gnupg ]]; then
        log "creating the pacman keyring"
        pacman-key --init
        pacman-key --populate archlinux
    fi
}

repair_host() {
    require_root "$@"
    local uid; uid="$(id -u "$BUILD_USER")"
    chown "$uid:$uid" "/run/user/$uid" 2>/dev/null || true
    chmod 700 "/run/user/$uid" 2>/dev/null || true
    ls -ld "/run/user/$uid"
}

kernel_chroot() {
    require_root "$@"
    local root=/var/lib/archbuild/x-kernel-x86_64/root
    [[ -d $root ]] && { log "kernel chroot exists"; return 0; }
    install -d "$(dirname "$root")"
    log "creating kernel chroot"
    mkarchroot -C "$ROOT/configs/pacman-build.conf" -M /etc/makepkg.conf "$root" base-devel
}

kernel_build() {
    require_root "$@"
    local k="$ROOT/vendor/x-kernel"
    [[ -x $k/scripts/build.sh ]] || die "vendor/x-kernel is missing"
    log "building linux-x stable locally"
    X_KERNEL_CONFIG="$k/config.env" bash "$k/scripts/build.sh" --channel stable
}

write_xpm_conf() {
    local file=$1 root=$2 db=$3 cache=$4 gpg=$5 sig=$6
    cat > "$file" <<EOF
[options]
root_dir = "$root"
db_path = "$db"
cache_dir = "$cache"
log_file = "$root/var/log/xpm.log"
gpg_dir = "$gpg"
mirror_pacman = false
shell_integration = false
sig_level = "$sig"
database_sig_level = "never"
architecture = "x86_64"
color = false
parallel_downloads = 8

[[repo]]
name = "x"
server = ["https://equislinux.github.io/x-repo/repo/x86_64"]
sig_level = "$sig"
database_sig_level = "never"

[[repo]]
name = "core"
server = ["https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"]

[[repo]]
name = "extra"
server = ["https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"]

EOF
}

write_online_xpm_conf() {
    local file=$1
    cat > "$file" <<'EOF'
[options]
root_dir = "/"
db_path = "/var/lib/xpm"
cache_dir = "/var/cache/xpm/pkg"
log_file = "/var/log/xpm.log"
gpg_dir = "/etc/xpm/gnupg"
mirror_pacman = false
shell_integration = false
sig_level = "required"
database_sig_level = "optional"
architecture = "x86_64"
color = false
parallel_downloads = 8

[[repo]]
name = "x"
server = ["https://equislinux.github.io/x-repo/repo/x86_64"]
sig_level = "required"
database_sig_level = "required"

[[repo]]
name = "core"
server = ["https://geo.mirror.pkgbuild.com/$repo/os/$arch"]

[[repo]]
name = "extra"
server = ["https://geo.mirror.pkgbuild.com/$repo/os/$arch"]
EOF
}

bind_pseudo() {
    local root=$1
    mkdir -p "$root"/dev "$root"/proc "$root"/sys "$root"/run
    mount --rbind /dev "$root/dev"; mount --make-rslave "$root/dev"
    mount --rbind /proc "$root/proc"; mount --make-rslave "$root/proc"
    mount --rbind /sys "$root/sys"; mount --make-rslave "$root/sys"
    mount -t tmpfs -o mode=755,nodev,nosuid tmpfs "$root/run"
}

unbind_pseudo() {
    local root=$1 p
    if mountpoint -q "$root/run"; then umount "$root/run" 2>/dev/null || umount -l "$root/run" 2>/dev/null || true; fi
    for p in sys proc dev; do
        mountpoint -q "$root/$p" && umount -R "$root/$p" 2>/dev/null || true
        mountpoint -q "$root/$p" && umount -Rl "$root/$p" 2>/dev/null || true
    done
}

write_target_xpm_conf() {
    local file=$1
    cat > "$file" <<EOF
[options]
root_dir = "$TARGET_ROOTFS"
db_path = "$TARGET_ROOTFS/var/lib/xpm"
cache_dir = "$CACHE/xpm"
log_file = "$TARGET_ROOTFS/var/log/xpm.log"
gpg_dir = "$TARGET_ROOTFS/etc/xpm/gnupg"
mirror_pacman = false
shell_integration = false
sig_level = "never"
database_sig_level = "never"
architecture = "x86_64"
color = false
parallel_downloads = 8

[[repo]]
name = "offline"
server = ["file://$REPO_DIR"]
sig_level = "never"
database_sig_level = "never"
EOF
}

build_base() {
    require_root "$@"
    rm -rf "$BASE_ROOTFS"
    mkdir -p "$BASE_ROOTFS/var/lib/xpm" "$BASE_ROOTFS/etc/xpm/gnupg" "$CACHE/xpm"
    local conf="$WORK/xpm-base.conf"
    write_xpm_conf "$conf" "$BASE_ROOTFS" "$BASE_ROOTFS/var/lib/xpm" "$CACHE/xpm" "$BASE_ROOTFS/etc/xpm/gnupg" "never"
    local -a pkgs
    mapfile -t pkgs < <(grep -v '^#' "$ROOT/manifests/base.x86_64" | sed '/^[[:space:]]*$/d')
    (( ${#pkgs[@]} )) || die "empty base manifest"
    log "xpm bootstrap base (${#pkgs[@]} packages)"
    bind_pseudo "$BASE_ROOTFS"
    trap 'unbind_pseudo "$BASE_ROOTFS"' EXIT
    xpm --config "$conf" bootstrap --root "$BASE_ROOTFS" \
        --dbpath "$BASE_ROOTFS/var/lib/xpm" --cachedir "$CACHE/xpm" \
        --no-confirm --scriptlets=skip --no-alpm-hooks --no-shell-integration \
        filesystem bash grep sed gawk coreutils findutils
    xpm --config "$conf" install --root "$BASE_ROOTFS" \
        --dbpath "$BASE_ROOTFS/var/lib/xpm" --cachedir "$CACHE/xpm" \
        --no-confirm --scriptlets=skip --no-alpm-hooks --no-shell-integration --needed base
    xpm --config "$conf" install --root "$BASE_ROOTFS" \
        --dbpath "$BASE_ROOTFS/var/lib/xpm" --cachedir "$CACHE/xpm" \
        --no-confirm --scriptlets=skip --no-alpm-hooks --no-shell-integration --needed "${pkgs[@]}"
    log "finalizing the base inside the chroot"
    arch-chroot "$BASE_ROOTFS" ldconfig
    arch-chroot "$BASE_ROOTFS" systemd-sysusers
    arch-chroot "$BASE_ROOTFS" systemd-tmpfiles --create
    if arch-chroot "$BASE_ROOTFS" test -x /usr/bin/update-ca-trust; then arch-chroot "$BASE_ROOTFS" update-ca-trust; fi
    if arch-chroot "$BASE_ROOTFS" test -x /usr/bin/x-release-apply; then arch-chroot "$BASE_ROOTFS" /usr/bin/x-release-apply || true; fi
    arch-chroot "$BASE_ROOTFS" fc-cache -f >/dev/null 2>&1 || true
    unbind_pseudo "$BASE_ROOTFS"; trap - EXIT
    write_online_xpm_conf "$BASE_ROOTFS/etc/xpm.conf"
    printf "Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch\n" > "$BASE_ROOTFS/etc/pacman.d/mirrorlist"
    rm -f "$BASE_ROOTFS/etc/fstab" "$BASE_ROOTFS/etc/machine-id" "$BASE_ROOTFS/etc/hostname" \
          "$BASE_ROOTFS/etc/locale.conf" "$BASE_ROOTFS/etc/vconsole.conf" "$BASE_ROOTFS/etc/localtime"
    find "$BASE_ROOTFS/home" -mindepth 1 -delete 2>/dev/null || true
    find "$BASE_ROOTFS/root" -mindepth 1 -delete 2>/dev/null || true
    find "$BASE_ROOTFS/boot" -mindepth 1 -delete 2>/dev/null || true
    find "$BASE_ROOTFS/var/cache/xpm/pkg" -mindepth 1 -delete 2>/dev/null || true
    find "$BASE_ROOTFS/var/cache/pacman/pkg" -mindepth 1 -delete 2>/dev/null || true
    find "$BASE_ROOTFS/var/log" -mindepth 1 -delete 2>/dev/null || true
    find "$BASE_ROOTFS/var/tmp" -mindepth 1 -delete 2>/dev/null || true
    find "$BASE_ROOTFS/tmp" -mindepth 1 -delete 2>/dev/null || true
    rm -rf "$BASE_ROOTFS/etc/xpm/gnupg" "$BASE_ROOTFS/etc/pacman.d/gnupg"
    rm -f "$BASE_ROOTFS/var/lib/xpm/transaction.lock" "$BASE_ROOTFS/var/lib/systemd/random-seed"
    rm -f "$BASE_ROOTFS"/etc/ssh/ssh_host_* 2>/dev/null || true
    find "$BASE_ROOTFS/etc/NetworkManager/system-connections" -mindepth 1 -delete 2>/dev/null || true
    find "$BASE_ROOTFS/var/lib/NetworkManager" -mindepth 1 -delete 2>/dev/null || true
    log "packing $BASE_IMAGE"
    rm -f "$BASE_IMAGE"
    tar --xattrs --acls --numeric-owner -C "$BASE_ROOTFS" \
        --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
        --exclude='./tmp/*' --exclude='./var/cache/*' --exclude='./var/log/*' \
        --exclude='./var/tmp/*' --exclude='./boot/*' --exclude='./home/*' \
        --exclude='./root/*' --exclude='./etc/fstab' --exclude='./etc/machine-id' \
        --exclude='./etc/hostname' --exclude='./etc/locale.conf' \
        --exclude='./etc/vconsole.conf' --exclude='./etc/localtime' \
        -cf - . | zstd -T0 -15 -o "$BASE_IMAGE"
    du -h "$BASE_IMAGE"
}


fetch_aur_recipes() {
    local p sha dir
    while read -r p sha; do
        [[ -n ${p:-} && $p != \#* ]] || continue
        [[ -n ${sha:-} ]] || continue
        dir="$VENDOR/aur/$p"
        log "fetch: AUR $p"
        git_clone_at "https://aur.archlinux.org/$p.git" "$sha" "$dir"
    done < "$ROOT/manifests/aur.lock"
}

build_aur() {
    local p dir
    [[ $EUID -ne 0 ]] || die "aur must run as the build user"
    for p in xwww-bin xfetch-bin; do
        dir="$VENDOR/aur/$p"
        [[ -d $dir ]] || die "missing $dir; run fetch"
        log "building $p"
        ( cd "$dir" && makepkg -f --nodeps --noconfirm ) || die "makepkg failed for $p"
    done
}

fetch_all() {
    local tmp="$VENDOR/.desktop-fetch"
    local repos="$tmp/repos" app="$tmp/app"
    local repos_line r sha f
    local -a repo_list=()
    [[ $EUID -ne 0 ]] || die "fetch must run as the build user"
    install -d "$VENDOR" "$OUT" "$tmp" "$repos" "$app"

    log "fetch: equisdots/dots (org main)"
    rm -rf "$tmp/dots"
    git clone -q --depth 1 https://github.com/equisdots/dots.git "$tmp/dots" \
        || die "cannot clone equisdots/dots"
    repos_line="$(sed -n 's/^REPOS=(\(.*\))/\1/p' "$tmp/dots/dots" | head -1)"
    [[ -n $repos_line ]] || die "cannot read REPOS from equisdots/dots"
    read -r -a repo_list <<< "$repos_line"

    {
        printf '# x-full desktop sources (equisdots/org main tips)\n'
        printf '# generated by x-full-build.sh fetch; commit this file with the build\n'
    } > "$tmp/lock"

    for r in "${repo_list[@]}"; do
        log "fetch: equisdots/$r"
        if [[ $r == dots ]]; then
            cp -a "$tmp/dots" "$repos/dots"
        else
            rm -rf "${repos:?}/$r"
            git clone -q --depth 1 --recurse-submodules --shallow-submodules \
                "https://github.com/equisdots/$r.git" "$repos/$r" \
                || die "cannot clone equisdots/$r"
        fi
        sha="$(git -C "$repos/$r" rev-parse HEAD)"
        printf 'equisdots-%s https://github.com/equisdots/%s.git %s\n' "$r" "$r" "$sha" >> "$tmp/lock"
    done

    # Plugin sources that are not part of REPOS but are installed from the
    # org plugin registry (timex has its own repo with plugin.json).
    # shellcheck disable=SC2043
    for r in timex; do
        [[ -d $repos/$r ]] && continue
        log "fetch: equisdots/$r (plugin)"
        rm -rf "${repos:?}/$r"
        git clone -q --depth 1 --recurse-submodules --shallow-submodules \
            "https://github.com/equisdots/$r.git" "$repos/$r" \
            || die "cannot clone equisdots/$r"
        sha="$(git -C "$repos/$r" rev-parse HEAD)"
        printf 'equisdots-%s https://github.com/equisdots/%s.git %s\n' "$r" "$r" "$sha" >> "$tmp/lock"
    done

    log "fetch: xscriptor-colors app configs (org main)"
    rm -rf "$tmp/terminal" "$tmp/nvimsrc"
    git clone -q --depth 1 https://github.com/xscriptor-colors/terminal.git "$tmp/terminal" \
        || die "cannot clone xscriptor-colors/terminal"
    git clone -q --depth 1 https://github.com/xscriptor-colors/nvim.git "$tmp/nvimsrc" \
        || die "cannot clone xscriptor-colors/nvim"
    printf 'terminal https://github.com/xscriptor-colors/terminal.git %s\n' \
        "$(git -C "$tmp/terminal" rev-parse HEAD)" >> "$tmp/lock"
    printf 'nvim https://github.com/xscriptor-colors/nvim.git %s\n' \
        "$(git -C "$tmp/nvimsrc" rev-parse HEAD)" >> "$tmp/lock"

    install -d "$app/kitty/themes" "$app/kitty/shaders" "$app/starship" "$app/nvim"
    if [[ -f $tmp/terminal/emulators/kitty/config ]]; then
        cp -a "$tmp/terminal/emulators/kitty/config" "$app/kitty/kitty.conf"
    fi
    if [[ -d $tmp/terminal/emulators/kitty/themes ]]; then
        cp -a "$tmp/terminal/emulators/kitty/themes/." "$app/kitty/themes/"
    fi
    if [[ -d $tmp/terminal/emulators/kitty/shaders ]]; then
        cp -a "$tmp/terminal/emulators/kitty/shaders/." "$app/kitty/shaders/"
    fi
    if [[ -d $tmp/terminal/prompts/starship ]]; then
        cp -a "$tmp/terminal/prompts/starship/." "$app/starship/"
    fi
    if [[ -d $tmp/nvimsrc ]]; then
        rsync -a --exclude='.git' --exclude='.github' "$tmp/nvimsrc/" "$app/nvim/"
    fi

    if [[ -f $tmp/terminal/assets/fonts/HackNerdFont/HackNerdFont-Regular.ttf ]]; then
        cp -a "$tmp/terminal/assets/fonts/HackNerdFont/HackNerdFont-Regular.ttf" \
            "$VENDOR/HackNerdFont-Regular.ttf"
    elif [[ ! -f $VENDOR/HackNerdFont-Regular.ttf ]]; then
        curl -fsSL --retry 3 -o "$VENDOR/HackNerdFont-Regular.ttf" \
            "https://raw.githubusercontent.com/xscriptor-colors/terminal/main/assets/fonts/HackNerdFont/HackNerdFont-Regular.ttf" \
            || warn "could not download HackNerdFont"
    fi
    if [[ ! -f $VENDOR/x-repo.pub ]]; then
        curl -fsSL --retry 3 -o "$VENDOR/x-repo.pub" \
            "https://equislinux.github.io/x-repo/repo/x86_64/signing.pub" \
            || warn "could not download the [x] repository key"
    fi

    find "$repos" "$app" \( -name .git -o -name .github \) -prune -exec rm -rf {} + 2>/dev/null || true

    cp -f "$tmp/lock" "$ROOT/manifests/equisdots.lock"

    rm -rf "$VENDOR/equisdots-config.prev"
    [[ -d $VENDOR/equisdots-config ]] && mv "$VENDOR/equisdots-config" "$VENDOR/equisdots-config.prev"
    install -d "$VENDOR/equisdots-config"
    mv "$repos" "$VENDOR/equisdots-config/repos"
    mv "$app" "$VENDOR/equisdots-config/app"
    rm -rf "$tmp"

    fetch_aur_recipes
    if [[ ! -x $VENDOR/x-kernel/scripts/build.sh ]]; then
        sha="$(head -1 "$ROOT/manifests/kernel.sha" 2>/dev/null || true)"
        log "fetch: equislinux/x-kernel"
        git_clone_at https://github.com/equislinux/x-kernel.git "${sha:-main}" "$VENDOR/x-kernel"
    fi
    log "fetch complete: $(find "$VENDOR/equisdots-config" -type f | wc -l) desktop files"
}

download_set() {
    local conf=$1; shift
    local -a clean=()
    local p
    for p in "$@"; do
        case "$p" in
            xwww-bin|xfetch-bin|linux-x|linux-x-headers) continue ;;
        esac
        clean+=("$p")
    done
    (( ${#clean[@]} )) || return 0
    xpm --config "$conf" install --download-only --no-confirm --needed "${clean[@]}"
}

build_repo() {
    require_root "$@"
    local kdir="$VENDOR/x-kernel/out/linux-x/stable"
    ls "$kdir"/linux-x-*.pkg.tar.zst >/dev/null 2>&1 \
        || die "missing local linux-x packages; run kernel-build first"
    local aur
    for aur in xwww-bin xfetch-bin; do
        ls "$VENDOR/aur/$aur/$aur-"*.pkg.tar.zst >/dev/null 2>&1 \
            || die "missing AUR package $aur under vendor/aur"
    done
    rm -rf "$OUT/offline-repo"
    mkdir -p "$REPO_DIR" "$WORK/repo-db" "$WORK/repo-root" "$CACHE/xpm"
    local conf="$WORK/xpm-download.conf"
    write_xpm_conf "$conf" "$WORK/repo-root" "$WORK/repo-db" "$CACHE/xpm" "/etc/xpm/gnupg" "never"
    xpm --config "$conf" sync
    log "downloading the edition closure"
    local m
    for m in "${EDITION_MANIFESTS[@]}"; do
        local -a set
        mapfile -t set < <(grep -v '^#' "$ROOT/manifests/$m.x86_64" | sed '/^[[:space:]]*$/d')
        (( ${#set[@]} )) || continue
        log "download: $m (${#set[@]} packages)"
        download_set "$conf" "${set[@]}"
    done
    # initramfs tooling is a dependency of the local linux-x package.
    download_set "$conf" mkinitcpio
    log "collecting cached packages"
    find "$CACHE/xpm" -maxdepth 1 -name '*.pkg.tar.zst' ! -name '*-debug-*' -exec cp -f {} "$REPO_DIR/" \;
    local f
    for f in "$VENDOR"/kernel/*.pkg.tar.zst "$VENDOR"/x-kernel/out/linux-x/stable/*.pkg.tar.zst \
             "$VENDOR"/aur/*/*.pkg.tar.zst; do
        [[ -f $f ]] || continue
        [[ $f == *-debug-* ]] && continue
        [[ $f == *linux-x-docs-* ]] && continue
        cp -f "$f" "$REPO_DIR/"
    done
    log "indexing $(find "$REPO_DIR" -name '*.pkg.tar.zst' | wc -l) packages"
    (cd "$REPO_DIR" && rm -f offline.db* offline.files* && repo-add -q offline.db.tar.gz ./*.pkg.tar.zst)
    ln -sf offline.db.tar.gz "$REPO_DIR/offline.db"
    ln -sf offline.files.tar.gz "$REPO_DIR/offline.files"
    log "repo ready: $(du -sh "$REPO_DIR" | cut -f1)"
}

edition_packages() {
    local p
    local -a pkgs=()
    local m
    for m in "${EDITION_MANIFESTS[@]}"; do
        while IFS= read -r p; do
            [[ -n $p && $p != \#* ]] && pkgs+=("$p")
        done < "$ROOT/manifests/$m.x86_64"
    done
    pkgs+=("${EDITION_KERNELS[@]}" "${EDITION_TOOLS[@]}")
    printf '%s\n' "${pkgs[@]}" | awk 'NF && !seen[$0]++'
}

kernel_tree() {
    local root=$1 pkgbase=${2:-linux-x} d
    for d in "$root"/usr/lib/modules/*; do
        [[ -f $d/pkgbase ]] || continue
        [[ "$(cat "$d/pkgbase")" == "$pkgbase" ]] && { basename "$d"; return 0; }
    done
    return 1
}

stage_desktop() {
    local root=$TARGET_ROOTFS kver=$1
    local snapshot="$VENDOR/equisdots-config"
    local repos="$snapshot/repos" app="$snapshot/app"
    local font="$VENDOR/HackNerdFont-Regular.ttf" f
    [[ -d $repos && -d $app ]] || die "missing org desktop snapshot; run fetch"
    [[ -f $font ]] || font="$ASSETS/HackNerdFont-Regular.ttf"
    [[ -f $font ]] || die "missing HackNerdFont"

    if ! arch-chroot "$root" id -u xbuild >/dev/null 2>&1; then
        arch-chroot "$root" useradd -m -G wheel -s /usr/bin/zsh xbuild
    fi
    local xuid xgid
    xuid="$(arch-chroot "$root" id -u xbuild)"
    xgid="$(arch-chroot "$root" id -g xbuild)"
    printf '%%wheel ALL=(ALL) NOPASSWD: ALL\n' > "$root/etc/sudoers.d/xfull-build"
    chmod 440 "$root/etc/sudoers.d/xfull-build"

    install -d "$root/home/xbuild/.local/share/equisdots"
    rsync -a "$repos/" "$root/home/xbuild/.local/share/equisdots/"
    install -d "$root/home/xbuild/.config"
    for f in kitty nvim; do
        [[ -d $app/$f ]] || continue
        install -d "$root/home/xbuild/.config/$f"
        rsync -a "$app/$f/" "$root/home/xbuild/.config/$f/"
    done
    if [[ -d $app/starship ]]; then
        install -d "$root/home/xbuild/.config/equisdots/starship"
        rsync -a "$app/starship/" "$root/home/xbuild/.config/equisdots/starship/"
        if [[ -f $app/starship/starship.toml ]]; then
            install -Dm644 "$app/starship/starship.toml" "$root/home/xbuild/.config/starship.toml"
        fi
    fi
    chown -R "$xuid:$xgid" "$root/home/xbuild"

    # Run the org dots installer offline: fetch_repo is overridden, every repo
    # is already staged above.
    install -d "$root/opt/x-full-stage"
    cp "$repos/dots/dots" "$root/opt/x-full-stage/dots"
    python3 - "$root/opt/x-full-stage/dots" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
marker = 'case "${1:-help}" in'
if 'X_FULL_OFFLINE_FETCH' not in s:
    if marker not in s:
        sys.exit('dots: case marker not found')
    s = s.replace(marker, 'X_FULL_OFFLINE_FETCH=1\nfetch_repo() { return 0; }\n\n' + marker, 1)
    p.write_text(s)
PY
    chmod 755 "$root/opt/x-full-stage/dots"
    install -Dm644 /etc/resolv.conf "$root/etc/resolv.conf" 2>/dev/null || true

    log "staging the org equisdots payload"
    timeout 900 arch-chroot "$root" runuser -u xbuild -- env \
        HOME=/home/xbuild \
        XDG_DATA_HOME=/home/xbuild/.local/share \
        XDG_CONFIG_HOME=/home/xbuild/.config \
        XDG_STATE_HOME=/home/xbuild/.local/state \
        XDG_CACHE_HOME=/tmp/xbuild-cache \
        GIT_TERMINAL_PROMPT=0 \
        bash /opt/x-full-stage/dots install 2>&1 | tee "$WORK/desktop-staging.log" \
        || warn "desktop staging reported errors (see $WORK/desktop-staging.log)"

    if [[ -f $repos/hyprland/config/pam.d/quickshell ]]; then
        install -Dm644 "$repos/hyprland/config/pam.d/quickshell" "$root/etc/pam.d/quickshell"
    fi
    if [[ -x $root/home/xbuild/.local/share/equisdots/login/install.sh ]]; then
        arch-chroot "$root" runuser -u xbuild -- \
            bash /home/xbuild/.local/share/equisdots/login/install.sh \
            || warn "login theme installation failed"
    fi
    if [[ -x $root/home/xbuild/.local/share/equisdots/theme-sync/theme-sync.sh ]]; then
        arch-chroot "$root" runuser -u xbuild -- env HOME=/home/xbuild \
            XDG_CONFIG_HOME=/home/xbuild/.config XDG_DATA_HOME=/home/xbuild/.local/share \
            XDG_STATE_HOME=/home/xbuild/.local/state XDG_CACHE_HOME=/tmp/xbuild-cache \
            bash /home/xbuild/.local/share/equisdots/theme-sync/theme-sync.sh \
            || warn "theme-sync failed"
    fi

    # Keep the org cursor-trail shader and its pipeline. Tune it so typing
    # (single-cell moves) does not trigger the shader on every key, which
    # stalls software renderers, and relax the repaint delay a little.
    local kitty_conf="$root/home/xbuild/.config/kitty/kitty.conf"
    if [[ -f $kitty_conf ]]; then
        python3 - "$kitty_conf" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = re.sub(r'^(\s*cursor_trail_start_threshold\s+)\d+', r'\g<1>3', s, flags=re.M)
s = re.sub(r'^(\s*repaint_delay\s+)\d+', r'\g<1>16', s, flags=re.M)
if not re.search(r'^\s*custom_shaders\s+', s, re.M):
    s = s.rstrip() + '\ncustom_shaders x-trail\n'
if not re.search(r'^\s*cursor_trail\s+', s, re.M):
    s = s.rstrip() + '\ncursor_trail 12\n'
p.write_text(s)
PY
        if [[ ! -f $root/home/xbuild/.config/kitty/shaders/x-trail.pipeline ]]; then
            warn "kitty x-trail.pipeline is missing"
        fi
    fi
    if [[ ! -x $root/usr/bin/slangc ]]; then
        warn "slangc (shader-slang) is missing; kitty custom shaders may not load"
    fi
    install -Dm755 "$ROOT/overlay/kitty" "$root/usr/local/bin/kitty"

    install -d "$root/usr/share/fonts/HackNerdFont"
    install -m 0644 "$font" "$root/usr/share/fonts/HackNerdFont/HackNerdFont-Regular.ttf"
    install -d "$root/home/xbuild/.local/share/fonts"
    install -m 0644 "$font" "$root/home/xbuild/.local/share/fonts/HackNerdFont-Regular.ttf"
    arch-chroot "$root" fc-cache -f >/dev/null 2>&1 || true

    arch-chroot "$root" systemctl enable NetworkManager.service >/dev/null 2>&1 || true
    arch-chroot "$root" systemctl enable sddm.service >/dev/null 2>&1 || true
    arch-chroot "$root" systemctl enable power-profiles-daemon.service >/dev/null 2>&1 || true
    arch-chroot "$root" systemctl enable bluetooth.service >/dev/null 2>&1 || true
    arch-chroot "$root" systemctl enable swayosd-libinput-backend.service >/dev/null 2>&1 || true
    arch-chroot "$root" systemctl enable fstrim.timer >/dev/null 2>&1 || true
    arch-chroot "$root" systemctl --global enable pipewire pipewire-pulse wireplumber >/dev/null 2>&1 || true

    local rc
    for rc in .zprofile .zshrc .bash_profile; do
        [[ -f $root/home/xbuild/$rc ]] || printf '# X Full shell profile\n' > "$root/home/xbuild/$rc"
        if ! grep -q '\.local/bin' "$root/home/xbuild/$rc"; then
            printf "\n# equisdots: local bin\nexport PATH=\"\$HOME/.local/bin:\$PATH\"\n" \
                >> "$root/home/xbuild/$rc"
        fi
    done
    if ! grep -q 'starship init zsh' "$root/home/xbuild/.zshrc"; then
        printf "\n# x: starship prompt\ncommand -v starship >/dev/null 2>&1 && eval \"\$(starship init zsh)\"\n" \
            >> "$root/home/xbuild/.zshrc"
    fi
    chown -R "$xuid:$xgid" "$root/home/xbuild"

    while IFS= read -r f; do
        sed -i 's|/home/xbuild|__XFULL_HOME__|g' "$f"
    done < <(grep -rIl --exclude-dir=.git -- '/home/xbuild' "$root/home/xbuild" 2>/dev/null || true)

    [[ -f $root/home/xbuild/.config/hypr/hyprland.lua ]] \
        || die "the org payload did not produce ~/.config/hypr/hyprland.lua"
    [[ -x $root/home/xbuild/.local/share/equisdots/dots/dots ]] \
        || die "the org payload is missing the dots checkout"
    [[ -x $root/home/xbuild/.local/bin/dots ]] \
        || warn "the org payload did not produce ~/.local/bin/dots"

    rm -rf "$root/etc/skel"
    install -d -m 0755 "$root/etc/skel"
    cp -a "$root/home/xbuild/." "$root/etc/skel/"
    rm -rf "$root/etc/skel/.cache"
    chmod 0755 "$root/etc/skel"
    arch-chroot "$root" pkill -9 -u xbuild 2>/dev/null || true
    arch-chroot "$root" userdel xbuild 2>/dev/null || true
    rm -rf "$root/home/xbuild" "$root/tmp/xbuild-cache" "$root/opt/x-full-stage"
    rm -f "$root/etc/sudoers.d/xfull-build"
    chown -R 0:0 "$root/etc/skel"
}

setup_keyrings() {
    local root=$TARGET_ROOTFS gpgdir fpr key="$VENDOR/x-repo.pub"
    [[ -f $key ]] || key="$ASSETS/x-repo.pub"
    [[ -f $key ]] || die "missing x-repo public key"
    # arch-chroot mounts a tmpfs on /tmp, so keep the keyfile on a persistent
    # path inside the target rootfs.
    install -Dm644 "$key" "$root/etc/x-full-repo.pub"
    for gpgdir in /etc/pacman.d/gnupg /etc/xpm/gnupg; do
        arch-chroot "$root" pacman-key --gpgdir "$gpgdir" --init
        arch-chroot "$root" pacman-key --gpgdir "$gpgdir" --populate archlinux
        arch-chroot "$root" pacman-key --gpgdir "$gpgdir" --add /etc/x-full-repo.pub
        fpr="$(arch-chroot "$root" gpg --batch --homedir "$gpgdir" --with-colons \
            --show-keys /etc/x-full-repo.pub 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
        [[ -n $fpr ]] || die "could not read the [x] repository key"
        arch-chroot "$root" pacman-key --gpgdir "$gpgdir" --lsign-key "$fpr"
    done
    rm -f "$root/etc/x-full-repo.pub"
    write_online_xpm_conf "$root/etc/xpm.conf"
    printf "Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch\n" > "$root/etc/pacman.d/mirrorlist"
    if ! grep -q '^\[x\]' "$root/etc/pacman.conf"; then
        cat >> "$root/etc/pacman.conf" <<'EOF'

[x]
SigLevel = Required
Server = https://equislinux.github.io/x-repo/repo/x86_64
EOF
    fi
}

setup_initramfs() {
    local root=$TARGET_ROOTFS kver=$1
    printf 'KEYMAP=us\n' > "$root/etc/vconsole.conf"
    cat > "$root/etc/mkinitcpio.conf" <<'EOF'
# Generic initramfs for the prebuilt X Full image. autodetect is disabled so
# the image boots on any machine, not only on the build host.
MODULES=(nvme nvme_core ahci libahci sd_mod usb_storage uas xhci_pci xhci_hcd
         virtio_blk virtio_pci virtio_scsi virtio_net hid_generic usbhid)
BINARIES=()
FILES=()
HOOKS=(base udev microcode modconf kms keyboard keymap consolefont block filesystems)
COMPRESSION="zstd"
COMPRESSION_OPTIONS=(-3 --long=27 -T0)
EOF
    install -d "$root/etc/mkinitcpio.d"
    cat > "$root/etc/mkinitcpio.d/linux-x.preset" <<'EOF'
# linux-x preset for the X Full image.
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-x"
PRESETS=('default')
default_image="/boot/initramfs-linux-x.img"
EOF
    install -Dm644 "$root/usr/lib/modules/$kver/vmlinuz" "$root/boot/vmlinuz-linux-x"
    arch-chroot "$root" depmod -a "$kver"
    log "building the prebuilt initramfs"
    arch-chroot "$root" mkinitcpio -P
    [[ -s $root/boot/vmlinuz-linux-x ]] || die "missing /boot/vmlinuz-linux-x"
    [[ -s $root/boot/initramfs-linux-x.img ]] || die "missing /boot/initramfs-linux-x.img"
    du -h "$root/boot/initramfs-linux-x.img"
}

clean_target() {
    local root=$TARGET_ROOTFS
    rm -f "$root/etc/fstab" "$root/etc/machine-id" "$root/etc/hostname" \
          "$root/etc/locale.conf" "$root/etc/vconsole.conf" "$root/etc/localtime" \
          "$root/etc/linux-x.kver"
    rm -f "$root/var/lib/systemd/random-seed" "$root/var/lib/xpm/transaction.lock" "$root/etc/resolv.conf"
    rm -f "$root"/etc/ssh/ssh_host_* 2>/dev/null || true
    find "$root/home" -mindepth 1 -delete 2>/dev/null || true
    find "$root/root" -mindepth 1 -delete 2>/dev/null || true
    find "$root/tmp" -mindepth 1 -delete 2>/dev/null || true
    find "$root/var/tmp" -mindepth 1 -delete 2>/dev/null || true
    find "$root/var/log" -mindepth 1 -delete 2>/dev/null || true
    find "$root/var/cache" -mindepth 1 -maxdepth 1 ! -name fontconfig -exec rm -rf {} + 2>/dev/null || true
    find "$root/var/lib/x" -mindepth 1 -delete 2>/dev/null || true
    find "$root/etc/NetworkManager/system-connections" -mindepth 1 -delete 2>/dev/null || true
    find "$root/var/lib/NetworkManager" -mindepth 1 -delete 2>/dev/null || true
    rm -rf "$root/etc/sudoers.d/xfull-build"
    arch-chroot "$root" gpgconf --homedir /etc/pacman.d/gnupg --kill gpg-agent 2>/dev/null || true
    arch-chroot "$root" gpgconf --homedir /etc/xpm/gnupg --kill gpg-agent 2>/dev/null || true
    rm -f "$root"/etc/pacman.d/gnupg/S.gpg-agent* "$root"/etc/xpm/gnupg/S.gpg-agent*
    install -d "$root/var/lib/x" "$root/home" "$root/root" "$root/tmp" "$root/var/tmp" \
              "$root/var/log" "$root/var/cache" "$root/etc/skel"
    chmod 1777 "$root/tmp" "$root/var/tmp"
    chmod 700 "$root/root"
}

build_target() {
    require_root "$@"
    [[ -f $BASE_IMAGE ]] || die "missing base image; run base first"
    [[ -f $REPO_DIR/offline.db ]] || die "missing offline repo; run repo first"
    # A previous failed chroot can leave /proc, /sys, /dev or /run mounted.
    unbind_pseudo "$TARGET_ROOTFS"
    rm -rf "$TARGET_ROOTFS"
    mkdir -p "$TARGET_ROOTFS"
    log "extracting the base image"
    tar --zstd -xpf "$BASE_IMAGE" -C "$TARGET_ROOTFS" --xattrs --acls --numeric-owner
    mkdir -p "$TARGET_ROOTFS/var/lib/xpm" "$TARGET_ROOTFS/etc/xpm/gnupg" "$CACHE/xpm"
    bind_pseudo "$TARGET_ROOTFS"
    trap 'unbind_pseudo "$TARGET_ROOTFS"' EXIT
    local conf="$WORK/xpm-target.conf"
    write_target_xpm_conf "$conf"
    local -a pkgs
    mapfile -t pkgs < <(edition_packages)
    log "installing the edition (${#pkgs[@]} packages)"
    xpm --config "$conf" sync
    xpm --config "$conf" install --root "$TARGET_ROOTFS" \
        --dbpath "$TARGET_ROOTFS/var/lib/xpm" --cachedir "$CACHE/xpm" \
        --no-confirm --scriptlets=skip --no-alpm-hooks --needed "${pkgs[@]}"
    log "finalizing the target image"
    arch-chroot "$TARGET_ROOTFS" ldconfig
    arch-chroot "$TARGET_ROOTFS" systemd-sysusers
    arch-chroot "$TARGET_ROOTFS" systemd-tmpfiles --create
    if arch-chroot "$TARGET_ROOTFS" test -x /usr/bin/update-ca-trust; then
        arch-chroot "$TARGET_ROOTFS" update-ca-trust
    fi
    arch-chroot "$TARGET_ROOTFS" fc-cache -f >/dev/null 2>&1 || true
    # NetworkManager must write /etc/resolv.conf itself; auto can leave a
    # dangling systemd-resolved stub in images without the resolver daemon.
    install -d "$TARGET_ROOTFS/etc/NetworkManager/conf.d"
    cat > "$TARGET_ROOTFS/etc/NetworkManager/conf.d/10-x-full-dns.conf" <<'EOF'
[main]
dns=default
rc-manager=file
EOF
    install -Dm755 "$ROOT/overlay/nm-dns-fallback" \
        "$TARGET_ROOTFS/etc/NetworkManager/dispatcher.d/90-x-full-dns"
    # The zsh scriptlet is skipped with --scriptlets=skip; login and SDDM use
    # pam_shells, so the shell must be listed explicitly.
    local sh
    for sh in /bin/zsh /usr/bin/zsh; do
        grep -qx "$sh" "$TARGET_ROOTFS/etc/shells" 2>/dev/null \
            || printf '%s\n' "$sh" >> "$TARGET_ROOTFS/etc/shells"
    done
    if arch-chroot "$TARGET_ROOTFS" test -x /usr/bin/glib-compile-schemas; then
        arch-chroot "$TARGET_ROOTFS" glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1 || true
    fi
    if arch-chroot "$TARGET_ROOTFS" test -x /usr/bin/update-desktop-database; then
        arch-chroot "$TARGET_ROOTFS" update-desktop-database >/dev/null 2>&1 || true
    fi
    if arch-chroot "$TARGET_ROOTFS" test -x /usr/bin/gtk-update-icon-cache; then
        arch-chroot "$TARGET_ROOTFS" gtk-update-icon-cache -q /usr/share/icons/hicolor >/dev/null 2>&1 || true
    fi

    local kver
    kver="$(kernel_tree "$TARGET_ROOTFS" linux-x)" || die "linux-x module tree is missing"
    log "linux-x kernel: $kver"

    if ! ls "$TARGET_ROOTFS"/usr/share/wayland-sessions/*hyprland*.desktop >/dev/null 2>&1; then
        install -d "$TARGET_ROOTFS/usr/share/wayland-sessions"
        cat > "$TARGET_ROOTFS/usr/share/wayland-sessions/hyprland.desktop" <<'EOF'
[Desktop Entry]
Name=Hyprland
Comment=X Linux Hyprland session
Exec=Hyprland
Type=Application
EOF
    fi

    install -d "$TARGET_ROOTFS/etc/modprobe.d"
    printf 'options nvidia_drm modeset=1 fbdev=1\n' > "$TARGET_ROOTFS/etc/modprobe.d/nvidia.conf"
    if ls "$TARGET_ROOTFS"/usr/src/*/dkms.conf >/dev/null 2>&1; then
        dkms_build
        unbind_pseudo "$TARGET_ROOTFS"
    fi

    setup_keyrings
    stage_desktop "$kver"
    setup_initramfs "$kver"
    clean_target
    unbind_pseudo "$TARGET_ROOTFS"; trap - EXIT
    log "packing $TARGET_IMAGE"
    rm -f "$TARGET_IMAGE"
    (cd "$TARGET_ROOTFS" && tar --xattrs --acls --numeric-owner -cf - . | zstd -T0 --long -15 -o "$TARGET_IMAGE")
    du -h "$TARGET_IMAGE"
}

dkms_build() {
    require_root "$@"
    local kver src name ver
    kver="$(kernel_tree "$TARGET_ROOTFS" linux-x)" || die "linux-x module tree is missing"
    arch-chroot "$TARGET_ROOTFS" dkms --version || true
    for src in "$TARGET_ROOTFS"/usr/src/*/dkms.conf; do
        [[ -f $src ]] || continue
        name="$(sed -n 's/^PACKAGE_NAME="\(.*\)"/\1/p' "$src" | head -1)"
        ver="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$src" | head -1)"
        [[ -n $name && -n $ver ]] || continue
        log "dkms: $name $ver for $kver"
        arch-chroot "$TARGET_ROOTFS" dkms add -m "$name" -v "$ver" || true
        arch-chroot "$TARGET_ROOTFS" dkms install -m "$name" -v "$ver" -k "$kver"
    done
    find "$TARGET_ROOTFS/usr/lib/modules/$kver" -maxdepth 2 -name '*.ko*' | head
    unbind_pseudo "$TARGET_ROOTFS"
}

stop_builds() {
    require_root "$@"
    pkill -9 -x mkarchiso 2>/dev/null || true
    pkill -9 -x pacstrap 2>/dev/null || true
    pkill -9 -x mksquashfs 2>/dev/null || true
    pkill -9 -x xorriso 2>/dev/null || true
}

build_iso() {
    require_root "$@"
    [[ -f $TARGET_IMAGE ]] || die "missing target image; run target first"
    rm -rf "$PROFILE_WORK"
    cp -a "$PROFILE_SRC" "$PROFILE_WORK"
    mkdir -p "$PROFILE_WORK/airootfs/root/xfull"
    install -Dm644 "$TARGET_IMAGE" "$PROFILE_WORK/airootfs/root/x-target.tar.zst"
    cp -a "$ROOT/installer" "$PROFILE_WORK/airootfs/root/xfull/installer"
    cp -a "$ASSETS" "$PROFILE_WORK/airootfs/root/xfull/assets"
    if [[ -f $VENDOR/x-repo.pub ]]; then
        install -Dm644 "$VENDOR/x-repo.pub" \
            "$PROFILE_WORK/airootfs/root/xfull/assets/x-repo.pub"
    fi
    chmod 755 "$PROFILE_WORK/airootfs/root/xfull/installer/xfull-install"
    local m
    for m in "$WORK"/mkarchiso/*/*/airootfs/{proc,sys,dev,run}; do
        mountpoint -q "$m" && umount -R "$m" 2>/dev/null || true
    done
    rm -rf "$WORK/mkarchiso"
    log "mkarchiso"
    mkarchiso -C "$ROOT/configs/pacman-build.conf" -v -w "$WORK/mkarchiso" -o "$OUT" "$PROFILE_WORK"
    find "$OUT" -maxdepth 1 -name '*.iso' -printf 'ISO: %p (%s bytes)\n'
}

finalize() {
    local iso name dest
    iso="$(find "$OUT" -maxdepth 1 -name '*.iso' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
    [[ -n $iso ]] || die "no ISO found"
    name="$(basename "$iso")"
    dest="$BUILD_HOME/Downloads"
    install -d -o "$BUILD_USER" -g "$BUILD_USER" "$dest"
    cp -f "$iso" "$dest/$name"
    (cd "$dest" && sha256sum "$name" > "$name.sha256")
    chown "$BUILD_USER:$BUILD_USER" "$dest/$name" "$dest/$name.sha256"
    # shellcheck disable=SC1091
    source "$KEYS/env.sh"
    if gpg --batch --yes --detach-sign -o "$dest/$name.sig" "$dest/$name" 2>/dev/null; then
        chown "$BUILD_USER:$BUILD_USER" "$dest/$name.sig"
        log "signed $dest/$name.sig"
    else
        warn "signing skipped"
    fi
    log "ready: $dest/$name"
}

case "${1:-}" in
    doctor) doctor ;;
    prepare) prepare_host "$@" ;;
    repair-host) repair_host "$@" ;;
    kernel-chroot) kernel_chroot "$@" ;;
    kernel-build) kernel_build "$@" ;;
    base) build_base "$@" ;;
    repo) build_repo "$@" ;;
    target) build_target "$@" ;;
    dkms) dkms_build "$@" ;;
    iso) build_iso "$@" ;;
    stop) stop_builds "$@" ;;
    all)
        require_root "$@"
        prepare_host
        as_build_user_bash fetch
        if ! ls "$VENDOR/x-kernel/out/linux-x/stable/"linux-x-*.pkg.tar.zst >/dev/null 2>&1; then
            kernel_chroot
            kernel_build
        fi
        as_build_user_bash aur
        build_base
        build_repo
        build_target
        build_iso
        finalize
        ;;
    fetch) if (( EUID == 0 )); then as_build_user_bash fetch; else fetch_all; fi ;;
    aur) if (( EUID == 0 )); then as_build_user_bash aur; else build_aur; fi ;;
    finalize) finalize ;;
    -h | --help | help | "") usage ;;
    *) usage >&2; exit 2 ;;
esac
