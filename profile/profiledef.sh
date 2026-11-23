#!/usr/bin/env bash
# X Full live ISO profile.
# shellcheck disable=SC2034

iso_name="x-full"
iso_label="X_FULL_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="X Linux <https://xscriptor.io/x>"
iso_application="X Full Installer"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux' 'uefi.grub')
packages_file="packages.x86_64"
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
# The prebuilt system image is already zstd-compressed. Keep it uncompressed
# inside the squashfs; compress the live root itself so it boots quickly.
airootfs_image_tool_options=(
  '-comp' 'zstd'
  '-Xcompression-level' '19'
  '-b' '1M'
  '-action' 'uncompressed@subpathname(root/x-target.tar.zst)'
)
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/root"]="0:0:750"
  ["/root/.bash_profile"]="0:0:755"
  ["/root/.zlogin"]="0:0:755"
  ["/root/xfull/installer/xfull-install"]="0:0:755"
)
