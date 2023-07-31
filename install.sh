#! /usr/bin/env nix-shell
#! nix-shell -i bash --packages bash nettools git
# shellcheck shell=bash
{ # Prevent execution if this script was only partially downloaded - BEGIN

  # To install NixOS Linux with MSF-OCB configuration on a machine not yet installed with any NixOS Linux:
  # - follow latest instructions at <https://github.com/MSF-OCB/NixOS-OCB/wiki/Install-NixOS> , in particular:
  #   - to prepare the configuration for this machine in private repository <https://github.com/MSF-OCB/NixOS-OCB>
  #   - to set up a USB key for booting with the latest MSF-OCB NixOS Rescue ISO image
  # - boot the machine with this bootable USB key and wait for the command prompt
  # - then at the command prompt, launch the installation with a command _similar_ to the following
  #   (replace <placeholders> with suitable values - see usage documentation for reference), e.g.:
  # $ curl -L https://github.com/MSF-OCB/NixOS-OCB-install/raw/main/install.sh | sudo bash -s -- -h <hostname> -d <system_device>
  # *WARNING*: *ALL* contents of any specified disk devices will be permanently *LOST*!

  # Set up the shell environment
  set -euo pipefail
  shopt -s extglob globstar nullglob

  declare -r script_name="install.sh"
  # TODO: keep script version string up-to-date
  declare -r script_version="v2023.07.31.0.BETA2"
  declare -r script_title="MSF-OCB customised NixOS Linux installation script (unified repo + flakes)"

  ##########
  ### FUNCTIONS:

  # Show script usage and then abort (with optional specific error exit code)
  # N.B.:
  # assumes the following variables/constants are already properly set by main code:
  # (so do not call this function too early, before these get properly defined by main code)
  # 'do_install', 'script_name', 'root_size_def', 'data_dev_def'
  # shellcheck disable=SC2120
  function exit_usage() {
    echo
    echo "Usage:"
    if ((do_install)); then
      echo "(as this system is not already set up with NixOS Linux, this script would perform a full installation of"
      echo " NixOS Linux with MSF-OCB configuration)"
      echo
      echo "  ${script_name} -h <hostname> -d <system_device> [-r <root_size_(GiB)>] [-D] [-l]"
      echo "    -h specifies the hostname for the new system (mandatory, no default)"
      echo "    -d specifies the disk device path for installing the system if installing a new system"
      echo "       (mandatory if installing a new system, no default)"
      echo "    -r specifies the size of the root disk partition in GiB if installing a new system"
      echo "       (default: ${root_size_def} GiB)"
      echo "    -D causes the creation of the encrypted data partition to be skipped"
      echo "       (default: false i.e. create data partition)"
      echo "    -l triggers legacy boot installation mode instead of UEFI (default: false i.e. UEFI boot mode)"
    else
      echo "(as this system is already set up with NixOS Linux, this script would only apply MSF-OCB configuration to it)"
      echo
      echo "  ${script_name} -h <hostname> [-D] [-e <data_device>] [-l]"
      echo "    -h specifies the hostname for the new system (mandatory, no default)"
      echo "    -D causes the creation of the encrypted data partition to be skipped"
      echo "       (default: false i.e. create data partition)"
      echo "    -e specifies the disk device or logical volume path for storing encrypted data"
      echo "       (default: logical volume path \"${data_dev_def}\")"
      echo "    -l triggers legacy boot installation mode instead of UEFI (default: false i.e. UEFI boot mode)"
    fi
    echo
    echo "*WARNING*: *ALL* contents of any specified disk devices will be *permanently* *LOST*!"
    exit "${1:-101}"
  }

  function exit_missing_arg() {
    echo_err "command-line option '-${1}' requires an argument!"
    exit_usage
  }

  function echo_info() {
    echo "${script_name}: ${target_hostname:+\"${target_hostname}\": }$(date -u +'%F_%TZ'):" "${@}"
  }

  function echo_err() {
    echo_info "*ERROR*:" "${@}" >&2
  }

  # Wait for devices to get ready
  # N.B.: assumes variable 'install_dev' already properly set by main code
  function wait_for_devices() {
    local _fn_devs=("${@}")
    local _fn_dev
    local -i _fn_countdown _fn_missing _fn_all_found
    for _fn_dev in "${_fn_devs[@]}"; do
      udevadm settle --exit-if-exists="${_fn_dev}"
    done
    for ((_fn_countdown = 60; _fn_countdown >= 0; _fn_countdown--)); do
      _fn_missing=0
      for _fn_dev in "${_fn_devs[@]}"; do
        if [[ ! -b "${_fn_dev}" ]]; then
          _fn_missing=1
          echo "waiting for ${_fn_dev}... (${_fn_countdown})"
        fi
      done
      if ((_fn_missing)); then
        if [[ -n "${install_dev}" ]]; then
          partprobe "${install_dev}"
        fi
        sleep 1
        for _fn_dev in "${_fn_devs[@]}"; do
          udevadm settle --exit-if-exists="${_fn_dev}"
        done
      else
        _fn_all_found=1
        break
      fi
    done
    if ((!_fn_all_found)); then
      echo_err "wait_for_devices(): time-out waiting for devices!" >&2
      return 2
    fi
  }

  ##########
  ### MAIN:

  echo "${script_title}"
  echo "${script_name} ${script_version}"
  echo

  # Display the NixOS version of the current system (e.g. the rescue ISO image), or fail if not running NixOS (set -e)
  echo_info "information on the currently running NixOS system:"
  uname -a
  echo -n "NixOS "
  nixos-version
  echo

  declare -r data_dev_def="/dev/LVMVolGroup/nixos_data"
  declare -ir root_size_def=25

  # If the current host name is not the standard one defined for the MSF-OCB NixOS rescue ISO image (i.e. "rescue-iso"),
  # then assume that we are running on a system already installed with NixOS
  # (e.g. an Amazon EC2 instance with a standard 'vanilla' NixOS AMI),
  # so in that case no need to install the NixOS system itself but only to apply MSF-OCB NixOS configuration on it.
  declare -i do_install=1
  if [[ "$(hostname)" != "rescue-iso" ]]; then
    do_install=0
  fi
  declare -ir do_install="${do_install}"

  if ((EUID != 0)); then
    echo_err "this script should be run using command 'sudo' or as super-user 'root'!"
    exit_usage 102
  fi

  if ((do_install)); then
    install_dir="/mnt"
  else
    install_dir=""
  fi
  declare -r install_dir="${install_dir}"

  declare -r nixos_dir="${install_dir}/etc/nixos"
  declare -r config_dir="${nixos_dir}/org-config"

  # Parse any command line options
  install_dev=""
  target_hostname=""
  root_size_raw=""
  root_size=""
  data_dev=""
  declare -i use_uefi=1
  declare -i create_data_part=1

  while getopts ':d:h:r:e:lD' flag; do
    case "${flag}" in
    d)
      if [[ "${OPTARG}" =~ ^-. ]]; then
        OPTIND=$((OPTIND - 1))
      else
        install_dev="${OPTARG}"
      fi
      # If we are not installing NixOS (assumed to be already installed),
      # then we can silently ignore this parameter
      if [[ -z "${install_dev}" ]] && ((do_install)); then
        exit_missing_arg "${flag}"
      fi
      ;;
    h)
      if [[ "${OPTARG}" =~ ^-. ]]; then
        OPTIND=$((OPTIND - 1))
      else
        target_hostname="${OPTARG}"
      fi
      if [[ -z "${target_hostname}" ]]; then
        exit_missing_arg "${flag}"
      fi
      ;;
    r)
      if [[ "${OPTARG}" =~ ^-. ]]; then
        OPTIND=$((OPTIND - 1))
      else
        root_size_raw="${OPTARG}"
        root_size="${root_size_raw}"
      fi
      if [[ -z "${root_size}" ]]; then
        exit_missing_arg "${flag}"
      elif [[ ! "${root_size}" =~ ^[1-9][0-9]*$ ]]; then
        # N.B.: usage error will be raised later in initialisation checks (showing raw option value originally specified)
        root_size="-1"
      fi
      ;;
    e)
      if [[ "${OPTARG}" =~ ^-. ]]; then
        OPTIND=$((OPTIND - 1))
      else
        data_dev="${OPTARG}"
      fi
      # If we are installing NixOS (assumed not to be already installed),
      # then we can silently ignore this parameter
      if [[ -z "${data_dev}" ]] && ((!do_install)); then
        exit_missing_arg "${flag}"
      fi
      ;;
    l)
      use_uefi=0
      ;;
    D)
      create_data_part=0
      ;;
    :)
      exit_missing_arg "${OPTARG}"
      ;;
    \?)
      echo_err "invalid command-line option: -${OPTARG}"
      exit_usage
      ;;
    *)
      exit_usage
      ;;
    esac
  done

  if ((do_install)); then
    echo_info "performing a full installation of NixOS Linux with MSF-OCB configuration into mounted directory \"${install_dir}\"..."
  else
    echo_info "only applying MSF-OCB configuration to system already set up with NixOS Linux..."
    if [[ ! -d "${nixos_dir}" ]]; then
      echo_err "NixOS base configuration directory \"${nixos_dir}\" is missing!"
      exit 103
    fi
  fi
  echo

  declare -r target_hostname="${target_hostname}"
  if [[ -z "${target_hostname}" ]]; then
    echo_err "no hostname specified for the new system!"
    exit_usage
  fi

  if ((do_install)); then
    # install_dev should already have been specified on command line
    :
  else
    install_dev=""
    root_size="0"
  fi
  declare -r install_dev="${install_dev}"
  declare -ir root_size="${root_size:-${root_size_def}}"
  declare -ir use_uefi="${use_uefi:-1}"
  declare -ir create_data_part="${create_data_part:-1}"
  if ((create_data_part)); then
    if ((do_install)); then
      data_dev="${data_dev_def}"
    else
      data_dev="${data_dev:-${data_dev_def}}"
    fi
  else
    data_dev=""
  fi
  declare -r data_dev="${data_dev}"

  if ((do_install)); then
    if [[ -z "${install_dev}" ]]; then
      echo_err "no disk device path specified for installing the system!"
      exit_usage
    elif [[ ! -b "${install_dev}" ]]; then
      echo_err "the specified disk device path \"${install_dev}\" for installing the system is missing or invalid!"
      echo "Please first set this disk device up and then retry this installation."
      echo
      echo "*WARNING*: *ALL* contents of this disk device will be permanently *LOST*!"
      exit 104
    fi
  fi

  if ((create_data_part)); then
    if ((!do_install)) && [[ ! -b "${data_dev}" ]]; then
      echo_err "the disk device or logical volume path \"${data_dev}\" for storing encrypted data is missing or invalid!"
      echo "Please first set this up (default: logical volume path \"${data_dev_def}\") and then retry this installation,"
      echo "or if you do not need to create an encrypted data partition then run this installer with command-line option '-D'."
      echo
      echo "*WARNING*: *ALL* contents of this disk device or logical volume will be permanently *LOST*!"
      echo
      echo "Example of commands to set up this default logical volume path \"${data_dev_def}\""
      echo "using the whole disk partition device \"/dev/sdX1\":"
      echo "# sudo pvcreate /dev/sdX1"
      echo "# sudo vgcreate LVMVolGroup /dev/sdX1"
      echo "# sudo lvcreate --yes --extents 100%FREE --name nixos_data LVMVolGroup"
      exit 105
    fi
    if [[ -b "${data_dev}" ]] && cryptsetup --batch-mode isLuks "${data_dev}" 2>/dev/null; then
      echo_err "the disk device or logical volume path \"${data_dev}\" for storing encrypted data seems to already contain encrypted data!"
      echo "Please check first (with an authoritative stakeholder!) whether all its contents could be deleted permanently!"
      echo "If formally confirmed, erase/wipe it (after backing up its data if needed) and then retry this installation."
      echo "If you do not need to create an encrypted data partition then run this installer with command-line option '-D'."
      echo
      echo "*WARNING*: *ALL* contents of this disk device or logical volume will be permanently *LOST*!"
      exit 106
    fi
  fi

  if ((do_install)); then
    if [[ ! "${root_size}" =~ ^[1-9][0-9]*$ ]]; then
      echo_err "invalid root partition size specified${root_size_raw:+ (${root_size_raw})}!"
      echo "Please specify a positive integer number (in GiB)."
      exit_usage
    fi
    declare -ir disk_size="$(($(blockdev --getsize64 "${install_dev}") / 1024 / 1024 / 1024 - 2))"
    if ((root_size > disk_size)); then
      echo_err "the specified root partition size (${root_size} GiB) is bigger than the size of" \
        "the provided device \"${install_dev}\" (${disk_size} GiB)!"
      echo "Please specify a smaller root partition size."
      exit_usage
    fi
  fi

  if ((use_uefi)) && [[ ! -d "/sys/firmware/efi" ]]; then
    echo_err "installing in UEFI mode but we are currently booted in legacy mode!"
    echo "Please check:"
    echo "  1. That your BIOS is configured to boot using UEFI only."
    echo "  2. That the hard disk that you booted from (USB key or hard drive)"
    echo "     is using the GPT format and has a valid ESP."
    echo "And reboot the system in UEFI mode."
    echo "Alternatively you can run this installer in legacy mode"
    echo "with command-line option '-l' (but usually *not* recommended on UEFI capable hardware)."
    exit 107
  fi

  if [ ! -L /etc/channels/nixpkgs ]; then
    echo_err "this installer no longer works on old NixOS images without Nix flake support!"
    echo "Please try again with an up-to-date MSF-OCB NixOS installer ISO image."
    exit 108
  fi

  # Define constants for use of MSF-OCB GitHub repositories
  declare -r github_org_name="MSF-OCB"
  declare -r main_repo_name="NixOS-OCB"
  declare -r main_repo="git@github.com:${github_org_name}/${main_repo_name}.git"
  declare -r main_repo_branch="main"
  declare -r main_repo_flake="git+ssh://git@github.com/${github_org_name}/${main_repo_name}.git"
  declare -r github_nixos_robot_name="OCB NixOS Robot"
  declare -r github_nixos_robot_email="69807852+nixos-ocb@users.noreply.github.com"

  # If command 'git' is not available, try to get it via its Nix package and add its folder to the system path
  if ! type -p "git" >&/dev/null; then
    echo_info "downloading missing required software package 'git'..."
    PATH="$(nix build 'nixpkgs#git')/bin:${PATH}"
    export PATH
    git --version
    echo
  fi

  echo_info "parameters:"
  echo "- hostname for the new system: \"${target_hostname}\""
  if ((do_install)); then
    echo "- disk device path for installing the system: \"${install_dev}\""
    echo "- size of the root disk partition (in GiB): ${root_size}"
  fi
  if ((create_data_part)); then
    echo "- create the encrypted data partition - in disk device path: \"${data_dev}\""
  else
    echo "- do not create the encrypted data partition"
  fi
  if ((use_uefi)); then
    echo "- use UEFI boot mode"
  else
    echo "- use legacy boot mode"
  fi
  echo "- GitHub.com private repository (@branch): \"${github_org_name}/${main_repo_name}@${main_repo_branch}\""
  echo
  echo "*WARNING*: *ALL* contents of any disk devices/partitions mentioned above will be permanently *LOST*!"
  echo

  echo_info "about to start MSF-OCB NixOS $( ((do_install)) && echo "installation" || echo "configuration") for host \"${target_hostname}\"..."
  echo "(Press [Ctrl+C] *now* to abort)"
  echo -ne "\n--> countdown before proceeding: "
  for ((countdown = 5; countdown >= 0; countdown--)); do
    echo -n "${countdown} "
    sleep 1
  done
  echo "GO!"
  echo

  # If installing the full OS on local disk, prepare the disks for the system (UEFI or legacy mode)
  if ((do_install)); then
    echo
    echo_info "installing NixOS Linux into mounted directory \"${install_dir}\"..."

    declare -r swapfile="${install_dir}/swapfile"
    # shellcheck disable=SC2155
    declare -ir detect_swap_rc="$(
      swapon | grep "${swapfile}" >/dev/null 2>&1
      echo $?
    )" || true
    if ((detect_swap_rc == 0)); then
      swapoff "${swapfile}"
      rm --force "${swapfile}"
    fi

    # shellcheck disable=SC2155
    declare -ir detect_install_dir_mount_rc="$(
      mountpoint --quiet "${install_dir}/"
      echo $?
    )" || true
    if ((detect_install_dir_mount_rc == 0)); then
      umount --recursive "${install_dir}/"
    fi

    echo
    echo_info "removing any target disk volumes (if pre-existing)..."
    cryptsetup close nixos_data_decrypted || true
    vgremove --force LVMVolGroup || true
    # We try both GPT and MBR style commands to wipe existing PVs.
    # If the existing partition table is GPT, we use the partlabel
    pvremove /dev/disk/by-partlabel/nixos_lvm || true
    # If the existing partition table is MBR, we need to use direct addressing
    pvremove "${install_dev}2" || true

    if ((use_uefi)); then
      echo
      echo_info "setting up disk partitions (UEFI)..."
      # Using zeroes for the start and end sectors, selects the default values, i.e.:
      #   the next unallocated sector for the start value
      #   the last sector of the device for the end value
      sgdisk --clear --mbrtogpt "${install_dev}"
      sgdisk --new=1:2048:+512M --change-name=1:"efi" --typecode=1:ef00 "${install_dev}"
      sgdisk --new=2:0:+512M --change-name=2:"nixos_boot" --typecode=2:8300 "${install_dev}"
      sgdisk --new=3:0:0 --change-name=3:"nixos_lvm" --typecode=3:8e00 "${install_dev}"
      sgdisk --print "${install_dev}"

      wait_for_devices "/dev/disk/by-partlabel/efi" \
        "/dev/disk/by-partlabel/nixos_boot" \
        "/dev/disk/by-partlabel/nixos_lvm"
    else
      echo
      echo_info "setting up disk partitions (legacy)..."
      sfdisk --wipe always --wipe-partitions always "${install_dev}" \
        <<EOF_sfdisk_01
