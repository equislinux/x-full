#!/usr/bin/env bash
# x-full build entrypoint.
#
#   doctor   host readiness report (no changes)
#   fetch    pin x/scripts/archiso inputs, kernel packages, AUR recipes,
#            the equisdots snapshot and the font
#   aur      build the AUR packages that go into the image
#   rootfs   build the prebuilt root filesystem with xpm
#   iso      build the live ISO with the root image and the installer
#   all      fetch + aur + rootfs + iso + copy to ~/Downloads
#   smoke    minimal xpm bootstrap test in a throwaway root
#
# Build steps need root (loop devices, mounts, mkarchiso) and re-exec
# themselves through sudo. Keys stay outside every git worktree, in
# <workspace>/keys.
set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SELF_DIR/.." && pwd)"
WS="${X_WORKSPACE:-$(cd -- "$ROOT/.." && pwd)}"
KEYS="${X_KEYS_DIR:-$WS/keys}"
VENDOR="$ROOT/vendor"
WORK="$ROOT/work"
OUT="$ROOT/out"
CACHE="$ROOT/.cache"
LOGS="$OUT/logs"
BUILD_USER="${SUDO_USER:-$(id -nu 1000 2>/dev/null || id -un)}"
BUILD_HOME="$(getent passwd "$BUILD_USER" | cut -d: -f6)"
ROOTFS="$WORK/rootfs"
PROFILE="$WORK/profile"
XPM_BUILD_CONF="$WORK/xpm-build.conf"

