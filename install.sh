#!/bin/bash
set -euo pipefail

# Load the install info from the choices file
source ./install_info.sh

# ---------------------------
# Helpers
# ---------------------------

# dry_run_mode: print commands instead of running if dry_mode=="true"
# Runs commands via bash -c (safer than eval)
dry_run_mode() {
    local cmd="$1"
    if [ "${dry_mode:-false}" == "true" ]; then
        echo "[Dry Run] $cmd"
    else
        bash -c "$cmd"
    fi
}

# run_in_chroot: run a command inside /mnt chroot using artix-chroot
run_in_chroot() {
    local cmd="$1"
    if [ "${dry_mode:-false}" == "true" ]; then
        echo "[Dry Run] artix-chroot /mnt /bin/bash -c \"$cmd\""
    else
        artix-chroot /mnt /bin/bash -c "$cmd"
    fi
}

# compute partition suffix for device (nvme/p??? or normal)
# usage: part 1 -> ${device}${part_suffix}1
compute_part_suffix() {
    if [[ "$device_name" =~ ^/dev/nvme ]] || [[ "$device_name" =~ ^/dev/mmcblk ]]; then
        part_suffix="p"
    else
        part_suffix=""
    fi
}

# timezone selector
select_timezone() {
    # list top level zones (directories)
    local zones_dir="/usr/share/zoneinfo"
    PS3="Choose a region (or Ctrl-C to cancel): "
    local continents=()
    while IFS= read -r -d $'\0' entry; do
        # get directory name relative to zoneinfo
        continents+=( "$(basename "$entry")" )
    done < <(find "$zones_dir" -maxdepth 1 -mindepth 1 -type d -print0 | sort -z)

    echo "Select continent/region:"
    select continent in "${continents[@]}"; do
        if [ -n "${continent:-}" ]; then
            break
        fi
    done

    # Now list zones under that continent (ignore posix and right links)
    local choices=()
    while IFS= read -r -d $'\0' f; do
        # skip files that are directories, zoneinfo has some binary files too
        # we want relative names: continent/zone
        # Only include regular files (not posix or right directories)
        if [ -f "$f" ]; then
            choices+=( "$(basename "$f")" )
        fi
    done < <(find "$zones_dir/$continent" -maxdepth 1 -mindepth 1 -type f -print0 | sort -z)

    # If no direct files (some zones are nested deeper), include subdirs entries
    if [ "${#choices[@]}" -eq 0 ]; then
        while IFS= read -r -d $'\0' f; do
            choices+=( "$(basename "$f")" )
        done < <(find "$zones_dir/$continent" -mindepth 2 -type f -print0 | sed -z 's#^.*/'"$continent"'\/##' | sort -z)
    fi

    PS3="Choose your timezone (or Ctrl-C to cancel): "
    echo "Select timezone:"
    select z in "${choices[@]}"; do
        if [ -n "${z:-}" ]; then
            timezone_choice="${continent}/${z}"
            break
        fi
    done
}

# ---------------------------
# Validate device_name
# ---------------------------
if [ -z "${device_name:-}" ]; then
    echo "Error: device_name is empty. Provide /dev/sdX or /dev/nvme0n1 in install_info.sh"
    exit 1
fi

if [ ! -b "$device_name" ]; then
    echo "Error: $device_name is not a valid block device."
    exit 1
fi

# compute part suffix (supports nvme/mmc)
compute_part_suffix
dev1="${device_name}${part_suffix}1"
dev2="${device_name}${part_suffix}2"

# ---------------------------
# 1. Wipe existing filesystem signatures and first MBs
# (User asked not to change this behavior)
# ---------------------------
dry_run_mode "echo 'Wiping the device $device_name with wipefs...'"
dry_run_mode "wipefs --all --force $device_name"
dry_run_mode "dd if=/dev/zero of=$device_name bs=1M count=10 status=progress || true"

# ---------------------------
# 2. Partition with fdisk (GPT or MBR)
# ---------------------------
if [ "${partitioning_scheme:-gpt}" == "gpt" ]; then
    dry_run_mode "fdisk $device_name <<'FDISK_EOF'
g
n


+512M
t
1
n



w
FDISK_EOF"
elif [ "${partitioning_scheme:-gpt}" == "mbr" ]; then
    dry_run_mode "fdisk $device_name <<'FDISK_EOF'
o
n
p
1


+512M
t
c
n
p
2



