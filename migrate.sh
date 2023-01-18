#!/usr/bin/env bash

# Set up the shell environment
set -euo pipefail
shopt -s extglob globstar nullglob

declare -r script_name="migrate.sh"
# TODO: keep script version string up-to-date
declare -r script_version="v2023.01.17.0-ALPHA0"
declare -r script_title="MSF-OCB custom NixOS Linux config 2-repo to 1-repo migration script"

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
declare -r hostname="$(hostname)"

declare -r nixos_cfg_dir="/etc/nixos"
declare -r nixos_cfg_2repo_dir="${nixos_cfg_dir}.2repo"
declare -r nixos_cfg_1repo_dir="${nixos_cfg_dir}.1repo"
declare -r org_tunnel_priv_key_file="${nixos_cfg_dir}/local/id_tunnel"

if [[ ! -d "${nixos_cfg_dir}" ]]; then
  echo_err "standard NixOS config directory \"${nixos_cfg_dir}\" does NOT exist!"
  exit 102
fi

if [[ ! -r "${org_tunnel_priv_key_file}" ]]; then
  echo_err "organisation tunnel private key file \"${org_tunnel_priv_key_file}\" does NOT exist or is NOT readable by the current user!"
  exit 103
fi

if [[ -d "${nixos_cfg_2repo_dir}" ]]; then
  echo_err "old 2-repo NixOS config directory \"${nixos_cfg_2repo_dir}\" already exists!"
  exit 104
fi

if [[ -d "${nixos_cfg_1repo_dir}" ]]; then
  echo_err "new 1-repo NixOS config directory \"${nixos_cfg_1repo_dir}\" already exists!"
  exit 105
fi

# Define constants for use of MSF-OCB GitHub repositories
declare -r github_org_name="MSF-OCB"
declare -r main_repo_name="NixOS-OCB"
declare -r main_repo="git@github.com:${github_org_name}/${main_repo_name}.git"
declare -r main_repo_branch="main"
declare -r github_nixos_robot_name="OCB NixOS Robot"
declare -r github_nixos_robot_email="69807852+nixos-ocb@users.noreply.github.com"

echo_info "parameters:"
echo "- GitHub.com private repository (@branch): \"${github_org_name}/${main_repo_name}@${main_repo_branch}\""
echo

# If command 'git' is not available, try to get it via its Nix package and add its folder to the system path
if ! which "git" >&/dev/null; then
  echo_info "downloading missing required software package 'git'..."
  PATH="$(nix-build --no-out-link -E '(import <nixpkgs> {})' -A 'git')/bin:${PATH}"
  export PATH
  git --version
  echo
fi

echo_info "about to start migrating to one MSF-OCB NixOS repo for host \"${hostname}\" on $(date +'%F_%T%z')..."
echo "(Press [Ctrl+C] *now* to abort)"
echo -ne "\n--> countdown before proceeding: "
for countdown in $(seq 9 -1 0); do
  echo -n "${countdown} "
  sleep 1
done
echo "GO!"

echo
echo_info "downloading MSF-OCB NixOS configuration files into \"${nixos_cfg_1repo_dir}\"..."
mkdir --parents --verbose -- "${nixos_cfg_1repo_dir}"
chmod --preserve-root --changes --reference="${nixos_cfg_dir}" -- "${nixos_cfg_1repo_dir}"
chown --preserve-root --changes --reference="${nixos_cfg_dir}" -- "${nixos_cfg_1repo_dir}"
git -c core.sshCommand="ssh -F none -o IdentitiesOnly=yes -i '${org_tunnel_priv_key_file}'" clone --filter=blob:none --single-branch --branch "${main_repo_branch}" "${main_repo}" "${nixos_cfg_1repo_dir}"
echo

cp --archive --force --verbose -- "${nixos_cfg_dir}/local" "${nixos_cfg_1repo_dir}/"
mv --verbose -- "${nixos_cfg_dir}" "${nixos_cfg_2repo_dir}"
mv --verbose -- "${nixos_cfg_1repo_dir}" "${nixos_cfg_dir}"

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
echo_info "migrating to one MSF-OCB NixOS repo completed successfully for host \"${hostname}\" on $(date +'%F_%T%z')."
echo

### EOF