log() { printf '[x-full] %s\n' "$*"; }
warn() { printf '[x-full] warning: %s\n' "$*" >&2; }
die() { printf '[x-full] error: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

require_root() {
    if (( EUID != 0 )); then
        exec sudo -- "$0" "$@"
    fi
}

as_user() {
    runuser -u "$BUILD_USER" -- "$@"
}

load_keys() {
    [[ -f "$KEYS/env.sh" ]] || die "missing signing keyring: $KEYS/env.sh"
    # shellcheck disable=SC1090
    source "$KEYS/env.sh"
}

source_manifest() {
    local f=$1
    [[ -f "$f" ]] || die "missing manifest: $f"
    grep -v '^#' "$f" | sed '/^[[:space:]]*$/d'
}

ok=0
fail=0
check_cmd() {
    if command -v "$1" >/dev/null 2>&1; then
        printf 'OK   %-22s %s\n' "$1" "$(command -v "$1")"
        ok=$((ok + 1))
    else
        printf 'MISS %-22s\n' "$1"
        fail=$((fail + 1))
    fi
}
check_file() {
    if [[ -e $2 ]]; then
        printf 'OK   %-22s %s\n' "$1" "$2"
        ok=$((ok + 1))
    else
        printf 'MISS %-22s %s\n' "$1" "$2"
        fail=$((fail + 1))
    fi
}

prepare_host() {
    require_root "$@"
    if [[ ! -d /etc/pacman.d/gnupg ]]; then
        log "initializing the pacman keyring (mkarchiso/pacstrap)"
        pacman-key --init
        pacman-key --populate archlinux
    fi
}

doctor() {
    printf '== workspace ==\n'
    printf 'workspace: %s\nkeys:      %s\nroot:      %s\n\n' "$WS" "$KEYS" "$ROOT"
    printf '== tools ==\n'
    for c in xpm xpm-aur mkarchiso mkarchroot makepkg repo-add updpkgsums \
             mksquashfs xorriso zstd gpg git gh ssh qemu-system-x86_64 \
             swtpm shellcheck pacman-key tar; do
        check_cmd "$c"
    done
    printf '\n== keys ==\n'
    check_file "signing keyring" "$KEYS/env.sh"
    check_file "public key" "$KEYS/signing.pub"
    check_file "sourceforge key" "$BUILD_HOME/.ssh/id_ed25519_sourceforge"
    if [[ -f $KEYS/env.sh ]]; then
        # shellcheck disable=SC1090
        source "$KEYS/env.sh"
        local count
        count=$(gpg --batch --no-tty --list-secret-keys --with-colons 2>/dev/null |
            awk -F: '/^sec:/{c++} END{print c+0}')
        if (( count > 0 )); then
            printf 'OK   %-22s %s secret key(s)\n' "gpg secret keys" "$count"
            ok=$((ok + 1))
        else
            printf 'MISS %-22s no secret key in %s\n' "gpg secret keys" "$GNUPGHOME"
            fail=$((fail + 1))
        fi
    fi
    printf '\n== host ==\n'
    if [[ -d /etc/pacman.d/gnupg ]]; then
        printf 'OK   %-22s %s\n' "pacman keyring" "/etc/pacman.d/gnupg"
        ok=$((ok + 1))
    else
        printf 'MISS %-22s run pacman-key --init + --populate archlinux\n' "pacman keyring"
        fail=$((fail + 1))
    fi
    if [[ -c /dev/kvm ]]; then
        printf 'OK   %-22s %s\n' "kvm" "/dev/kvm"
        ok=$((ok + 1))
    else
        printf 'MISS %-22s %s\n' "kvm" "/dev/kvm"
        fail=$((fail + 1))
    fi
    local avail
    avail=$(df -Pk "$WS" | awk 'NR==2{print int($4/1024/1024)}')
    if (( avail >= 60 )); then
        printf 'OK   %-22s %s GiB free\n' "disk" "$avail"
        ok=$((ok + 1))
    else
        printf 'MISS %-22s %s GiB free, need >= 60 GiB\n' "disk" "$avail"
        fail=$((fail + 1))
    fi
    printf '\n== result ==\nok=%d missing=%d\n' "$ok" "$fail"
    (( fail == 0 ))
}


download_parallel() {
    local url=$1 out=$2
    local final size chunks part_size part_dir i start end pids=() pid fail=0
    final=$(curl -sIL --max-time 30 "$url" | awk 'tolower($1)=="location:"{l=$2} END{print l}' | tr -d '\r')
    [[ -n $final ]] || final=$url
    size=$(curl -sIL --max-time 30 "$url" | awk 'tolower($1)=="content-length:"{s=$2} END{print s}' | tr -d '\r')
    if ! [[ $size =~ ^[0-9]+$ ]] || (( size < 4*1024*1024 )); then
        curl -fsSL --retry 3 -o "$out" "$url"
        return 0
    fi
    chunks=12
    part_size=$(( (size + chunks - 1) / chunks ))
    part_dir=$(mktemp -d "$CACHE/dl.XXXXXX")
    log "downloading $(basename "$out") ($size bytes, $chunks ranges)"
    for (( i=0; i<chunks; i++ )); do
        start=$(( i * part_size ))
        end=$(( start + part_size - 1 ))
        (( end >= size )) && end=$(( size - 1 ))
        curl -fsSL --retry 3 -r "$start-$end" -o "$part_dir/$i" "$final" &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || fail=1
    done
    if (( fail != 0 )); then
        rm -rf "$part_dir"
        die "parallel download failed: $url"
    fi
    : > "$out"
    for (( i=0; i<chunks; i++ )); do cat "$part_dir/$i" >> "$out"; done
    rm -rf "$part_dir"
    if (( $(stat -c %s "$out") != size )); then
        rm -f "$out"
        die "download size mismatch: $out"
    fi
}

git_clone_at() {
    local url=$1 sha=$2 dir=$3
    if [[ -d $dir/.git ]]; then
        as_user git -C "$dir" fetch --depth 1 origin "$sha" >/dev/null 2>&1 ||
            as_user git -C "$dir" fetch origin >/dev/null 2>&1 || true
    else
        rm -rf "$dir"
        as_user git clone --filter=blob:none "$url" "$dir" >/dev/null 2>&1 ||
            die "could not clone $url"
    fi
    as_user git -C "$dir" checkout -q "$sha" || die "$dir: commit $sha not found"
}

fetch() {
    require_root "$@"
    install -d -o "$BUILD_USER" -g "$BUILD_USER" "$VENDOR" "$VENDOR/aur" "$VENDOR/kernel"
    chown -R "$BUILD_USER:$BUILD_USER" "$VENDOR" 2>/dev/null || true
    install -d "$WORK" "$OUT" "$OUT/pkgs" "$LOGS" "$CACHE"

    local x_sha scripts_sha
    x_sha="$(head -1 "$ROOT/manifests/x.sha")"
    scripts_sha="$(head -1 "$ROOT/manifests/scripts.sha")"
    log "x: $x_sha"
    git_clone_at https://github.com/equislinux/x.git "$x_sha" "$VENDOR/x"
    log "scripts: $scripts_sha"
    git_clone_at https://github.com/equislinux/scripts.git "$scripts_sha" "$VENDOR/scripts"

    log "AUR recipes"
    local p sha
    for p in xwww-bin xfetch-bin; do
        sha="$(awk -v p="$p" '$1==p{print $2; exit}' "$ROOT/manifests/aur.lock" 2>/dev/null || true)"
        if [[ -n $sha ]]; then
            git_clone_at "https://aur.archlinux.org/$p.git" "$sha" "$VENDOR/aur/$p"
        else
            as_user git clone --depth 1 "https://aur.archlinux.org/$p.git" "$VENDOR/aur/$p" >/dev/null 2>&1 ||
                die "could not clone AUR $p"
        fi
    done

    log "equisdots snapshot"
    if [[ ! -d $VENDOR/equisdots-config/equisdots ]]; then
        as_user env X_VENDOR_LOCK="$VENDOR/scripts/packaging/vendor-config.lock" \
            bash "$VENDOR/scripts/packaging/vendor-config.sh" "$VENDOR/scripts" ||
            die "vendor-config failed"
        rm -rf "$VENDOR/equisdots-config"
        cp -a "$VENDOR/scripts/packaging/.vendor/x-config" "$VENDOR/equisdots-config"
    fi

    log "HackNerdFont"
    if [[ ! -f $VENDOR/HackNerdFont-Regular.ttf ]]; then
        curl -fsSL --retry 3 --connect-timeout 15 \
            -o "$VENDOR/HackNerdFont-Regular.ttf" \
            "https://raw.githubusercontent.com/xscriptor-colors/terminal/main/assets/fonts/HackNerdFont/HackNerdFont-Regular.ttf" ||
            die "could not download HackNerdFont"
    fi

    log "linux-x packages"
    local base version f
    version="$(awk -F'\t' '$1=="version"{print $2}' "$ROOT/manifests/kernel.tsv")"
    base="$(awk -F'\t' '$1=="base"{print $2}' "$ROOT/manifests/kernel.tsv")"
    [[ -n $version && -n $base ]] || die "invalid kernel.tsv"
    curl -fsSL --retry 3 -o "$VENDOR/kernel/SHA256SUMS" "$base/SHA256SUMS"
    curl -fsSL --retry 3 -o "$VENDOR/kernel/SHA256SUMS.sig" "$base/SHA256SUMS.sig"
    while IFS= read -r f; do
        [[ -n $f && $f != \#* ]] || continue
        case "$f" in version*|base*) continue ;; esac
        if [[ -f $VENDOR/kernel/$f ]] &&
           (cd "$VENDOR/kernel" && grep -F " $f" SHA256SUMS | sha256sum -c --status -); then
            log "reuse verified $f"
            continue
        fi
        case "$f" in
            *.pkg.tar.zst) download_parallel "$base/$f" "$VENDOR/kernel/$f" ;;
            *) curl -fsSL --retry 3 -o "$VENDOR/kernel/$f" "$base/$f" ;;
        esac
    done < "$ROOT/manifests/kernel.tsv"
    (cd "$VENDOR/kernel" && sha256sum -c --ignore-missing SHA256SUMS >/dev/null) ||
        die "kernel checksum verification failed"
    load_keys
    gpg --batch --verify "$VENDOR/kernel/SHA256SUMS.sig" "$VENDOR/kernel/SHA256SUMS" >/dev/null 2>&1 ||
        die "kernel SHA256SUMS signature verification failed"
    for f in "$VENDOR"/kernel/*.pkg.tar.zst.sig; do
        [[ -f $f ]] || continue
        gpg --batch --verify "$f" "${f%.sig}" >/dev/null 2>&1 ||
            die "kernel signature verification failed: $f"
    done
    log "kernel $version verified"

    printf 'x=%s\nscripts=%s\narchiso=%s\nkernel=%s\nbuilt_at=%s\n' \
        "$x_sha" "$scripts_sha" "$(head -1 "$ROOT/manifests/archiso.version")" "$version" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT/manifest.txt"
    log "fetch complete"
}

build_aur() {
    require_root "$@"
    install -d "$OUT/pkgs"
    local p dir pkg
    for p in xwww-bin xfetch-bin; do
        dir="$VENDOR/aur/$p"
        [[ -d $dir ]] || die "AUR recipe missing: $p (run fetch)"
        log "building $p"
        as_user bash -c 'cd "$1" && makepkg -f --nodeps --noconfirm' _ "$dir" ||
            die "makepkg failed for $p"
        for pkg in "$dir"/*.pkg.tar.zst; do
            [[ -f $pkg ]] || continue
            [[ $pkg == *-debug-* ]] && continue
            cp -f "$pkg" "$OUT/pkgs/"
        done
    done
    log "AUR packages: $(find "$OUT/pkgs" -maxdepth 1 -name '*.pkg.tar.zst' | wc -l)"
}

write_xpm_build_conf() {
    local root=$1 db=$2 cache=$3 gpg=$4
    cat > "$XPM_BUILD_CONF" <<EOF
[options]
root_dir = "$root"
db_path = "$db"
cache_dir = "$cache"
log_file = "$root/var/log/xpm.log"
gpg_dir = "$gpg"
mirror_pacman = false
shell_integration = false
sig_level = "never"
database_sig_level = "never"
architecture = "x86_64"
color = false
parallel_downloads = 5

[[repo]]
name = "x"
server = ["https://equislinux.github.io/x-repo/repo/x86_64"]

[[repo]]
name = "core"
server = ["https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"]

[[repo]]
name = "extra"
server = ["https://geo.mirror.pkgbuild.com/\$repo/os/\$arch"]
EOF
}

bind_pseudo() {
    local root=$1
    mkdir -p "$root"/dev "$root"/proc "$root"/sys "$root"/run
    mount --rbind /dev "$root/dev"
    mount --rbind /proc "$root/proc"
    mount --rbind /sys "$root/sys"
    mount --rbind /run "$root/run"
}

unbind_pseudo() {
    local root=$1 p
    for p in run sys proc dev; do
        mountpoint -q "$root/$p" && umount -R "$root/$p" 2>/dev/null || true
        mountpoint -q "$root/$p" && umount -Rl "$root/$p" 2>/dev/null || true
    done
}

smoke() {
    require_root "$@"
    local root="$WORK/smoke"
    rm -rf "$root"
    mkdir -p "$root/var/lib/xpm" "$root/etc/xpm/gnupg"
    write_xpm_build_conf "$root" "$root/var/lib/xpm" "$CACHE/xpm" "$root/etc/xpm/gnupg"
    bind_pseudo "$root"
    trap 'unbind_pseudo "$WORK/smoke"' EXIT
    log "xpm bootstrap smoke test"
    xpm --config "$XPM_BUILD_CONF" bootstrap --root "$root" \
        --dbpath "$root/var/lib/xpm" --cachedir "$CACHE/xpm" \
        --no-confirm --scriptlets=auto --no-shell-integration bash
    chroot "$root" bash --version | head -1
    unbind_pseudo "$root"
    trap - EXIT
    rm -rf "$root"
    log "smoke test passed"
}

prepare_rootfs() {
    require_root "$@"
    rm -rf "$ROOTFS"
    mkdir -p "$ROOTFS/var/lib/xpm" "$ROOTFS/etc/xpm/gnupg"
    write_xpm_build_conf "$ROOTFS" "$ROOTFS/var/lib/xpm" "$CACHE/xpm" "$ROOTFS/etc/xpm/gnupg"

    local -a pkgs
    mapfile -t pkgs < <(grep -v '^#' "$ROOT/manifests/packages.x86_64" | sed '/^[[:space:]]*$/d')
    (( ${#pkgs[@]} > 0 )) || die "empty package list"

    log "xpm bootstrap seed and base into $ROOTFS"
    bind_pseudo "$ROOTFS"
    trap 'unbind_pseudo "$ROOTFS"' EXIT
    xpm --config "$XPM_BUILD_CONF" bootstrap --root "$ROOTFS" \
        --dbpath "$ROOTFS/var/lib/xpm" --cachedir "$CACHE/xpm" \
        --no-confirm --scriptlets=auto --no-shell-integration \
        filesystem bash grep sed gawk coreutils findutils
    xpm --config "$XPM_BUILD_CONF" install --root "$ROOTFS" \
        --dbpath "$ROOTFS/var/lib/xpm" --cachedir "$CACHE/xpm" \
        --no-confirm --scriptlets=auto --no-shell-integration --needed base
    log "xpm install target package set (${#pkgs[@]} packages)"
    xpm --config "$XPM_BUILD_CONF" install --root "$ROOTFS" \
        --dbpath "$ROOTFS/var/lib/xpm" --cachedir "$CACHE/xpm" \
        --no-confirm --scriptlets=auto --no-shell-integration --needed "${pkgs[@]}"
    unbind_pseudo "$ROOTFS"
    trap - EXIT

    log "local packages (kernel + AUR)"
    local -a local_pkgs=()
    local f
    for f in "$VENDOR"/kernel/*.pkg.tar.zst "$OUT"/pkgs/*.pkg.tar.zst; do
        [[ -f $f ]] || continue
        local_pkgs+=("$f")
    done
    (( ${#local_pkgs[@]} > 0 )) || die "no local packages; run fetch and aur first"
    xpm --config "$XPM_BUILD_CONF" install --root "$ROOTFS" \
        --dbpath "$ROOTFS/var/lib/xpm" --cachedir "$CACHE/xpm" \
        --no-confirm --scriptlets=skip --needed "${local_pkgs[@]}"

    log "NVIDIA packages"
    local -a nv
    mapfile -t nv < <(grep -v '^#' "$ROOT/manifests/packages.nvidia" | sed '/^[[:space:]]*$/d')
    xpm --config "$XPM_BUILD_CONF" install --root "$ROOTFS" \
        --dbpath "$ROOTFS/var/lib/xpm" --cachedir "$CACHE/xpm" \
        --no-confirm --scriptlets=skip --needed "${nv[@]}"

    log "equisdots snapshot and font"
    install -d "$ROOTFS/usr/share/x/config" "$ROOTFS/usr/share/fonts/HackNerdFont"
    cp -a "$VENDOR/equisdots-config/." "$ROOTFS/usr/share/x/config/"
    install -m 0644 "$VENDOR/HackNerdFont-Regular.ttf" \
        "$ROOTFS/usr/share/fonts/HackNerdFont/HackNerdFont-Regular.ttf"
    python3 "$ROOT/overlay/patch-hyprland.py" "$ROOTFS/usr/share/x/tools/hyprland-install.sh"

    log "online xpm config for the installed system"
    cat > "$ROOTFS/etc/xpm.conf" <<'EOF'
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
parallel_downloads = 5

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

    log "cleaning machine-specific state"
    rm -f "$ROOTFS/etc/fstab" "$ROOTFS/etc/machine-id" "$ROOTFS/etc/hostname" \
          "$ROOTFS/etc/locale.conf" "$ROOTFS/etc/vconsole.conf" "$ROOTFS/etc/localtime"
    find "$ROOTFS/home" -mindepth 1 -delete 2>/dev/null || true
    find "$ROOTFS/root" -mindepth 1 -delete 2>/dev/null || true
    find "$ROOTFS/boot" -mindepth 1 -delete 2>/dev/null || true
    find "$ROOTFS/var/cache/xpm/pkg" -mindepth 1 -delete 2>/dev/null || true
    find "$ROOTFS/var/cache/pacman/pkg" -mindepth 1 -delete 2>/dev/null || true
    find "$ROOTFS/var/log" -mindepth 1 -delete 2>/dev/null || true
    find "$ROOTFS/var/tmp" -mindepth 1 -delete 2>/dev/null || true
    find "$ROOTFS/tmp" -mindepth 1 -delete 2>/dev/null || true
    rm -rf "$ROOTFS/etc/xpm/gnupg" "$ROOTFS/etc/pacman.d/gnupg"
    rm -rf "$ROOTFS/var/lib/x/generations" "$ROOTFS/var/lib/x/current" \
           "$ROOTFS/var/lib/x/boot" "$ROOTFS/var/lib/x/pending"
    rm -f "$ROOTFS/var/lib/xpm/transaction.lock"
    rm -f "$ROOTFS/var/lib/systemd/random-seed"
    rm -f "$ROOTFS"/etc/ssh/ssh_host_* 2>/dev/null || true
    find "$ROOTFS/etc/NetworkManager/system-connections" -mindepth 1 -delete 2>/dev/null || true
    find "$ROOTFS/var/lib/NetworkManager" -mindepth 1 -delete 2>/dev/null || true

    log "packing $OUT/x-rootfs.tar.zst"
    tar --xattrs --acls --numeric-owner -C "$ROOTFS" \
        --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
        --exclude='./tmp/*' --exclude='./var/cache/*' --exclude='./var/log/*' \
        --exclude='./var/tmp/*' --exclude='./boot/*' --exclude='./home/*' \
        --exclude='./root/*' --exclude='./etc/fstab' --exclude='./etc/machine-id' \
        --exclude='./etc/hostname' --exclude='./etc/locale.conf' \
        --exclude='./etc/vconsole.conf' --exclude='./etc/localtime' \
        -cf - . | zstd -T0 -15 -o "$OUT/x-rootfs.tar.zst"
    du -h "$OUT/x-rootfs.tar.zst"
}

set_profiledef() {
    local profile=$1
    python3 - "$profile/profiledef.sh" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('iso_name="x"', 'iso_name="x-full"')
s = s.replace('iso_application="X Live/Rescue DVD"', 'iso_application="X Full Installer"')
new = """airootfs_image_type="squashfs"
airootfs_image_tool_options=(
  '-comp' 'zstd'
  '-Xcompression-level' '19'
  '-b' '1M'
  '-action' 'uncompressed@subpathname(root/x-installer/x-rootfs.tar.zst)'
)"""
s = re.sub(r'airootfs_image_type="squashfs"\nairootfs_image_tool_options=\([^)]*\)', new, s, count=1)
p.write_text(s)
PY
}

build_iso() {
    require_root "$@"
    rm -rf "$PROFILE"
    mkdir -p "$PROFILE"
    cp -a "$VENDOR/x/." "$PROFILE/"
    rm -rf "$PROFILE/.git" "$PROFILE/work" "$PROFILE/out"
    cp -a "$ROOT/overlay/airootfs/." "$PROFILE/airootfs/"
    install -Dm644 "$OUT/x-rootfs.tar.zst" "$PROFILE/airootfs/root/x-installer/x-rootfs.tar.zst"
    if ! grep -qx zstd "$PROFILE/packages.x86_64"; then
        printf 'zstd\n' >> "$PROFILE/packages.x86_64"
    fi
    set_profiledef "$PROFILE"
    log "mkarchiso"
    mkarchiso -C "$ROOT/configs/pacman-build.conf" -v \
        -w "$WORK/mkarchiso" -o "$OUT" "$PROFILE"
    log "ISO files:"
    find "$OUT" -maxdepth 1 -name '*.iso' -printf '  %p (%s bytes)\n'
}

finalize() {
    local iso name dest
    iso="$(find "$OUT" -maxdepth 1 -name '*.iso' -print -quit)"
    [[ -n $iso ]] || die "no ISO found in $OUT"
    name="$(basename "$iso")"
    dest="$BUILD_HOME/Downloads"
    install -d -o "$BUILD_USER" -g "$BUILD_USER" "$dest"
    cp -f "$iso" "$dest/$name"
    chown "$BUILD_USER:$BUILD_USER" "$dest/$name"
    (cd "$dest" && sha256sum "$name" > "$name.sha256")
    chown "$BUILD_USER:$BUILD_USER" "$dest/$name.sha256"
    load_keys
    if gpg --batch --yes --detach-sign -o "$dest/$name.sig" "$dest/$name" 2>/dev/null; then
        chown "$BUILD_USER:$BUILD_USER" "$dest/$name.sig"
        log "signed: $dest/$name.sig"
    else
        warn "ISO signing skipped (GPG key needs a passphrase or is unavailable)"
    fi
    log "ready: $dest/$name"
}

case "${1:-}" in
    doctor) doctor ;;
    prepare) prepare_host "$@" ;;
    fetch) fetch "$@" ;;
    aur) build_aur "$@" ;;
    smoke) smoke "$@" ;;
    rootfs) prepare_rootfs "$@" ;;
    iso) build_iso "$@" ;;
    all)
        require_root "$@"
        prepare_host
        fetch
        build_aur
        prepare_rootfs
        build_iso
        finalize
        ;;
    finalize) finalize ;;
    -h | --help | help | "") usage ;;
    *) usage >&2; exit 2 ;;
esac