w
FDISK_EOF"
else
    echo "Unsupported partitioning scheme: $partitioning_scheme"
    exit 1
fi

# slight pause to let kernel re-read partition table
dry_run_mode "sleep 1"
dry_run_mode "partprobe $device_name || true"

# ---------------------------
# 3. Format EFI partition
# ---------------------------
dry_run_mode "mkfs.vfat -F32 -n EFI $dev1"

# ---------------------------
# 4. Format root partition directly to selected fs (no double-format)
# ---------------------------
if [ "${fs_type:-btrfs}" == "btrfs" ]; then
    is_btrfs=true
    dry_run_mode "mkfs.btrfs -L ROOT $dev2"
elif [ "${fs_type:-ext4}" == "ext4" ]; then
    is_btrfs=false
    dry_run_mode "mkfs.ext4 -L ROOT $dev2"
    dry_run_mode "tune2fs -o journal_data_writeback $dev2 || true"
else
    echo "Unsupported filesystem type: $fs_type"
    exit 1
fi

# ---------------------------
# 5. Mounting
# ---------------------------
dry_run_mode "mount $dev2 /mnt"
dry_run_mode "mkdir -p /mnt/boot/efi"
dry_run_mode "mount $dev1 /mnt/boot/efi"

# ---------------------------
# 6. Mount tmpfs
# ---------------------------
dry_run_mode "mkdir -p /mnt/tmp"
dry_run_mode "mount -t tmpfs -o rw,nosuid,nodev,exec,auto,nouser,async,noatime,mode=1777,size=1G tmpfs /mnt/tmp"

# ---------------------------
# 7. BTRFS Subvolumes
# ---------------------------
if [ "${is_btrfs:-false}" == "true" ]; then
    for subvol in @ @home @swap @snapshots @btrfs @srv @log @tmp @abs @pkg; do
        dry_run_mode "btrfs subvolume create /mnt/$subvol"
    done

    dry_run_mode "umount -l /mnt"
    dry_run_mode "mount -o subvol=@ $dev2 /mnt"
    dry_run_mode "mkdir -p /mnt/boot/efi"
    dry_run_mode "mount $dev1 /mnt/boot/efi"

    dry_run_mode "mkdir -p /mnt/home /mnt/swap /mnt/btrfs /mnt/srv /mnt/tmp /mnt/.snapshots"
    dry_run_mode "mkdir -p /mnt/var/log /mnt/var/tmp /mnt/var/abs /mnt/var/cache/pacman/pkg"

    dry_run_mode "mount -o subvol=@home $dev2 /mnt/home"
    dry_run_mode "mount -o subvol=@swap $dev2 /mnt/swap"
    dry_run_mode "mount -o subvol=@btrfs $dev2 /mnt/btrfs"
    dry_run_mode "mount -o subvol=@srv $dev2 /mnt/srv"
    dry_run_mode "mount -o subvol=@tmp $dev2 /mnt/tmp"
    dry_run_mode "mount -o subvol=@snapshots $dev2 /mnt/.snapshots"
    dry_run_mode "mount -o subvol=@log $dev2 /mnt/var/log"
    dry_run_mode "mount -o subvol=@tmp $dev2 /mnt/var/tmp"
    dry_run_mode "mount -o subvol=@abs $dev2 /mnt/var/abs"
    dry_run_mode "mount -o subvol=@pkg $dev2 /mnt/var/cache/pacman/pkg"
fi

# ---------------------------
# 8. Create Swap (only if user asked)
# ---------------------------
if [ -n "${swap_size:-}" ]; then
    dry_run_mode "mkdir -p /mnt/swap"
    dry_run_mode "truncate -s 0 /mnt/swap/swapfile"
    dry_run_mode "chattr +C /mnt/swap/swapfile"
    dry_run_mode "btrfs property set /mnt/swap compression none || true"
    dry_run_mode "fallocate -l $swap_size /mnt/swap/swapfile"
    dry_run_mode "chmod 600 /mnt/swap/swapfile"
    dry_run_mode "mkswap /mnt/swap/swapfile"
    dry_run_mode "swapon /mnt/swap/swapfile"
fi

# ---------------------------
# 9. Install base system
# ---------------------------
packages=(base base-devel "${init_system}" "elogind-${init_system}" "${kernel_choice}" linux-firmware "${cpu_choice}-ucode" nano)
if [ "${is_btrfs:-false}" == "true" ]; then
    packages+=(btrfs-progs)
