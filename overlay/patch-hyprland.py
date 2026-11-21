#!/usr/bin/env python3
"""Patch the packaged hyprland-install.sh for the offline x-full image.

Two changes:
  1. X_HYPR_SKIP_PKGS=1 skips the package/AUR installation section.
  2. The font step prefers the system HackNerdFont shipped in the image.
"""
import pathlib
import sys

PKG_START = "# --- package split: official (repos) vs AUR ---------------------------------"
PAYLOAD_START = "# --- user payload: mirror `dots install` (offline) or delegate to dots -----"
FONT_OLD = '''    wget -q -O "$FONT" \\
        "https://raw.githubusercontent.com/xscriptor-colors/terminal/main/assets/fonts/HackNerdFont/HackNerdFont-Regular.ttf" \\
        || warn "font download failed"
'''


def fail(msg: str) -> None:
    print(f"patch-hyprland: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: patch-hyprland.py <hyprland-install.sh>")
    path = pathlib.Path(sys.argv[1])
    text = path.read_text()

    if 'X_HYPR_SKIP_PKGS' not in text:
        if PKG_START not in text:
            fail("package section marker not found")
        if PAYLOAD_START not in text:
            fail("payload section marker not found")
        text = text.replace(
            PKG_START,
            PKG_START
            + '\nif [[ "${X_HYPR_SKIP_PKGS:-0}" != "1" ]]; then\n',
            1,
        )
        text = text.replace(
            PAYLOAD_START,
            "fi\n\n" + PAYLOAD_START,
            1,
        )

    if "/usr/share/fonts/HackNerdFont/HackNerdFont-Regular.ttf" not in text:
        if FONT_OLD not in text:
            fail("font download block not found")
        text = text.replace(
            FONT_OLD,
            "    if [[ -f /usr/share/fonts/HackNerdFont/HackNerdFont-Regular.ttf ]]; then\n"
            '        install -m 0644 /usr/share/fonts/HackNerdFont/HackNerdFont-Regular.ttf "$FONT"\n'
            "    else\n"
            + FONT_OLD
            + "    fi\n",
            1,
        )

    path.write_text(text)
    print(f"patched {path}")


if __name__ == "__main__":
    main()
