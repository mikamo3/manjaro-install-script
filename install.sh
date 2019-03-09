#!/usr/bin/env bash
set -e
# params
PACMAN_COUNTRY="Japan"
BOOT_PARTITION_SIZE="512M"
ROOT_PARTITION_SIZE=""
INSTALL_TARGET_PATH=
KERNEL_VERSION=
TARGET_LOCALES=("en_US.UTF-8 UTF-8" "ja_JP.UTF-8 UTF-8")
MAIN_LOCALE="en_US.UTF-8"
HOSTNAME="manjaro-main"
CPU_VENDOR=

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
  mkfs.ext4 "$(lsblk "$INSTALL_TARGET_PATH" -pnlo NAME | grep -E "^$INSTALL_TARGET_PATH.+" | sed -n 2p)"
}

mount_partition() {
  echo "mount partition"
  boot_path="$(lsblk "$INSTALL_TARGET_PATH" -pnlo NAME | grep -E "^$INSTALL_TARGET_PATH.+" | sed -n 1p)"
  root_path="$(lsblk "$INSTALL_TARGET_PATH" -pnlo NAME | grep -E "^$INSTALL_TARGET_PATH.+" | sed -n 2p)"
  mount "$root_path" /mnt
  mkdir -p /mnt/boot
  mount "$boot_path" /mnt/boot

}

select_kernel_version() {
  echo "select kernel version"
  KERNEL_VERSION="$(
    pacman -Ssq '^linux[0-9]+$' \
      | fzf --header="Select Linux Kernel version to install"
  )"
  [[ -z $KERNEL_VERSION ]] && {
    echo "abort"
    return 1
  }
  return 0
}

install_base_package() {
  echo "install base package"
  timedatectl set-ntp true
  [[ $(grep -Ec "^vendor_id.*Intel" /proc/cpuinfo) != 0 ]] && CPU_VENDOR=intel
  [[ $(grep -Ec "^vendor_id.*AMD" /proc/cpuinfo) != 0 ]] && CPU_VENDOR=amd
  [[ -n $CPU_VENDOR ]] && micro_code="${CPU_VENDOR}-ucode"
  pacstrap /mnt base base-devel "$KERNEL_VERSION" "${KERNEL_VERSION}-headers" "$micro_code"
}

create_fstab() {
  echo "generate fstab"
  genfstab -U /mnt >/mnt/etc/fstab
}

set_timezone() {
  echo "set timezone"
  arch-chroot /mnt ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  arch-chroot /mnt hwclock --systohc --utc
}

set_locale() {
  echo "set locale"
  : >/mnt/etc/locale.gen
  for locale in "${TARGET_LOCALES[@]}"; do
    echo "$locale" >>/mnt/etc/locale.gen
  done
  arch-chroot /mnt locale-gen
  echo "LANG=$MAIN_LOCALE" >/mnt/etc/locale.conf
}

set_hostname() {
  echo "set hostname"
  echo -n "input hostname:"
  read -r host_name
  [[ -z $host_name ]] && {
    echo "abort"
    return 1
  }
  echo "$host_name" >/mnt/etc/hostname
  {
    echo "127.0.0.1 $host_name"
    echo "::1 $host_name"
    echo "127.0.1.1 $host_name.localdomain $host_name"
  } >/mnt/etc/hosts
}

run_mkinitcpio() {
  echo "run mkinitcpio"
  arch-chroot /mnt mkinitcpio -p "$KERNEL_VERSION"
}

set_rootpasswd() {
  echo "set root password"
  arch-chroot /mnt passwd
}

install_bootmanager() {
  echo "install bootmanager"
  arch-chroot /mnt bootctl --path=/boot install
  root_uuid=$(blkid -o value "$(df --output=source /mnt | tail -1)" | head -1)
  echo "default manjaro
timeout 4
editor no
  " >/mnt/boot/loader/loader.conf
  mkdir -p /mnt/boot/loader/entries

  vmlinuz_name=$(grep -E "^ALL_kver" "/mnt/etc/mkinitcpio.d/$KERNEL_VERSION.preset" | sed 's/^.*=\"\/boot\(.*\)"/\1/')
  image_name=$(grep -E "^default_image" "/mnt/etc/mkinitcpio.d/$KERNEL_VERSION.preset" | sed 's/^.*=\"\/boot\(.*\)"/\1/')

  [[ -n $CPU_VENDOR ]] && micro_code="initrd /$CPU_VENDOR-ucode.img"

  echo "title manjaro linux
linux $vmlinuz_name
$micro_code
initrd $image_name
options root=UUID=$root_uuid rw" >/mnt/boot/loader/entries/manjaro.conf
}

install_packages_for_install
create_partition
mount_partition
select_kernel_version
install_base_package
create_fstab
set_timezone
set_locale
set_hostname
run_mkinitcpio
set_rootpasswd
install_bootmanager

echo "DONE"