fi
# join array into string for basestrap
packages_string="${packages[*]}"
dry_run_mode "basestrap /mnt $packages_string"

# ---------------------------
# 10. Generate fstab (and only append swap if created)
# ---------------------------
dry_run_mode "fstabgen -U /mnt > /mnt/etc/fstab"
if [ -n "${swap_size:-}" ]; then
    dry_run_mode "echo '/swap/swapfile none swap defaults 0 0' >> /mnt/etc/fstab"
fi

# ---------------------------
# 11. Timezone selection
# ---------------------------
echo "Select your timezone"
select_timezone
if [ -z "${timezone_choice:-}" ]; then
    echo "No timezone selected, aborting."
    exit 1
fi
run_in_chroot "ln -sf /usr/share/zoneinfo/$timezone_choice /etc/localtime"
run_in_chroot "hwclock --systohc"

# ---------------------------
# 12. Locale
# ---------------------------
run_in_chroot "sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true"
run_in_chroot "locale-gen || true"
run_in_chroot "echo LANG=en_US.UTF-8 > /etc/locale.conf"

# ---------------------------
# 13. Hostname
# ---------------------------
read -p "Enter hostname: " hostname
run_in_chroot "echo \"$hostname\" > /etc/hostname"
run_in_chroot "bash -c 'cat > /etc/hosts <<EOF
127.0.0.1        localhost
::1              localhost
127.0.1.1        $hostname
EOF'"

# ---------------------------
# 14. Root password (non-interactive, safer)
# ---------------------------
read -s -p "Enter root password: " rootpass
echo
# use chpasswd inside chroot
run_in_chroot "bash -c 'printf \"root:%s\n\" \"$rootpass\" | chpasswd'"

# ---------------------------
# 15. Install core packages & GRUB
# ---------------------------
run_in_chroot "pacman -S --noconfirm grub efibootmgr networkmanager networkmanager-${init_system} network-manager-applet dosfstools ${kernel_choice}-headers bluez bluez-utils bluez-${init_system} xdg-utils xdg-user-dirs"
run_in_chroot "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB"
run_in_chroot "grub-mkconfig -o /boot/grub/grub.cfg"

# ---------------------------
# 16. Add user & password (non-interactive)
# ---------------------------
read -p "Enter username: " username
run_in_chroot "useradd -mG wheel \"$username\""
read -s -p "Enter $username password: " userpass
echo
run_in_chroot "bash -c 'printf \"%s:%s\n\" \"$username\" \"$userpass\" | chpasswd'"

# Enable wheel group in sudoers
run_in_chroot "sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true"

# ---------------------------
# 17. GPU drivers
# ---------------------------
if [ "${gpu_choice:-nvidia}" == "amd" ]; then
    run_in_chroot "pacman -S --noconfirm mesa xf86-video-amdgpu"
elif [ "${gpu_choice:-nvidia}" == "nvidia" ]; then
    if [ "${nvidia_driver_choice:-open}" == "open" ]; then
        run_in_chroot "pacman -S --noconfirm mesa xf86-video-nouveau"
    else
        run_in_chroot "pacman -S --noconfirm nvidia-dkms nvidia-settings nvidia-utils"
    fi
fi

# ---------------------------
# 18. Yay installer
# ---------------------------
if [[ "${yay_choice:-no}" =~ ^(yes|true)$ ]]; then
    run_in_chroot "pacman -S --noconfirm git"
    run_in_chroot "bash -c 'git clone https://aur.archlinux.org/yay.git /home/$username/yay && chown -R $username:users /home/$username/yay'"
    run_in_chroot "bash -c 'cd /home/$username/yay && sudo -u $username makepkg -si --noconfirm'"
    run_in_chroot "rm -rf /home/$username/yay || true"
fi

# ---------------------------
# 19. Extra packages
# ---------------------------
if [ -n "${extra_packages:-}" ]; then
    run_in_chroot "pacman -S --noconfirm $extra_packages"
fi

# ---------------------------
# Final message and reboot
# ---------------------------
clear
echo "Installation complete. The system will reboot in 10 seconds."
sleep 10

# Exit chroot and reboot
dry_run_mode "umount -R /mnt || true"
if [ "${dry_mode:-false}" == "true" ]; then
    echo "[Dry Run] Reboot skipped."
else
    umount -R /mnt || true
    reboot
fi
