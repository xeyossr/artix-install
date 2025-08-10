#!/bin/bash

# Function to handle Y/n questions with default Y
ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local display_default

    # Normalize default to uppercase
    local def_uc="${default^^}"

    if [[ "$def_uc" == "Y" ]]; then
        display_default="Y/n"
    elif [[ "$def_uc" == "N" ]]; then
        display_default="y/N"
    else
        display_default="$default"
    fi

    read -p "$prompt ($display_default): " response

    if [[ -z "$response" ]]; then
        response="$default"
    fi

    echo "$response"
}

# Function to handle option selection with default choice
ask_option() {
    local prompt="$1"
    local default="$2"
    local valid_choices="$3"
    local response

    while true; do
        read -p "$prompt ($valid_choices): " response
        response=$(echo "$response" | tr '[:upper:]' '[:lower:]')  # Convert to lowercase
        if [[ -z "$response" ]]; then
            response="$default"
            break
        elif [[ "$valid_choices" == *"$response"* ]]; then
            break
        else
            echo "Invalid option. Please choose from $valid_choices."
        fi
    done
    echo "$response"
}

# Check if dry-run option is set
dry_run=false
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        dry_run=true
    fi
done

# 1. Device name for installation
read -p "Enter the device name to install on (/dev/sdX): " device_name

# 2. Partitioning Scheme (GPT or MBR)
partitioning_scheme=$(ask_option "Choose the partitioning scheme" "gpt" "gpt mbr")

# 3. Filesystem type (BTRFS or Ext4)
fs_type=$(ask_option "Choose the filesystem" "btrfs" "btrfs ext4")

# 4. Swap space option
swap_choice=$(ask_yes_no "Do you want to create swap?" "Y")
if [[ "$swap_choice" =~ ^[Yy]$ ]]; then
    # 4.1. Swap size
    read -p "Enter the swap size (e.g., 500M, 1G): " swap_size
else
    swap_size=""
fi

# 5. Kernel choice
kernel_choice=$(ask_option "Which kernel would you like to install?" "linux" "linux linux-zen linux-lts")

# 6 CPU choice (Intel, AMD)
cpu_choice=$(ask_option "Do you use Intel or AMD CPU?" "intel" "intel amd")

# 7. GPU choice (NVIDIA, AMD, Intel)
gpu_choice=$(ask_option "Do you use NVIDIA, AMD, or Intel?" "nvidia" "nvidia amd intel")

if [[ "$gpu_choice" == "nvidia" ]]; then
    # 7.1. NVIDIA driver choice (open or closed source)
    nvidia_driver_choice=$(ask_option "Would you prefer open-source or proprietary NVIDIA drivers?" "open" "open proprietary")
    # Warning message
    echo "Warning: Some old NVIDIA drivers (e.g., 380x) are no longer supported."
elif [[ "$gpu_choice" == "amd" ]]; then
    # AMD drivers are automatically chosen
    echo "AMD GPU selected, the driver will be installed automatically."
fi

# 8. Init system choice
init_system=$(ask_option "Which init system would you like to install?" "openrc" "runit openrc s6 dinit")

# 9. Yay installation option
yay_choice=$(ask_yes_no "Do you want to install Yay?" "Y")

# 10. Extra packages (separate with spaces)
read -p "Enter any extra packages (e.g., sddm plasma fastfetch): " extra_packages

# Now we will save these details to a file
cat > install_info.sh <<EOF
dry_mode="$dry_run"
device_name="$device_name"
partitioning_scheme="$partitioning_scheme"
fs_type="$fs_type"
swap_size="$swap_size"
kernel_choice="$kernel_choice"
cpu_choice="$cpu_choice"
gpu_choice="$gpu_choice"
nvidia_driver_choice="$nvidia_driver_choice"
init_system="$init_system"
yay_choice="$yay_choice"
extra_packages="$extra_packages"
EOF

sudo ./install.sh
