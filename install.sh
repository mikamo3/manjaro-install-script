#!/usr/bin/env bash
set -e
# params
PACMAN_COUNTRY="Japan"
BOOT_PARTITION_SIZE="512M"
ROOT_PARTITION_SIZE=""
INSTALL_TARGET_PATH=
HOSTNAME="manjaro-main"

install_packages_for_install() {
  echo "Install Packages for install"
  pacman-mirrors -c "$PACMAN_COUNTRY"
  pacman -Sy
  pacman -S --noconfirm arch-install-scripts fzf gdisk
}

create_partition() {
  echo "Partition Layout"
  INSTALL_TARGET_PATH="$(
    lsblk -pno NAME,SIZE,TYPE,MODEL \
      | grep ^/ \
      | fzf --header="Select Installation target Disk" \
      | awk '{print $1}'
  )"

  [[ -z $INSTALL_TARGET_PATH ]] && {
    echo "abort"
    return 1
  }

  if [[ $(lsblk "$INSTALL_TARGET_PATH" -pnlo NAME | grep -cE "^$INSTALL_TARGET_PATH.+") -gt 0 ]]; then
    echo -n "$INSTALL_TARGET_PATH contains data. Do you want to format? (y/N) : "
    read -r
    [[ $REPLY =~ ^[Yy]$ ]] || {
      echo "abort"
      return 1
    }
  fi

  sgdisk -Z "$INSTALL_TARGET_PATH"
  sgdisk -n "0::$BOOT_PARTITION_SIZE" -t "0:ef00" "$INSTALL_TARGET_PATH"
  sgdisk -n "0::$ROOT_PARTITION_SIZE" -t "0:8300" "$INSTALL_TARGET_PATH"
  mkfs.vfat -F32 "$(lsblk "$INSTALL_TARGET_PATH" -pnlo NAME | grep -E "^$INSTALL_TARGET_PATH.+" | sed -n 1p)"
  mkfs.btrfs "$(lsblk "$INSTALL_TARGET_PATH" -pnlo NAME | grep -E "^$INSTALL_TARGET_PATH.+" | sed -n 2p)"
}

make_subvolumes() {
  echo "make subvolumes"
  root_path="$(lsblk "$INSTALL_TARGET_PATH" -pnlo NAME | grep -E "^$INSTALL_TARGET_PATH.+" | sed -n 2p)"
  mount "$root_path" /mnt
  cd /mnt
  btrfs subvolume create @
  btrfs subvolume create @home
  btrfs subvolume create @var
  cd /
  umount /mnt
}

mount_partition() {
  echo "mount partition"
  boot_path="$(lsblk "$INSTALL_TARGET_PATH" -pnlo NAME | grep -E "^$INSTALL_TARGET_PATH.+" | sed -n 1p)"
  root_path="$(lsblk "$INSTALL_TARGET_PATH" -pnlo NAME | grep -E "^$INSTALL_TARGET_PATH.+" | sed -n 2p)"
  mount -o defaults,relatime,ssd,compress=zstd,subvol=@ "$root_path" /mnt
  mkdir /mnt/{home,var}
  mount -o defaults,relatime,ssd,compress=zstd,subvol=@home "$root_path" /mnt/home
  mount -o defaults,relatime,ssd,compress=zstd,subvol=@var "$root_path" /mnt/var
  mkdir -p /mnt/boot
  mount "$boot_path" /mnt/boot
}

install_base_package() {
  echo "install base package"
  timedatectl set-ntp true
  pacstrap /mnt base ansible
}

create_fstab() {
  echo "generate fstab"
  genfstab -U /mnt >/mnt/etc/fstab
}

install_packages_for_install
create_partition
make_subvolumes
mount_partition
install_base_package
create_fstab

echo "DONE"
