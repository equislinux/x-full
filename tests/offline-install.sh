#!/usr/bin/env bash
# Offline install smoke test for x-full.
#
# Boots the ISO in QEMU (UEFI, KVM, no NIC), performs an automatic install on
# a fresh virtio disk, measures the installer time, then boots the installed
# system and waits for the graphical target on the serial console.
#
# Usage: tests/offline-install.sh [ISO]
# Env:   BUDGET=90 (install seconds)  BOOT_TIMEOUT=180  BOOT_CHECK=1  KEEP=0
#        OVMF_CODE=/usr/share/edk2/x64/OVMF_CODE.4m.fd
#        OVMF_VARS=/usr/share/edk2/x64/OVMF_VARS.4m.fd
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/tests/.run"
BUDGET="${BUDGET:-90}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-180}"
BOOT_CHECK="${BOOT_CHECK:-1}"
KEEP="${KEEP:-0}"
LUKS="${LUKS:-0}"
LOGIN_CHECK="${LOGIN_CHECK:-1}"
BOOT="${BOOT:-grub}"
BIOS="${BIOS:-0}"
OVMF_CODE="${OVMF_CODE:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"

say() { printf '[x-full test] %s\n' "$*"; }
die() { printf '[x-full test] error: %s\n' "$*" >&2; exit 1; }

ISO="${1:-}"
if [[ -z $ISO ]]; then
    ISO="$(find "$ROOT/out" -maxdepth 1 -name '*.iso' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
fi
[[ -f $ISO ]] || die "no ISO found (pass one as an argument)"

for c in qemu-system-x86_64 qemu-img xorriso blkid timeout; do
    command -v "$c" >/dev/null 2>&1 || die "missing tool: $c"
done
if [[ $BIOS != 1 ]]; then
    [[ -r $OVMF_CODE && -r $OVMF_VARS ]] || die "OVMF firmware not found in $OVMF_CODE"
fi

ISO_UUID="$(blkid -p -s UUID -o value "$ISO" 2>/dev/null || true)"
[[ -n $ISO_UUID ]] || die "cannot read the ISO UUID: $ISO"

rm -rf "$RUN"
mkdir -p "$RUN"
if [[ $BIOS != 1 ]]; then cp "$OVMF_VARS" "$RUN/OVMF_VARS.fd"; fi
qemu-img create -f qcow2 "$RUN/disk.qcow2" 40G >/dev/null

say "extracting the live kernel and initramfs"
xorriso -osirrox on -indev "$ISO" \
    -extract /arch/boot/x86_64/vmlinuz-linux "$RUN/vmlinuz" \
    -extract /arch/boot/x86_64/initramfs-linux.img "$RUN/initramfs" 2>/dev/null
[[ -s $RUN/vmlinuz && -s $RUN/initramfs ]] || die "could not extract the live boot files"

# shellcheck disable=SC2054  # commas inside -drive/-machine values
qemu_common=(-machine q35 -accel kvm -cpu host -m 6144 -smp 4)
if [[ $BIOS != 1 ]]; then
    # shellcheck disable=SC2054  # commas inside -drive values
    qemu_common+=(
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE"
        -drive if=pflash,format=raw,file="$RUN/OVMF_VARS.fd"
    )
fi
# shellcheck disable=SC2054  # commas inside -drive values
qemu_common+=(
    -drive if=virtio,format=qcow2,file="$RUN/disk.qcow2"
    -nic none -display none -no-reboot
)

append="archisobasedir=arch archisosearchuuid=$ISO_UUID console=ttyS0,115200"
append+=" xfull.auto=1 xfull.disk=/dev/vda xfull.mode=wipe xfull.esp=2"
if [[ $LUKS == 1 ]]; then
    append+=" xfull.encrypt=yes xfull.luks_pass=test"
else
    append+=" xfull.encrypt=no"
fi
append+=" xfull.user=x xfull.pass=test"
append+=" xfull.locale=es_ES.UTF-8 xfull.keymap=es xfull.timezone=Europe/Madrid"
append+=" xfull.boot=$BOOT xfull.cmdline=console=ttyS0,115200 xfull.poweroff=1"

say "installing (budget ${BUDGET}s)"
set +e
timeout --foreground $((BUDGET + 240)) qemu-system-x86_64 "${qemu_common[@]}" \
    -drive file="$ISO",media=cdrom,readonly=on \
    -kernel "$RUN/vmlinuz" -initrd "$RUN/initramfs" \
    -append "$append" \
    -serial "file:$RUN/install.log"
rc=$?
set -e
if (( rc != 0 )); then
    tail -n 40 "$RUN/install.log" 2>/dev/null || true
    die "QEMU exited with rc=$rc during the install"
fi

grep -q 'installation complete' "$RUN/install.log" \
    || { tail -n 60 "$RUN/install.log"; die "the installer did not report completion"; }
