#!/usr/bin/env bash
# x-full build entrypoint.
#
# Steps:
#   doctor   host readiness report (no changes, no root)
#   repo     build the local package set (Arch + AUR + X)
#   image    build the prebuilt btrfs root image
#   iso      build the live ISO with the root image and local delta
#   all      repo + image + iso
#
# The build steps need root (loop devices, mounts, mkarchiso) and re-exec
# themselves through sudo. The narrow rule lives in
# utils/bin/equislinux-sudo. The workspace keys stay outside every git
# worktree, in <workspace>/keys.
set -Eeuo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SELF_DIR/.." && pwd)"
WS="${X_WORKSPACE:-$(cd -- "$ROOT/.." && pwd)}"
KEYS="${X_KEYS_DIR:-$WS/keys}"

usage() {
    sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

require_root() {
    if (( EUID != 0 )); then
        exec sudo -- "$0" "$@"
    fi
}

ok=0
fail=0

check_cmd() {
    local c=$1
    if command -v "$c" >/dev/null 2>&1; then
        printf 'OK   %-22s %s\n' "$c" "$(command -v "$c")"
        ok=$((ok + 1))
    else
        printf 'MISS %-22s\n' "$c"
        fail=$((fail + 1))
    fi
}

check_file() {
    local label=$1 path=$2
    if [[ -e $path ]]; then
        printf 'OK   %-22s %s\n' "$label" "$path"
        ok=$((ok + 1))
    else
        printf 'MISS %-22s %s\n' "$label" "$path"
        fail=$((fail + 1))
    fi
}

doctor() {
    printf '== workspace ==\n'
    printf 'workspace: %s\n' "$WS"
    printf 'keys:      %s\n' "$KEYS"
    printf 'root:      %s\n\n' "$ROOT"

    printf '== tools ==\n'
    for c in xpm xpm-aur mkarchiso mkarchroot makepkg repo-add updpkgsums \
             mksquashfs xorriso zstd gpg git gh ssh qemu-system-x86_64 \
             swtpm shellcheck pacman-key; do
        check_cmd "$c"
    done

    printf '\n== keys ==\n'
    check_file "signing keyring" "$KEYS/env.sh"
    check_file "public key" "$KEYS/signing.pub"
    check_file "sourceforge key" "$HOME/.ssh/id_ed25519_sourceforge"
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

    printf '\n== result ==\n'
    printf 'ok=%d missing=%d\n' "$ok" "$fail"
    (( fail == 0 ))
}

case "${1:-}" in
    doctor)
        doctor
        ;;
    repo | image | iso | all)
        require_root "$@"
        printf '[x-full] step "%s" is not implemented yet\n' "$1" >&2
        exit 2
        ;;
    -h | --help | help | "")
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
