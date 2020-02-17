#!/usr/bin/env bash
set -e
# params
PACMAN_COUNTRY="Japan"
BOOT_PARTITION_SIZE="512M"
ROOT_PARTITION_SIZE=
INSTALL_TARGET_PATH=
TARGET_BOOT_PARTITION=

#edit
ENABLE_MAKE_BOOT_PARTITION=""
ROOT_PARTITION_LABEL_NAME="manjaro"
ANSIBLE_REPOSITORY_URL="https://github.com/mikamo3/manjaro-ansible.git"
ANSIBLE_REPOSITORY_BRANCH="master"

install_packages_for_install() {
  echo "Install Packages for install"
  pacman-mirrors -c "$PACMAN_COUNTRY"
  pacman -Sy
  pacman -S --noconfirm arch-install-scripts fzf gdisk
}

create_partition() {
  echo "Partition Layout"
  read -n1 -r -p "do you want to create boot partition? (y/N): " ENABLE_MAKE_BOOT_PARTITION
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

  if [[ ! $ENABLE_MAKE_BOOT_PARTITION =~ ^[yY] ]]; then
    TARGET_BOOT_PARTITION="$(
      blkid \
        | fzf --header="Select boot partition" \
        | awk '{sub(/:$/,"",$1);print $1}'
    )"
    [[ -z $TARGET_BOOT_PARTITION ]] && {
      echo "abort"
      return 1
    }
  fi

  if [[ $ENABLE_MAKE_BOOT_PARTITION =~ ^[yY] ]]; then
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
    mkfs.vfat -F32 "$(lsblk "$INSTALL_TARGET_PATH" -pnlo NAME | grep -E "^$INSTALL_TARGET_PATH.+" | sed -n 1p)"
  fi
  sgdisk -n "0::$ROOT_PARTITION_SIZE" -t "0:8300" "$INSTALL_TARGET_PATH" -c 0:"$ROOT_PARTITION_LABEL_NAME"
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
  btrfs subvolume create @snapshots
  cd /
  umount /mnt
}

mount_partition() {
  echo "mount partition"
  boot_path="$(lsblk "$INSTALL_TARGET_PATH" -pnlo NAME | grep -E "^$INSTALL_TARGET_PATH.+" | sed -n 1p)"
  mount -o defaults,relatime,ssd,compress=zstd,subvol=@ "$root_path" /mnt
  mkdir /mnt/{home,var,.snapshots}
  mount -o defaults,relatime,ssd,compress=zstd,subvol=@home "$root_path" /mnt/home
  mount -o defaults,relatime,ssd,compress=zstd,subvol=@var "$root_path" /mnt/var
  mount -o defaults,relatime,ssd,compress=zstd,subvol=@snapshots "$root_path" /mnt/.snapshots
  mkdir -p /mnt/boot
  if [[ $ENABLE_MAKE_BOOT_PARTITION =~ ^[Yy] ]]; then
    root_path="$(lsblk "$INSTALL_TARGET_PATH" -pnlo NAME | grep -E "^$INSTALL_TARGET_PATH.+" | sed -n 2p)"
    mount "$boot_path" /mnt/boot
  else
    mount "$TARGET_BOOT_PARTITION" /mnt/boot
  fi
}

install_base_package() {
  echo "install base package"
  timedatectl set-ntp true
  pacstrap /mnt base ansible git
}

create_fstab() {
  echo "generate fstab"
  genfstab -U /mnt >/mnt/etc/fstab
}

run_ansible() {
  arch-chroot /mnt /bin/bash -c "git clone $ANSIBLE_REPOSITORY_URL -b $ANSIBLE_REPOSITORY_BRANCH /root/ansible &&
  cd /root/ansible &&
  git submodule update --init --recursive &&
  bash ./run_init.sh"

}

install_packages_for_install
create_partition
make_subvolumes
mount_partition
install_base_package
create_fstab
run_ansible

echo "DONE"
