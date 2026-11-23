# Start the X Full installer on the live tty1 (zsh login shell) or on the
# serial console when the kernel command line asks for an automatic install.
if [[ -x /root/xfull/installer/xfull-install ]]; then
    if grep -qw 'xfull.auto=1' /proc/cmdline; then
        if [[ "$(tty)" == /dev/ttyS0 && ! -e /run/xfull-installer.started ]]; then
            : > /run/xfull-installer.started
            exec /root/xfull/installer/xfull-install
        fi
    elif ! grep -qw 'xfull.no_tui=1' /proc/cmdline && [[ "$(tty)" == /dev/tty1 ]] \
        && [[ ! -e /run/xfull-installer.started ]]; then
        : > /run/xfull-installer.started
        exec /root/xfull/installer/xfull-install
    fi
fi