label: dos
unit:  sectors

# Boot partition
type=83, start=2048, size=512MiB, bootable

# LVM partition, from first unallocated sector to end of disk
# These start and size values are the defaults when nothing is specified
type=8e
EOF_sfdisk_01
    fi

    if ((use_uefi)); then
      boot_part="/dev/disk/by-partlabel/nixos_boot"
      lvm_part="/dev/disk/by-partlabel/nixos_lvm"
    else
      boot_part="${install_dev}1"
      lvm_part="${install_dev}2"
    fi

    wait_for_devices "${lvm_part}"
    pvcreate "${lvm_part}"
    wait_for_devices "${lvm_part}"
    vgcreate LVMVolGroup "${lvm_part}"
    lvcreate --yes --size "${root_size}"GB --name nixos_root LVMVolGroup
    wait_for_devices "/dev/LVMVolGroup/nixos_root"

    echo
    echo_info "setting up file systems..."
    if ((use_uefi)); then
      wipefs --all /dev/disk/by-partlabel/efi
      mkfs.vfat -n EFI -F32 /dev/disk/by-partlabel/efi
    fi
    wipefs --all "${boot_part}"
    # We set the inode size to 256B for the boot partition.
    # Small partitions default to 128B inodes but these cannot store dates
    # beyond the year 2038.
    mkfs.ext4 -e remount-ro -L nixos_boot -I 256 "${boot_part}"
    mkfs.ext4 -e remount-ro -L nixos_root /dev/LVMVolGroup/nixos_root

    if ((use_uefi)); then
      wait_for_devices "/dev/disk/by-label/EFI"
    fi
    wait_for_devices "/dev/disk/by-label/nixos_boot" \
      "/dev/disk/by-label/nixos_root"
    echo

    mount /dev/disk/by-label/nixos_root "${install_dir}"
    mkdir --parents "${install_dir}/boot"
    mount /dev/disk/by-label/nixos_boot "${install_dir}/boot"
    if ((use_uefi)); then
      mkdir --parents "${install_dir}/boot/efi"
      mount /dev/disk/by-label/EFI "${install_dir}/boot/efi"
    fi

    echo
    echo_info "setting up temporary swap file \"${swapfile}\"..."
    fallocate --length 4G "${swapfile}"
    chmod 0600 "${swapfile}"
    mkswap "${swapfile}"
    swapon "${swapfile}"

    # For the ISO, the nix store is mounted using tmpfs with default options,
    # meaning that its size is limited to 50% of physical memory.
    # On machines with low memory (< 8GB), this can cause issues.
    # Now that we have created swap space above, and since we have ZRAM swap enabled,
    # we can safely increase the size of the nix store for those machines.
    # shellcheck disable=SC2155
    declare -ir total_mem="$(grep 'MemTotal:' /proc/meminfo | awk -F ' ' '{ print $2; }')"
    if ((total_mem < (8 * 1000 * 1000))); then
      echo
      echo_info "remounting the nix store (low RAM)..."
      mount --options remount,size=4G /nix/.rw-store
    fi
  fi

  if [[ ! -f "/tmp/id_tunnel" || ! -f "/tmp/id_tunnel.pub" ]]; then
    if [ -f "/tmp/id_tunnel" ]; then
      rm --force "/tmp/id_tunnel"
    fi
    if [ -f "/tmp/id_tunnel.pub" ]; then
      rm --force "/tmp/id_tunnel.pub"
    fi
    echo
    echo_info "generating a new SSH key pair for this host \"${target_hostname}\"..."
    ssh-keygen -a 100 \
      -t ed25519 \
      -N "" \
      -C "" \
      -f /tmp/id_tunnel
    echo_info "SSH key pair generated."
  else
    # Make sure that we have the right permissions
    chmod 0400 /tmp/id_tunnel
  fi

  # Check whether we can authenticate to GitHub using this server's SSH key.
  # We run this part in a subshell, delimited by the parentheses, and in which we
  # set +e, such that the installation script does not abort when the git command
  # exits with a non-zero exit code.
  (
    set +e

    function test_auth() {
      # Try to run a git command on the remote to test the authentication.
      # If this command exists with a zero exit code, then we have successfully
      # authenticated to GitHub.
      git -c core.sshCommand="ssh -F none -o IdentitiesOnly=yes -i /tmp/id_tunnel" \
        ls-remote "${main_repo}"
    }

    echo
    echo_info "trying to authenticate to GitHub.com private repository \"${main_repo_name}\"..."
    test_auth >/dev/null
    declare -i test_auth_rc="${?}"
    declare -i test_auth_tries=1

    if ((test_auth_rc != 0)); then
      echo -e "\nThis server's SSH key does not give us access to GitHub."
      echo "Please add the following public key for this host \"${target_hostname}\""
      echo -e "to the file \"json/tunnels.d/tunnels.json\" in the repo \"${main_repo_name}\":\n"
      cat /tmp/id_tunnel.pub
      echo -e "\nThe installation will automatically continue once the key"
      echo "has been added to GitHub and the deployment actions have completed."
      echo -e "\nIf you want me to generate a new key pair instead, then"
      echo "remove files \"/tmp/id_tunnel\" and \"/tmp/id_tunnel.pub\" and restart"
      echo "the installer. You will then see this message again, and"
      echo -e "you will need to add the newly generated key to GitHub."
      echo -e "\nThe installer will continue once you have added the key"
      echo -e "to GitHub and the deployment actions have successfully run...\n"

      while ((test_auth_rc != 0)); do
        sleep 10
        echo -n "."
        if ((test_auth_tries % 18 != 0)); then
          test_auth >/dev/null 2>&1
          test_auth_rc="${?}"
        else
          echo -e "\n"
          echo_info "output of try #${test_auth_tries} to authenticate to GitHub.com private repository \"${main_repo_name}\":"
          test_auth
          test_auth_rc="${?}"
          echo_info "exit code of try #${test_auth_tries}: ${test_auth_rc}"
          echo
        fi
        ((test_auth_tries++))
      done
      echo
    fi
    echo_info "successfully authenticated to GitHub.com private repository \"${main_repo_name}\"."
  )

  # Set some global Git settings
  git config --global pull.rebase true
  git config --global user.name "${github_nixos_robot_name}"
  git config --global user.email "${github_nixos_robot_email}"
  git config --global core.sshCommand "ssh -i /tmp/id_tunnel"

  if ((create_data_part)); then
    echo
    echo_info "creating the encrypted data partition using device \"${data_dev}\" (part #1 of 2)..."

    # Commit a new encryption key to GitHub, if one does not exist yet
    declare -r secrets_dir="${MSFOCB_SECRETS_DIRECTORY:-/run/.secrets}"

    # Clean up potential left-over directories
    if [[ -e "${nixos_dir}" ]]; then
      rm --recursive --preserve-root --force "${nixos_dir}"
    fi
    if [[ -e "${secrets_dir}" ]]; then
      rm --recursive --preserve-root --force "${secrets_dir}"
    fi

    echo
    echo_info "downloading MSF-OCB NixOS configuration files into directory \"${nixos_dir}\" (keyfile)..."
    git clone --filter=blob:none --single-branch --branch "${main_repo_branch}" "${main_repo}" "${nixos_dir}"
    echo

    echo
    echo_info "trying to decrypt the data encryption key for host '${target_hostname}'..."
    function decrypt_secrets() {
      mkdir --parents "${secrets_dir}"
      nix shell "${main_repo_flake}#nixostools" \
        --command decrypt_server_secrets \
                  --server_name "${target_hostname}" \
                  --secrets_path "${config_dir}/secrets/generated/generated-secrets.yml" \
                  --output_path "${secrets_dir}" \
                  --private_key_file /tmp/id_tunnel
    }

    function git_pull_and_decrypt_secrets() {
      git -C "${nixos_dir}" pull
      echo
      decrypt_secrets
    }

    decrypt_secrets >/dev/null
    declare -i decrypt_secrets_tries=1
    declare -r secrets_key_file="${secrets_dir}/keyfile"
    declare -r secrets_master_file="${config_dir}/secrets/master/nixos_encryption-secrets.yml"
    if [[ ! -f "${secrets_key_file}" ]]; then
      echo
      echo_info "the data encryption key for host '${target_hostname}' was not found - generating a new key..."
      nix shell "${main_repo_flake}#nixostools" \
        --command add_encryption_key \
                  --hostname "${target_hostname}" \
                  --secrets_file "${secrets_master_file}"

      random_id="$(tr --complement --delete 'A-Za-z0-9' </dev/urandom | head --bytes=10)" || true
      branch_name="installer_commit_enc_key_${target_hostname}_${random_id}"
      git -C "${nixos_dir}" checkout -b "${branch_name}"
      git -C "${nixos_dir}" add "${secrets_master_file}"
      git -C "${nixos_dir}" commit --message "Commit data encryption key for host '${target_hostname}'."
      git -C "${nixos_dir}" push -u origin "${branch_name}"
      git -C "${nixos_dir}" checkout "${main_repo_branch}"

      echo -e "\n\nThe new data encryption key for this host \"${target_hostname}\" has just been committed to GitHub."
      echo -e "Please go to the following link to create a pull request:\n"
      echo -e "https://github.com/${github_org_name}/${main_repo_name}/pull/new/${branch_name}\n"
      echo -e "The installer will continue once the pull request has been merged into branch \"${main_repo_branch}\".\n"

      declare -i git_pull_and_decrypt_secrets_rc=-1
      while [[ ! -f "${secrets_key_file}" ]]; do
        sleep 10
        echo -n "."
        if ((decrypt_secrets_tries % 18 != 0)); then
          git_pull_and_decrypt_secrets >/dev/null 2>&1
          git_pull_and_decrypt_secrets_rc="${?}"
        else
          echo -e "\n"
          echo_info "output of try #${decrypt_secrets_tries} to pull and decrypt the new data encryption key from repo \"${main_repo_name}@${main_repo_branch}\":"
          git_pull_and_decrypt_secrets >/dev/null
          git_pull_and_decrypt_secrets_rc="${?}"
          echo_info "exit code of try #${decrypt_secrets_tries}: ${git_pull_and_decrypt_secrets_rc}"
          ls -ldp "${secrets_key_file}" || true
          echo
        fi
        ((decrypt_secrets_tries++))
      done
      echo
    fi
    echo_info "found the data encryption key for this host \"${target_hostname}\": \"${secrets_key_file}\"."
    ls -ldp "${secrets_key_file}"
  fi

  # Now that the repos on GitHub should contain all the information,
  # we throw away the clones that we made.
  echo
  echo_info "removing temporary directory \"${nixos_dir}\"..."
  rm --recursive --preserve-root --force "${nixos_dir}"

  declare -r org_key_dir="${install_dir}/var/lib/msf-ocb"
  mkdir --parents "${org_key_dir}"
  cp /tmp/id_tunnel /tmp/id_tunnel.pub "${org_key_dir}"

  # Create an encrypted data partition, unless requested not to do so
  if ((create_data_part)); then
    echo
    echo_info "creating the encrypted data partition using device \"${data_dev}\" (part #2 of 2)..."
    if ((do_install)); then
      # Do this only after having generated the hardware config
      lvcreate --yes --extents 100%FREE --name nixos_data LVMVolGroup
    fi
    wait_for_devices "${data_dev}"
    echo

    mkdir --parents /run/cryptsetup
    cryptsetup --verbose \
      --batch-mode \
      --cipher aes-xts-plain64 \
      --key-size 512 \
      --hash sha512 \
      --use-urandom \
      luksFormat \
      --type luks2 \
      --key-file "${secrets_key_file}" \
      "${data_dev}"
    cryptsetup open \
      --key-file "${secrets_key_file}" \
      "${data_dev}" nixos_data_decrypted
    mkfs.ext4 -e remount-ro \
      -m 1 \
      -L nixos_data \
      /dev/mapper/nixos_data_decrypted

    wait_for_devices "/dev/disk/by-label/nixos_data"
    echo

    mkdir --parents "${install_dir}/opt"
    mount /dev/disk/by-label/nixos_data "${install_dir}/opt"
    mkdir --parents "${install_dir}/home"
    mkdir --parents "${install_dir}/opt/.home"
    mount --bind "${install_dir}/opt/.home" "${install_dir}/home"
  fi

  if ((do_install)); then
    echo
    echo_info "installing the new customised NixOS system on local disk..."
    GIT_SSH_COMMAND="ssh -i '${org_key_dir}/id_tunnel'" nixos-install \
      --no-root-passwd \
      --max-jobs 4 \
      --option extra-experimental-features 'flakes nix-command' \
      --flake "${main_repo_flake}#${target_hostname}-install"
  else
    echo
    echo_info "rebuilding the configuration of this pre-installed NixOS system..."
    GIT_SSH_COMMAND="ssh -i '${org_key_dir}/id_tunnel'" nixos-rebuild \
      --option extra-experimental-features 'flakes nix-command' \
      --flake "${main_repo_flake}#${target_hostname}" \
      switch

    if [[ ! -b /dev/disk/by-label/nixos_root && -b /dev/disk/by-label/nixos ]]; then
      echo
      echo_info "correcting label of the root disk partition (for system boot)..."
      e2label /dev/disk/by-label/nixos nixos_root
    fi
  fi

  if ((do_install && create_data_part)); then
    echo
    echo_info "closing the encrypted data partition..."
    umount --recursive "${install_dir}"/home
    umount --recursive "${install_dir}"/opt
    cryptsetup close nixos_data_decrypted
  fi

  if ((do_install)); then
    echo
    echo_info "tearing down temporary swap file \"${swapfile}\"..."
    swapoff "${swapfile}"
    rm --force "${swapfile}"
  fi

  echo
  echo_info "MSF-OCB NixOS $( ((do_install)) && echo "installation" || echo "configuration") completed successfully for host \"${target_hostname}\"."
  echo
  echo "Please now reboot this machine using command:"
  echo "# sudo systemctl reboot"

} # Prevent execution if this script was only partially downloaded - END
# ## EOF
