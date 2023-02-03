#! /usr/bin/env nix-shell
#! nix-shell -i bash --packages bash nettools git
# shellcheck shell=bash

# To migrate a NixOS Linux system installed with the old 2-repo MSF-OCB NixOS configuration to the new 1-repo one,
# follow latest instructions at <https://github.com/MSF-OCB/NixOS-OCB/wiki/> (private repo).
# Typically this script is executed with a command-line like this (sudo access required):
# $ curl -L https://github.com/MSF-OCB/NixOS-OCB-install/raw/main/migrate.sh | sudo bash -s --

# Set up the shell environment
set -euo pipefail
shopt -s extglob globstar nullglob

declare -r script_name="migrate.sh"
# TODO: keep script version string up-to-date
declare -r script_version="v2023.02.03.0-BETA1"
declare -r script_title="MSF-OCB custom NixOS Linux configuration 2-repo to 1-repo migration script (2023-01)"

##########
### FUNCTIONS:

function echo_info() {
  echo "${script_name}:" "${@}"
}

function echo_err() {
  echo "${script_name}: ERROR:" "${@}" >&2
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

if ((EUID != 0)); then
  echo_err "this script should be run using command 'sudo' or as super-user 'root'!"
  exit 102
fi

# shellcheck disable=SC2155
declare -r hostname="${HOSTNAME:-$(hostname)}"

declare -r nixos_cfg_dir="/etc/nixos"
declare -r nixos_cfg_2repo_dir="${nixos_cfg_dir}.2repo"
declare -r nixos_cfg_1repo_dir="${nixos_cfg_dir}.1repo"
declare -r nixos_cfg_git_cfg_file="${nixos_cfg_dir}/.git/config"
declare -r org_tunnel_priv_key_file="${nixos_cfg_dir}/local/id_tunnel"

# Define constants for use of MSF-OCB GitHub repositories
declare -r github_org_name="MSF-OCB"
declare -r main_repo_name="NixOS-OCB"
declare -r main_repo="git@github.com:${github_org_name}/${main_repo_name}.git"
declare -r main_repo_branch="main"
# declare -r github_nixos_robot_name="OCB NixOS Robot"
# declare -r github_nixos_robot_email="69807852+nixos-ocb@users.noreply.github.com"

echo_info "checking current NixOS configuration directory \"${nixos_cfg_dir}\"..."
if [[ ! -d "${nixos_cfg_dir}" ]]; then
  echo_err "standard NixOS configuration directory \"${nixos_cfg_dir}\" not found!"
  exit 103
fi
if [[ -f "${nixos_cfg_git_cfg_file}" ]] && grep -F "${main_repo}" "${nixos_cfg_git_cfg_file}"; then
  echo_err "current NixOS configuration directory \"${nixos_cfg_dir}\" seems to be already migrated to the new 1-repo MSF-OCB NixOS configuration!"
  exit 104
fi
if [[ ! -r "${org_tunnel_priv_key_file}" ]]; then
  echo_err "organisation tunnel private key file \"${org_tunnel_priv_key_file}\" not found/readable by the current user!"
  exit 105
fi
echo

if [[ -d "${nixos_cfg_2repo_dir}" ]]; then
  echo_err "old 2-repo NixOS configuration backup directory \"${nixos_cfg_2repo_dir}\" already exists!"
  echo "Please check its contents to see if it is (still) needed (esp. to be able revert to the old 2-repo configuration)."
  echo "Please only delete it if confirmed that it is not needed - if in doubt please rather rename it (better safe than sorry)."
  echo "Then try to run again this migration script."
  exit 106
fi

# If command 'git' is not available, try to get it via its Nix package and add its folder to the system path
if ! type -p "git" >&/dev/null; then
  echo_info "downloading missing required software package 'git'..."
  PATH="$(nix-build --no-out-link -E '(import <nixpkgs> {})' -A 'git')/bin:${PATH}"
  export PATH
  git --version
  echo
fi

if [[ -d "${nixos_cfg_1repo_dir}" ]]; then
  echo_info "temporary new 1-repo NixOS configuration directory \"${nixos_cfg_1repo_dir}\" already exists - it will first get purged."
  echo
fi

echo_info "parameters:"
echo "- GitHub.com private repository (@branch): \"${github_org_name}/${main_repo_name}@${main_repo_branch}\""
echo

echo_info "about to start the migration of host \"${hostname}\" to the new 1-repo MSF-OCB NixOS configuration on $(date +'%F_%T%z')..."
echo "(Press [Ctrl+C] *now* to abort)"
echo -ne "\n--> countdown before proceeding: "
for countdown in $(seq 9 -1 0); do
  echo -n "${countdown} "
  sleep 1
done
echo "GO!"

if [[ -d "${nixos_cfg_1repo_dir}" ]]; then
  echo_info "temporary new 1-repo NixOS configuration directory \"${nixos_cfg_1repo_dir}\" already exists - first purging it..."
  rm --recursive --dir --force --preserve-root "${nixos_cfg_1repo_dir}"
  echo
fi

echo
echo_info "downloading new 1-repo MSF-OCB NixOS configuration files into directory \"${nixos_cfg_1repo_dir}\"..."
mkdir --parents --verbose -- "${nixos_cfg_1repo_dir}"
chmod --reference="${nixos_cfg_dir}" --preserve-root --changes -- "${nixos_cfg_1repo_dir}"
chown --reference="${nixos_cfg_dir}" --preserve-root --changes -- "${nixos_cfg_1repo_dir}"
git -c core.sshCommand="ssh -F none -o IdentitiesOnly=yes -i '${org_tunnel_priv_key_file}'" clone --filter=blob:none --single-branch --branch "${main_repo_branch}" "${main_repo}" "${nixos_cfg_1repo_dir}"
cp --archive --force --verbose -- "${nixos_cfg_dir}/local" "${nixos_cfg_1repo_dir}/"
echo

echo
echo_info "switching directory \"${nixos_cfg_dir}\" to new 1-repo MSF-OCB NixOS configuration files..."
mv --verbose -- "${nixos_cfg_dir}" "${nixos_cfg_2repo_dir}"
mv --verbose -- "${nixos_cfg_1repo_dir}" "${nixos_cfg_dir}"

echo
echo_info "updating Nix channels..."
nix-channel --add https://nix-channel-redirect.ocb.msf.org nixos
nix-channel --list
nix-channel --update nixos

# Generate hardware-configuration.nix, but omit the filesystems which
# we already define statically in eval_host.nix.
echo
echo_info "generating NixOS configuration..."
nixos-generate-config --no-filesystems
# Create the settings.nix symlink pointing to the file defining the current server.
(cd "${nixos_cfg_dir}" && ln --symbolic --verbose -- "org-config/hosts/${hostname}.nix" "settings.nix")

echo
echo_info "rebuilding the configuration of this NixOS system..."
nixos-rebuild switch

echo
echo_info "completed successfully the migration of host \"${hostname}\" to the new 1-repo MSF-OCB NixOS configuration on $(date +'%F_%T%z')..."
echo

### EOF