seconds="$(grep -o 'XFULL_DONE seconds=[0-9]*' "$RUN/install.log" | tail -1 | cut -d= -f2)"
[[ -n $seconds ]] || die "the installer did not report XFULL_DONE"
if (( seconds > BUDGET )); then
    die "install took ${seconds}s, over the ${BUDGET}s budget"
fi
grep -q 'XFULL_GEN=ok' "$RUN/install.log" || say "warning: the first generation was not recorded"
say "install completed in ${seconds}s (budget ${BUDGET}s)"

if [[ $BOOT_CHECK == 1 ]]; then
    say "booting the installed system"
    if [[ $LUKS == 1 ]]; then
        ( sleep 15; printf 'test\n'; sleep 15; printf 'x\n'; sleep 2; printf 'test\n'; \
          sleep 2; printf 'id\n'; sleep 1; printf 'Hyprland --verify-config >/dev/null 2>&1 && echo MARK-CONFIG-OK\n'; \
          sleep 1; printf 'firefox --version >/dev/null 2>&1 && echo MARK-BROWSER-OK\n'; \
          sleep 1; printf "command -v kitty >/dev/null 2>&1 && test -f \"\$HOME/.config/kitty/shaders/x-trail.pipeline\" && command -v slangc >/dev/null 2>&1 && echo MARK-KITTY-OK\n"; \
          sleep 2; printf 'echo MARK-LOGIN-OK\n'; sleep 4 ) | \
            timeout --foreground "$BOOT_TIMEOUT" qemu-system-x86_64 "${qemu_common[@]}" \
                -serial stdio > "$RUN/boot.log" 2>&1 &
    else
        ( sleep 20; printf 'x\n'; sleep 2; printf 'test\n'; \
          sleep 2; printf 'id\n'; sleep 1; printf 'Hyprland --verify-config >/dev/null 2>&1 && echo MARK-CONFIG-OK\n'; \
          sleep 1; printf 'firefox --version >/dev/null 2>&1 && echo MARK-BROWSER-OK\n'; \
          sleep 1; printf "command -v kitty >/dev/null 2>&1 && test -f \"\$HOME/.config/kitty/shaders/x-trail.pipeline\" && command -v slangc >/dev/null 2>&1 && echo MARK-KITTY-OK\n"; \
          sleep 2; printf 'echo MARK-LOGIN-OK\n'; sleep 4 ) | \
            timeout --foreground "$BOOT_TIMEOUT" qemu-system-x86_64 "${qemu_common[@]}" \
                -serial stdio > "$RUN/boot.log" 2>&1 &
    fi
    qpid=$!
    booted=0; logged=0; config_ok=0; browser_ok=0; kitty_ok=0
    for ((i = 0; i < BOOT_TIMEOUT; i += 2)); do
        if grep -qE 'Graphical Interface|Simple Desktop Display Manager|Startup finished in' "$RUN/boot.log" 2>/dev/null; then
            booted=1
        fi
        if grep -q 'MARK-LOGIN-OK' "$RUN/boot.log" 2>/dev/null; then logged=1; fi
        if grep -q 'MARK-CONFIG-OK' "$RUN/boot.log" 2>/dev/null; then config_ok=1; fi
        if grep -q 'MARK-BROWSER-OK' "$RUN/boot.log" 2>/dev/null; then browser_ok=1; fi
        if grep -q 'MARK-KITTY-OK' "$RUN/boot.log" 2>/dev/null; then kitty_ok=1; fi
        if (( logged == 1 && config_ok == 1 && browser_ok == 1 && kitty_ok == 1 )); then break; fi
        if (( booted == 1 )) && [[ $LOGIN_CHECK != 1 ]]; then break; fi
        if ! kill -0 "$qpid" 2>/dev/null; then break; fi
        sleep 2
    done
    kill "$qpid" 2>/dev/null || true
    wait "$qpid" 2>/dev/null || true
    if (( booted != 1 )); then
        tail -n 60 "$RUN/boot.log" 2>/dev/null || true
        die "the installed system did not reach graphical.target"
    fi
    if [[ $LOGIN_CHECK == 1 ]] && (( logged != 1 || config_ok != 1 || browser_ok != 1 || kitty_ok != 1 )); then
        tail -n 90 "$RUN/boot.log" 2>/dev/null || true
        die "the installed system did not verify login, Hyprland config, Firefox and kitty shaders"
    fi
    say "installed system reached graphical.target"
    if [[ $LOGIN_CHECK == 1 ]]; then say "user login, Hyprland config, Firefox and kitty shaders verified"; fi
fi

say "PASS  install=${seconds}s  boot=${BOOT}  luks=${LUKS}  bios=${BIOS}  login=${LOGIN_CHECK}"
say "disk: $RUN/disk.qcow2"
if [[ $KEEP != 1 ]]; then
    rm -rf "$RUN"
fi
