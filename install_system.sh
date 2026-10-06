#!/usr/bin/env bash

set -Eeuo pipefail
set +x
shopt -s inherit_errexit nullglob
IFS=$' \t\n'
umask 077

readonly PROGRAM="install-system"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
ARCH_DATA=""
ARCH_POLICY_REF=""
ARCH_LEGACY_STATE=0
readonly NEUROARCH_URL="https://github.com/Neur0leptic/neuroarch.git"
readonly NEUROARCH_BRANCH="main"
readonly NEUROARCH_CACHE="/usr/local/share/install-system/.neuroarch-snapshots"
COMMON_DATA="$(dirname "$SCRIPT_PATH")/packaging/common"
[[ -d "$COMMON_DATA" ]] || COMMON_DATA=/usr/local/share/install-system/common
readonly COMMON_DATA
readonly DEFAULT_STATE_FILE="/var/lib/install-system/state"
readonly DEFAULT_TARGET_MOUNT="/mnt/gentoo"
readonly RUN_LOCK_FILE="/run/install-system/lock"
readonly PROFILE_PATH="default/linux/amd64/23.0/no-multilib"
readonly STAGE_BASE_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds"
readonly STAGE_LATEST_FILE="latest-stage3-amd64-nomultilib-openrc.txt"
readonly GENTOO_KEYRING_URL="https://qa-reports.gentoo.org/output/service-keys.gpg"
readonly GENTOO_MASTER_FINGERPRINT="13EBBDBEDE7A12775DFDB1BABB572E0E2D182910"
readonly GENTOO_SIGNING_FINGERPRINT="534E4209AB49EEE1C19D96162C44695DB9F6043D"

readonly NEUROGENTOO_URL="https://github.com/Neur0leptic/neurogentoo.git"
readonly NEUROGENTOO_BRANCH="main"
# Ebuild workers must be able to read this public tree. Installer state remains
# private under /var/lib/install-system (0700), so repositories cannot live there.
NEUROGENTOO_REF=""
NEUROGENTOO_ROOT=""
PORTAGE_POLICY=""

readonly PUBLIC_DOTFILES_URL="https://github.com/Neur0leptic/dotfiles.git"
readonly PUBLIC_DOTFILES_BRANCH="main"
readonly PRIVATE_DOTFILES_URL="git@github.com:Neur0leptic/dotfiles-private.git"
readonly PRIVATE_APPLY_POLICY="selected-private-with-transmission-v2"
# Published at https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
readonly GITHUB_SSH_HOST_KEY="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
readonly LIBREWOLF_REPOSITORY_URL="https://codeberg.org/librewolf/gentoo.git"
readonly -a HOST_TOOLS=(blkid chroot cmp curl findmnt flock git gpg gpgv lsblk mkfs.f2fs mkfs.vfat mount mountpoint parted partprobe python3 readlink sha256sum sha512sum tar udevadm umount wipefs xz)


declare -a HOST_SEQUENCE=(
    host-preflight:host_preflight:validate_host_preflight
    disk:partition_target_disk:validate_disk_stage
    filesystems:format_target_filesystems:validate_filesystems_stage
    mounts:phase_mounts:validate_mounts_stage
    stage3:phase_stage3:validate_stage3
    target-setup:phase_target_setup:validate_target_setup
    chroot-mounts:phase_chroot_mounts:validate_chroot_mounts
    chroot-install:phase_chroot_install:validate_chroot_install
)
declare -a MINIMAL_SEQUENCE=(
    target-preflight:phase_target_preflight:validate_target_preflight
    profile:phase_profile:validate_profile
    portage:phase_portage:validate_portage
    base-packages:phase_base_packages:validate_build_pass
    bootstrap-world:phase_bootstrap_world:validate_build_pass
    toolchain-bootstrap:phase_toolchain_bootstrap:validate_build_pass
    prepolly-world:phase_prepolly_world:validate_build_pass
    gcc-runtime:phase_gcc_runtime:validate_build_pass
    gcc-toolchain:phase_gcc_toolchain:validate_build_pass
    clang-toolchain:phase_clang_toolchain:validate_build_pass
    polly-runtime:phase_polly_runtime:validate_build_pass
    clang-policy:phase_clang_policy:validate_compiler_policy_stage
    world-rebuild:phase_world_rebuild:validate_build_pass
    base-cleanup:phase_base_cleanup:validate_base_packages
    system-config:phase_system_config:validate_system_config
    accounts:phase_accounts:validate_accounts
    account-shell:phase_user_shell:validate_user_shell
    network:phase_network:validate_network
    fstab:phase_fstab:validate_fstab
    kernel-config:phase_kernel_config:validate_kernel_config_stage
    kernel:phase_kernel:validate_kernel
    boot:phase_boot:validate_boot
    minimal-complete:phase_marker:validate_minimal_complete
)
declare -a EXISTING_SEQUENCE=(existing-preflight:phase_existing_preflight:validate_existing_preflight)
declare -a DWL_SEQUENCE=(
    minimal-to-dwl:phase_minimal_to_dwl_approval:validate_minimal_to_dwl_approval
    hardware-policy:phase_hardware_policy:validate_hardware_policy
    display-config:phase_display_config:validate_display_config
    desktop-repositories:phase_desktop_repositories:validate_desktop_repositories
    desktop-packages:phase_desktop_packages:validate_desktop_packages
    user-shell:phase_user_shell:validate_user_shell
    dwl-build:phase_dwl_build:validate_dwl_build
    public-dotfiles:phase_public_dotfiles:validate_public_dotfiles
    librewolf-setup:phase_librewolf_setup:validate_librewolf_setup
    browser-theme:phase_browser_theme:validate_browser_theme
    browser-extensions:phase_browser_extensions:validate_browser_extensions
    private-dotfiles:phase_private_dotfiles:validate_private_dotfiles
    dwl-complete:phase_marker:validate_dwl_complete
)
declare -a FULL_SEQUENCE=(
    dwl-to-full:phase_dwl_to_full_approval:validate_dwl_to_full_approval
    full-packages:phase_full_packages:validate_full_packages
    full-public-dotfiles:phase_public_dotfiles:validate_public_dotfiles
    full-browser-theme:phase_browser_theme:validate_browser_theme
    full-browser-extensions:phase_browser_extensions:validate_browser_extensions
    full-private-dotfiles:phase_private_dotfiles:validate_private_dotfiles
    source-apps:phase_source_apps:validate_source_apps
    binary-apps:phase_binary_apps:validate_binary_apps
    full-complete:phase_marker:validate_full_complete
)
# Preserve the Gentoo sequences when loading a different distribution's state.
for group in HOST MINIMAL EXISTING DWL FULL; do
    declare -a "GENTOO_${group}_SEQUENCE=()" "${group}_STAGES=()"
    declare -n sequence="${group}_SEQUENCE" saved="GENTOO_${group}_SEQUENCE"
    saved=("${sequence[@]}")
done
unset -n sequence saved
unset group

declare -A STATE=()
declare -a OWNED_MOUNTS=()

COMMAND=""
MODE=""
TIER=""
DISTRIBUTION=""
DESKTOP="dwl"
FILESYSTEM="f2fs"
BOOT_METHOD="efistub"
REPOSITORIES="vanilla"
ARCH_SELECTION_OPTIONS=0
ARCH_OPTION_NAMES=""
TARGET_MOUNT="$DEFAULT_TARGET_MOUNT"
MOUNTPOINT_OPTION_SET=0
STATE_FILE=""
DISK=""
DISK_OPTION_SET=0
ROOT_PARTITION=""
ROOT_PARTITION_OPTION_SET=0
BOOT_PARTITION=""
BOOT_PARTITION_OPTION_SET=0
USERNAME=""
USERNAME_OPTION_SET=0
HOSTNAME_VALUE=""
HOSTNAME_OPTION_SET=0
TIMEZONE=""
TIMEZONE_OPTION_SET=0
GPU_PROFILE="auto"
GRAPHICS=""
GPU_OPTION_SET=0
MACHINE_PROFILE="generic"
MACHINE_OPTION_SET=0
DISPLAY_CONFIG=""
KERNEL_CONFIG_READY=0
CHROOT_RESULTS_CHECKED=0
GPG_RECIPIENT=""
PRIVATE_DOTFILES="ask"
SSH_KEY=""
CREATE_EFI_ENTRY="yes"
EFI_OPTION_SET=0
FEATURE_MAIL="false"
FEATURE_KEEPASS="false"
FEATURE_WIREGUARD="false"
TORRENT="ask"
DISK_MODE="erase"
ACCOUNT_PASSWORD=""
export -n ACCOUNT_PASSWORD
RESUME_QUESTION_DONE=0
DRY_RUN=0
NON_INTERACTIVE=0
INTERNAL_CHROOT=0
FORCE_STAGE=""
CHILD_FORCE_STAGE=""
CURRENT_STAGE=""
PHASE_WAITING=0
STOP_REQUESTED=0
RUN_LOCK_FD=""
STATE_WRITE_ACTIVE=0

usage() {
    cat <<'EOF'
Usage:
  install_system.sh new [options]
  install_system.sh existing [options]
  install_system.sh continue [options]
  install_system.sh status [--mountpoint PATH] [--state-file PATH]
  install_system.sh --list-stages

Modes:
  new       Install Gentoo or Arch, then optionally desktop/full.
  existing  Add desktop/full to an existing Gentoo OpenRC or Arch system.
  continue  Resume saved progress or complete an existing installation.
  status    Print saved inputs and phase states without changing the system.

Options:
  --distribution gentoo|arch
  --tier minimal|dwl|desktop|full  dwl for Gentoo; desktop for Arch
  --desktop dwl|hyprland          Arch desktop/full selection
  --filesystem btrfs|f2fs         Arch new installations
  --boot-method grub|efistub      Arch F2FS only; Btrfs always uses GRUB
  --repositories vanilla|cachyos  Arch; selects linux or linux-cachyos
  --disk /dev/DEVICE
  --root-partition /dev/PARTITION
  --boot-partition /dev/PARTITION
  --mountpoint PATH
  --state-file PATH
  --username NAME
  --hostname NAME
  --timezone REGION/CITY
  --graphics FAMILY[,FAMILY]    intel-legacy, intel-modern, amd, radeon, nvidia-open, nvidia-closed, virtual
  --machine generic|main
  --display-config FILE         Per-output JSON answers instead of interactive prompts
  --kernel-config-ready         Confirm manual kernel configuration on continue
  --gpg-recipient FINGERPRINT
  --private-dotfiles | --no-private-dotfiles  Private payload for neuroleptic only
  --ssh-key FILE
  --no-efi-entry
  --torrent yes|no              Optional full-tier torrent/search tools
  --non-interactive
  --dry-run
  --step STAGE
  -h, --help

Safety:
  --dry-run prints only a phase plan. It never runs phase bodies.
  Choose DELETE_EVERYTHING or SKIP (prepared root and EFI partitions).
  Passwords, SSH keys and GPG material are never saved in installer state.
EOF
}

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

quote_command() {
    local arg
    printf '+'
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
}

run() {
    if ((DRY_RUN)); then
        quote_command "$@"
        return 0
    fi
    "$@"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_root() {
    ((EUID == 0)) || die "this command must be run as root"
}

root_controls_directory() {
    local path="$1" mode
    [[ -d "$path" && ! -L "$path" && "$(stat -c %u "$path")" == "0" ]] || return 1
    mode="$(stat -c %a "$path")"
    (( (8#$mode & 8#022) == 0 ))
}

path_contains_mountpoint() {
    local path="$1" mounted
    while IFS= read -r mounted; do
        [[ "$mounted" != "$path" && "$mounted" != "$path"/* ]] || return 0
    done < <(findmnt -rn -o TARGET)
    return 1
}

root_lock_file_is_safe() {
    local path="$1" mode
    [[ ! -e "$path" ]] && return 0
    [[ -f "$path" && ! -L "$path" && "$(stat -c %u "$path")" == "0" && \
        "$(stat -c %h "$path")" == "1" ]] || return 1
    mode="$(stat -c %a "$path")"
    (( (8#$mode & 8#022) == 0 ))
}

valid_state_key() {
    [[ "$1" =~ ^(mode|tier|distribution|desktop|filesystem|boot_method|repositories|arch_cpu|arch_graphics|arch_isa|arch_sof|arch_outputs|arch_policy_ref|username|user_shell|librewolf_setup_result|hostname|timezone|gpu_profile|machine|system_id|policy_ref|compiler_policy|feature_mail|feature_keepass|feature_wireguard|torrent|disk_mode|private_dotfiles|disk|disk_serial|disk_wwn|disk_ptuuid|boot_partition|root_partition|boot_uuid|root_uuid|boot_partuuid|root_partuuid|stage_sha512|stage_path|efi_entry|approval\.(minimal-to-dwl|dwl-to-full|minimal-to-desktop|desktop-to-full|user-shell)|stage\.[a-z0-9-]+)$ ]]
}

valid_state_value() {
    [[ "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *$'\t'* ]]
}

validate_loaded_state() {
    local key stage status
    [[ "${STATE[distribution]:-gentoo}" =~ ^(gentoo|arch)$ ]] || die "invalid distribution in state"
    if [[ "${STATE[distribution]:-gentoo}" == arch ]]; then
        arch_validate_state
    else
        [[ "${STATE[tier]}" =~ ^(minimal|dwl|full)$ ]] || die "invalid Gentoo tier in state"
        [[ ! -v STATE[arch_policy_ref] ]] || die "Gentoo state contains an Arch policy revision"
    fi
    [[ ! -v STATE[policy_ref] || "${STATE[policy_ref]}" =~ ^[0-9a-f]{40}$ ]] || die "invalid policy revision in state"
    [[ ! -v STATE[compiler_policy] || "${STATE[compiler_policy]}" =~ ^(bootstrap|prepolly|gcc|clang|polly|final)$ ]] || die "invalid compiler transition in state"
    [[ "${STATE[torrent]:-ask}" =~ ^(ask|yes|no)$ ]] || die "invalid torrent choice"
    [[ "${STATE[disk_mode]:-erase}" =~ ^(erase|prepared)$ ]] || die "invalid disk mode"
    [[ "${STATE[mode]}" =~ ^(new|existing)$ ]] || die "invalid mode in state"
    [[ "${STATE[mode]}" != "existing" || "${STATE[tier]}" != "minimal" ]] || die "invalid existing-mode tier in state"
    [[ "${STATE[username]:-}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "invalid username in state"
    [[ ! -v STATE[user_shell] || "${STATE[user_shell]}" == /bin/zsh ]] || die "invalid target shell in state"
    [[ ! -v STATE[librewolf_setup_result] || "${STATE[librewolf_setup_result]}" =~ ^(success|failed)$ ]] || die "invalid LibreWolf setup result in state"
    [[ "${STATE[hostname]:-}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?$ ]] || die "invalid hostname in state"
    [[ "${STATE[timezone]:-}" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$ ]] || die "invalid timezone in state"
    [[ "${STATE[gpu_profile]:-}" =~ ^(auto|intel-x220|modern-amd-intel|nvidia|mesa)$ ]] || die "invalid GPU profile in state"
    [[ "${STATE[machine]:-}" =~ ^(generic|main)$ ]] || die "invalid machine profile in state"
    for key in feature_mail feature_keepass feature_wireguard; do
        [[ "${STATE[$key]:-}" =~ ^(true|false)$ ]] || die "invalid boolean state value: $key"
    done
    [[ "${STATE[private_dotfiles]:-}" =~ ^(ask|yes|no)$ ]] || die "invalid private-dotfiles state"
    [[ "${STATE[efi_entry]:-}" =~ ^(yes|no)$ ]] || die "invalid EFI-entry state"
    for key in approval.minimal-to-dwl approval.dwl-to-full approval.minimal-to-desktop approval.desktop-to-full approval.user-shell; do
        [[ ! -v "STATE[$key]" || "${STATE[$key]}" == "yes" ]] || die "invalid tier approval state: $key"
    done
    if [[ "${STATE[mode]}" == "new" ]]; then
        [[ -n "${STATE[disk]:-}" ]] || die "new-install state is missing disk"
        if [[ "${STATE["stage.disk"]:-pending}" == "done" ]]; then
            for key in boot_partition root_partition boot_partuuid root_partuuid disk_ptuuid; do
                [[ -n "${STATE[$key]:-}" ]] || die "completed disk stage is missing $key"
            done
        fi
        if [[ "${STATE["stage.filesystems"]:-pending}" == "done" ]]; then
            for key in boot_uuid root_uuid; do
                [[ -n "${STATE[$key]:-}" ]] || die "completed filesystems stage is missing $key"
            done
        fi
    else
        [[ "${STATE[system_id]:-}" =~ ^[0-9a-fA-F]{32}$ ]] || die "existing-mode state has no valid machine ID"
    fi
    for key in "${!STATE[@]}"; do
        [[ "$key" == stage.* ]] || continue
        stage="${key#stage.}"
        stage_exists "$stage" || die "unknown stage in state: $stage"
        status="${STATE[$key]}"
        [[ "$status" =~ ^(pending|running|waiting|failed|done)$ ]] || die "invalid stage state for $stage: $status"
    done
}

state_write() {
    ((DRY_RUN)) && return 0
    [[ -n "$STATE_FILE" ]] || die "internal error: state path is unset"
    ((STATE_WRITE_ACTIVE == 0)) || die "recursive state write"
    STATE_WRITE_ACTIVE=1
    validate_loaded_state

    local dir tmp key lock_fd
    local -a keys=()
    dir="$(dirname "$STATE_FILE")"
    [[ ! -L "$dir" ]] || die "state directory must not be a symlink: $dir"
    if [[ -e "$dir" ]]; then
        [[ -d "$dir" ]] || die "state directory is not a directory: $dir"
        root_controls_directory "$dir" || die "state directory is not exclusively controlled by root: $dir"
    else
        install -d -m 0700 "$dir"
    fi
    [[ ! -L "$STATE_FILE" ]] || die "state file must not be a symlink: $STATE_FILE"
    [[ ! -e "$STATE_FILE" || -f "$STATE_FILE" ]] || die "state path is not a regular file: $STATE_FILE"
    root_lock_file_is_safe "${STATE_FILE}.lock" || die "state lock is not a safe root-owned regular file"
    exec {lock_fd}>"${STATE_FILE}.lock"
    chmod 0600 "${STATE_FILE}.lock"
    chown root:root "${STATE_FILE}.lock"
    flock "$lock_fd"
    tmp="$(mktemp "${dir}/.state.XXXXXX")"
    chmod 0600 "$tmp"
    for key in "${!STATE[@]}"; do
        keys+=("$key")
    done
    mapfile -t keys < <(printf '%s\n' "${keys[@]}" | LC_ALL=C sort)
    for key in "${keys[@]}"; do
        valid_state_key "$key" || die "refusing to write invalid state key: $key"
        valid_state_value "${STATE[$key]}" || die "refusing to write unsafe state value for $key"
        printf '%s=%s\n' "$key" "${STATE[$key]}" >>"$tmp"
    done
    mv -fT -- "$tmp" "$STATE_FILE"
    chmod 0600 "$STATE_FILE"
    chown root:root "$STATE_FILE"
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    STATE_WRITE_ACTIVE=0
}

state_load() {
    [[ -r "$STATE_FILE" ]] || die "state file not found or unreadable: $STATE_FILE"
    [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || die "state path must be a regular non-symlink file: $STATE_FILE"
    if [[ "$COMMAND" != "status" ]]; then
        root_controls_directory "$(dirname "$STATE_FILE")" || \
            die "mutable state directory is not exclusively controlled by root"
        [[ "$(stat -c %u "$STATE_FILE")" == "0" && "$(stat -c %a "$STATE_FILE")" == "600" ]] || \
            die "mutable state must be root-owned with mode 0600"
    fi

    local line key value
    STATE=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        [[ "$line" == *=* ]] || die "invalid state line"
        key="${line%%=*}"
        value="${line#*=}"
        valid_state_key "$key" || die "invalid state key: $key"
        valid_state_value "$value" || die "invalid state value for key: $key"
        [[ ! -v "STATE[$key]" ]] || die "duplicate state key: $key"
        STATE["$key"]="$value"
    done <"$STATE_FILE"

    configure_sequences "${STATE[distribution]:-gentoo}"
    validate_loaded_state
    ARCH_LEGACY_STATE=0
    if [[ "${STATE[distribution]:-gentoo}" == arch ]]; then
        if [[ -v STATE[arch_policy_ref] ]]; then
            select_arch_snapshot "${STATE[arch_policy_ref]}"
        else
            ARCH_POLICY_REF=""
            ARCH_DATA=""
            ARCH_LEGACY_STATE=1
        fi
    else
        [[ ! -v STATE[policy_ref] ]] || select_portage_snapshot "${STATE[policy_ref]}"
    fi
}

state_set() {
    local key="$1" value="$2"
    valid_state_key "$key" || die "invalid state key: $key"
    valid_state_value "$value" || die "invalid state value for key: $key"
    STATE["$key"]="$value"
    state_write
}

state_stage_status() {
    printf '%s' "${STATE["stage.$1"]:-pending}"
}

state_initialize() {
    local write_now="${1:-yes}"
    STATE=()
    STATE[mode]="$MODE"
    STATE[tier]="$TIER"
    STATE[distribution]="$DISTRIBUTION"
    if [[ "$DISTRIBUTION" == arch ]]; then
        STATE[desktop]="$DESKTOP"
        STATE[filesystem]="$FILESYSTEM"
        STATE[boot_method]="$BOOT_METHOD"
        STATE[repositories]="$REPOSITORIES"
    fi
    STATE[username]="$USERNAME"
    [[ "$MODE" != new ]] || STATE[user_shell]=/bin/zsh
    STATE[hostname]="$HOSTNAME_VALUE"
    STATE[timezone]="$TIMEZONE"
    STATE[torrent]="$TORRENT"
    STATE[disk_mode]="$DISK_MODE"
    if [[ "$MODE" == new && "$DISK_MODE" == prepared ]]; then
        STATE[root_partition]="$ROOT_PARTITION"
        STATE[boot_partition]="$BOOT_PARTITION"
    fi
    STATE[gpu_profile]="$GPU_PROFILE"
    STATE[machine]="$MACHINE_PROFILE"
    STATE[feature_mail]="$FEATURE_MAIL"
    STATE[feature_keepass]="$FEATURE_KEEPASS"
    STATE[feature_wireguard]="$FEATURE_WIREGUARD"
    STATE[private_dotfiles]="$PRIVATE_DOTFILES"
    STATE[efi_entry]="$CREATE_EFI_ENTRY"
    if [[ "$MODE" == "existing" ]]; then
        [[ -s /etc/machine-id ]] || die "existing mode requires /etc/machine-id"
        STATE[system_id]="$(tr -d '\r\n' </etc/machine-id)"
    fi
    if [[ "$DISTRIBUTION" == arch && $DRY_RUN -eq 0 ]]; then
        ARCH_LEGACY_STATE=0
        ensure_arch_source no
        STATE[arch_policy_ref]="$ARCH_POLICY_REF"
    fi
    [[ "$write_now" == "no" ]] || state_write
}

restore_globals_from_state() {
    [[ -z "$DISTRIBUTION" || "$DISTRIBUTION" == "${STATE[distribution]:-gentoo}" ]] || die "distribution differs from saved state"
    DISTRIBUTION="${STATE[distribution]:-gentoo}"
    DESKTOP="${STATE[desktop]:-dwl}"
    FILESYSTEM="${STATE[filesystem]:-f2fs}"
    BOOT_METHOD="${STATE[boot_method]:-efistub}"
    REPOSITORIES="${STATE[repositories]:-vanilla}"
    configure_sequences "$DISTRIBUTION"
    MODE="${STATE[mode]}"
    TIER="${STATE[tier]}"
    USERNAME="${STATE[username]:-}"
    HOSTNAME_VALUE="${STATE[hostname]:-}"
    TIMEZONE="${STATE[timezone]}"
    [[ "$TORRENT" != ask ]] || TORRENT="${STATE[torrent]:-ask}"
    DISK_MODE="${STATE[disk_mode]:-erase}"
    GPU_PROFILE="${STATE[gpu_profile]:-auto}"
    MACHINE_PROFILE="${STATE[machine]:-generic}"
    set_tier_features
    [[ "$PRIVATE_DOTFILES" != "ask" ]] || PRIVATE_DOTFILES="${STATE[private_dotfiles]:-ask}"
    ((EFI_OPTION_SET)) || CREATE_EFI_ENTRY="${STATE[efi_entry]:-yes}"
    DISK="${STATE[disk]:-}"
    ROOT_PARTITION="${STATE[root_partition]:-}"
    BOOT_PARTITION="${STATE[boot_partition]:-}"
}

acquire_run_lock() {
    ((DRY_RUN)) && return 0
    if [[ -e /run/install-system ]]; then
        root_controls_directory /run/install-system || die "run-lock directory is not exclusively controlled by root"
    else
        install -d -m 0755 /run/install-system
    fi
    root_lock_file_is_safe "$RUN_LOCK_FILE" || die "run lock is not a safe root-owned regular file"
    exec {RUN_LOCK_FD}>"$RUN_LOCK_FILE"
    chmod 0600 "$RUN_LOCK_FILE"
    chown root:root "$RUN_LOCK_FILE"
    flock -n "$RUN_LOCK_FD" || die "another install-system process is running"
}

release_run_lock() {
    [[ -n "$RUN_LOCK_FD" ]] || return 0
    flock -u "$RUN_LOCK_FD" || true
    exec {RUN_LOCK_FD}>&-
    RUN_LOCK_FD=""
}

remember_mount() {
    OWNED_MOUNTS+=("$1")
}

forget_mount() {
    local wanted="$1" mount index
    local -a retained=()
    for ((index = 0; index < ${#OWNED_MOUNTS[@]}; index++)); do
        mount="${OWNED_MOUNTS[index]}"
        [[ "$mount" == "$wanted" ]] || retained+=("$mount")
    done
    OWNED_MOUNTS=("${retained[@]}")
}

cleanup_mounts() {
    local index target
    for ((index = ${#OWNED_MOUNTS[@]} - 1; index >= 0; index--)); do
        target="${OWNED_MOUNTS[index]}"
        if mountpoint -q "$target" 2>/dev/null; then
            umount -R "$target" 2>/dev/null || warn "could not unmount $target"
        fi
    done
    OWNED_MOUNTS=()
}

ensure_target_mount_directory() {
    local -a entries=()
    [[ ! -L "$TARGET_MOUNT" ]] || die "target mountpoint must not be a symlink"
    if [[ -e "$TARGET_MOUNT" ]]; then
        root_controls_directory "$TARGET_MOUNT" || die "target mountpoint is not exclusively controlled by root"
    else
        root_controls_directory /mnt || die "/mnt must be exclusively controlled by root"
        install -d -m 0755 "$TARGET_MOUNT"
    fi
    entries=("$TARGET_MOUNT"/* "$TARGET_MOUNT"/.[!.]* "$TARGET_MOUNT"/..?*)
    ((${#entries[@]} == 0)) || die "unmounted target directory is not empty: $TARGET_MOUNT"
}

target_mount_tree_is_empty() {
    local mounted
    while IFS= read -r mounted; do
        [[ "$mounted" == "$TARGET_MOUNT" || "$mounted" == "$TARGET_MOUNT"/* ]] && return 1
    done < <(findmnt -rn -o TARGET)
    return 0
}

on_error() {
    local status=$? line="${BASH_LINENO[0]:-unknown}" command="${BASH_COMMAND:-unknown}" stage="${CURRENT_STAGE:-none}"
    trap - ERR
    if ((STATE_WRITE_ACTIVE == 0)) && [[ -n "$CURRENT_STAGE" && -n "$STATE_FILE" && -d "$(dirname "$STATE_FILE")" ]]; then
        STATE["stage.$CURRENT_STAGE"]="failed"
        (state_write) || true
    fi
    CURRENT_STAGE=""
    printf '%s: stage %s failed at line %s: %s (status %s)\n' \
        "$PROGRAM" "$stage" "$line" "$command" "$status" >&2
    if [[ "$stage" == chroot-install ]]; then
        local key
        for key in "${!STATE[@]}"; do
            if [[ "$key" == stage.* && "$key" != stage.chroot-install && "${STATE[$key]}" == failed ]]; then
                stage="${key#stage.}"
                break
            fi
        done
    fi
    if [[ "$stage" =~ ^(none|host-preflight|disk|filesystems|mounts|stage3|bootstrap|target-setup|chroot-mounts|chroot-install)$ ]]; then
        printf 'Repair the failure manually, then run continue.\n' >&2
    else
        printf 'Repair the failure manually, then run continue (stage menu) or continue --step %s.\n' "$stage" >&2
    fi
    exit "$status"
}

on_exit() {
    local status=$?
    trap - EXIT ERR INT TERM HUP
    if ((status != 0 && STATE_WRITE_ACTIVE == 0)) && [[ -n "$CURRENT_STAGE" && "${STATE["stage.$CURRENT_STAGE"]:-}" == "running" ]]; then
        STATE["stage.$CURRENT_STAGE"]="failed"
        (state_write) || true
    fi
    cleanup_mounts
    release_run_lock
    exit "$status"
}

trap on_error ERR
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

parse_arguments() {
    while (($#)); do
        case "$1" in
            new|existing|continue|status)
                [[ -z "$COMMAND" ]] || die "only one command may be specified"
                COMMAND="$1"
                shift
                ;;
            --list-stages)
                [[ -z "$COMMAND" ]] || die "only one command may be specified"
                COMMAND="list-stages"
                shift
                ;;
            --tier)
                (($# >= 2)) || die "--tier requires a value"
                TIER="$2"
                shift 2
                ;;
            --distribution)
                (($# >= 2)) || die "--distribution requires a value"
                DISTRIBUTION="$2"
                shift 2
                ;;
            --desktop|--filesystem|--boot-method|--repositories)
                (($# >= 2)) || die "$1 requires a value"
                case "$1" in
                    --desktop) DESKTOP="$2" ;;
                    --filesystem) FILESYSTEM="$2" ;;
                    --boot-method) BOOT_METHOD="$2" ;;
                    --repositories) REPOSITORIES="$2" ;;
                esac
                ARCH_SELECTION_OPTIONS=1
                ARCH_OPTION_NAMES+=" $1 "
                shift 2
                ;;
            --disk)
                (($# >= 2)) || die "--disk requires a value"
                DISK="$2"
                DISK_OPTION_SET=1
                shift 2
                ;;
            --root-partition)
                (($# >= 2)) || die "--root-partition requires a value"
                ROOT_PARTITION="$2"
                ROOT_PARTITION_OPTION_SET=1
                shift 2
                ;;
            --boot-partition)
                (($# >= 2)) || die "--boot-partition requires a value"
                BOOT_PARTITION="$2"
                BOOT_PARTITION_OPTION_SET=1
                shift 2
                ;;
            --mountpoint)
                (($# >= 2)) || die "--mountpoint requires a value"
                TARGET_MOUNT="$2"
                MOUNTPOINT_OPTION_SET=1
                shift 2
                ;;
            --username)
                (($# >= 2)) || die "--username requires a value"
                USERNAME="$2"
                USERNAME_OPTION_SET=1
                shift 2
                ;;
            --hostname)
                (($# >= 2)) || die "--hostname requires a value"
                HOSTNAME_VALUE="$2"
                HOSTNAME_OPTION_SET=1
                shift 2
                ;;
            --timezone)
                (($# >= 2)) || die "--timezone requires a value"
                TIMEZONE="$2"
                TIMEZONE_OPTION_SET=1
                shift 2
                ;;
            --graphics)
                (($# >= 2)) || die "--graphics requires a value"
                GRAPHICS="$2"
                GPU_OPTION_SET=1
                shift 2
                ;;
            --machine)
                (($# >= 2)) || die "--machine requires a value"
                MACHINE_PROFILE="$2"
                MACHINE_OPTION_SET=1
                shift 2
                ;;
            --display-config)
                (($# >= 2)) || die "--display-config requires a file"
                DISPLAY_CONFIG="$(readlink -f -- "$2")"
                shift 2
                ;;
            --kernel-config-ready)
                KERNEL_CONFIG_READY=1
                shift
                ;;
            --gpg-recipient)
                (($# >= 2)) || die "--gpg-recipient requires a value"
                GPG_RECIPIENT="$2"
                shift 2
                ;;
            --ssh-key)
                (($# >= 2)) || die "--ssh-key requires a value"
                SSH_KEY="$2"
                shift 2
                ;;
            --private-dotfiles)
                PRIVATE_DOTFILES="yes"
                shift
                ;;
            --no-private-dotfiles)
                PRIVATE_DOTFILES="no"
                shift
                ;;
            --no-efi-entry)
                CREATE_EFI_ENTRY="no"
                EFI_OPTION_SET=1
                shift
                ;;
            --torrent)
                (($# >= 2)) || die "--torrent requires yes or no"
                TORRENT="$2"
                [[ "$TORRENT" == yes || "$TORRENT" == no ]] || die "--torrent requires yes or no"
                shift 2
                ;;
            --non-interactive)
                NON_INTERACTIVE=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --step)
                (($# >= 2)) || die "--step requires a value"
                FORCE_STAGE="$2"
                shift 2
                ;;
            --state-file)
                (($# >= 2)) || die "--state-file requires a value"
                STATE_FILE="$2"
                shift 2
                ;;
            --internal-chroot)
                INTERNAL_CHROOT=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                (($# == 0)) || die "positional arguments after -- are not supported"
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done
}

validate_options() {
    [[ -n "$COMMAND" ]] || {
        if [[ -t 0 && -t 1 ]]; then
            select_command
        else
            usage >&2
            die "a command is required"
        fi
    }

    [[ -z "$DISTRIBUTION" || "$DISTRIBUTION" =~ ^(gentoo|arch)$ ]] || die "invalid distribution"
    [[ -z "$TIER" || "$TIER" =~ ^(minimal|dwl|desktop|full)$ ]] || die "invalid tier: $TIER"
    [[ "$DESKTOP" =~ ^(dwl|hyprland|none)$ ]] || die "invalid desktop"
    [[ "$FILESYSTEM" =~ ^(btrfs|f2fs)$ ]] || die "invalid filesystem"
    [[ "$BOOT_METHOD" =~ ^(grub|efistub)$ ]] || die "invalid boot method"
    [[ "$REPOSITORIES" =~ ^(vanilla|cachyos)$ ]] || die "invalid repositories"
    [[ "$COMMAND" != continue || "$ARCH_SELECTION_OPTIONS" == 0 ]] || die "continue reuses saved Arch selections"
    configure_sequences "${DISTRIBUTION:-gentoo}"
    discover_arch_mountpoint
    [[ -z "$GRAPHICS" || "$GRAPHICS" =~ ^(intel-legacy|intel-modern|amd|radeon|nvidia-open|nvidia-closed|virtual)(,(intel-legacy|intel-modern|amd|radeon|nvidia-open|nvidia-closed|virtual))*$ ]] || die "invalid --graphics selection"
    [[ "$MACHINE_PROFILE" =~ ^(generic|main)$ ]] || die "invalid machine profile"
    [[ "$PRIVATE_DOTFILES" =~ ^(ask|yes|no)$ ]] || die "invalid private-dotfiles setting"
    [[ "$CREATE_EFI_ENTRY" =~ ^(yes|no)$ ]] || die "invalid EFI-entry setting"
    [[ "$TARGET_MOUNT" =~ ^/mnt/[A-Za-z0-9._-]+$ ]] || die "mountpoint must be a direct child of /mnt"
    [[ "${TARGET_MOUNT##*/}" != "." && "${TARGET_MOUNT##*/}" != ".." ]] || die "invalid mountpoint leaf"
    [[ -z "$USERNAME" || "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "invalid username"
    [[ -z "$HOSTNAME_VALUE" || "$HOSTNAME_VALUE" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?$ ]] || die "invalid hostname"
    [[ -z "$GPG_RECIPIENT" || "$GPG_RECIPIENT" =~ ^[0-9A-Fa-f]{40}$ ]] || die "GPG recipient must be a full 40-hex fingerprint"
    GPG_RECIPIENT="${GPG_RECIPIENT^^}"
    [[ -z "$SSH_KEY" || ( "$SSH_KEY" == /* && "$SSH_KEY" != *$'\n'* && "$SSH_KEY" != *$'\r'* ) ]] || die "SSH key path must be a safe absolute path"
    [[ -z "$TIMEZONE" || "$TIMEZONE" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$ ]] || die "invalid timezone path"

    if [[ "$COMMAND" == "existing" && "$TIER" == "minimal" ]]; then
        die "existing mode supports only dwl or full tiers"
    fi
    [[ -z "$DISPLAY_CONFIG" || -f "$DISPLAY_CONFIG" ]] || die "display config is not a regular file"
    ((KERNEL_CONFIG_READY == 0)) || [[ "$COMMAND" == continue ]] || die "--kernel-config-ready is valid only with continue"
    if [[ "$COMMAND" != "continue" && -n "$FORCE_STAGE" ]]; then
        die "--step is valid only with continue"
    fi
    if [[ -n "$FORCE_STAGE" ]]; then
        # run_sequence checks the stage name after loading the saved distribution.
        [[ ! "$FORCE_STAGE" =~ -(complete)$ ]] || die "completion marker stages cannot be forced"
        [[ "$FORCE_STAGE" != *-to-* ]] || \
            die "tier approval stages cannot be forced"
    fi
    case "$COMMAND" in
        new)
            ((ROOT_PARTITION_OPTION_SET == BOOT_PARTITION_OPTION_SET)) || die "prepared disks need both --root-partition and --boot-partition"
            ((ROOT_PARTITION_OPTION_SET == 0)) || DISK_MODE=prepared
            ;;
        existing)
            ((DISK_OPTION_SET == 0 && ROOT_PARTITION_OPTION_SET == 0 && BOOT_PARTITION_OPTION_SET == 0)) || \
                die "disk and partition options are not valid in existing mode"
            ((HOSTNAME_OPTION_SET == 0 && TIMEZONE_OPTION_SET == 0 && EFI_OPTION_SET == 0)) || \
                die "hostname, timezone, and EFI options are not changed in existing mode"
            ;;
        continue)
            ((DISK_OPTION_SET == 0 && BOOT_PARTITION_OPTION_SET == 0 && USERNAME_OPTION_SET == 0 && HOSTNAME_OPTION_SET == 0 && \
                TIMEZONE_OPTION_SET == 0 && GPU_OPTION_SET == 0 && MACHINE_OPTION_SET == 0)) || \
                die "continue uses persisted identity and hardware settings; only --root-partition may identify an unmounted target"
            ;;
    esac
    if ((INTERNAL_CHROOT)); then
        [[ "$COMMAND" == "continue" && "${INSTALL_SYSTEM_CHROOT:-}" == "1" ]] || die "--internal-chroot is reserved for installer handoff"
    fi
    if [[ -n "$STATE_FILE" ]]; then
        [[ "$STATE_FILE" == /* ]] || die "state file path must be absolute"
        case "$COMMAND" in
            new|existing)
                [[ "$COMMAND" == "existing" && "$STATE_FILE" == "$DEFAULT_STATE_FILE" ]] || die "custom state files are not supported for $COMMAND"
                ;;
            continue)
                [[ "$STATE_FILE" == "$DEFAULT_STATE_FILE" || "$STATE_FILE" == "$TARGET_MOUNT$DEFAULT_STATE_FILE" ]] || \
                    die "continue state must be $DEFAULT_STATE_FILE or $TARGET_MOUNT$DEFAULT_STATE_FILE"
                ;;
        esac
    fi
}

select_command() {
    local choice
    printf '1) New installation\n2) Continue / complete an existing installation\n3) Status\n'
    read -r -p 'Selection: ' choice
    case "$choice" in
        1) COMMAND="new" ;;
        2) COMMAND="continue" ;;
        3) COMMAND="status" ;;
        *) die "invalid selection" ;;
    esac
}

select_tier() {
    local choice
    if [[ "$DISTRIBUTION" == arch ]]; then arch_select_tier; return; fi
    [[ "$TIER" != desktop ]] || die "Gentoo uses --tier dwl"
    [[ -z "$TIER" ]] || return 0
    if ((NON_INTERACTIVE)); then
        die "--tier is required in non-interactive mode"
    fi
    if [[ "$MODE" == "existing" ]]; then
        printf '1) Minimal DWL\n2) Full System\n'
        read -r -p 'Installation tier: ' choice
        case "$choice" in
            1) TIER="dwl" ;;
            2) TIER="full" ;;
            *) die "invalid tier selection" ;;
        esac
    else
        printf '1) Minimal Gentoo\n2) Minimal Gentoo + Minimal DWL\n3) Full System\n'
        read -r -p 'Installation tier: ' choice
        case "$choice" in
            1) TIER="minimal" ;;
            2) TIER="dwl" ;;
            3) TIER="full" ;;
            *) die "invalid tier selection" ;;
        esac
    fi
}

select_existing_user() {
    local entries account uid home shell choice index
    local -a users=()
    if [[ -z "$USERNAME" ]]; then
        entries="$(getent passwd)" || die "could not read existing user accounts"
        while IFS=: read -r account _ uid _ _ home shell; do
            [[ "$uid" =~ ^[0-9]+$ ]] || continue
            ((uid >= 1000 && uid < 65534)) || continue
            [[ "$home" == "/home/$account" ]] || continue
            case "${shell##*/}" in ''|false|nologin) continue ;; esac
            users+=("$account")
        done <<<"$entries"
        case "${#users[@]}" in
            0) die "no normal user with a /home/USERNAME home was found; create the target account first" ;;
            1) USERNAME="${users[0]}" ;;
            *)
                ((NON_INTERACTIVE == 0)) || die "multiple existing users found; select one with existing --username NAME"
                printf 'Select the existing user for this installation:\n'
                for index in "${!users[@]}"; do printf '%s) %s\n' "$((index + 1))" "${users[index]}"; done
                read -r -p 'Selection: ' choice
                [[ "$choice" =~ ^[1-9][0-9]{0,5}$ ]] && ((choice <= ${#users[@]})) || die "invalid user selection"
                USERNAME="${users[choice - 1]}"
                ;;
        esac
        log "Using existing user: $USERNAME"
    fi
    user_home_is_safe || die "target user is missing or has an unsafe home directory: $USERNAME"
}

prompt_identity() {
    [[ "$MODE" != existing ]] || select_existing_user
    if [[ -z "$USERNAME" ]]; then
        ((NON_INTERACTIVE)) && die "--username is required in non-interactive mode"
        read -r -p 'Username: ' USERNAME
    fi
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "invalid username"
    if [[ "$MODE" == new ]] && system_account_name "$USERNAME"; then
        die "username is reserved for a system account or group: $USERNAME"
    fi
    if [[ "$MODE" == new ]] && ((DRY_RUN == 0)); then collect_password; fi
    HOSTNAME_VALUE="${HOSTNAME_VALUE:-$USERNAME}"
    [[ "$HOSTNAME_VALUE" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?$ ]] || die "invalid hostname"
    if [[ "$MODE" == existing ]]; then
        TIMEZONE="$(readlink -f /etc/localtime)"
        TIMEZONE="${TIMEZONE#/usr/share/zoneinfo/}"
        [[ "$TIMEZONE" != /* && -f "/usr/share/zoneinfo/$TIMEZONE" ]] || TIMEZONE=Etc/UTC
    elif ((DRY_RUN == 0)); then
        select_timezone
    fi
    [[ "$TIER" != full ]] || select_torrent
}

system_account_name() {
    # Reject the account before long builds; useradd would refuse it only later.
    # The live environment shares common system users and groups with the target.
    local entry id
    for entry in "$(getent passwd "$1" || true)" "$(getent group "$1" || true)"; do
        [[ -n "$entry" ]] || continue
        IFS=: read -r _ _ id _ <<<"$entry"
        ((id < 1000 || id >= 60000)) && return 0
    done
    return 1
}

choose_number() {
    local prompt="$1" choice index
    shift
    local -a choices=("$@")
    ((${#choices[@]})) || die "no choices available: $prompt"
    for index in "${!choices[@]}"; do printf '%s) %s\n' "$((index + 1))" "${choices[index]}" >&2; done
    while true; do
        read -r -p "$prompt: " choice || return 1
        if [[ "$choice" =~ ^[1-9][0-9]{0,5}$ ]] && ((choice <= ${#choices[@]})); then
            printf '%s' "${choices[choice - 1]}"
            return
        fi
        printf 'Choose a listed number.\n' >&2
    done
}

select_timezone() {
    local region
    local -a zones=() regions=() cities=()
    if [[ -z "$TIMEZONE" ]]; then
        ((NON_INTERACTIVE == 0)) || die "--timezone is required"
        mapfile -t zones < <(awk '!/^#/ && NF >= 3 {print $3}' /usr/share/zoneinfo/zone.tab | LC_ALL=C sort)
        mapfile -t regions < <(printf '%s\n' "${zones[@]}" Etc/UTC | cut -d/ -f1 | LC_ALL=C sort -u)
        region="$(choose_number 'Timezone region (Etc includes UTC)' "${regions[@]}")"
        mapfile -t cities < <(printf '%s\n' "${zones[@]}" Etc/UTC | sed -n "s|^$region/||p" | LC_ALL=C sort -u)
        TIMEZONE="$region/$(choose_number 'Timezone city' "${cities[@]}")"
    fi
    [[ "$TIMEZONE" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$ && -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "timezone is unavailable: $TIMEZONE"
    log "Timezone: $TIMEZONE"
}

collect_password() {
    local confirmation
    [[ -z "$ACCOUNT_PASSWORD" ]] || return 0
    ((NON_INTERACTIVE == 0)) || die "collect the initial account password interactively before starting builds"
    printf 'The new user and root will use this password, as in part2.sh.\n' >/dev/tty
    while true; do
        IFS= read -r -s -p "Password for $USERNAME: " ACCOUNT_PASSWORD </dev/tty || die "password input ended"
        printf '\n' >/dev/tty
        IFS= read -r -s -p 'Confirm password: ' confirmation </dev/tty || die "password confirmation ended"
        printf '\n' >/dev/tty
        if [[ -n "$ACCOUNT_PASSWORD" && "$ACCOUNT_PASSWORD" == "$confirmation" && ${#ACCOUNT_PASSWORD} -le 512 ]]; then break; fi
        ACCOUNT_PASSWORD=""
        printf 'Passwords must match and contain 1–512 characters.\n' >/dev/tty
    done
    unset confirmation
}

password_hash_is_set() {
    local password="$1"
    # passwd -l prefixes an existing hash with '!'; preserve that hash and lock.
    # Bare !, !! or * markers still need initial credentials on a new installation.
    while [[ "$password" == '!'* ]]; do password="${password#!}"; done
    [[ -n "$password" && "$password" != '*'* ]]
}

prepare_credentials() {
    local root="${1:-}" account password name rest missing=0
    [[ "$MODE" == new ]] || return 0
    if ((INTERNAL_CHROOT)) && [[ "${INSTALL_SYSTEM_CREDENTIALS:-}" == 1 ]]; then
        IFS= read -r -d '' ACCOUNT_PASSWORD <&3 || die "credential handoff failed"
        exec 3<&-
        unset INSTALL_SYSTEM_CREDENTIALS
    fi
    for account in root "$USERNAME"; do
        password=""
        if [[ -r "$root/etc/shadow" ]]; then
            while IFS=: read -r name password rest; do [[ "$name" != "$account" ]] || break; password=""; done <"$root/etc/shadow"
        fi
        password_hash_is_set "$password" || missing=1
    done
    ((missing == 0)) || collect_password
}

apply_collected_password() {
    local account
    for account in root "$USERNAME"; do
        account_password_is_set "$account" && continue
        [[ -n "$ACCOUNT_PASSWORD" ]] || die "password was not collected at startup; resume to supply it"
        printf '%s:%s\n' "$account" "$ACCOUNT_PASSWORD" | chpasswd
    done
    ACCOUNT_PASSWORD=""
}

select_torrent() {
    [[ "$TORRENT" == ask ]] || return 0
    ((DRY_RUN == 0)) || return 0
    ((NON_INTERACTIVE == 0)) || die "full tier requires --torrent yes|no"
    printf 'Optional torrent tools: Transmission downloads/seeds torrents; hck supports the torrent menu;\nProwlarr searches indexers and FlareSolverr handles their browser challenges.\n' >&2
    local choice
    choice="$(choose_number 'Install these tools with the full tier?' 'No' 'Yes')"
    TORRENT=no
    [[ "$choice" != Yes ]] || TORRENT=yes
}

list_stages() {
    local stage
    printf 'New-install host stages:\n'
    for stage in "${HOST_STAGES[@]}"; do printf '  %s\n' "$stage"; done
    printf 'Minimal %s stages:\n' "${DISTRIBUTION:-gentoo}"
    for stage in "${MINIMAL_STAGES[@]}"; do printf '  %s\n' "$stage"; done
    printf 'Existing-system stages:\n'
    for stage in "${EXISTING_STAGES[@]}"; do printf '  %s\n' "$stage"; done
    printf 'Desktop stages:\n'
    for stage in "${DWL_STAGES[@]}"; do printf '  %s\n' "$stage"; done
    printf 'Full System stages:\n'
    for stage in "${FULL_STAGES[@]}"; do printf '  %s\n' "$stage"; done
}

stage_exists() {
    local wanted="$1" stage
    for stage in "${HOST_STAGES[@]}" "${MINIMAL_STAGES[@]}" "${EXISTING_STAGES[@]}" "${DWL_STAGES[@]}" "${FULL_STAGES[@]}"; do
        [[ "$stage" == "$wanted" ]] && return 0
    done
    return 1
}

stage_allowed_for_target() {
    local wanted="$1" stage
    if [[ "$MODE" == "new" ]]; then
        for stage in "${MINIMAL_STAGES[@]}"; do [[ "$stage" == "$wanted" ]] && return 0; done
    else
        for stage in "${EXISTING_STAGES[@]}"; do [[ "$stage" == "$wanted" ]] && return 0; done
    fi
    if [[ "$TIER" == dwl || "$TIER" == desktop || "$TIER" == full ]]; then
        for stage in "${DWL_STAGES[@]}"; do [[ "$stage" == "$wanted" ]] && return 0; done
    fi
    if [[ "$TIER" == "full" ]]; then
        for stage in "${FULL_STAGES[@]}"; do [[ "$stage" == "$wanted" ]] && return 0; done
    fi
    return 1
}

show_status() {
    local key stage local_state=0 target_state=0
    discover_arch_mountpoint
    if [[ -z "$STATE_FILE" ]]; then
        [[ -r "$DEFAULT_STATE_FILE" ]] && local_state=1
        [[ -r "$TARGET_MOUNT$DEFAULT_STATE_FILE" ]] && target_state=1
        ((local_state + target_state < 2)) || die "multiple state files found; select one with --state-file"
        if ((local_state)); then
            STATE_FILE="$DEFAULT_STATE_FILE"
        elif ((target_state)); then
            STATE_FILE="$TARGET_MOUNT$DEFAULT_STATE_FILE"
        else
            die "no state file found"
        fi
    fi
    state_load
    printf 'State file: %s\n' "$STATE_FILE"
    for key in distribution mode tier desktop filesystem boot_method repositories arch_cpu arch_graphics arch_isa username user_shell librewolf_setup_result hostname timezone gpu_profile machine torrent disk_mode system_id policy_ref arch_policy_ref compiler_policy disk disk_ptuuid boot_partition root_partition root_uuid boot_uuid boot_partuuid root_partuuid stage_path stage_sha512 approval.minimal-to-dwl approval.dwl-to-full approval.minimal-to-desktop approval.desktop-to-full approval.user-shell; do
        [[ -z "${STATE[$key]:-}" ]] || printf '%-18s %s\n' "$key:" "${STATE[$key]}"
    done
    printf 'Stages:\n'
    # An unset final stage must not become the function's (failing) exit status.
    for stage in "${HOST_STAGES[@]}" "${MINIMAL_STAGES[@]}" "${EXISTING_STAGES[@]}" "${DWL_STAGES[@]}" "${FULL_STAGES[@]}"; do
        [[ -z "${STATE["stage.$stage"]:-}" ]] || printf '  %-24s %s\n' "$stage" "${STATE["stage.$stage"]}"
    done
}

print_dry_plan() {
    local stage
    printf 'DRY-RUN: no phase body will execute and no state will be written.\n'
    printf 'distribution=%s desktop=%s filesystem=%s boot=%s repositories=%s\n' "${DISTRIBUTION:-gentoo}" "$DESKTOP" "$FILESYSTEM" "$BOOT_METHOD" "$REPOSITORIES"
    printf 'command=%s mode=%s tier=%s mountpoint=%s username=%s hostname=%s\n' \
        "$COMMAND" "${MODE:-unset}" "${TIER:-unset}" "$TARGET_MOUNT" "${USERNAME:-unset}" "${HOSTNAME_VALUE:-unset}"
    if [[ "$MODE" == "new" && $INTERNAL_CHROOT -eq 0 ]]; then
        for stage in "${HOST_STAGES[@]}"; do printf '[dry-run] %s\n' "$stage"; done
    fi
    if [[ "$MODE" == "existing" ]]; then
        printf '[dry-run] existing-preflight\n'
    else
        for stage in "${MINIMAL_STAGES[@]}"; do printf '[dry-run] %s\n' "$stage"; done
    fi
    for stage in "${DWL_STAGES[@]}"; do printf '[dry-run] %s\n' "$stage"; done
    for stage in "${FULL_STAGES[@]}"; do printf '[dry-run] %s\n' "$stage"; done
}

write_file() {
    local path="$1" mode="$2" dir tmp
    dir="$(dirname "$path")"
    if ((DRY_RUN)); then
        log "would write $path (mode $mode)"
        return 0
    fi
    [[ -d "$dir" ]] || install -d -m 0755 "$dir"
    tmp="$(mktemp "$dir/.install-system.XXXXXX")"
    cat >"$tmp"
    chmod "$mode" "$tmp"
    chown root:root "$tmp"
    if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
    else
        mv -fT -- "$tmp" "$path"
    fi
}

user_home_is_safe() {
    local entry account uid account_home mode expected_home="/home/$USERNAME"
    entry="$(getent passwd "$USERNAME")" || return 1
    IFS=: read -r account _ uid _ _ account_home _ <<<"$entry"
    [[ "$account" == "$USERNAME" && "$uid" =~ ^[0-9]+$ && "$uid" -ge 1000 && "$account_home" == "$expected_home" ]] || return 1
    [[ -d "$expected_home" && ! -L "$expected_home" && "$(stat -c %u "$expected_home")" == "$uid" ]] || return 1
    mode="$(stat -c %a "$expected_home")"
    (( (8#$mode & 8#022) == 0 ))
}

user_ssh_agent_is_safe() {
    local socket="${SSH_AUTH_SOCK:-}" uid
    [[ "$socket" == /* && "$socket" != *$'\n'* && "$socket" != *$'\r'* && \
        -S "$socket" && ! -L "$socket" ]] || return 1
    uid="$(id -u "$USERNAME")" || return 1
    [[ "$(stat -c %u "$socket")" == "$uid" ]]
}

private_ssh_key_is_safe() {
    local path="$1" home="/home/$USERNAME" uid mode canonical
    user_home_is_safe || return 1
    [[ "$path" =~ ^/home/${USERNAME}/[A-Za-z0-9._/-]+$ && -f "$path" && ! -L "$path" ]] || return 1
    canonical="$(readlink -f -- "$path")" || return 1
    [[ "$canonical" == "$path" ]] || return 1
    uid="$(id -u "$USERNAME")" || return 1
    [[ "$(stat -c %u "$path")" == "$uid" && "$(stat -c %h "$path")" == "1" ]] || return 1
    mode="$(stat -c %a "$path")"
    (( (8#$mode & 8#400) != 0 && (8#$mode & 8#077) == 0 ))
}

ensure_github_known_host() {
    local home="/home/$USERNAME" ssh_dir known_hosts uid mode
    ssh_dir="$home/.ssh"
    known_hosts="$ssh_dir/known_hosts"
    uid="$(id -u "$USERNAME")" || return 1

    [[ ! -L "$ssh_dir" ]] || die "unsafe SSH directory: $ssh_dir"
    if [[ -e "$ssh_dir" ]]; then
        [[ -d "$ssh_dir" && ! -L "$ssh_dir" && "$(stat -c %u "$ssh_dir")" == "$uid" ]] || \
            die "unsafe SSH directory: $ssh_dir"
        mode="$(stat -c %a "$ssh_dir")"
        (( (8#$mode & 8#022) == 0 )) || die "SSH directory is writable by another user: $ssh_dir"
    else
        run_as_user install -d -m 0700 "$ssh_dir"
    fi

    [[ ! -L "$known_hosts" ]] || die "unsafe SSH known_hosts file: $known_hosts"
    if [[ -e "$known_hosts" ]]; then
        [[ -f "$known_hosts" && ! -L "$known_hosts" && "$(stat -c %u "$known_hosts")" == "$uid" && \
            "$(stat -c %h "$known_hosts")" == "1" ]] || die "unsafe SSH known_hosts file: $known_hosts"
        mode="$(stat -c %a "$known_hosts")"
        (( (8#$mode & 8#022) == 0 )) || die "SSH known_hosts is writable by another user: $known_hosts"
    else
        run_as_user install -m 0600 /dev/null "$known_hosts"
    fi

    if ! run_as_user grep -qxF "$GITHUB_SSH_HOST_KEY" "$known_hosts"; then
        run_as_user sh -c '
            file=$1
            key=$2
            if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then
                printf "\n" >>"$file"
            fi
            printf "%s\n" "$key" >>"$file"
        ' sh "$known_hosts" "$GITHUB_SSH_HOST_KEY"
    fi
    run_as_user chmod 0600 "$known_hosts"
    run_as_user grep -qxF "$GITHUB_SSH_HOST_KEY" "$known_hosts" || \
        die "could not install the pinned GitHub SSH host key"
}

run_as_user() {
    local home="/home/$USERNAME" account_shell
    account_shell="$(getent passwd "$USERNAME" | cut -d: -f7)" || return 1
    [[ "$account_shell" == /* ]] || die "target account has no valid shell"
    local -a clean_env=(
        "HOME=$home" "USER=$USERNAME" "LOGNAME=$USERNAME" "SHELL=$account_shell"
        "XDG_CONFIG_HOME=$home/.config"
        "XDG_DATA_HOME=$home/.local/share"
        "XDG_CACHE_HOME=$home/.cache"
        "XDG_STATE_HOME=$home/.local/state"
        "PATH=$home/.local/bin:$home/.cargo/bin:/usr/local/bin:/usr/bin:/bin"
        "LANG=C.UTF-8" "LC_ALL=C.UTF-8"
    )
    user_home_is_safe || die "unsafe or unexpected home directory for $USERNAME"
    user_ssh_agent_is_safe && clean_env+=("SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
    run setsid --fork --wait -- runuser -u "$USERNAME" -- env -i "${clean_env[@]}" "$@" </dev/null
}

request_wait() {
    local message="$1"
    warn "$message"
    state_set "stage.$CURRENT_STAGE" "waiting"
    PHASE_WAITING=1
}

run_phase() {
    local name="$1" action="$2" validator="$3" forced="${4:-no}" status
    STOP_REQUESTED=0
    PHASE_WAITING=0
    status="$(state_stage_status "$name")"

    if [[ "$forced" != "yes" ]] && "$validator" "$name"; then
        if [[ "$status" != "done" ]]; then
            state_set "stage.$name" "done"
        fi
        log "SKIP $name (result already validated)"
        return 0
    fi
    if [[ "$status" == "done" ]]; then
        [[ "$name" != disk && "$name" != filesystems ]] || die "$name identity changed; repair it manually before resuming"
        [[ "$name" != stage3 && "$name" != bootstrap ]] || die "$name validation failed; restore the damaged base files before continuing instead of bootstrapping over the configured target"
        warn "$name was marked done but validation failed; running it again"
        state_set "stage.$name" "pending"
    fi

    log "START $name"
    CURRENT_STAGE="$name"
    state_set "stage.$name" "running"
    "$action"
    if ((PHASE_WAITING)); then
        log "WAITING $name"
        STOP_REQUESTED=1
        CURRENT_STAGE=""
        return 0
    fi
    if ! "$validator" "$name"; then
        state_set "stage.$name" "failed"
        die "postcondition failed for stage: $name"
    fi
    state_set "stage.$name" "done"
    CURRENT_STAGE=""
    log "DONE $name"
}

invalidate_stage_results() {
    local selected="$1" selected_status="$2" entry name invalidate=0
    shift 2
    for entry in "$@"; do
        name="${entry%%:*}"
        [[ "$name" != "$selected" ]] || invalidate=1
        if ((invalidate)); then
            STATE["stage.$name"]="pending"
            rm -f -- "/var/lib/install-system/build-passes/$name.json"
            if [[ "$name" != "$selected" || "$selected_status" == done ]]; then
                rm -f -- "/var/lib/install-system/build-passes/$name.prepared"
            fi
        fi
    done
    state_write
}

run_sequence() {
    local entry name action validator status selected_status forced=no start=1 selected=0
    if [[ "$1" != host-preflight:* ]]; then select_resume_stage "$@"; fi
    if [[ -n "$FORCE_STAGE" ]]; then
        stage_exists "$FORCE_STAGE" || die "unknown stage: $FORCE_STAGE"
        [[ ! "$FORCE_STAGE" =~ -(complete)$ ]] || die "completion marker stages cannot be forced"
        for entry in "$@"; do
            IFS=':' read -r name action validator <<<"$entry"
            [[ "$name" == "$FORCE_STAGE" ]] && selected=1
        done
        ((selected)) || die "stage is not part of the selected mode/tier: $FORCE_STAGE"
        [[ ! "$FORCE_STAGE" =~ ^(host-preflight|disk|filesystems|mounts|stage3|bootstrap|target-setup|chroot-mounts|chroot-install)$ ]] || \
            die "host stages are resumed by validators and cannot be forced with --step"
        [[ "$FORCE_STAGE" != *-to-* ]] || die "tier approval stages cannot be forced"
        selected_status="$(state_stage_status "$FORCE_STAGE")"
        # Validate prerequisites before changing any progress or build receipts.
        for entry in "$@"; do
            IFS=':' read -r name action validator <<<"$entry"
            [[ "$name" != "$FORCE_STAGE" ]] || break
            [[ "$(state_stage_status "$name")" == done ]] && "$validator" "$name" || \
                die "cannot start at $FORCE_STAGE: prerequisite $name is incomplete; resume it after manual repair"
        done
        # Retrying a failed pass retains its prepared policy and manual repairs.
        invalidate_stage_results "$FORCE_STAGE" "$selected_status" "$@"
        start=0
    fi

    for entry in "$@"; do
        IFS=':' read -r name action validator <<<"$entry"
        forced=no
        if ((start == 0)); then
            if [[ "$name" != "$FORCE_STAGE" ]]; then
                status="$(state_stage_status "$name")"
                [[ "$status" == "done" ]] || die "cannot start at $FORCE_STAGE: prerequisite $name is $status"
                "$validator" "$name" || die "cannot start at $FORCE_STAGE: prerequisite $name failed validation"
                log "PREREQUISITE $name (done and validated)"
                continue
            fi
            [[ "$name" =~ ^(disk|filesystems|mounts|stage3)$ ]] && \
                die "--step cannot force a destructive host stage"
            start=1
            forced=yes
        fi
        if [[ "$DISTRIBUTION" == gentoo && "$validator" =~ ^validate_(build_pass|compiler_policy_stage)$ &&
              "$(state_stage_status "$name")" == done ]] && ! "$validator" "$name"; then
            warn "$name build result changed; invalidating later compiler passes before repeating it"
            invalidate_stage_results "$name" done "$@"
        fi
        run_phase "$name" "$action" "$validator" "$forced"
        ((STOP_REQUESTED == 0)) || return 0
    done

}

select_resume_stage() {
    local entry name status selected needs_question=0
    local -a choices=('Resume the first incomplete stage')
    [[ "$COMMAND" == continue && -z "$FORCE_STAGE" ]] && ((NON_INTERACTIVE == 0 && RESUME_QUESTION_DONE == 0)) || return 0
    RESUME_QUESTION_DONE=1
    for entry in "$@"; do
        name="${entry%%:*}"
        [[ "$name" != *-complete && "$name" != *-to-* ]] || continue
        status="$(state_stage_status "$name")"
        [[ "$status" != failed && "$status" != waiting && "$status" != running ]] || needs_question=1
        choices+=("$name [$status]")
    done
    ((needs_question)) || return 0
    selected="$(choose_number 'Resume after manual intervention' "${choices[@]}")"
    [[ "$selected" == "${choices[0]}" ]] || FORCE_STAGE="${selected%% *}"
}

canonical_block_device() {
    local device="$1" canonical
    [[ "$device" == /dev/* ]] || return 1
    canonical="$(readlink -f "$device")"
    [[ -b "$canonical" ]] || return 1
    printf '%s' "$canonical"
}

device_is_under_disk() {
    local device="$1" disk="$2" ancestor
    while IFS= read -r ancestor; do
        [[ "$ancestor" == "$disk" ]] && return 0
    done < <(lsblk -snrpo NAME "$device")
    return 1
}

disk_has_active_users() {
    local disk="$1" device mounts swap_device _
    while read -r device mounts; do
        [[ -z "${mounts:-}" ]] || return 0
    done < <(lsblk -nrpo NAME,MOUNTPOINTS "$disk")

    while read -r swap_device _; do
        [[ "$swap_device" == "Filename" ]] && continue
        [[ -b "$swap_device" ]] || continue
        device_is_under_disk "$swap_device" "$disk" && return 0
    done </proc/swaps
    return 1
}

disk_has_holders() {
    local disk="$1" device base
    while IFS= read -r device; do
        base="$(basename "$device")"
        compgen -G "/sys/class/block/$base/holders/*" >/dev/null && return 0
    done < <(lsblk -nrpo NAME "$disk")
    return 1
}

validate_target_disk() {
    local type read_only removable bytes
    DISK="$(canonical_block_device "$DISK")" || die "not a block device: $DISK"
    type="$(lsblk -dnro TYPE "$DISK")"
    read_only="$(lsblk -dnro RO "$DISK")"
    removable="$(lsblk -dnro RM "$DISK")"
    [[ "$type" == "disk" ]] || die "target is not a whole disk: $DISK"
    [[ "$read_only" == "0" ]] || die "target disk is read-only: $DISK"
    [[ "$removable" =~ ^[01]$ ]] || die "could not determine target disk removability"
    bytes="$(lsblk -bdnro SIZE "$DISK")"
    [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -ge 26000000000 ]] || die "target disk must be at least 26 GB"
    disk_has_active_users "$DISK" && die "target disk or a child partition is mounted or used as swap"
    if disk_has_holders "$DISK"; then
        die "target disk has active holders: $DISK"
    fi
}

select_disk() {
    local selected device type
    local -a devices=() labels=()
    [[ -n "$DISK" ]] && return 0
    if [[ "$DISK_MODE" == prepared ]]; then
        ROOT_PARTITION="$(canonical_block_device "$ROOT_PARTITION")" || die "invalid prepared root"
        device="$(lsblk -nro PKNAME "$ROOT_PARTITION")"
        DISK="/dev/$device"
        return
    fi
    ((NON_INTERACTIVE)) && die "--disk is required in non-interactive new mode"
    while read -r device type; do
        [[ "$type" == disk ]] || continue
        devices+=("$device")
        labels+=("$(lsblk -dnpo NAME,SIZE,MODEL,SERIAL "$device")")
    done < <(lsblk -dnpo NAME,TYPE)
    selected="$(choose_number 'Target disk' "${labels[@]}")"
    DISK="${selected%% *}"
}

select_disk_mode() {
    local choice
    [[ "$DISK_MODE" != prepared ]] || return 0
    printf 'DELETE_EVERYTHING: erase the chosen disk and create root/EFI partitions.\nSKIP: use already formatted root/EFI partitions without formatting them.\n' >/dev/tty
    read -r -p 'Disk action [DELETE_EVERYTHING/SKIP]: ' choice </dev/tty
    case "$choice" in
        DELETE_EVERYTHING) DISK_MODE=erase ;;
        SKIP)
            DISK_MODE=prepared
            lsblk -po NAME,SIZE,FSTYPE,PARTTYPE,MOUNTPOINTS
            read -r -p 'Prepared root partition: ' ROOT_PARTITION </dev/tty
            read -r -p 'Prepared EFI partition: ' BOOT_PARTITION </dev/tty
            ;;
        *) die "disk action was not selected" ;;
    esac
}

confirm_disk_destruction() {
    local model serial size confirmation
    model="$(lsblk -dnro MODEL "$DISK")"
    serial="$(lsblk -dnro SERIAL "$DISK")"
    size="$(lsblk -dnro SIZE "$DISK")"
    if ! printf 'Target: %s\nSize: %s\nModel: %s\nSerial: %s\nErase this disk and create a FAT32 ESP plus %s root? [y/N] ' \
        "$DISK" "$size" "${model:-unknown}" "${serial:-unknown}" "$FILESYSTEM" >/dev/tty; then
        die "destructive confirmation requires a controlling terminal"
    fi
    if ! IFS= read -r confirmation </dev/tty; then
        die "destructive confirmation requires a controlling terminal"
    fi
    [[ "$confirmation" =~ ^[yY]([eE][sS])?$ ]] || die "disk erasure was not confirmed"
}

find_partition_by_label() {
    local disk="$1" label="$2" device partlabel
    while read -r device partlabel; do
        [[ "$partlabel" == "$label" ]] && {
            printf '%s' "$device"
            return 0
        }
    done < <(lsblk -nrpo NAME,PARTLABEL "$disk")
    return 1
}

host_preflight() {
    require_root
    [[ "$(uname -m)" == "x86_64" ]] || die "only x86_64 is supported"
    [[ -d /sys/firmware/efi ]] || die "new mode requires an UEFI-booted environment"
    # The minimal ISO removes diffutils but retains BusyBox's cmp applet.
    if ! command -v cmp >/dev/null; then
        # grep -q may close the pipe before BusyBox finishes: SIGPIPE under pipefail.
        busybox --list | grep -x cmp >/dev/null || die "cmp (or the BusyBox cmp applet) is required"
        cmp() { busybox cmp "$@"; }
    fi
    local command
    for command in "${HOST_TOOLS[@]}"; do
        require_command "$command"
    done
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || die "Python 3.9 or newer is required on the live ISO"
}

partition_target_disk() {
    local disk_identity esp_end=250MiB
    [[ "$DISTRIBUTION" != arch ]] || esp_end=1025MiB
    select_disk
    validate_target_disk
    if [[ "$DISK_MODE" == prepared ]]; then
        BOOT_PARTITION="$(canonical_block_device "$BOOT_PARTITION")" || die "invalid prepared ESP"
        ROOT_PARTITION="$(canonical_block_device "$ROOT_PARTITION")" || die "invalid prepared root"
        device_is_under_disk "$ROOT_PARTITION" "$DISK" && device_is_under_disk "$BOOT_PARTITION" "$DISK" || die "prepared partitions must belong to the selected disk"
        [[ "$ROOT_PARTITION" != "$BOOT_PARTITION" ]] || die "root and ESP must differ"
        [[ "$(blkid -s TYPE -o value "$ROOT_PARTITION")" == "$FILESYSTEM" && "$(blkid -s TYPE -o value "$BOOT_PARTITION")" == vfat ]] || die "prepared filesystems do not match the selected root/ESP types"
        record_partition_identity
        validate_disk_stage || die "prepared partitions must have Linux-root and EFI GPT types"
        return
    fi
    disk_identity="$(lsblk -dnro MAJ:MIN,SERIAL,WWN,SIZE "$DISK")"
    confirm_disk_destruction
    validate_target_disk
    [[ "$(lsblk -dnro MAJ:MIN,SERIAL,WWN,SIZE "$DISK")" == "$disk_identity" ]] || die "target disk identity changed after confirmation"
    run wipefs --all "$DISK"
    run parted -s "$DISK" mklabel gpt
    run parted -s "$DISK" mkpart "$DISTRIBUTION-efi" fat32 1MiB "$esp_end"
    run parted -s "$DISK" set 1 esp on
    run parted -s "$DISK" mkpart "$DISTRIBUTION-root" "$esp_end" 100%
    run parted -s "$DISK" type 2 0fc63daf-8483-4772-8e79-3d69d8477de4
    run partprobe "$DISK"
    run udevadm settle
    BOOT_PARTITION="$(find_partition_by_label "$DISK" "$DISTRIBUTION-efi")" || die "could not resolve ESP by partition label"
    ROOT_PARTITION="$(find_partition_by_label "$DISK" "$DISTRIBUTION-root")" || die "could not resolve root by partition label"
    BOOT_PARTITION="$(canonical_block_device "$BOOT_PARTITION")" || die "could not canonicalize ESP"
    ROOT_PARTITION="$(canonical_block_device "$ROOT_PARTITION")" || die "could not canonicalize root partition"
    record_partition_identity
}

record_partition_identity() {
    STATE[disk]="$DISK"
    STATE[disk_serial]="$(lsblk -dnro SERIAL "$DISK" | tr -d '\r\n')"
    STATE[disk_wwn]="$(lsblk -dnro WWN "$DISK" | tr -d '\r\n')"
    STATE[disk_ptuuid]="$(blkid -s PTUUID -o value "$DISK")"
    STATE[boot_partition]="$BOOT_PARTITION"
    STATE[root_partition]="$ROOT_PARTITION"
    STATE[boot_partuuid]="$(blkid -s PARTUUID -o value "$BOOT_PARTITION")"
    STATE[root_partuuid]="$(blkid -s PARTUUID -o value "$ROOT_PARTITION")"
    [[ -n "${STATE[disk_ptuuid]}" && -n "${STATE[boot_partuuid]}" && -n "${STATE[root_partuuid]}" ]] || \
        die "partition identifiers are incomplete"
    state_write
}

format_target_filesystems() {
    [[ -b "$BOOT_PARTITION" && -b "$ROOT_PARTITION" ]] || die "partition devices are unavailable"
    device_is_under_disk "$BOOT_PARTITION" "$DISK" || die "ESP is not on target disk"
    device_is_under_disk "$ROOT_PARTITION" "$DISK" || die "root partition is not on target disk"
    [[ "${BOOT_PARTITION}" != "${ROOT_PARTITION}" ]] || die "ESP and root partition resolve to the same device"
    disk_has_active_users "$DISK" && die "target disk became active before formatting"
    disk_has_holders "$DISK" && die "target disk gained holders before formatting"
    [[ "$(lsblk -nro PARTTYPE "$BOOT_PARTITION")" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] || die "ESP partition type is incorrect"
    [[ "$(lsblk -nro PARTTYPE "$ROOT_PARTITION")" == "0fc63daf-8483-4772-8e79-3d69d8477de4" ]] || die "root partition type is incorrect"
    if [[ "$DISK_MODE" == erase ]]; then
        run mkfs.vfat -F 32 -n "${DISTRIBUTION^^}_EFI" "$BOOT_PARTITION"
        if [[ "$FILESYSTEM" == btrfs ]]; then
            run mkfs.btrfs -f -L ARCH_ROOT "$ROOT_PARTITION"
        else
            run mkfs.f2fs -f -l "${DISTRIBUTION^^}_ROOT" "$ROOT_PARTITION"
        fi
    fi
    run udevadm settle
    STATE[boot_uuid]="$(blkid -s UUID -o value "$BOOT_PARTITION")"
    STATE[root_uuid]="$(blkid -s UUID -o value "$ROOT_PARTITION")"
    [[ -n "${STATE[boot_uuid]}" && -n "${STATE[root_uuid]}" ]] || die "filesystem identifiers are incomplete"
    state_write
}

mount_target_root() {
    if [[ "$DISTRIBUTION" == arch ]]; then arch_mount_root; return; fi
    local mounted_source
    if mountpoint -q "$TARGET_MOUNT"; then
        mounted_source="$(readlink -f "$(findmnt -rn -o SOURCE -T "$TARGET_MOUNT")")"
        [[ "$mounted_source" == "$ROOT_PARTITION" ]] || die "wrong filesystem is mounted at $TARGET_MOUNT"
        return 0
    fi
    target_mount_tree_is_empty || die "target mountpoint or a descendant is already mounted: $TARGET_MOUNT"
    ensure_target_mount_directory
    run mount "$ROOT_PARTITION" "$TARGET_MOUNT"
    remember_mount "$TARGET_MOUNT"
    findmnt -rn -S "$ROOT_PARTITION" -T "$TARGET_MOUNT" >/dev/null || die "root mount validation failed"
}

phase_mounts() {
    local previous_state="$STATE_FILE" target_state="$TARGET_MOUNT$DEFAULT_STATE_FILE"
    mount_target_root
    if [[ "$previous_state" != "$target_state" ]]; then
        if [[ "$DISK_MODE" == prepared && ( -e "$TARGET_MOUNT/etc/os-release" ||
              -e "$TARGET_MOUNT/etc/gentoo-release" || -e "$TARGET_MOUNT/etc/arch-release" ||
              -e "$TARGET_MOUNT/usr/bin/env" || -e "$TARGET_MOUNT/bin/bash" ) ]]; then
            die "prepared root already contains a system; boot it and use existing, or resume its saved installation"
        fi
        copy_hardware_state "$(dirname "$target_state")/hardware"
        STATE_FILE="$target_state"
        state_write
        rm -f -- "$previous_state" "${previous_state}.lock"
    fi
}

validate_host_preflight() {
    local command
    [[ "$(uname -m)" == "x86_64" && -d /sys/firmware/efi ]] || return 1
    for command in "${HOST_TOOLS[@]}"; do
        command -v "$command" >/dev/null || return 1
    done
}

validate_disk_stage() {
    [[ -b "$DISK" && -b "$BOOT_PARTITION" && -b "$ROOT_PARTITION" ]] &&
        device_is_under_disk "$BOOT_PARTITION" "$DISK" &&
        device_is_under_disk "$ROOT_PARTITION" "$DISK" &&
        [[ "$(blkid -s PTUUID -o value "$DISK" 2>/dev/null)" == "${STATE[disk_ptuuid]:-}" ]] &&
        [[ "$(blkid -s PARTUUID -o value "$BOOT_PARTITION" 2>/dev/null)" == "${STATE[boot_partuuid]:-}" ]] &&
        [[ "$(blkid -s PARTUUID -o value "$ROOT_PARTITION" 2>/dev/null)" == "${STATE[root_partuuid]:-}" ]] &&
        { [[ "$DISK_MODE" == prepared ]] || {
            [[ "$(lsblk -nro PARTLABEL "$BOOT_PARTITION" 2>/dev/null)" == "$DISTRIBUTION-efi" ]] &&
            [[ "$(lsblk -nro PARTLABEL "$ROOT_PARTITION" 2>/dev/null)" == "$DISTRIBUTION-root" ]]; }; } &&
        [[ "$(lsblk -nro PARTTYPE "$BOOT_PARTITION" 2>/dev/null)" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] &&
        [[ "$(lsblk -nro PARTTYPE "$ROOT_PARTITION" 2>/dev/null)" == "0fc63daf-8483-4772-8e79-3d69d8477de4" ]]
}

validate_filesystems_stage() {
    validate_disk_stage &&
        [[ "$(blkid -s TYPE -o value "$BOOT_PARTITION" 2>/dev/null)" == "vfat" ]] &&
        [[ "$(blkid -s TYPE -o value "$ROOT_PARTITION" 2>/dev/null)" == "$FILESYSTEM" ]] &&
        [[ "$(blkid -s UUID -o value "$BOOT_PARTITION" 2>/dev/null)" == "${STATE[boot_uuid]:-}" ]] &&
        [[ "$(blkid -s UUID -o value "$ROOT_PARTITION" 2>/dev/null)" == "${STATE[root_uuid]:-}" ]]
}
validate_mounts_stage() {
    validate_filesystems_stage && findmnt -rn -S "$ROOT_PARTITION" -M "$TARGET_MOUNT" >/dev/null &&
        [[ "$STATE_FILE" == "$TARGET_MOUNT$DEFAULT_STATE_FILE" &&
           -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] && hardware_plan_valid
}

download_to() {
    local url="$1" destination="$2"
    run curl --fail --location --retry 3 --retry-delay 2 --proto '=https' --tlsv1.2 \
        --output "$destination" "$url"
}

keyring_has_fingerprint() {
    local keyring="$1" wanted="$2" line
    while IFS=: read -r type _ _ _ _ _ _ _ _ fingerprint _; do
        if [[ "$type" == "fpr" && "$fingerprint" == "$wanted" ]]; then
            return 0
        fi
    done < <(gpg --batch --show-keys --with-colons "$keyring" 2>/dev/null)
    return 1
}

verify_gentoo_signature() {
    local keyring="$1" signed_file="$2" status_file="$3" line signer primary valid=0
    local -a fields=()
    if ! run gpgv --status-fd 1 --keyring "$keyring" "$signed_file" >"$status_file"; then
        die "Gentoo signature verification failed: $(basename "$signed_file")"
    fi
    while IFS= read -r line; do
        [[ "$line" == '[GNUPG:] VALIDSIG '* ]] || continue
        read -r -a fields <<<"$line"
        ((${#fields[@]} >= 12)) || continue
        signer="${fields[2]}"
        primary="${fields[${#fields[@]} - 1]}"
        if [[ "$signer" == "$GENTOO_SIGNING_FINGERPRINT" && "$primary" == "$GENTOO_MASTER_FINGERPRINT" ]]; then
            valid=1
        fi
    done <"$status_file"
    ((valid)) || die "signature was not made by the pinned Gentoo release subkey"
}

extract_signed_stage_path() {
    local metadata="$1" line first _
    while IFS= read -r line; do
        read -r first _ <<<"$line"
        if [[ "$first" =~ ^[0-9]{8}T[0-9]{6}Z/stage3-amd64-nomultilib-openrc-[0-9]{8}T[0-9]{6}Z\.tar\.xz$ ]]; then
            printf '%s' "$first"
            return 0
        fi
    done <"$metadata"
    return 1
}

extract_sha512_from_digests() {
    local digests="$1" filename="$2" line hash file rest in_sha512=0
    while IFS= read -r line; do
        if [[ "$line" == "# SHA512 HASH" ]]; then
            in_sha512=1
            continue
        fi
        if [[ "$line" == '# '* && "$line" != "# SHA512 HASH" ]]; then
            in_sha512=0
            continue
        fi
        ((in_sha512)) || continue
        read -r hash file rest <<<"$line"
        file="${file#\*}"
        if [[ "$file" == "$filename" && "$hash" =~ ^[0-9a-fA-F]{128}$ && -z "${rest:-}" ]]; then
            printf '%s' "${hash,,}"
            return 0
        fi
    done <"$digests"
    return 1
}

phase_stage3() {
    local work keyring latest relative filename digests archive expected actual signature_status
    if [[ -e "$TARGET_MOUNT/etc/gentoo-release" || -e "$TARGET_MOUNT/bin/bash" || \
        -e "$TARGET_MOUNT/usr/bin/env" ]]; then
        die "target already contains stage3 files without a validated stage3 record; refusing to overlay it"
    fi
    work="$(mktemp -d /tmp/install-system-stage3.XXXXXX)"
    keyring="$work/service-keys.gpg"
    latest="$work/$STAGE_LATEST_FILE"

    download_to "$GENTOO_KEYRING_URL" "$keyring"
    keyring_has_fingerprint "$keyring" "$GENTOO_MASTER_FINGERPRINT" || die "Gentoo master key fingerprint is absent from keyring"
    keyring_has_fingerprint "$keyring" "$GENTOO_SIGNING_FINGERPRINT" || die "expected Gentoo signing key is absent from keyring"
    download_to "$STAGE_BASE_URL/$STAGE_LATEST_FILE" "$latest"
    signature_status="$work/latest.signature-status"
    verify_gentoo_signature "$keyring" "$latest" "$signature_status"
    relative="$(extract_signed_stage_path "$latest")" || die "signed stage metadata did not contain the expected artifact"
    filename="${relative##*/}"
    digests="$work/$filename.DIGESTS"
    archive="$TARGET_MOUNT/$filename"
    download_to "$STAGE_BASE_URL/$relative.DIGESTS" "$digests"
    signature_status="$work/digests.signature-status"
    verify_gentoo_signature "$keyring" "$digests" "$signature_status"
    expected="$(extract_sha512_from_digests "$digests" "$filename")" || die "SHA512 for $filename was not found in signed DIGESTS"
    download_to "$STAGE_BASE_URL/$relative" "$archive"
    actual="$(sha512sum "$archive")"
    actual="${actual%% *}"
    [[ "$actual" == "$expected" ]] || die "stage3 SHA512 mismatch"
    run tar -tJf "$archive" >/dev/null
    run tar xpf "$archive" --xattrs-include='*.*' --numeric-owner -C "$TARGET_MOUNT"
    # Recognize pristine stage3 defaults before the user can edit the target.
    # Only the fields selected by native policy are subsequently managed.
    system_policy seed minimal --root "$TARGET_MOUNT" \
        etc/locale.gen etc/env.d/02locale etc/conf.d/hostname etc/hosts \
        etc/conf.d/hwclock etc/rc.conf etc/doas.conf etc/fstab etc/timezone
    STATE[stage_path]="$relative"
    STATE[stage_sha512]="$expected"
    state_write
    rm -f "$archive"
    rm -rf --one-file-system -- "$work"
}

validate_stage3() {
    [[ -s "$TARGET_MOUNT/etc/gentoo-release" && -x "$TARGET_MOUNT/bin/bash" && -x "$TARGET_MOUNT/usr/bin/env" ]] &&
        [[ "${STATE[stage_path]:-}" =~ ^[0-9]{8}T[0-9]{6}Z/stage3-amd64-nomultilib-openrc-[0-9]{8}T[0-9]{6}Z\.tar\.xz$ ]] &&
        [[ "${STATE[stage_sha512]:-}" =~ ^[0-9a-f]{128}$ ]]
}

mount_target_boot() {
    local existing_target destination="$TARGET_MOUNT/boot"
    [[ "$DISTRIBUTION" != arch ]] || destination="$TARGET_MOUNT/efi"
    install -d -m 0755 "$destination"
    while IFS= read -r existing_target; do
        [[ "$existing_target" == "$destination" ]] || die "persisted ESP is mounted elsewhere: $existing_target"
    done < <(findmnt -rn -S "$BOOT_PARTITION" -o TARGET 2>/dev/null || true)
    if mountpoint -q "$destination"; then
        findmnt -rn -S "$BOOT_PARTITION" -T "$destination" >/dev/null || die "wrong filesystem mounted at target ESP"
        return 0
    fi
    run mount "$BOOT_PARTITION" "$destination"
    remember_mount "$destination"
}

phase_target_setup() {
    local repository_config="$TARGET_MOUNT/etc/portage/repos.conf/gentoo.conf"
    mount_target_boot
    copy_portage_source_to_target
    copy_common_data
    install -d -m 0755 "$TARGET_MOUNT/etc/portage/repos.conf"
    if [[ -e "$repository_config" || -L "$repository_config" ]]; then
        log "Preserving existing Gentoo repository configuration: $repository_config"
    elif [[ -f "$TARGET_MOUNT/usr/share/portage/config/repos.conf" ]]; then
        run cp -- "$TARGET_MOUNT/usr/share/portage/config/repos.conf" "$repository_config"
    fi
    if [[ ! -s "$TARGET_MOUNT/etc/resolv.conf" && ! -L "$TARGET_MOUNT/etc/resolv.conf" ]]; then
        run cp -L /etc/resolv.conf "$TARGET_MOUNT/etc/resolv.conf"
        system_policy seed minimal --root "$TARGET_MOUNT" etc/resolv.conf
    fi
    install -d -m 0755 "$TARGET_MOUNT/usr/local/sbin"
    run install -m 0755 "$SCRIPT_PATH" "$TARGET_MOUNT/usr/local/sbin/install-system"
}

validate_target_setup() {
    validate_portage_source "$TARGET_MOUNT$NEUROGENTOO_ROOT" &&
        common_data_matches "$TARGET_MOUNT/usr/local/share/install-system/common" &&
        [[ -x "$TARGET_MOUNT/usr/local/sbin/install-system" ]] &&
        cmp -s "$SCRIPT_PATH" "$TARGET_MOUNT/usr/local/sbin/install-system" &&
        findmnt -rn -S "$BOOT_PARTITION" -T "$TARGET_MOUNT/boot" >/dev/null &&
        [[ -r "$TARGET_MOUNT/etc/resolv.conf" ]]
}

mount_one_chroot_fs() {
    local kind="$1" source="$2" target="$3"
    if mountpoint -q "$target"; then
        if [[ "$kind" == "proc" ]]; then
            [[ "$(findmnt -rn -o FSTYPE -T "$target")" == "proc" ]] || die "wrong filesystem mounted at $target"
        elif [[ "$kind" == tmpfs ]]; then
            [[ "$(findmnt -rn -o FSTYPE -M "$target")" == tmpfs &&
               "$(stat -Lc '%d:%i' "$source")" != "$(stat -Lc '%d:%i' "$target")" ]] || die "target /run must be a private tmpfs"
        else
            [[ "$(stat -Lc '%d:%i' "$source")" == "$(stat -Lc '%d:%i' "$target")" ]] || die "wrong bind source mounted at $target"
        fi
        return 0
    fi
    case "$kind" in
        tmpfs)
            run mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$target"
            remember_mount "$target"
            ;;
        proc)
            run mount -t proc "$source" "$target"
            remember_mount "$target"
            ;;
        rbind)
            run mount --rbind "$source" "$target"
            remember_mount "$target"
            run mount --make-rslave "$target"
            ;;
        bind)
            run mount --bind "$source" "$target"
            remember_mount "$target"
            run mount --make-slave "$target"
            ;;
        *) die "internal error: unknown mount kind $kind" ;;
    esac
}

phase_chroot_mounts() {
    mount_one_chroot_fs proc /proc "$TARGET_MOUNT/proc"
    mount_one_chroot_fs rbind /sys "$TARGET_MOUNT/sys"
    mount_one_chroot_fs rbind /dev "$TARGET_MOUNT/dev"
    if [[ "$DISTRIBUTION" == arch ]]; then
        mount_one_chroot_fs tmpfs /run "$TARGET_MOUNT/run"
    else
        mount_one_chroot_fs bind /run "$TARGET_MOUNT/run"
    fi
}

validate_chroot_mounts() {
    [[ "$(findmnt -rn -o FSTYPE -T "$TARGET_MOUNT/proc" 2>/dev/null)" == "proc" ]] &&
        [[ "$(stat -Lc '%d:%i' /sys)" == "$(stat -Lc '%d:%i' "$TARGET_MOUNT/sys")" ]] &&
        [[ "$(stat -Lc '%d:%i' /dev)" == "$(stat -Lc '%d:%i' "$TARGET_MOUNT/dev")" ]] || return 1
    if [[ "$DISTRIBUTION" == arch ]]; then
        [[ "$(findmnt -rn -o FSTYPE -M "$TARGET_MOUNT/run")" == tmpfs &&
           "$(stat -Lc '%d:%i' /run)" != "$(stat -Lc '%d:%i' "$TARGET_MOUNT/run")" ]]
    else
        [[ "$(stat -Lc '%d:%i' /run)" == "$(stat -Lc '%d:%i' "$TARGET_MOUNT/run")" ]]
    fi
}

chroot_argument_array() {
    CHROOT_ARGS=(--internal-chroot continue --state-file "$DEFAULT_STATE_FILE")
    ((NON_INTERACTIVE)) && CHROOT_ARGS+=(--non-interactive)
    ((KERNEL_CONFIG_READY == 0)) || CHROOT_ARGS+=(--kernel-config-ready)
    [[ -n "$GPG_RECIPIENT" ]] && CHROOT_ARGS+=(--gpg-recipient "$GPG_RECIPIENT")
    [[ "$PRIVATE_DOTFILES" == "yes" ]] && CHROOT_ARGS+=(--private-dotfiles)
    [[ "$PRIVATE_DOTFILES" == "no" ]] && CHROOT_ARGS+=(--no-private-dotfiles)
    [[ -n "$SSH_KEY" ]] && CHROOT_ARGS+=(--ssh-key "$SSH_KEY")
    [[ -n "$CHILD_FORCE_STAGE" ]] && CHROOT_ARGS+=(--step "$CHILD_FORCE_STAGE")
    return 0
}

phase_chroot_install() {
    local -a CHROOT_ARGS=()
    local completion key status=0
    chroot_argument_array
    prepare_credentials "$TARGET_MOUNT"
    chroot "$TARGET_MOUNT" /usr/bin/env -i \
        HOME=/root TERM="${TERM:-linux}" INSTALL_SYSTEM_CHROOT=1 INSTALL_SYSTEM_CREDENTIALS=1 \
        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        /bin/bash /usr/local/sbin/install-system "${CHROOT_ARGS[@]}" 3< <(printf '%s\0' "$ACCOUNT_PASSWORD") || status=$?
    ACCOUNT_PASSWORD=""
    CHROOT_RESULTS_CHECKED=1
    state_load
    ((status == 0)) || return "$status"
    for key in "${!STATE[@]}"; do
        if [[ "$key" == stage.* && "${STATE[$key]}" == "waiting" ]]; then
            state_set stage.chroot-install waiting
            PHASE_WAITING=1
            warn "target installation is waiting at ${key#stage.}"
            return 0
        fi
    done
    restore_globals_from_state
    completion="${TIER}-complete"
    [[ "${STATE["stage.$completion"]:-}" != "done" ]] || return 0
}

validate_chroot_install() {
    local key
    # Re-enter the target on every host resume so target validators see config
    # edits and new manual stages, even if older state marked a tier complete.
    ((CHROOT_RESULTS_CHECKED)) || return 1
    state_load
    for key in "${!STATE[@]}"; do
        [[ "$key" != stage.* || "${STATE[$key]}" != "waiting" ]] || return 1
    done
    [[ "${STATE["stage.${STATE[tier]}-complete"]:-}" == done ]]
}

validate_persisted_devices() {
    local current_serial current_wwn resolved_root resolved_boot root_disk_name boot_disk_name resolved_disk
    resolved_root="$(blkid -U "${STATE[root_uuid]}" 2>/dev/null || true)"
    resolved_boot="$(blkid -U "${STATE[boot_uuid]}" 2>/dev/null || true)"
    [[ -n "$resolved_root" && -n "$resolved_boot" ]] || die "persisted filesystem UUIDs cannot be resolved"
    ROOT_PARTITION="$(canonical_block_device "$resolved_root")" || die "resolved root is not a block device"
    BOOT_PARTITION="$(canonical_block_device "$resolved_boot")" || die "resolved ESP is not a block device"
    [[ "$ROOT_PARTITION" != "$BOOT_PARTITION" ]] || die "root and ESP resolve to the same device"
    [[ "$(blkid -s UUID -o value "$ROOT_PARTITION")" == "${STATE[root_uuid]}" ]] || die "root UUID changed"
    [[ "$(blkid -s UUID -o value "$BOOT_PARTITION")" == "${STATE[boot_uuid]}" ]] || die "ESP UUID changed"
    [[ "$(blkid -s PARTUUID -o value "$BOOT_PARTITION")" == "${STATE[boot_partuuid]}" ]] || die "ESP PARTUUID changed"
    [[ "$(blkid -s PARTUUID -o value "$ROOT_PARTITION")" == "${STATE[root_partuuid]}" ]] || die "root PARTUUID changed"
    [[ "$(blkid -s TYPE -o value "$ROOT_PARTITION")" == "${STATE[filesystem]:-f2fs}" ]] || die "persisted root filesystem changed"
    [[ "$(blkid -s TYPE -o value "$BOOT_PARTITION")" == "vfat" ]] || die "persisted ESP is not VFAT"
    [[ "$(lsblk -nro PARTTYPE "$ROOT_PARTITION")" == "0fc63daf-8483-4772-8e79-3d69d8477de4" ]] || die "persisted root GPT type changed"
    [[ "$(lsblk -nro PARTTYPE "$BOOT_PARTITION")" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] || die "persisted ESP GPT type changed"
    root_disk_name="$(lsblk -nro PKNAME "$ROOT_PARTITION")"
    boot_disk_name="$(lsblk -nro PKNAME "$BOOT_PARTITION")"
    [[ -n "$root_disk_name" && "$root_disk_name" == "$boot_disk_name" ]] || die "root and ESP do not share a parent disk"
    resolved_disk="/dev/$root_disk_name"
    DISK="$(canonical_block_device "$resolved_disk")" || die "could not resolve persisted parent disk"
    [[ "$(blkid -s PTUUID -o value "$DISK")" == "${STATE[disk_ptuuid]}" ]] || die "disk partition-table UUID changed"
    current_serial="$(lsblk -dnro SERIAL "$DISK" | tr -d '\r\n')"
    current_wwn="$(lsblk -dnro WWN "$DISK" | tr -d '\r\n')"
    [[ -z "${STATE[disk_serial]:-}" || "$current_serial" == "${STATE[disk_serial]}" ]] || die "disk serial changed"
    [[ -z "${STATE[disk_wwn]:-}" || "$current_wwn" == "${STATE[disk_wwn]}" ]] || die "disk WWN changed"
    STATE[root_partition]="$ROOT_PARTITION"
    STATE[boot_partition]="$BOOT_PARTITION"
    STATE[disk]="$DISK"
}

current_root_matches_state() {
    local source uuid partuuid
    source="$(findmnt -ern -o SOURCE -T / 2>/dev/null || true)"
    source="${source%%\[*}"
    [[ -n "$source" ]] || return 1
    source="$(readlink -f "$source" 2>/dev/null || true)"
    [[ -b "$source" ]] || return 1
    if [[ "${STATE[filesystem]:-f2fs}" == btrfs ]]; then
        [[ "$(findmnt -rn -o FSROOT -T /)" == /@ ]] || return 1
    fi
    uuid="$(blkid -s UUID -o value "$source" 2>/dev/null || true)"
    partuuid="$(blkid -s PARTUUID -o value "$source" 2>/dev/null || true)"
    [[ -n "$uuid" && "$uuid" == "${STATE[root_uuid]:-}" && "$partuuid" == "${STATE[root_partuuid]:-}" ]]
}

resume_new_from_host() {
    local requested_tier="${1:-}" mounted_source mount_options
    local supplied_root="" temporary_mount=0
    require_root
    if mountpoint -q "$TARGET_MOUNT"; then
        STATE_FILE="$TARGET_MOUNT$DEFAULT_STATE_FILE"
        state_load
    else
        [[ -n "$ROOT_PARTITION" ]] || {
            ((NON_INTERACTIVE)) && die "--root-partition is required to resume an unmounted target"
            read -r -p 'Installed root partition: ' ROOT_PARTITION
        }
        supplied_root="$(canonical_block_device "$ROOT_PARTITION")" || die "invalid root partition"
        target_mount_tree_is_empty || die "target mountpoint or a descendant is already mounted: $TARGET_MOUNT"
        ensure_target_mount_directory
        mount_options=ro
        [[ "$(blkid -s TYPE -o value "$supplied_root")" != btrfs ]] || mount_options=ro,subvol=@
        run mount -o "$mount_options" "$supplied_root" "$TARGET_MOUNT"
        remember_mount "$TARGET_MOUNT"
        temporary_mount=1
        STATE_FILE="$TARGET_MOUNT$DEFAULT_STATE_FILE"
        state_load
    fi
    [[ "${STATE[mode]}" == "new" ]] || die "host resume requires new-install state"
    restore_globals_from_state
    validate_persisted_devices
    if ((temporary_mount)); then
        mounted_source="$(findmnt -ern -o SOURCE -T "$TARGET_MOUNT")"
        mounted_source="$(readlink -f "${mounted_source%%\[*}")"
        [[ "$mounted_source" == "$ROOT_PARTITION" ]] || die "supplied root does not match the persisted root UUID"
        run umount "$TARGET_MOUNT"
        forget_mount "$TARGET_MOUNT"
        mount_target_root
    else
        mounted_source="$(findmnt -ern -o SOURCE -T "$TARGET_MOUNT")"
        mounted_source="$(readlink -f "${mounted_source%%\[*}")"
        [[ "$mounted_source" == "$ROOT_PARTITION" ]] || die "target mountpoint contains a different root"
        mount_options="$(findmnt -rn -o OPTIONS -T "$TARGET_MOUNT")"
        [[ ",$mount_options," == *,rw,* ]] || die "target root is mounted read-only; remount it read-write before continuing"
    fi

    STATE_FILE="$TARGET_MOUNT$DEFAULT_STATE_FILE"
    state_load
    validate_persisted_devices
    state_write
    restore_globals_from_state
    promote_tier_if_requested "$requested_tier"
    apply_runtime_overrides

    route_force_stage_to_chroot
    run_new_host_sequence
}

route_force_stage_to_chroot() {
    local requested_step="$FORCE_STAGE" stage
    CHILD_FORCE_STAGE=""
    [[ -n "$requested_step" ]] || return 0
    stage_exists "$requested_step" || die "unknown stage: $requested_step"
    for stage in "${HOST_STAGES[@]}"; do
        [[ "$stage" != "$requested_step" ]] || die "host stages are resumed by validators and cannot be forced with --step"
    done
    stage_allowed_for_target "$requested_step" || die "stage is not part of the selected mode/tier: $requested_step"
    [[ ! "$requested_step" =~ -(complete)$ ]] || die "completion marker stages cannot be forced"
    [[ "$requested_step" != *-to-* ]] || \
        die "tier approval stages cannot be forced"
    CHILD_FORCE_STAGE="$requested_step"
    FORCE_STAGE=""
    STATE["stage.chroot-install"]="pending"
    state_write
}

run_new_host_sequence() {
    prepare_credentials "$TARGET_MOUNT"
    if [[ "$DISTRIBUTION" == arch ]]; then
        arch_host_preflight
        [[ -z "${STATE[root_uuid]:-}" ]] || validate_persisted_devices
        run_sequence "${HOST_SEQUENCE[@]}"
        return
    fi
    host_preflight
    ensure_portage_source
    ensure_hardware_plan
    run_sequence "${HOST_SEQUENCE[@]}"
}

run_new_host() {
    MODE="new"
    select_distribution
    select_tier
    [[ "$DISTRIBUTION" != arch ]] || arch_select_install_options
    prompt_identity
    if ((DRY_RUN)); then
        print_dry_plan
        return 0
    fi
    require_root
    acquire_run_lock
    STATE_FILE="$DEFAULT_STATE_FILE"
    archive_previous_installation
    select_disk_mode
    select_disk
    DISK="$(canonical_block_device "$DISK")" || die "not a block device: $DISK"
    state_initialize no
    STATE[disk]="$DISK"
    STATE[disk_serial]="$(lsblk -dnro SERIAL "$DISK" | tr -d '\r\n')"
    STATE[disk_wwn]="$(lsblk -dnro WWN "$DISK" | tr -d '\r\n')"
    state_write
    run_new_host_sequence
}

archive_previous_installation() {
    [[ -e "$STATE_FILE" ]] || return 0
    local answer directory archive
    ((NON_INTERACTIVE == 0)) || die "installer state exists; use continue or archive it interactively"
    read -r -p 'Archive the previous installer record and start a new installation? [y/N] ' answer </dev/tty
    [[ "$answer" =~ ^[yY]([eE][sS])?$ ]] || die "previous installation retained; use continue"
    directory="$(dirname "$STATE_FILE")"
    archive="$(mktemp -d "${directory}.previous.XXXXXX")"
    rmdir "$archive"
    mv -T -- "$directory" "$archive"
    log "Previous record: $archive"
}

hardware_root() {
    printf '%s/hardware' "$(dirname "$STATE_FILE")"
}

hardware_tool() {
    python3 "$COMMON_DATA/hardware.py" "$@"
}

hardware_field() {
    hardware_tool field --plan "$(hardware_root)/inventory.json" --field "$1"
}

hardware_plan_valid() {
    local root jobs
    root="$(hardware_root)"
    [[ -d "$root" && ! -L "$root" && -f "$root/inventory.json" && ! -L "$root/inventory.json" ]] || return 1
    jobs="$(hardware_field resources.jobs)" || return 1
    [[ "$jobs" =~ ^[1-9][0-9]*$ ]] && { [[ "$DISTRIBUTION" == arch ]] || [[ -d "$root/policy/minimal" ]]; }
}

ensure_hardware_plan() {
    local root temporary
    local -a args=()
    require_command python3
    root="$(hardware_root)"
    ((NON_INTERACTIVE == 0)) || args+=(--non-interactive)
    [[ "$MODE" != existing ]] || args+=(--existing)
    if [[ -e "$root" || -L "$root" ]]; then
        hardware_plan_valid || die "incomplete hardware settings: $root"
    else
        if [[ "$TIER" == minimal && -z "$GRAPHICS" ]]; then args+=(--no-graphics); fi
        temporary="$(mktemp -d "$(dirname "$STATE_FILE")/.hardware.XXXXXX")"
        if ! hardware_tool probe --graphics "$GRAPHICS" "${args[@]}" >"$temporary/inventory.json"; then
            rm -rf -- "$temporary"
            die "hardware preparation failed before package/disk operations"
        fi
        mv -T -- "$temporary" "$root"
    fi
    if [[ "$(hardware_field graphics.families)" == '[]' && "$TIER" != minimal ]]; then
        temporary="$(mktemp "$root/.inventory.XXXXXX")"
        hardware_tool select --plan "$root/inventory.json" --graphics "$GRAPHICS" "${args[@]}" >"$temporary"
        mv -T "$temporary" "$root/inventory.json"
    fi
    if [[ "$DISTRIBUTION" == gentoo ]]; then
        hardware_tool render --plan "$root/inventory.json" --destination "$root/policy" --templates "$NEUROGENTOO_ROOT/config/hardware/templates"
    fi
    GPU_PROFILE="$(hardware_field graphics.profile)"
    [[ "${STATE[gpu_profile]:-}" == "$GPU_PROFILE" ]] || state_set gpu_profile "$GPU_PROFILE"
    hardware_plan_valid || die "new hardware snapshot did not validate"
    if [[ -n "$DISPLAY_CONFIG" && "$DISPLAY_CONFIG" != "$root/display-input.json" ]]; then
        install -m 0600 -- "$DISPLAY_CONFIG" "$root/display-input.json"
    fi
    log "Hardware: $(hardware_field graphics.profile); build workers $(hardware_field resources.jobs), load $(hardware_field resources.load), emerge jobs $(hardware_field resources.emerge_jobs)"
}

copy_hardware_state() {
    local destination="$1" source
    source="$(hardware_root)"
    hardware_plan_valid || die "hardware snapshot is invalid before handoff"
    [[ "$source" != "$destination" ]] || return 0
    [[ ! -L "$destination" && "$(readlink -m "$destination")" == "$destination" ]] || die "symlinked hardware handoff path"
    if [[ -e "$destination" ]]; then
        cmp -s "$source/inventory.json" "$destination/inventory.json" || die "conflicting target hardware settings"
        [[ ! -f "$source/display-input.json" ]] || install -m 0600 "$source/display-input.json" "$destination/display-input.json"
    else
        install -d -m 0700 "$(dirname "$destination")"
        cp -a -- "$source" "$destination"
    fi
}

emerge_with_resources() {
    local jobs load
    jobs="$(hardware_field resources.emerge_jobs)" && load="$(hardware_field resources.load)" || die "missing resource budget"
    [[ "$jobs" =~ ^[1-9][0-9]*$ && "$load" =~ ^[1-9][0-9]*$ ]] || die "invalid resource budget"
    # Override a retained --keep-going default: the first failed build stops the pass.
    run emerge --jobs="$jobs" --load-average="$load" --keep-going=n "$@"
}

phase_hardware_policy() {
    ensure_hardware_plan
    deploy_policy_layer hardware/auto/resources
    deploy_policy_layer hardware/auto/minimal
    install_policy_sets hardware/auto/minimal
}

validate_hardware_policy() {
    hardware_plan_valid && validate_policy_layer hardware/auto/resources &&
        validate_policy_sets hardware/auto/minimal
}

phase_display_config() {
    local root temporary saved
    local -a args=()
    root="$(hardware_root)"
    if [[ "$DISTRIBUTION" == arch ]]; then arch_prepare_hardware; else ensure_hardware_plan; fi
    temporary="$(mktemp "$root/.inventory.XXXXXX")"
    hardware_tool refresh-displays --plan "$root/inventory.json" >"$temporary"
    mv -T "$temporary" "$root/inventory.json"
    ensure_public_dotfiles_source
    args+=(--presets "/home/$USERNAME/.local/share/chezmoi/.chezmoidata/machinePresets.json")
    saved="$root/chezmoi-saved.json"
    if command -v chezmoi >/dev/null && [[ -f "/home/$USERNAME/.config/chezmoi/chezmoi.toml" ]]; then
        run_as_user chezmoi dump-config --format json >"$saved"
        args+=(--saved "$saved")
    fi
    if [[ -n "$DISPLAY_CONFIG" ]]; then
        args+=(--input "$DISPLAY_CONFIG")
    elif [[ -f "$root/display-input.json" ]]; then
        args+=(--input "$root/display-input.json")
    elif ((NON_INTERACTIVE)); then
        request_wait "display preferences need interactive answers or --display-config FILE"
        return 0
    fi
    temporary="$(mktemp "$root/.displays.XXXXXX")"
    if ! python3 "$COMMON_DATA/displays.py" \
        --inventory "$root/inventory.json" "${args[@]}" >"$temporary"; then
        rm -f -- "$temporary"
        die "display configuration was not saved"
    fi
    mv -T -- "$temporary" "$root/displays.json"
    rm -f -- "$root/display-input.json" "$saved"
    DISPLAY_CONFIG=""
    state_set stage.public-dotfiles pending
}

validate_display_config() {
    local path input
    path="$(hardware_root)/displays.json"
    input="${DISPLAY_CONFIG:-$(hardware_root)/display-input.json}"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    [[ ! -f "$input" ]] || cmp -s "$path" <(python3 "$COMMON_DATA/displays.py" \
        --inventory "$(hardware_root)/inventory.json" --input "$input") || return 1
    python3 "$COMMON_DATA/displays.py" --inventory "$(hardware_root)/inventory.json" --input "$path" --check-hardware >/dev/null
}

portage_source_digest() (
    cd "$1" || return 1
    find . -type f ! -path './.install-system-revision' ! -path './.install-system-files.sha256' -print0 | \
        LC_ALL=C sort -z | xargs -0 -r sha256sum
)

select_portage_snapshot() {
    [[ "$1" =~ ^[0-9a-f]{40}$ ]] || die "invalid resolved neurogentoo revision"
    NEUROGENTOO_REF="$1"
    NEUROGENTOO_ROOT="/var/db/repos/.neurogentoo-snapshots/$NEUROGENTOO_REF"
    PORTAGE_POLICY="$NEUROGENTOO_ROOT/config/portage"
}

validate_portage_source() {
    local source="${1:-$NEUROGENTOO_ROOT}" digest
    [[ "$NEUROGENTOO_REF" =~ ^[0-9a-f]{40}$ ]] || return 1
    [[ -d "$source" && ! -L "$source" ]] && root_controls_directory "$source" || return 1
    [[ -z "$(find "$source" ! -type d ! -type f -print -quit)" ]] || return 1
    [[ -f "$source/.install-system-revision" && -s "$source/.install-system-files.sha256" ]] || return 1
    cmp -s "$source/.install-system-revision" <(printf '%s\n%s\n' "$NEUROGENTOO_URL" "$NEUROGENTOO_REF") || return 1
    [[ "$(cat "$source/profiles/repo_name" 2>/dev/null)" == neurogentoo &&
        "$(cat "$source/config/portage/schema" 2>/dev/null)" == 3 &&
        -s "$source/config/portage/build-state.py" && -d "$source/config/hardware/templates" ]] || return 1
    digest="$(portage_source_digest "$source")" || return 1
    [[ "$digest" == "$(cat "$source/.install-system-files.sha256")" ]]
}

ensure_portage_source() {
    local ref remote_ref
    if [[ -v STATE[policy_ref] ]]; then
        select_portage_snapshot "${STATE[policy_ref]}"
    else
        require_command git
        remote_ref="$(git ls-remote --exit-code "$NEUROGENTOO_URL" "refs/heads/$NEUROGENTOO_BRANCH")" || \
            die "could not resolve neurogentoo/$NEUROGENTOO_BRANCH"
        ref="${remote_ref%%[[:space:]]*}"
        select_portage_snapshot "$ref"
    fi
    if ! validate_portage_source; then
        [[ ! -e "$NEUROGENTOO_ROOT" && ! -L "$NEUROGENTOO_ROOT" ]] || \
            die "cached neurogentoo snapshot has changed; preserve/review it before continuing: $NEUROGENTOO_ROOT"
        require_command git
        local parent work
        parent="$(dirname "$NEUROGENTOO_ROOT")"
        [[ ! -L "$parent" ]] || die "snapshot parent must not be a symlink"
        install -d -m 0755 "$parent"
        root_controls_directory "$parent" || die "snapshot parent is not controlled by root"
        work="$(mktemp -d "$parent/.prepare.XXXXXX")"
        if ! (
            git clone --no-checkout --branch "$NEUROGENTOO_BRANCH" "$NEUROGENTOO_URL" "$work/git" || exit 1
            git -C "$work/git" cat-file -e "$NEUROGENTOO_REF^{commit}" 2>/dev/null || \
                git -C "$work/git" fetch origin "$NEUROGENTOO_REF" || exit 1
            mkdir "$work/tree" || exit 1
            git -C "$work/git" archive "$NEUROGENTOO_REF" | tar -xf - -C "$work/tree" || exit 1
            [[ -z "$(find "$work/tree" ! -type d ! -type f -print -quit)" ]] || exit 1
            [[ "$(cat "$work/tree/profiles/repo_name")" == neurogentoo &&
                "$(cat "$work/tree/config/portage/schema")" == 3 &&
                -s "$work/tree/config/portage/build-state.py" && -d "$work/tree/config/hardware/templates" ]] || exit 1
            printf '%s\n%s\n' "$NEUROGENTOO_URL" "$NEUROGENTOO_REF" >"$work/tree/.install-system-revision" || exit 1
            portage_source_digest "$work/tree" >"$work/tree/.install-system-files.sha256" || exit 1
            chmod -R u=rwX,go=rX "$work/tree" || exit 1
        ); then
            rm -rf -- "$work"
            die "neurogentoo/$NEUROGENTOO_BRANCH lacks policy schema 3 or could not be fetched; the prepared policy must be published first"
        fi
        mv -T -- "$work/tree" "$NEUROGENTOO_ROOT"
        rm -rf -- "$work"
        validate_portage_source || die "neurogentoo snapshot verification failed"
    fi
    if [[ ! -v STATE[policy_ref] ]]; then state_set policy_ref "$NEUROGENTOO_REF"; fi
}

copy_portage_source_to_target() (
    local destination="$TARGET_MOUNT$NEUROGENTOO_ROOT" parent temporary
    validate_portage_source || die "host neurogentoo snapshot is invalid"
    if [[ -e "$destination" || -L "$destination" ]]; then
        validate_portage_source "$destination" || die "target neurogentoo snapshot has changed"
        return 0
    fi
    parent="$(dirname "$destination")"
    [[ "$(readlink -m "$parent")" == "$parent" ]] || die "symlinked target snapshot parent"
    install -d -m 0755 "$parent"
    temporary="$(mktemp -d "$parent/.copy.XXXXXX")"
    trap 'rm -rf -- "$temporary"' EXIT
    cp -a -- "$NEUROGENTOO_ROOT/." "$temporary"
    validate_portage_source "$temporary" || die "copied neurogentoo snapshot failed verification"
    mv -T -- "$temporary" "$destination"
)

policy_layer_directory() {
    if [[ "$1" == hardware/auto/* ]]; then
        printf '%s/policy/%s' "$(hardware_root)" "${1#hardware/auto/}"
    else
        printf '%s/%s' "$PORTAGE_POLICY" "$1"
    fi
}

policy_layer_files() {
    local layer="$1" directory
    directory="$(policy_layer_directory "$layer")" || return 1
    [[ "$layer" =~ ^[a-z0-9-]+(/[a-z0-9-]+)*$ && -d "$directory" && ! -L "$directory" ]] || return 1
    [[ -z "$(find "$directory" ! -type f ! -type d -print -quit)" ]] || return 1
    find "$directory" -type f ! -path "$directory/required-files" -printf '%P\n' | LC_ALL=C sort
}

policy_file_contents() {
    local layer="$1" relative="$2" cpu_flags directory
    directory="$(policy_layer_directory "$layer")" || return 1
    if [[ "$relative" == make.conf ]]; then
        hardware_tool template --plan "$(hardware_root)/inventory.json" --template "$directory/$relative" || return 1
    else
        cat "$directory/$relative" || return 1
    fi
    if [[ "$relative" == make.conf ]] && command -v cpuid2cpuflags >/dev/null; then
        cpu_flags="$(cpuid2cpuflags)" || return 1
        [[ "$cpu_flags" == CPU_FLAGS_X86:\ * ]] || return 1
        cpu_flags="${cpu_flags#CPU_FLAGS_X86: }"
        [[ "$cpu_flags" =~ ^[a-z0-9_[:blank:]]+$ ]] || return 1
        printf '\nCPU_FLAGS_X86="%s"\n' "$cpu_flags"
    fi
}

deploy_policy_layer() {
    local layer="$1" files relative target content hash receipt previous
    local only="${2:-}"
    local receipts=/var/lib/install-system/portage-files
    local -A contents=() backups=() retained=()
    files="$(policy_layer_files "$layer")" || die "missing/invalid Portage policy layer: $layer"
    if [[ -n "$only" ]]; then files="$(printf '%s\n' "$files" | grep -xF "$only")"; fi
    [[ -n "$files" ]] || die "empty Portage policy layer: $layer"
    # Check the entire layer before replacing any files or converting file-form
    # configuration. A late conflict must not leave half of a compiler policy.
    while IFS= read -r relative; do
        [[ "$relative" =~ ^[a-zA-Z0-9_+./-]+$ && "$relative" != *..* ]] || die "invalid policy path: $relative"
        target="/etc/portage/$relative"
        [[ "$relative" != make.conf || "$MODE" == new ]] || die "existing mode cannot replace base compiler policy"
        [[ "$(readlink -m "$target")" == "$target" ]] || die "symlinked policy destination: $target"
        content="$(policy_file_contents "$layer" "$relative")" || die "cannot render $layer/$relative"
        contents["$relative"]="$content"
        receipt="$receipts/$relative.sha256"
        if [[ -e "$target" ]]; then
            [[ -f "$target" ]] || die "policy destination is not a file: $target"
            if ! cmp -s "$target" <(printf '%s\n' "$content"); then
                hash="$(sha256sum "$target")"
                previous="$(cat "$receipt" 2>/dev/null || true)"
                if [[ "$previous" != "${hash%% *}" ]]; then
                    if policy_repair_is_retained "$relative" "$content"; then
                        retained["$relative"]=1
                        continue
                    fi
                    if [[ "$MODE/$relative" == new/make.conf && ! -e "$receipt" &&
                        ! -e "$target.pre-install-system" && ! -L "$target.pre-install-system" ]]; then
                        backups["$relative"]=1
                    else
                        die "Portage policy conflicts with a local edit: $target (expected $layer/$relative)"
                    fi
                fi
            fi
        fi
    done <<<"$files"
    while IFS= read -r relative; do
        if [[ -v "retained[$relative]" ]]; then
            log "Retaining manual Portage repair: /etc/portage/$relative"
            continue
        fi
        target="/etc/portage/$relative"
        case "$relative" in
            package.*/*|repos.conf/*) portage_fragment_path "${relative%%/*}" >/dev/null ;;
            profile/use.*/*) portage_fragment_path "${relative%/*}" >/dev/null ;;
        esac
        [[ ! -v "backups[$relative]" ]] || cp -p -- "$target" "$target.pre-install-system"
        printf '%s\n' "${contents[$relative]}" | write_file "$target" 0644
        receipt="$receipts/$relative.sha256"
        hash="$(sha256sum "$target")"
        printf '%s\n' "${hash%% *}" | write_file "$receipt" 0600
    done <<<"$files"
}

policy_repair_is_retained() {
    local relative="$1" content="$2" expected previous
    case "$relative" in
        package.use/*|package.env/*|package.accept_keywords/*|package.mask/*|package.unmask/*|env/*|profile/use.*/*) ;;
        *) return 1 ;;
    esac
    # Only retain edits to a previously deployed version of this exact policy.
    # A different policy transition still requires resolving conflicts explicitly.
    expected="$(printf '%s\n' "$content" | sha256sum)" || return 1
    previous="$(cat "/var/lib/install-system/portage-files/$relative.sha256" 2>/dev/null)" || return 1
    [[ "$previous" == "${expected%% *}" ]]
}

validate_policy_layer() {
    local layer="$1" files relative content
    files="$(policy_layer_files "$layer")" && [[ -n "$files" ]] || return 1
    while IFS= read -r relative; do
        [[ "$(readlink -m "/etc/portage/$relative")" == "/etc/portage/$relative" ]] || return 1
        [[ -f "/etc/portage/$relative" && ! -L "/etc/portage/$relative" ]] || return 1
        content="$(policy_file_contents "$layer" "$relative")" || return 1
        cmp -s "/etc/portage/$relative" <(printf '%s\n' "$content") || \
            policy_repair_is_retained "$relative" "$content" || return 1
    done <<<"$files"
}

selected_policy_layers() {
    POLICY_LAYERS=("$1")
    case "$1" in
        dwl)
            POLICY_LAYERS+=("hardware/auto/dwl")
            ;;
        full)
            POLICY_LAYERS+=("hardware/auto/full" features/mail features/keepass features/wireguard)
            [[ "$TORRENT" != yes ]] || POLICY_LAYERS+=(features/torrent)
            ;;
    esac
}

install_policy_sets() {
    local layer file directory
    local -a sets=() options=(--update --newuse --select)
    if [[ -n "${CURRENT_STAGE:-}" && "${FORCE_STAGE:-none}" == "$CURRENT_STAGE" ]]; then
        options=(--newuse --select)
    fi
    for layer in "$@"; do
        directory="$(policy_layer_directory "$layer")" || die "cannot locate $layer"
        for file in "$directory/sets/"*; do
            [[ -f "$file" ]] || continue
            validate_policy_layer "$layer" || die "Portage policy must be deployed before selecting $layer"
            sets+=("@${file##*/}")
        done
    done
    ((${#sets[@]})) || die "no package sets selected"
    emerge_with_resources "${options[@]}" "${sets[@]}"
}

validate_policy_sets() {
    local layer file atom directory found=0 check_selection=1
    if [[ "${1:-}" == --installed-only ]]; then check_selection=0; shift; fi
    for layer in "$@"; do
        validate_policy_layer "$layer" || return 1
        directory="$(policy_layer_directory "$layer")" || return 1
        for file in "$directory/sets/"*; do
            [[ -f "$file" ]] || continue
            ((check_selection == 0)) || grep -qxF "@${file##*/}" /var/lib/portage/world_sets || return 1
            while IFS= read -r atom || [[ -n "$atom" ]]; do
                [[ -n "$atom" && "$atom" != \#* ]] || continue
                [[ "$atom" != @* ]] || return 1
                portageq has_version / "$atom" || return 1
                found=1
            done <"$file"
        done
    done
    ((found))
}

portage_fragment_path() {
    local name="$1" directory="/etc/portage/$1" preserved
    [[ ! -L "$directory" ]] || die "symlinked Portage configuration is unsupported: $directory"
    if [[ -f "$directory" ]]; then
        preserved="${directory}.pre-install-system"
        [[ ! -e "$preserved" && ! -L "$preserved" ]] || die "cannot preserve $directory: $preserved already exists"
        mv "$directory" "$preserved"
        install -d -m 0755 "$directory"
        mv "$preserved" "$directory/00-pre-install-system"
    elif [[ -e "$directory" && ! -d "$directory" ]]; then
        die "unsupported Portage configuration object: $directory"
    else
        install -d -m 0755 "$directory"
    fi
    printf '%s/install-system' "$directory"
}

phase_target_preflight() {
    require_root
    [[ "$(uname -m)" == "x86_64" ]] || die "only x86_64 is supported"
    [[ -s /etc/gentoo-release ]] || die "target is not a Gentoo system"
    [[ -x /sbin/openrc-init || -x /sbin/init ]] || die "OpenRC init is unavailable"
    local command
    for command in emerge env-update eselect getent install runuser setsid sha256sum; do
        require_command "$command"
    done
    if [[ "$MODE" == "new" ]]; then
        validate_persisted_devices
        current_root_matches_state || die "chroot root does not match persisted root identity"
        state_write
    fi
}

validate_target_preflight() {
    [[ -s /etc/gentoo-release && -x /sbin/openrc-init ]] || return 1
    command -v runuser >/dev/null && command -v setsid >/dev/null || return 1
    [[ "$MODE" != "new" ]] || current_root_matches_state
}

phase_profile() {
    local line index=""
    if [[ ! -d /var/db/repos/gentoo/profiles ]]; then
        run emerge-webrsync
    else
        run emerge --sync
    fi
    while IFS= read -r line; do
        if [[ "$line" == *"$PROFILE_PATH"* && "$line" != *systemd* && "$line" =~ \[([0-9]+)\] ]]; then
            index="${BASH_REMATCH[1]}"
            break
        fi
    done < <(eselect profile list 2>&1)
    [[ -n "$index" ]] || die "required profile was not found: $PROFILE_PATH"
    run eselect profile set "$index"
    run env-update
}

validate_profile() {
    local profile
    profile="$(readlink -f /etc/portage/make.profile 2>/dev/null || true)"
    [[ "$profile" == *"/$PROFILE_PATH" && "$profile" != *systemd* ]]
}

write_portage_fragments() {
    deploy_policy_layer base
}

phase_portage() {
    deploy_policy_layer bootstrap
    deploy_policy_layer polly-off
    deploy_policy_layer hardware/auto/resources
    deploy_policy_layer hardware/auto/minimal
    deploy_policy_layer minimal
    deploy_policy_layer toolchain
    state_set compiler_policy bootstrap
    mark_pass_prepared
}

validate_portage() {
    # Compiler/USE edits are legitimate manual recovery inputs. Never roll them
    # back by replaying bootstrap when a later compilation fails.
    [[ -s /var/lib/install-system/build-passes/portage.prepared && -s /etc/portage/make.conf &&
       -s /etc/portage/sets/install-minimal && -s /etc/portage/sets/install-toolchain ]] &&
        hardware_plan_valid
}

phase_base_packages() {
    if ! pass_prepared; then
        deploy_policy_layer bootstrap
        deploy_policy_layer polly-off
        state_set compiler_policy bootstrap
        mark_pass_prepared
    fi
    emerge_with_resources --oneshot sys-apps/portage app-portage/cpuid2cpuflags
    if ! grep -q '^CPU_FLAGS_X86=' /etc/portage/make.conf; then deploy_policy_layer bootstrap make.conf; fi
    emerge_with_resources --select dev-vcs/git
    emerge_with_resources --update @world
    run env-update
    record_build_pass 'sys-apps/portage|sys-libs/glibc|sys-devel/gcc|dev-vcs/git'
}

build_state() {
    python3 "$PORTAGE_POLICY/build-state.py" "$@"
}

mark_pass_prepared() {
    printf '%s\n' "$CURRENT_STAGE" | write_file "/var/lib/install-system/build-passes/$CURRENT_STAGE.prepared" 0600
}

pass_prepared() {
    [[ -s "/var/lib/install-system/build-passes/$CURRENT_STAGE.prepared" ]]
}

record_build_pass() {
    build_state record --stage "$CURRENT_STAGE" --receipt "/var/lib/install-system/build-passes/$CURRENT_STAGE.json" \
        --pattern "${1:-llvm|rust}"
}

validate_build_pass() {
    build_state check --stage "$1" --receipt "/var/lib/install-system/build-passes/$1.json" >/dev/null 2>&1
}

phase_bootstrap_world() {
    if ! pass_prepared; then
        deploy_policy_layer bootstrap
        deploy_policy_layer polly-off
        state_set compiler_policy bootstrap
        mark_pass_prepared
    fi
    emerge_with_resources -e --newuse --update @world
    emerge_with_resources --depclean
    record_build_pass 'sys-apps/portage|sys-libs/glibc|sys-devel/gcc'
}

phase_toolchain_bootstrap() {
    if ! pass_prepared; then
        write_portage_fragments
        deploy_policy_layer prepolly
        deploy_policy_layer polly-off
        state_set compiler_policy prepolly
        mark_pass_prepared
    fi
    install_policy_sets minimal hardware/auto/minimal toolchain
    run env-update
    record_build_pass
}

phase_prepolly_world() {
    if ! pass_prepared; then
        deploy_policy_layer prepolly make.conf
        deploy_policy_layer polly-off
        deploy_policy_layer clang package.env/install-system-compiler
        state_set compiler_policy prepolly
        mark_pass_prepared
    fi
    emerge_with_resources --update --newuse -e @world
    emerge_with_resources --depclean
    record_build_pass
}

toggle_no_polly() {
    # Comment only active entries and remember exactly which lines we changed.
    # Existing manual comments and all other package exceptions survive the pass.
    python3 - "$1" /etc/portage/package.env/install-system-compiler /var/lib/install-system/portage-files/package.env/install-system-compiler.sha256 <<'PY'
from pathlib import Path
import hashlib
import re
import sys
path = Path(sys.argv[2])
receipt = Path(sys.argv[3])
managed = receipt.is_file() and receipt.read_text().strip() == hashlib.sha256(path.read_bytes()).hexdigest()
prefix = '# install-system-gcc: '
lines = path.read_text().splitlines(keepends=True)
if sys.argv[1] == 'off':
    lines = [prefix + line if not line.lstrip().startswith('#') and
             re.search(r'\sno_polly(?:\s|$)', line) else line for line in lines]
else:
    lines = [line[len(prefix):] if line.startswith(prefix) else line for line in lines]
temporary = path.with_suffix('.tmp')
temporary.write_text(''.join(lines))
temporary.chmod(0o644)
temporary.replace(path)
if managed:
    receipt.write_text(hashlib.sha256(path.read_bytes()).hexdigest() + '\n')
PY
}

phase_gcc_runtime() {
    if ! pass_prepared; then
        deploy_policy_layer prepolly make.conf
        toggle_no_polly off
        deploy_policy_layer polly-off
        state_set compiler_policy gcc
        mark_pass_prepared
    fi
    emerge_with_resources --oneshot llvm-runtimes/clang-runtime
    record_build_pass '^llvm-runtimes/clang-runtime$'
}

remove_toolchain_bootstrap_dependencies() {
    local atom
    local -a installed=()
    for atom in dev-libs/jsoncpp dev-build/cmake; do
        if portageq has_version / "$atom"; then installed+=("$atom"); fi
    done
    ((${#installed[@]} == 0)) || emerge_with_resources --unmerge "${installed[@]}"
}

rebuild_installed_toolchain() {
    local atoms
    local -a selected=()
    atoms="$(build_state list --pattern 'llvm|rust')"
    mapfile -t selected <<<"$atoms"
    emerge_with_resources --oneshot "${selected[@]}"
    run env-update
    record_build_pass
}

phase_gcc_toolchain() {
    if ! pass_prepared; then
        deploy_policy_layer prepolly make.conf
        deploy_policy_layer polly-off
        toggle_no_polly off
        state_set compiler_policy gcc
        remove_toolchain_bootstrap_dependencies
        mark_pass_prepared
    fi
    rebuild_installed_toolchain
}

phase_clang_toolchain() {
    if ! pass_prepared; then
        deploy_policy_layer prepolly make.conf
        deploy_policy_layer polly-off
        remove_toolchain_bootstrap_dependencies
        toggle_no_polly on
        state_set compiler_policy clang
        mark_pass_prepared
    fi
    rebuild_installed_toolchain
}

phase_polly_runtime() {
    if ! pass_prepared; then
        deploy_policy_layer prepolly make.conf
        toggle_no_polly on
        deploy_policy_layer polly-on
        state_set compiler_policy polly
        mark_pass_prepared
    fi
    emerge_with_resources --oneshot llvm-runtimes/clang-runtime
    record_build_pass '^llvm-runtimes/clang-runtime$'
}

phase_clang_policy() {
    deploy_policy_layer clang make.conf
    state_set compiler_policy final
    run env-update
    mark_pass_prepared
}

validate_compiler_policy_stage() {
    [[ -s /var/lib/install-system/build-passes/clang-policy.prepared && -s /etc/portage/make.conf ]] &&
        command -v clang >/dev/null && command -v ld.lld >/dev/null
}

phase_world_rebuild() {
    local excluded
    excluded="$(build_state list --pattern 'llvm|rust|glibc|gcc|binutils')"
    excluded="${excluded//$'\n'/ }"
    emerge_with_resources --update --newuse -e @world --exclude "$excluded"
    record_build_pass 'sys-apps/portage|sys-libs/glibc|sys-devel/gcc|llvm|rust'
}

phase_base_cleanup() {
    emerge_with_resources @preserved-rebuild
    emerge_with_resources --depclean
    record_build_pass
}

validate_base_packages() {
    validate_build_pass base-cleanup && validate_policy_sets minimal toolchain hardware/auto/minimal &&
        command -v clang >/dev/null && command -v ld.lld >/dev/null &&
        command -v rustc >/dev/null && command -v cargo >/dev/null &&
        command -v git >/dev/null &&
        command -v busybox >/dev/null && command -v nvim >/dev/null &&
        command -v ninja >/dev/null && command -v pipewire >/dev/null &&
        command -v seatd >/dev/null && command -v wireplumber >/dev/null &&
        busybox --list | grep -x udhcpc >/dev/null
}

system_policy() {
    local action="$1" layer="$2"
    shift 2
    python3 "$NEUROGENTOO_ROOT/config/system/deploy.py" "$action" "$layer" \
        --root / --value "HOSTNAME=${HOSTNAME_VALUE:-}" --value "USERNAME=${USERNAME:-}" \
        --value "TIMEZONE=${TIMEZONE:-}" \
        --value "BOOT_UUID=${STATE[boot_uuid]:-}" --value "ROOT_UUID=${STATE[root_uuid]:-}" "$@"
}

system_policy_services() {
    local action="$1" layer="$2" service runlevel extra
    local file="$NEUROGENTOO_ROOT/config/system/$layer/services"
    [[ -s "$file" ]] || return 1
    while read -r service runlevel extra; do
        [[ -n "$service" && "$service" != \#* ]] || continue
        [[ "$service" =~ ^[a-zA-Z0-9_.-]+$ && "$runlevel" =~ ^[a-zA-Z0-9_-]+$ && -z "$extra" ]] || return 1
        if [[ "$action" == apply ]]; then
            if [[ "$service" == agetty.tty* && ! -e "/etc/init.d/$service" && ! -L "/etc/init.d/$service" ]]; then
                ln -s agetty "/etc/init.d/$service"
            fi
            run rc-update add "$service" "$runlevel"
        else
            rc-update show "$runlevel" | awk '{print $1}' | grep -qxF "$service" || return 1
        fi
    done <"$file"
}

system_policy_groups() {
    local layer="$1" group
    local file="$NEUROGENTOO_ROOT/config/system/$layer/account-groups"
    [[ -s "$file" ]] || return 1
    while IFS= read -r group; do
        [[ -n "$group" && "$group" != \#* ]] || continue
        [[ "$group" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
        printf '%s\n' "$group"
    done <"$file"
}

system_shell_policy_entries() {
    local relative="$1" line key value
    [[ "$relative" =~ ^[a-zA-Z0-9_./-]+$ && "$relative" != *..* ]] || return 1
    local source="$NEUROGENTOO_ROOT/config/system/minimal/etc/$relative"
    [[ -s "$source" && ! -L "$source" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" && "$line" != \#* ]] || continue
        [[ "$line" == *=* ]] || return 1
        key="${line%%=*}" value="${line#*=}"
        [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ && "$value" == \"*\" ]] || return 1
        printf '%s\n' "$line"
    done <"$source"
}

phase_system_config() {
    local localtime_receipt=/var/lib/install-system/localtime.target localtime_target
    localtime_target="/usr/share/zoneinfo/$TIMEZONE"
    [[ -e "$localtime_target" ]] || die "timezone is unavailable: $TIMEZONE"
    if [[ -f "$localtime_receipt" && "$(readlink /etc/localtime || true)" != "$(cat "$localtime_receipt")" ]]; then
        die "local timezone link changed; preserve/review /etc/localtime before continuing"
    fi
    system_policy apply minimal etc/locale.gen etc/env.d/02locale etc/conf.d/hostname \
        etc/hosts etc/conf.d/hwclock etc/rc.conf etc/timezone
    ln -sfn "$localtime_target" /etc/localtime
    printf '%s\n' "$localtime_target" | write_file "$localtime_receipt" 0600

    run locale-gen
    run env-update
    system_policy_services apply minimal
}

validate_system_config() {
    local locale_entry
    [[ "$(< /etc/timezone)" == "$TIMEZONE" ]] &&
        [[ "$(readlink -f /etc/localtime)" == "/usr/share/zoneinfo/$TIMEZONE" ]] &&
        system_policy check minimal etc/locale.gen etc/env.d/02locale etc/conf.d/hostname \
            etc/hosts etc/conf.d/hwclock etc/rc.conf etc/timezone || return 1
    locale_entry="$(system_shell_policy_entries env.d/02locale | sed -n 's/^LANG="\(.*\)"$/\1/p')" || return 1
    [[ -n "$locale_entry" ]] && locale -a | grep -qxF "$locale_entry" || return 1
    system_policy_services check minimal
}

account_password_is_set() {
    local account="$1" name password _
    IFS=: read -r name password _ < <(getent shadow "$account") || return 1
    [[ "$name" == "$account" ]] && password_hash_is_set "$password"
}

gentoo_account_shell() {
    # An approved shell transition must not replace an older compiler-policy snapshot.
    local current
    if [[ -n "${STATE[user_shell]:-}" ]]; then
        printf '%s' "${STATE[user_shell]}"
        return 0
    fi
    if [[ "${STATE[approval.user-shell]:-}" == yes ]]; then
        current="$(getent passwd "$USERNAME" | cut -d: -f7)" || return 1
        # Account changes can succeed just before the result is persisted.
        if [[ "$(readlink -f "$current")" == "$(readlink -f /bin/zsh)" ]]; then
            printf '%s' /bin/zsh
            return 0
        fi
    fi
    cat "$NEUROGENTOO_ROOT/config/system/minimal/account-shell"
}

phase_accounts() {
    local group groups="" separator="" account_shell
    local -a requested_groups=()
    account_shell="$(gentoo_account_shell)"
    [[ "$account_shell" == /* && -x "$account_shell" ]] || die "invalid account shell policy"
    mapfile -t requested_groups < <(system_policy_groups minimal)
    ((${#requested_groups[@]})) || die "missing minimal account groups"
    for group in "${requested_groups[@]}"; do
        getent group "$group" >/dev/null || die "required account group is missing: $group"
        groups+="$separator$group"
        separator=,
    done

    if ! getent passwd "$USERNAME" >/dev/null; then
        if [[ -n "$groups" ]]; then
            run useradd --create-home --user-group --shell "$account_shell" --groups "$groups" -- "$USERNAME"
        else
            run useradd --create-home --user-group --shell "$account_shell" -- "$USERNAME"
        fi
    else
        user_home_is_safe || die "refusing to modify an unsafe existing account: $USERNAME"
        [[ "$(readlink -f "$(getent passwd "$USERNAME" | cut -d: -f7)")" == "$(readlink -f "$account_shell")" ]] || \
            die "existing account shell differs from policy; preserve/review it before continuing"
        if [[ -n "$groups" ]]; then
            run usermod --append --groups "$groups" -- "$USERNAME"
        fi
    fi
    user_home_is_safe || die "new account has an unsafe or unexpected home directory: $USERNAME"
    run_as_user install -d -m 0755 "/home/$USERNAME/.local/bin"
    system_policy apply minimal etc/doas.conf
    run doas -C /etc/doas.conf

    apply_collected_password
}

validate_accounts() {
    local _ shell group groups
    IFS=: read -r _ _ _ _ _ _ shell < <(getent passwd "$USERNAME") || return 1
    [[ "$(readlink -f "$shell")" == "$(readlink -f "$(gentoo_account_shell)")" ]] || return 1
    groups=" $(id -nG "$USERNAME") " || return 1
    [[ "$groups" == *" $USERNAME "* ]] || return 1
    local policy_groups
    policy_groups="$(system_policy_groups minimal)" && [[ -n "$policy_groups" ]] || return 1
    for group in $policy_groups; do
        [[ "$groups" == *" $group "* ]] || return 1
    done
    user_home_is_safe &&
        system_policy check minimal etc/doas.conf &&
        doas -C /etc/doas.conf >/dev/null &&
        account_password_is_set root && account_password_is_set "$USERNAME"
}

phase_network() {
    system_policy apply minimal etc/resolv.conf
    system_policy apply network usr/local/sbin/udhcpc-all etc/udhcpc/default.script etc/init.d/udhcpc
    system_policy_services apply network
}

validate_network() {
    system_policy check minimal etc/resolv.conf &&
        system_policy check network usr/local/sbin/udhcpc-all etc/udhcpc/default.script etc/init.d/udhcpc &&
        sh -n /usr/local/sbin/udhcpc-all && sh -n /etc/udhcpc/default.script &&
        busybox --list | grep -x udhcpc >/dev/null &&
        system_policy_services check network
}

phase_fstab() {
    system_policy apply minimal etc/fstab
}

validate_fstab() {
    system_policy check minimal etc/fstab &&
        [[ "$(blkid -U "${STATE[root_uuid]}")" == "$ROOT_PARTITION" ]] &&
        [[ "$(blkid -U "${STATE[boot_uuid]}")" == "$BOOT_PARTITION" ]] &&
        findmnt --verify --verbose --tab-file /etc/fstab >/dev/null
}

selected_kernel_directory() {
    local directory
    directory="$(readlink -f /usr/src/linux)" || return 1
    [[ -d "$directory" && -f "$directory/Makefile" ]] || return 1
    printf '%s' "$directory"
}

efi_pe_image_is_valid() {
    local image="$1" magic offset signature
    [[ -s "$image" && ! -L "$image" ]] || return 1
    magic="$(od -An -tx1 -N2 -- "$image" 2>/dev/null | tr -d '[:space:]')"
    [[ "$magic" == "4d5a" ]] || return 1
    offset="$(od -An -tu4 -j60 -N4 -- "$image" 2>/dev/null | tr -d '[:space:]')"
    [[ "$offset" =~ ^[0-9]+$ ]] || return 1
    signature="$(od -An -tx1 -j "$offset" -N6 -- "$image" 2>/dev/null | tr -d '[:space:]')"
    [[ "$signature" == "504500006486" ]]
}

kernel_config_identity() {
    local kernel_dir="$1" config_sha makefile_sha
    [[ -s "$kernel_dir/.config" ]] || return 1
    config_sha="$(sha256sum "$kernel_dir/.config")" || return 1
    makefile_sha="$(sha256sum "$kernel_dir/Makefile")" || return 1
    printf 'source=%s\nconfig_sha256=%s\nmakefile_sha256=%s\n' \
        "$kernel_dir" "${config_sha%% *}" "${makefile_sha%% *}"
}

phase_kernel_config() {
    local kernel_dir identity waiting=/var/lib/install-system/kernel-config.waiting
    if ((KERNEL_CONFIG_READY == 0)) && [[ -s "$waiting" ]] && ((NON_INTERACTIVE == 0)); then
        local answer
        read -r -p 'Have you prepared /usr/src/linux/.config manually and is it ready to compile? [y/N] ' answer </dev/tty
        [[ ! "$answer" =~ ^[yY]([eE][sS])?$ ]] || KERNEL_CONFIG_READY=1
    fi
    if ((KERNEL_CONFIG_READY == 0)) || [[ ! -s "$waiting" ]]; then
        printf 'Manual kernel configuration requested.\n' | write_file "$waiting" 0600
        log "Select your kernel sources at /usr/src/linux and prepare their .config manually."
        log "You may obtain your config from GitHub or configure it yourself."
        log "The boot stage installs an x86-64 EFI kernel image to the ESP; root PARTUUID is ${STATE[root_partuuid]}."
        request_wait "prepare the kernel manually, then use Continue and confirm readiness (or continue --kernel-config-ready)"
        return 0
    fi
    kernel_dir="$(selected_kernel_directory)" || {
        request_wait "select the intended kernel source tree at /usr/src/linux before confirming"
        return 0
    }
    identity="$(kernel_config_identity "$kernel_dir")" || {
        request_wait "prepare a nonempty $kernel_dir/.config before confirming"
        return 0
    }
    printf '%s\n' "$identity" | write_file /var/lib/install-system/kernel-config.approved 0600
    rm -f -- "$waiting"
}

validate_kernel_config_stage() {
    local kernel_dir identity
    [[ ! -e /var/lib/install-system/kernel-config.waiting ]] || return 1
    kernel_dir="$(selected_kernel_directory)" || return 1
    identity="$(kernel_config_identity "$kernel_dir")" || return 1
    cmp -s /var/lib/install-system/kernel-config.approved <(printf '%s\n' "$identity")
}

phase_kernel() {
    local kernel_dir before after makeopts
    local -a make_options=()
    validate_kernel_config_stage || die "kernel config changed; resume at the manual kernel-config stage"
    kernel_dir="$(selected_kernel_directory)" || die "no selected kernel source tree"
    before="$(kernel_config_identity "$kernel_dir")"
    makeopts="$(portageq envvar MAKEOPTS)"
    read -r -a make_options <<<"$makeopts"
    # Refuse implicit Kconfig updates during compilation. The user prepares the
    # config, including adapting downloaded settings to the selected sources.
    run make -C "$kernel_dir" LLVM=1 LLVM_IAS=1 KCONFIG_NOSILENTUPDATE=1 "${make_options[@]}"
    # Install exactly the modules selected by the user's configuration.
    if grep -qx 'CONFIG_MODULES=y' "$kernel_dir/.config"; then
        require_command depmod
        run make -C "$kernel_dir" LLVM=1 LLVM_IAS=1 KCONFIG_NOSILENTUPDATE=1 "${make_options[@]}" modules_install
    fi
    after="$(kernel_config_identity "$kernel_dir")"
    [[ "$after" == "$before" ]] || die "kernel build changed the config; review it at the manual kernel-config stage"
    [[ -s "$kernel_dir/arch/x86/boot/bzImage" ]] || die "kernel build did not produce bzImage"
    efi_pe_image_is_valid "$kernel_dir/arch/x86/boot/bzImage" || die "kernel image is not an x86-64 EFI PE executable"
    kernel_modules_installed "$kernel_dir" || die "kernel module installation is incomplete"
    install -m 0600 "$kernel_dir/arch/x86/boot/bzImage" /var/lib/install-system/bzImage
    sha256sum /var/lib/install-system/bzImage > /var/lib/install-system/bzImage.sha256
    printf '%s\n' "$before" | write_file /var/lib/install-system/kernel-build.inputs 0600
}

kernel_modules_installed() {
    local kernel_dir="$1" release
    if grep -qx 'CONFIG_MODULES=y' "$kernel_dir/.config"; then
        release="$(cat "$kernel_dir/include/config/kernel.release")" || return 1
        [[ "$release" =~ ^[a-zA-Z0-9._+-]+$ && -f "/lib/modules/$release/modules.dep" ]] || return 1
    fi
}

validate_kernel() {
    validate_kernel_config_stage &&
        cmp -s /var/lib/install-system/kernel-config.approved /var/lib/install-system/kernel-build.inputs &&
        [[ -s /var/lib/install-system/bzImage && -s /var/lib/install-system/bzImage.sha256 ]] &&
        sha256sum -c /var/lib/install-system/bzImage.sha256 >/dev/null &&
        efi_pe_image_is_valid /var/lib/install-system/bzImage &&
        kernel_modules_installed "$(selected_kernel_directory)"
}

efi_entry_exists() {
    local line line_lower expected_uuid="${STATE[boot_partuuid],,}"
    local expected_path='\efi\boot\bootx64.efi'
    while IFS= read -r line; do
        line_lower="${line,,}"
        if [[ "$line_lower" == *gentoo* && "$line_lower" == *"$expected_uuid"* && "$line_lower" == *"$expected_path"* ]]; then
            return 0
        fi
    done < <(efibootmgr -v 2>/dev/null)
    return 1
}

phase_boot() {
    local destination directory temporary disk_name parent_disk partition_number
    findmnt -rn -S "$BOOT_PARTITION" -T /boot >/dev/null || die "/boot is not the persisted ESP"
    directory=/boot/EFI/BOOT
    destination="$directory/BOOTX64.EFI"
    install -d -m 0755 "$directory"
    temporary="$(mktemp "$directory/.BOOTX64.EFI.XXXXXX")"
    install -m 0644 /var/lib/install-system/bzImage "$temporary"
    if [[ -s "$destination" ]]; then
        cp -f "$destination" "$directory/BOOTX64.EFI.previous"
    fi
    sync "$temporary"
    mv -fT -- "$temporary" "$destination"
    sync "$directory"

    if [[ "$CREATE_EFI_ENTRY" == "yes" ]]; then
        disk_name="$(lsblk -nro PKNAME "$BOOT_PARTITION")"
        partition_number="$(lsblk -nro PARTN "$BOOT_PARTITION")"
        [[ -n "$disk_name" && "$partition_number" =~ ^[0-9]+$ ]] || die "could not derive EFI disk metadata"
        parent_disk="/dev/$disk_name"
        if ! efi_entry_exists; then
            run efibootmgr -c -d "$parent_disk" -p "$partition_number" -L Gentoo -l '\EFI\BOOT\BOOTX64.EFI'
        fi
    fi
}

validate_boot() {
    [[ -s /boot/EFI/BOOT/BOOTX64.EFI ]] &&
        cmp -s /var/lib/install-system/bzImage /boot/EFI/BOOT/BOOTX64.EFI &&
        efi_pe_image_is_valid /boot/EFI/BOOT/BOOTX64.EFI || return 1
    [[ "$CREATE_EFI_ENTRY" != "yes" ]] || efi_entry_exists
}

phase_marker() {
    local marker="/var/lib/install-system/$CURRENT_STAGE"
    printf '%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$marker"
}

stage_group_complete_before() {
    local stop="$1" stage status
    shift
    for stage in "$@"; do
        [[ "$stage" == "$stop" ]] && return 0
        status="$(state_stage_status "$stage")"
        [[ "$status" == "done" ]] || return 1
    done
    return 1
}

validate_minimal_complete() {
    [[ -s /var/lib/install-system/minimal-complete ]] &&
        stage_group_complete_before minimal-complete "${MINIMAL_STAGES[@]}"
}

phase_existing_preflight() {
    require_root
    [[ -s /etc/gentoo-release ]] || die "existing mode requires Gentoo"
    [[ -x /sbin/openrc-init ]] || die "existing mode requires OpenRC"
    local profile
    profile="$(readlink -f /etc/portage/make.profile 2>/dev/null || true)"
    [[ "$profile" == *"/$PROFILE_PATH" && "$profile" != *systemd* ]] || \
        die "existing mode requires the $PROFILE_PATH OpenRC profile"
    [[ -s /etc/machine-id && "$(tr -d '\r\n' </etc/machine-id)" == "${STATE[system_id]}" ]] || die "existing state belongs to a different machine"
    user_home_is_safe || die "existing user has an unsafe or unexpected home directory: $USERNAME"
    require_command runuser
    require_command setsid
    ensure_hardware_plan
}

validate_existing_preflight() {
    local profile
    profile="$(readlink -f /etc/portage/make.profile 2>/dev/null || true)"
    [[ -s /etc/gentoo-release && -x /sbin/openrc-init ]] &&
        [[ "$profile" == *"/$PROFILE_PATH" && "$profile" != *systemd* ]] &&
        [[ -s /etc/machine-id && "$(tr -d '\r\n' </etc/machine-id)" == "${STATE[system_id]}" ]] &&
        user_home_is_safe && command -v runuser >/dev/null && command -v setsid >/dev/null && hardware_plan_valid
}

repository_enabled() {
    local repository="$1" line index name rest
    while IFS= read -r line; do
        read -r index name rest <<<"$line"
        [[ "$index" =~ ^\[[0-9]+\]$ && "$name" == "$repository" ]] && return 0
    done < <(eselect repository list -i 2>/dev/null)
    return 1
}

write_desktop_portage_fragments() {
    local layer
    local -a POLICY_LAYERS=()
    selected_policy_layers dwl
    for layer in "${POLICY_LAYERS[@]}"; do deploy_policy_layer "$layer"; done
}

phase_desktop_repositories() {
    deploy_policy_layer repository-tools
    install_policy_sets repository-tools
    ensure_neurogentoo_repository
    deploy_policy_layer overlay
    validate_neurogentoo_sync_policy || die "conflicting Portage neurogentoo sync settings; preserve/reconcile them before syncing"
    run emaint sync -r neurogentoo
    validate_overlay_registration || die "synchronized neurogentoo lacks the required live DWL recipe or repository identity"
    if ! repository_enabled guru; then
        run eselect repository enable guru
    fi
    if ! repository_enabled librewolf; then
        run eselect repository add librewolf git "$LIBREWOLF_REPOSITORY_URL"
    fi
    run emaint sync -r guru
    run emaint sync -r librewolf
    [[ "$(git -C /var/db/repos/librewolf remote get-url origin)" == "$LIBREWOLF_REPOSITORY_URL" ]] || \
        die "unexpected LibreWolf repository origin"
    write_desktop_portage_fragments
}

neurogentoo_checkout_is_safe() {
    local overlay="${1:-/var/db/repos/neurogentoo}" origin status
    root_controls_directory "$overlay" && [[ -d "$overlay/.git" && ! -L "$overlay/.git" ]] || return 1
    origin="$(git -C "$overlay" remote get-url origin)" || return 1
    case "$origin" in
        "$NEUROGENTOO_URL"|git@github.com:Neur0leptic/neurogentoo.git) ;;
        *) return 1 ;;
    esac
    [[ "$(git -C "$overlay" symbolic-ref --quiet --short HEAD)" == "$NEUROGENTOO_BRANCH" &&
       "$(git -C "$overlay" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')" == "origin/$NEUROGENTOO_BRANCH" ]] || return 1
    status="$(git -C "$overlay" status --porcelain --untracked-files=all)" || return 1
    [[ -z "$status" ]] && git -C "$overlay" merge-base --is-ancestor HEAD "origin/$NEUROGENTOO_BRANCH"
}

validate_neurogentoo_repository() {
    local overlay="${1:-/var/db/repos/neurogentoo}"
    neurogentoo_checkout_is_safe "$overlay" &&
        [[ "$(cat "$overlay/profiles/repo_name")" == neurogentoo &&
           -s "$overlay/gui-wm/dwl/dwl-9999.ebuild" ]]
}

ensure_neurogentoo_repository() {
    local overlay=/var/db/repos/neurogentoo temporary backup="/var/db/repos/neurogentoo.pre-install-system"
    if [[ -d "$overlay" && ! -L "$overlay" ]]; then
        neurogentoo_checkout_is_safe || die "neurogentoo has local changes or unexpected origin/branch; preserve/reconcile them before continuing"
    else
        if [[ -e "$overlay" || -L "$overlay" ]]; then
            [[ -L "$overlay" && "$(readlink -f "$overlay")" == "$NEUROGENTOO_ROOT" ]] && validate_portage_source || \
                die "unexpected neurogentoo path; no existing repository was replaced"
            [[ ! -e "$backup" && ! -L "$backup" ]] || die "previous neurogentoo link backup already exists: $backup"
        fi
        install -d -m 0755 /var/db/repos
        temporary="$(mktemp -d /var/db/repos/.neurogentoo.XXXXXX)"
        if ! run git clone --branch "$NEUROGENTOO_BRANCH" --single-branch "$NEUROGENTOO_URL" "$temporary"; then
            rm -rf -- "$temporary"
            die "could not clone neurogentoo/$NEUROGENTOO_BRANCH"
        fi
        if ! validate_neurogentoo_repository "$temporary"; then
            rm -rf -- "$temporary"
            die "published neurogentoo/$NEUROGENTOO_BRANCH lacks the live DWL recipe or repository identity"
        fi
        chmod -R u=rwX,go=rX "$temporary"
        [[ ! -L "$overlay" ]] || mv -T -- "$overlay" "$backup"
        mv -T -- "$temporary" "$overlay"
        validate_neurogentoo_repository || die "published neurogentoo/$NEUROGENTOO_BRANCH lacks the live DWL recipe or repository identity"
    fi
    # Native Portage sync follows main without resetting user changes.
    run git -C "$overlay" config merge.ff only
}

validate_overlay_registration() {
    local registered
    registered="$(portageq get_repo_path / neurogentoo)" || return 1
    [[ -n "$registered" && "$(readlink -f "$registered")" == /var/db/repos/neurogentoo ]] &&
        validate_neurogentoo_sync_policy && validate_neurogentoo_repository
}

validate_neurogentoo_sync_policy() {
    # Check effective settings as well as our fragment: another repos.conf file
    # must not silently re-enable Portage's destructive Git sync behavior.
    portageq repos_config / | python3 -c '
import configparser
import sys
config = configparser.ConfigParser(interpolation=None)
config.read_file(sys.stdin)
repo = config["neurogentoo"]
valid = (repo.get("location") == sys.argv[1]
         and repo.get("sync-type") == "git" and repo.get("sync-uri") == sys.argv[2]
         and repo.get("auto-sync", "").lower() in ("yes", "true")
         and repo.getboolean("volatile", fallback=False)
         and repo.getint("sync-depth", fallback=1) == 0)
sys.exit(0 if valid else 1)
' /var/db/repos/neurogentoo "$NEUROGENTOO_URL"
}

validate_desktop_repositories() {
    local layer
    local -a POLICY_LAYERS=()
    validate_policy_sets repository-tools || return 1
    validate_policy_layer overlay || return 1
    validate_overlay_registration || return 1
    selected_policy_layers dwl
    for layer in "${POLICY_LAYERS[@]}"; do validate_policy_layer "$layer" || return 1; done
    repository_enabled guru && repository_enabled librewolf &&
        [[ -d /var/db/repos/guru && -d /var/db/repos/librewolf ]] &&
        [[ "$(git -C /var/db/repos/librewolf remote get-url origin 2>/dev/null)" == "$LIBREWOLF_REPOSITORY_URL" ]]
}

phase_desktop_packages() {
    local -a POLICY_LAYERS=()
    selected_policy_layers dwl
    install_policy_sets "${POLICY_LAYERS[@]}"
    required_files repair "${POLICY_LAYERS[@]}"
    system_policy_services apply dwl

    local group groups="" separator="" policy_groups
    policy_groups="$(system_policy_groups dwl)" && [[ -n "$policy_groups" ]] || die "missing desktop account groups"
    for group in $policy_groups; do
        getent group "$group" >/dev/null || die "required desktop group is missing: $group"
        groups+="$separator$group"
        separator=,
    done
    [[ -z "$groups" ]] || run usermod --append --groups "$groups" -- "$USERNAME"

    [[ -f /etc/pam.d/system-login ]] || die "system-login PAM configuration is missing"
    system_policy apply dwl etc/pam.d/system-login
}

validate_desktop_packages() {
    local -a POLICY_LAYERS=()
    selected_policy_layers dwl
    validate_policy_sets "${POLICY_LAYERS[@]}" || return 1
    local group groups policy_groups
    required_files check "${POLICY_LAYERS[@]}" || return 1
    groups=" $(id -nG "$USERNAME") " || return 1
    policy_groups="$(system_policy_groups dwl)" && [[ -n "$policy_groups" ]] || return 1
    for group in $policy_groups; do [[ "$groups" == *" $group "* ]] || return 1; done
    system_policy_services check dwl && system_policy check dwl etc/pam.d/system-login
}

phase_user_shell() {
    local current answer
    [[ "$USERNAME" != root ]] && user_home_is_safe || die "unsafe target account for Zsh"
    [[ -x /bin/zsh ]] || die "installed packages must provide Zsh before changing the target shell"
    current="$(getent passwd "$USERNAME" | cut -d: -f7)"
    if [[ "$(readlink -f "$current")" != "$(readlink -f /bin/zsh)" ]]; then
        if [[ "${STATE[approval.user-shell]:-}" != yes ]]; then
            if ((NON_INTERACTIVE)); then
                request_wait "target shell is $current; approve the change to Zsh interactively before continuing"
                return 0
            fi
            read -r -p "Change $USERNAME's shell from $current to Zsh? [y/N] " answer
            if [[ ! "$answer" =~ ^[yY]([eE][sS])?$ ]]; then
                request_wait "Zsh is required for the target user; existing shell preserved"
                return 0
            fi
            state_set approval.user-shell yes
        fi
        run usermod --shell /bin/zsh -- "$USERNAME"
    fi
    state_set user_shell /bin/zsh
}

validate_user_shell() {
    local current
    [[ "$USERNAME" != root && "${STATE[user_shell]:-}" == /bin/zsh && -x /bin/zsh ]] || return 1
    user_home_is_safe || return 1
    current="$(getent passwd "$USERNAME" | cut -d: -f7)" || return 1
    [[ "$(readlink -f "$current")" == "$(readlink -f /bin/zsh)" ]]
}

ensure_public_dotfiles_source() {
    local home="/home/$USERNAME" source parent temporary branch upstream
    source="$home/.local/share/chezmoi"
    parent="$(dirname "$source")"
    [[ ! -L "$source" ]] || die "chezmoi source must not be a symlink: $source"
    if [[ ! -d "$source/.git" ]]; then
        [[ ! -e "$source" ]] || die "chezmoi source exists but is not a Git repository: $source"
        run_as_user install -d -m 0755 "$parent"
        user_owned_directory_is_safe "$parent" || die "unsafe parent for public dotfiles: $parent"
        temporary="$(run_as_user mktemp -d "$parent/.chezmoi-install.XXXXXX")"
        if ! run_as_user git clone --branch "$PUBLIC_DOTFILES_BRANCH" "$PUBLIC_DOTFILES_URL" "$temporary"; then
            run_as_user rm -rf --one-file-system -- "$temporary"
            die "could not clone public dotfiles"
        fi
        run_as_user mv -T -- "$temporary" "$source"
    fi
    public_dotfiles_checkout_is_safe || die "public dotfiles has local changes, an unexpected origin or unsafe ownership; synchronize/review it without discarding edits"
    branch="$(run_as_user git -C "$source" symbolic-ref --quiet --short HEAD || true)"
    if [[ -z "$branch" ]]; then
        # Migrate the old installer's detached checkout without dropping commits.
        run_as_user git -C "$source" fetch origin "refs/heads/$PUBLIC_DOTFILES_BRANCH:refs/remotes/origin/$PUBLIC_DOTFILES_BRANCH"
        run_as_user git -C "$source" merge-base --is-ancestor HEAD "origin/$PUBLIC_DOTFILES_BRANCH" || \
            die "detached dotfiles commits are not on origin/$PUBLIC_DOTFILES_BRANCH; preserve/reconcile them before continuing"
        if run_as_user git -C "$source" show-ref --verify --quiet "refs/heads/$PUBLIC_DOTFILES_BRANCH"; then
            run_as_user git -C "$source" merge-base --is-ancestor "$PUBLIC_DOTFILES_BRANCH" "origin/$PUBLIC_DOTFILES_BRANCH" || \
                die "local dotfiles branch diverged; reconcile it with the existing sync workflow"
            run_as_user git -C "$source" switch "$PUBLIC_DOTFILES_BRANCH"
            run_as_user git -C "$source" merge --ff-only "origin/$PUBLIC_DOTFILES_BRANCH"
        else
            run_as_user git -C "$source" switch --create "$PUBLIC_DOTFILES_BRANCH" --track "origin/$PUBLIC_DOTFILES_BRANCH"
        fi
        branch="$PUBLIC_DOTFILES_BRANCH"
    fi
    [[ "$branch" == "$PUBLIC_DOTFILES_BRANCH" ]] || die "public dotfiles must use its $PUBLIC_DOTFILES_BRANCH branch; no branch was replaced"
    upstream="$(run_as_user git -C "$source" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
    if [[ -z "$upstream" ]]; then
        run_as_user git -C "$source" branch --set-upstream-to="origin/$PUBLIC_DOTFILES_BRANCH" "$PUBLIC_DOTFILES_BRANCH"
    fi
    public_dotfiles_source_valid || die "public dotfiles needs published machine-settings, shell, browser-theme and extension support on $PUBLIC_DOTFILES_BRANCH; use the existing sync workflow"
}

public_dotfiles_checkout_is_safe() {
    local source="/home/$USERNAME/.local/share/chezmoi" origin status
    [[ -d "$source/.git" && ! -L "$source/.git" ]] || return 1
    user_owned_tree_is_safe "$source" && user_owned_directory_is_safe "$source/.git" || return 1
    origin="$(run_as_user git -C "$source" remote get-url origin)" || return 1
    case "$origin" in
        "$PUBLIC_DOTFILES_URL"|git@github.com:Neur0leptic/dotfiles.git) ;;
        *) return 1 ;;
    esac
    status="$(run_as_user git -C "$source" status --porcelain --untracked-files=all)" || return 1
    [[ -z "$status" ]]
}

public_dotfiles_source_valid() {
    local source="/home/$USERNAME/.local/share/chezmoi"
    public_dotfiles_checkout_is_safe || return 1
    [[ "$(run_as_user git -C "$source" symbolic-ref --quiet --short HEAD)" == "$PUBLIC_DOTFILES_BRANCH" &&
       "$(run_as_user git -C "$source" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')" == "origin/$PUBLIC_DOTFILES_BRANCH" ]] || return 1
    # Later synchronized commits are valid. Only unpublished/local work is blocked.
    run_as_user git -C "$source" merge-base --is-ancestor HEAD "origin/$PUBLIC_DOTFILES_BRANCH" || return 1
    [[ -s "$source/.chezmoitemplates/machine-settings" && -s "$source/.chezmoidata/machinePresets.json" ]] &&
        grep -q 'DWL_TAG_OUTPUT_' "$source/dot_config/dwl/patches/0001-neuroleptic.patch" &&
        [[ -s "$source/dot_config/shell/env.sh.tmpl" &&
           -s "$source/dot_local/bin/executable_setup_browser_theme.sh" &&
           -s "$source/dot_config/browser-extensions.json" &&
           -s "$source/dot_librewolf/librewolf.overrides.cfg" ]]
}

user_owned_directory_is_safe() {
    local path="$1" uid mode canonical
    uid="$(id -u "$USERNAME")" || return 1
    [[ -d "$path" && ! -L "$path" && "$(stat -c %u "$path")" == "$uid" ]] || return 1
    canonical="$(readlink -f -- "$path")" || return 1
    [[ "$canonical" == "$path" ]] || return 1
    mode="$(stat -c %a "$path")"
    (( (8#$mode & 8#022) == 0 ))
}

user_owned_tree_is_safe() {
    local path="$1" unsafe
    user_owned_directory_is_safe "$path" || return 1
    path_contains_mountpoint "$path" && return 1
    unsafe="$(find "$path" -xdev ! -user "$USERNAME" -print -quit)" || return 1
    [[ -z "$unsafe" ]] || return 1
    unsafe="$(find "$path" -xdev \( -type f -o -type d \) -perm /022 -print -quit)" || return 1
    [[ -z "$unsafe" ]] || return 1
    unsafe="$(find "$path" -xdev ! -type f ! -type d ! -type l -print -quit)" || return 1
    [[ -z "$unsafe" ]]
}

phase_dwl_build() {
    if ! packaged_commands_are_unshadowed dwl yazi ya clipse timer ripdrag wayland-pipewire-idle-inhibit unimatrix; then
        request_wait "dwl-build needs local executable path conflicts resolved"
        return 0
    fi
    ensure_public_dotfiles_source
    local dotfiles_ref
    dotfiles_ref="$(public_dotfiles_revision)" || die "could not resolve the synchronized public dotfiles revision"
    if [[ "${FORCE_STAGE:-none}" == "$CURRENT_STAGE" ]] || ! validate_dwl_packaged_apps; then
        deploy_policy_layer dwl-apps
        EGIT_OVERRIDE_COMMIT_NEUR0LEPTIC_DOTFILES="$dotfiles_ref" install_policy_sets dwl-apps
        required_files repair dwl-apps
    fi
    if ! validate_dwl_package_inputs; then
        # Runtime-only dotfile updates need no rebuild; changed compiled inputs do.
        EGIT_OVERRIDE_COMMIT_NEUR0LEPTIC_DOTFILES="$dotfiles_ref" \
            emerge_with_resources --oneshot '=gui-wm/dwl-9999::neurogentoo'
        validate_dwl_package_inputs || die "rebuilt DWL does not match the synchronized canonical patch/protocol"
    fi
    # start-dwl intentionally uses this existing user-local executable path.
    # The application itself is owned by Portage at /usr/bin/dwl.
    local launcher="/home/$USERNAME/.local/bin/dwl"
    if [[ ! -e "$launcher" && ! -L "$launcher" ]]; then
        run_as_user install -d -m 0755 "/home/$USERNAME/.local/bin"
        run_as_user ln -s /usr/bin/dwl "$launcher"
    fi
}

public_dotfiles_revision() {
    public_dotfiles_source_valid || die "DWL requires a clean, published public dotfiles checkout"
    run_as_user git -C "/home/$USERNAME/.local/share/chezmoi" rev-parse HEAD
}

validate_dwl_packaged_apps() {
    validate_policy_sets dwl-apps &&
        packaged_commands_are_unshadowed dwl yazi ya clipse timer ripdrag wayland-pipewire-idle-inhibit unimatrix &&
        [[ -x /usr/bin/dwl && -x /usr/bin/yazi && -x /usr/bin/ya && -x /usr/bin/clipse &&
           -x /usr/bin/timer && -x /usr/bin/ripdrag && -x /usr/bin/wayland-pipewire-idle-inhibit &&
           -x /usr/bin/unimatrix ]] &&
        required_files check dwl-apps
}

validate_dwl_package_inputs() {
    local source="/home/$USERNAME/.local/share/chezmoi/dot_config/dwl"
    cmp -s "$source/patches/0001-neuroleptic.patch" /usr/share/dwl/neurogentoo/desktop.patch &&
        cmp -s "$source/protocols/dwl-ipc-unstable-v2.xml" /usr/share/dwl/neurogentoo/dwl-ipc-unstable-v2.xml
}

validate_dwl_build() {
    validate_dwl_packaged_apps && validate_dwl_package_inputs &&
        [[ -L "/home/$USERNAME/.local/bin/dwl" &&
           "$(readlink -f "/home/$USERNAME/.local/bin/dwl")" == /usr/bin/dwl ]]
}

detect_gpg_recipient() {
    local home="/home/$USERNAME" type fingerprint seen_secret=0
    while IFS=: read -r type _ _ _ _ _ _ _ _ fingerprint _; do
        if [[ "$type" == "sec" ]]; then
            seen_secret=1
        elif [[ "$type" == "fpr" && $seen_secret -eq 1 && "$fingerprint" =~ ^[0-9A-F]{40}$ ]]; then
            printf '%s' "$fingerprint"
            return 0
        fi
    done < <(run_as_user env GNUPGHOME="$home/.gnupg" \
        gpg --batch --with-colons --list-secret-keys 2>/dev/null)
    return 1
}

phase_public_dotfiles() {
    local home="/home/$USERNAME" source yazi_mount_plugin display_answers session_gpu prompts
    local FEATURE_MAIL=false FEATURE_KEEPASS=false FEATURE_WIREGUARD=false
    if [[ "$CURRENT_STAGE" == full-public-dotfiles ]]; then
        full_tier_approved || die "full dotfiles require full-tier approval"
        FEATURE_MAIL=true
        FEATURE_KEEPASS=true
        FEATURE_WIREGUARD=true
    fi
    source="$home/.local/share/chezmoi"
    local config="$home/.config/chezmoi/chezmoi.toml"
    yazi_mount_plugin="$home/.config/yazi/plugins/mount.yazi/sudo.lua"
    ensure_public_dotfiles_source

    if [[ -z "$GPG_RECIPIENT" ]]; then
        GPG_RECIPIENT="$(detect_gpg_recipient || true)"
    fi
    # Public files are not encrypted; an empty recipient disables chezmoi encryption.
    # Only the private payload (offered to neuroleptic unless declined) needs one.
    if [[ -z "$GPG_RECIPIENT" && "$USERNAME" == neuroleptic && "$PRIVATE_DOTFILES" != no ]]; then
        if ((NON_INTERACTIVE)); then
            request_wait "private chezmoi requires --gpg-recipient or a restored user secret key"
            return 0
        fi
        read -r -p 'GPG recipient fingerprint for chezmoi: ' GPG_RECIPIENT
        [[ -n "$GPG_RECIPIENT" ]] || die "private dotfiles need a GPG recipient; use --no-private-dotfiles to skip them"
    fi
    [[ -z "$GPG_RECIPIENT" || "$GPG_RECIPIENT" =~ ^[0-9A-Fa-f]{40}$ ]] || die "invalid GPG recipient fingerprint"
    GPG_RECIPIENT="${GPG_RECIPIENT^^}"
    validate_display_config || die "approved desktop preferences are missing"
    display_answers="$(cat "$(hardware_root)/displays.json")"
    session_gpu="$GPU_PROFILE"
    # Chezmoi keys prompt answers by question text. Its string-map CLI uses CSV,
    # so encode the JSON answer as one field, including embedded commas/quotes.
    prompts="$(python3 - "$GPG_RECIPIENT" "$display_answers" <<'PY'
import csv
import sys
csv.writer(sys.stdout, lineterminator='').writerow([
    'GPG recipient fingerprint=' + sys.argv[1],
    'DWL output configuration JSON (empty for machine defaults)=' + sys.argv[2],
    'Machine settings JSON (empty for portable defaults)=' + sys.argv[2],
])
PY
    )"

    run_as_user install -d -m 0755 "$(dirname "$config")"
    run_as_user chezmoi init --no-tty --prompt \
        --source "$source" --config "$config" --config-path "$config" \
        --promptString "$prompts" \
        --promptChoice "Desktop profile=$DESKTOP" \
        --promptChoice "GPU profile=$session_gpu" \
        --promptChoice "Machine profile=$MACHINE_PROFILE" \
        --promptBool "Enable mail configuration=$FEATURE_MAIL" \
        --promptBool "Enable KeePass configuration=$FEATURE_KEEPASS" \
        --promptBool "Enable WireGuard integrations=$FEATURE_WIREGUARD" \
        --promptBool 'Enable Hermes integrations=false'
    run_as_user dbus-run-session -- \
        chezmoi --source "$source" --config "$config" --no-tty apply
    if [[ ! -s "$yazi_mount_plugin" ]]; then
        run_as_user env \
            GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false GCM_INTERACTIVE=never \
            GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=protocol.version GIT_CONFIG_VALUE_0=1 \
            GIT_CONFIG_KEY_1=credential.interactive GIT_CONFIG_VALUE_1=false \
            SSH_ASKPASS=/bin/false SSH_ASKPASS_REQUIRE=never \
            ya pkg install
    fi
}

validate_public_preferences() {
    local config="/home/$USERNAME/.config/chezmoi/chezmoi.toml" profile settings
    local stage="${1:-public-dotfiles}" require_full=false
    if [[ "$stage" == full-public-dotfiles ]]; then
        full_tier_approved || return 1
        require_full=true
    fi
    settings="$(cat "$(hardware_root)/displays.json")" || return 1
    if [[ "$DISTRIBUTION" == arch ]]; then
        profile="$GPU_PROFILE"
    else
        profile="$(hardware_field graphics.profile)" || return 1
    fi
    run_as_user chezmoi --config "$config" dump-config --format json | jq -e \
        --arg profile "$profile" --arg machine "$MACHINE_PROFILE" --arg desktop "$DESKTOP" \
        --argjson settings "$settings" \
        --argjson require_full "$require_full" \
        '.data | .desktop == $desktop and .gpuProfile == $profile and .machine == $machine
          and ([.features.mail, .features.keepass, .features.wireguard] | all(type == "boolean"))
          and (if $require_full then
                 .features.mail and .features.keepass and .features.wireguard
               else true end)
          and .features.hermes == false
           and (.machineSettings | fromjson) == $settings' >/dev/null
}

validate_public_dotfiles() {
    local home="/home/$USERNAME" source stage="${1:-public-dotfiles}"
    source="$home/.local/share/chezmoi"
    public_dotfiles_source_valid && validate_public_preferences "$stage" &&
        [[ -s "$home/.config/chezmoi/chezmoi.toml" ]] &&
        validate_desktop_dotfiles && validate_shell_theme_dotfiles &&
        [[ -x "$home/.local/bin/waybar_toggle.sh" ]] &&
        [[ -x "$home/.local/bin/recorder.sh" ]] &&
        [[ -s "$home/.config/yazi/plugins/mount.yazi/sudo.lua" ]] &&
        cmp -s "$source/dot_local/bin/executable_waybar_toggle.sh" "$home/.local/bin/waybar_toggle.sh" &&
        [[ -s "$home/.local/share/icons/candy-icons/index.theme" ]] &&
        [[ -s "$home/.config/zsh/powerlevel10k/powerlevel10k.zsh-theme" ]] &&
        [[ -s "$home/.config/zsh/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh" ]] &&
        [[ -s "$home/.config/zsh/fzf-tab/fzf-tab.plugin.zsh" ]] &&
        [[ -s "$home/.config/zsh/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] &&
        { [[ "$stage" != full-public-dotfiles ]] ||
            [[ -x "$home/.local/bin/wireguard.sh" && -d "$home/.local/share/wireguard/.git" ]]; }
}

validate_shell_theme_dotfiles() {
    local home="/home/$USERNAME" source file rendered
    source="$home/.local/share/chezmoi"
    for file in .zshenv .config/shell/env.sh .config/zsh/.zprofile .config/zsh/.zshrc \
        .config/foot/foot.ini .config/librewolf/chrome/userChrome.css .config/librewolf/chrome/userContent.css \
        .librewolf/librewolf.overrides.cfg .config/helium-browser-theme.json .config/browser-extensions.json \
        .local/bin/setup_librewolf.sh .local/bin/setup_browser_theme.sh \
        .local/share/themes/Neurowave/index.theme .local/share/themes/Neurowave/gtk-3.0/gtk.css \
        .local/share/themes/Neurowave/gtk-4.0/gtk.css .local/share/Kvantum/Neurowave/Neurowave.kvconfig \
        .local/share/Kvantum/Neurowave/Neurowave.svg .config/neurowave/apply.sh \
        .config/neurowave/palette.sh .config/neurowave/palette.yaml; do
        [[ -s "$home/$file" ]] || return 1
        rendered="$(run_as_user chezmoi --source "$source" cat "$home/$file")" || return 1
        [[ "$rendered" == "$(cat "$home/$file")" ]] || return 1
    done
    [[ -x "$home/.local/bin/setup_librewolf.sh" && -x "$home/.local/bin/setup_browser_theme.sh" &&
       -x "$home/.config/neurowave/apply.sh" ]] || return 1
    [[ "$(readlink "$home/.config/librewolf/librewolf/librewolf.overrides.cfg")" == "$home/.librewolf/librewolf.overrides.cfg" ]] || return 1
    diff -qr "$source/dot_config/neurowave/templates" "$home/.config/neurowave/templates" >/dev/null
}

validate_librewolf_setup_outputs() {
    local home="/home/$USERNAME" profile file
    [[ -x "$home/.local/bin/setup_browser_theme.sh" ]] || return 1
    profile="$(run_as_user "$home/.local/bin/setup_browser_theme.sh" --librewolf-profile)" || return 1
    [[ "$profile" == "$home/"* && "$(readlink -m "$profile")" == "$profile" ]] || return 1
    for file in user.js updater.sh prefsCleaner.sh; do
        [[ -f "$profile/$file" && ! -L "$profile/$file" ]] && grep -qi arkenfox "$profile/$file" || return 1
    done
    [[ -x "$profile/updater.sh" && -x "$profile/prefsCleaner.sh" ]]
}

phase_librewolf_setup() {
    local script="/home/$USERNAME/.local/bin/setup_librewolf.sh" result answer
    [[ -x "$script" ]] || die "managed LibreWolf setup script is missing"
    if [[ "${STATE[librewolf_setup_result]:-}" == failed && "${FORCE_STAGE:-}" != librewolf-setup ]]; then
        if validate_librewolf_setup_outputs && ((NON_INTERACTIVE == 0)); then
            read -r -p 'Did the unchanged LibreWolf setup script succeed when you reran it manually? [y/N] ' answer
            if [[ "$answer" =~ ^[yY]([eE][sS])?$ ]]; then
                state_set librewolf_setup_result success
                log "LibreWolf setup: manual success confirmed; existing profile retained."
                return 0
            fi
        fi
        request_wait "LibreWolf setup failed previously; rerun $script as $USERNAME and confirm success on resume, or select librewolf-setup to retry it"
        return 0
    fi
    # Interruptions and explicit retries must not retain a previous success result.
    state_set librewolf_setup_result failed
    log "Calling the unchanged LibreWolf/Arkenfox setup script as $USERNAME."
    if run_as_user "$script"; then
        if validate_librewolf_setup_outputs; then
            state_set librewolf_setup_result success
            log "LibreWolf setup: SUCCESS (exit status 0)."
            return 0
        fi
        warn "LibreWolf setup returned exit status 0, but its expected Arkenfox files are incomplete."
    else
        result=$?
        warn "LibreWolf setup: FAILED (exit status $result)."
    fi
    state_set librewolf_setup_result failed
    request_wait "LibreWolf setup did not complete; its script is unchanged and can be rerun manually as $USERNAME"
}

validate_librewolf_setup() {
    [[ "${STATE[librewolf_setup_result]:-}" == success ]] && validate_librewolf_setup_outputs
}

phase_browser_theme() {
    local helper="/home/$USERNAME/.local/bin/setup_browser_theme.sh"
    [[ -x "$helper" ]] || die "managed browser-theme helper is missing"
    if ! run_as_user "$helper" --apply; then
        request_wait "browser theme setup needs review; existing differing CSS and active Helium profiles are preserved"
        return 0
    fi
    log "Browser theme setup: SUCCESS."
}

validate_browser_theme() {
    local helper="/home/$USERNAME/.local/bin/setup_browser_theme.sh"
    [[ -x "$helper" ]] && run_as_user "$helper" --check
}

browser_extension_policies() {
    local mode="$1" defaults="" candidate manifest="/home/$USERNAME/.config/browser-extensions.json"
    [[ -s "$COMMON_DATA/browser-extensions.sh" && -f "$manifest" && ! -L "$manifest" ]] || return 1
    for candidate in /usr/lib/librewolf/distribution/policies.json /usr/lib64/librewolf/distribution/policies.json /opt/librewolf/distribution/policies.json; do
        if [[ -f "$candidate" ]]; then defaults="$(readlink -f -- "$candidate")"; break; fi
    done
    [[ -n "$defaults" ]] || { warn "LibreWolf's packaged policy file was not found"; return 1; }
    bash "$COMMON_DATA/browser-extensions.sh" "$mode" "$manifest" "$defaults" \
        /etc/librewolf/policies/policies.json /etc/chromium/policies/managed
}

phase_browser_extensions() {
    if ! browser_extension_policies apply; then
        request_wait "browser extension policies need review; conflicting settings are preserved"
        return 0
    fi
    log "Browser extension policies: READY; first online startup installs extensions, without locking disable controls."
    log "Helium extension downloads require its normal services/proxy consent; no browser was started or closed."
}

validate_browser_extensions() {
    browser_extension_policies check
}

validate_desktop_dotfiles() {
    local home="/home/$USERNAME" source="/home/$USERNAME/.local/share/chezmoi"
    if [[ "$DESKTOP" == hyprland ]]; then
        [[ -s "$home/.config/hypr/hyprland.lua" && -s "$home/.config/swayidle/config" &&
           -s "$home/.config/waybar/config.jsonc" ]] &&
            cmp -s "$home/.config/hypr/machine.lua" <(run_as_user chezmoi --source "$source" cat "$home/.config/hypr/machine.lua")
        return
    fi
    [[ -x "$home/.local/bin/start-dwl" && -x "$home/.local/bin/dwl-autostart" &&
       -x "$home/.local/bin/dwl-outputs" && -s "$home/.config/dwl/outputs.json" &&
       -s "$home/.config/swayidle/config-dwl" && -s "$home/.config/waybar/config-dwl.jsonc" &&
       -s "$home/.config/waybar/style-dwl.css" ]] &&
        cmp -s "$source/dot_local/bin/executable_dwl-autostart" "$home/.local/bin/dwl-autostart" &&
        cmp -s "$source/dot_local/bin/executable_dwl-outputs" "$home/.local/bin/dwl-outputs" &&
        grep -qF 'config-dwl.jsonc' "$home/.local/bin/waybar_toggle.sh" &&
        cmp -s "$home/.local/bin/start-dwl" <(run_as_user chezmoi --source "$source" cat "$home/.local/bin/start-dwl") || return 1
    python3 "$COMMON_DATA/displays.py" --inventory "$(hardware_root)/inventory.json" \
        --input "$(hardware_root)/displays.json" --check-target "$home/.config/dwl/outputs.json"
}

private_apply_policy() {
    printf '%s' "$PRIVATE_APPLY_POLICY"
}

private_dotfiles_requested() {
    [[ "$USERNAME" == neuroleptic ]] || return 1
    local answer
    case "$PRIVATE_DOTFILES" in
        yes) return 0 ;;
        no) return 1 ;;
        ask)
            ((NON_INTERACTIVE == 0)) || return 2
            read -r -p 'Apply private dotfiles? [y/N] ' answer
            [[ "$answer" =~ ^[yY]([eE][sS])?$ ]]
            ;;
    esac
}

private_dotfiles_files() {
    local action="$1" home="/home/$USERNAME" target target_file weather_selected=0
    local stage="${2:-${CURRENT_STAGE:-private-dotfiles}}"
    local source="$home/.local/share/chezmoi-private" persistent="$home/.local/state/chezmoi-private.boltdb"
    local -a managed_targets=() private_targets=() scope=()
    [[ "$action" == apply || "$action" == verify ]] || return 1
    # Full preferences can enable additional targets after the desktop receipt.
    # The desktop stage owns only its original, feature-independent subset.
    if [[ "$stage" == private-dotfiles ]]; then
        scope=(--override-data '{"features":{"mail":false,"keepass":false,"wireguard":false}}')
    fi
    target_file="$(mktemp "${TMPDIR:-/tmp}/install-system-private-targets.XXXXXX")" || return 1
    if ! run_as_user chezmoi -S "$source" --persistent-state "$persistent" --no-tty "${scope[@]}" \
        managed --include=files,symlinks --path-style=absolute --nul-path-separator >"$target_file"; then
        rm -f -- "$target_file"
        warn "could not enumerate private chezmoi targets"
        return 1
    fi
    mapfile -d '' -t managed_targets <"$target_file"
    rm -f -- "$target_file"
    for target in "${managed_targets[@]}"; do
        if [[ "$target" != "$home"/* || "$target" =~ [[:cntrl:]] ]]; then
            warn "private chezmoi produced an unsafe target path"
            return 1
        fi
        case "$target" in
            */../*|*/..|*/./*|*/.|*//*)
                warn "private chezmoi produced a non-canonical target path"
                return 1
                ;;
        esac
        [[ "$target" != "$home/.local/bin/weather.sh" ]] || weather_selected=1
        private_targets+=("$target")
    done
    if ((weather_selected == 0)); then
        warn "private chezmoi does not manage the required weather.sh target"
        return 1
    fi
    # Include selected targets' parents so newly enabled features can create their
    # directories without recursively applying excluded siblings.
    run_as_user chezmoi -S "$source" --persistent-state "$persistent" --no-tty "${scope[@]}" \
        "$action" --include=files,symlinks,dirs --parent-dirs --recursive=false -- "${private_targets[@]}"
}

phase_private_dotfiles() {
    local home="/home/$USERNAME" source parent temporary weather weather_sha uid
    source="$home/.local/share/chezmoi-private"
    parent="$(dirname "$source")"
    local persistent="$home/.local/state/chezmoi-private.boltdb"
    local marker=/var/lib/install-system/private-dotfiles.skipped ssh_command origin local_head
    local -a ssh_env
    ssh_command='ssh -o BatchMode=yes -o ClearAllForwardings=yes -o StrictHostKeyChecking=yes'
    ssh_env=(env "GIT_SSH_COMMAND=$ssh_command")

    local private_request_status=0
    private_dotfiles_requested || private_request_status=$?
    if ((private_request_status == 2)); then
        request_wait "choose --private-dotfiles or --no-private-dotfiles, then continue"
        return 0
    fi
    if ((private_request_status != 0)); then
        PRIVATE_DOTFILES="no"
        STATE[private_dotfiles]="no"
        state_write
        rm -f /var/lib/install-system/private-dotfiles.applied
        write_file "$marker" 0644 <<'EOF'
not requested
EOF
        return 0
    fi
    PRIVATE_DOTFILES="yes"
    STATE[private_dotfiles]="yes"
    state_write
    rm -f "$marker"
    rm -f /var/lib/install-system/private-dotfiles.applied
    ensure_github_known_host

    if [[ -z "$SSH_KEY" ]] && private_ssh_key_is_safe "$home/.ssh/id_ed25519_github"; then
        SSH_KEY="$home/.ssh/id_ed25519_github"
    fi
    if [[ -n "$SSH_KEY" ]]; then
        private_ssh_key_is_safe "$SSH_KEY" || {
            request_wait "private SSH key must be a non-symlink, user-owned private file under $home: $SSH_KEY"
            return 0
        }
        printf -v ssh_command 'ssh -i %q -o IdentitiesOnly=yes -o BatchMode=yes -o ClearAllForwardings=yes -o StrictHostKeyChecking=yes' "$SSH_KEY"
        ssh_env=(env "GIT_SSH_COMMAND=$ssh_command")
    elif ! run_as_user ssh-add -l >/dev/null 2>&1; then
        request_wait "restore the private GitHub SSH key or load it into ssh-agent, then continue"
        return 0
    fi

    if [[ ! -d "$source/.git" ]]; then
        [[ ! -L "$source" ]] || die "private chezmoi source must not be a symlink: $source"
        [[ ! -e "$source" ]] || die "private chezmoi source is not a Git repository: $source"
        run_as_user install -d -m 0755 "$parent"
        user_owned_directory_is_safe "$parent" || die "unsafe parent for private dotfiles: $parent"
        temporary="$(run_as_user mktemp -d "$parent/.chezmoi-private-install.XXXXXX")"
        if ! run_as_user "${ssh_env[@]}" git clone "$PRIVATE_DOTFILES_URL" "$temporary"; then
            run_as_user rm -rf --one-file-system -- "$temporary"
            request_wait "private dotfiles clone failed; restore access and continue"
            return 0
        fi
        run_as_user mv -T -- "$temporary" "$source"
    fi
    [[ ! -L "$source" ]] || die "private chezmoi source must not be a symlink: $source"
    [[ -d "$source/.git" && ! -L "$source/.git" ]] || die "private chezmoi Git metadata must be a directory"
    user_owned_tree_is_safe "$source" && user_owned_directory_is_safe "$source/.git" || \
        die "private dotfiles checkout has unsafe ownership or permissions"
    origin="$(run_as_user git -C "$source" remote get-url origin)"
    [[ "$origin" == "$PRIVATE_DOTFILES_URL" ]] || die "unexpected private dotfiles origin: $origin"
    [[ -z "$(run_as_user git -C "$source" status --porcelain)" ]] || die "private dotfiles source has local changes"
    local_head="$(run_as_user git -C "$source" rev-parse HEAD)"

    [[ -n "$GPG_RECIPIENT" ]] || GPG_RECIPIENT="$(detect_gpg_recipient || true)"
    if [[ -z "$GPG_RECIPIENT" ]] || ! run_as_user gpg --batch --list-secret-keys "$GPG_RECIPIENT" >/dev/null 2>&1; then
        request_wait "restore the GPG private key for the chezmoi recipient, then continue"
        return 0
    fi
    run_as_user install -d -m 0755 "$(dirname "$persistent")"
    private_dotfiles_files apply
    weather="$home/.local/bin/weather.sh"
    uid="$(id -u "$USERNAME")" || die "could not resolve user ID for private dotfiles"
    [[ -f "$weather" && ! -L "$weather" && -x "$weather" && \
        "$(stat -c %u "$weather")" == "$uid" && "$(stat -c %h "$weather")" == "1" ]] || \
        die "private chezmoi did not install a safe executable weather.sh"
    weather_sha="$(run_as_user sha256sum -- "$weather")"
    weather_sha="${weather_sha%% *}"
    [[ "$weather_sha" =~ ^[0-9a-f]{64}$ ]] || die "could not hash private weather.sh"
    write_file /var/lib/install-system/private-dotfiles.applied 0644 <<EOF
commit=$local_head
policy=$(private_apply_policy)
weather_sha256=$weather_sha
EOF
}

validate_private_dotfiles() {
    if [[ "$USERNAME" != neuroleptic ]]; then
        [[ "${STATE[private_dotfiles]:-ask}" == no ]] || return 1
    fi
    local home="/home/$USERNAME" source applied origin status weather mode uid expected_weather_sha actual_weather_sha
    source="$home/.local/share/chezmoi-private"
    case "${STATE[private_dotfiles]:-ask}" in
        no)
            [[ -f /var/lib/install-system/private-dotfiles.skipped && \
                ! -L /var/lib/install-system/private-dotfiles.skipped && \
                "$(stat -c %u /var/lib/install-system/private-dotfiles.skipped)" == "0" && \
                "$(stat -c %a /var/lib/install-system/private-dotfiles.skipped)" == "644" && \
                "$(stat -c %h /var/lib/install-system/private-dotfiles.skipped)" == "1" && \
                ! -e /var/lib/install-system/private-dotfiles.applied ]] &&
                grep -qxF 'not requested' /var/lib/install-system/private-dotfiles.skipped
            ;;
        yes)
            [[ -f /var/lib/install-system/private-dotfiles.applied && \
                ! -L /var/lib/install-system/private-dotfiles.applied && \
                "$(stat -c %u /var/lib/install-system/private-dotfiles.applied)" == "0" && \
                "$(stat -c %a /var/lib/install-system/private-dotfiles.applied)" == "644" && \
                "$(stat -c %h /var/lib/install-system/private-dotfiles.applied)" == "1" && \
                ! -e /var/lib/install-system/private-dotfiles.skipped && \
                -d "$source/.git" && ! -L "$source/.git" ]] || return 1
            user_owned_tree_is_safe "$source" && user_owned_directory_is_safe "$source/.git" || return 1
            applied="$(grep '^commit=' /var/lib/install-system/private-dotfiles.applied 2>/dev/null)"
            applied="${applied#commit=}"
            [[ "$applied" =~ ^[0-9a-fA-F]{40,64}$ ]] || return 1
            grep -qxF "policy=$(private_apply_policy)" /var/lib/install-system/private-dotfiles.applied || return 1
            origin="$(run_as_user git -C "$source" remote get-url origin 2>/dev/null)" || return 1
            [[ "$origin" == "$PRIVATE_DOTFILES_URL" ]] || return 1
            [[ "$(run_as_user git -C "$source" rev-parse HEAD 2>/dev/null)" == "$applied" ]] || return 1
            status="$(run_as_user git -C "$source" status --porcelain --untracked-files=all 2>/dev/null)" || return 1
            [[ -z "$status" ]] || return 1
            weather="$home/.local/bin/weather.sh"
            uid="$(id -u "$USERNAME")" || return 1
            [[ -f "$weather" && ! -L "$weather" && -x "$weather" && \
                "$(stat -c %u "$weather")" == "$uid" && "$(stat -c %h "$weather")" == "1" ]] || return 1
            mode="$(stat -c %a "$weather")"
            (( (8#$mode & 8#100) != 0 && (8#$mode & 8#022) == 0 )) || return 1
            expected_weather_sha="$(grep '^weather_sha256=' /var/lib/install-system/private-dotfiles.applied 2>/dev/null)"
            expected_weather_sha="${expected_weather_sha#weather_sha256=}"
            [[ "$expected_weather_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
            actual_weather_sha="$(run_as_user sha256sum -- "$weather" 2>/dev/null)" || return 1
            [[ "${actual_weather_sha%% *}" == "$expected_weather_sha" ]] || return 1
            private_dotfiles_files verify "${1:-private-dotfiles}"
            ;;
        *) return 1 ;;
    esac
}

validate_dwl_complete() {
    [[ -s /var/lib/install-system/dwl-complete ]] || return 1
    if [[ "$MODE" == "new" ]]; then
        [[ "$(state_stage_status minimal-complete)" == "done" ]] || return 1
    else
        [[ "$(state_stage_status existing-preflight)" == "done" ]] || return 1
    fi
    stage_group_complete_before dwl-complete "${DWL_STAGES[@]}"
}

phase_full_packages() {
    local layer
    local -a POLICY_LAYERS=()
    selected_policy_layers full
    for layer in "${POLICY_LAYERS[@]}"; do deploy_policy_layer "$layer"; done
    install_policy_sets "${POLICY_LAYERS[@]}"
    required_files repair "${POLICY_LAYERS[@]}"
    if [[ "$TORRENT" == yes ]]; then system_policy apply torrent etc/init.d/flaresolverr; fi
}

validate_full_packages() {
    local -a POLICY_LAYERS=()
    selected_policy_layers full
    validate_policy_sets "${POLICY_LAYERS[@]}" || return 1
    required_files check "${POLICY_LAYERS[@]}" || return 1
    [[ "$TORRENT" != yes ]] || system_policy check torrent etc/init.d/flaresolverr || return 1
    local command encoders
    # Read the whole list first: grep -q closing the pipe early makes ffmpeg exit
    # with SIGPIPE, which pipefail reports as a failed check.
    encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null)" || return 1
    for command in aac libopus libx264; do
        grep -qw "$command" <<<"$encoders" || return 1
    done
    if hardware_field graphics.families | grep -q nvidia; then
        grep -qw h264_nvenc <<<"$encoders" || return 1
    fi
    tesseract --list-langs 2>/dev/null | grep -qx deu || return 1
    [[ "$FEATURE_KEEPASS" != "true" ]] || python -c 'import pykeepass' >/dev/null 2>&1 || return 1
    return 0
}

elf64_x86_64_is_valid() {
    local path="$1" header
    [[ -f "$path" && ! -L "$path" ]] || return 1
    header="$(od -An -tx1 -N20 -- "$path" | tr -d '[:space:]')" || return 1
    [[ "${header:0:12}" == "7f454c460201" && "${header:36:4}" == "3e00" ]]
}

phase_source_apps() {
    if ! packaged_commands_are_unshadowed nchat wiki-tui croc; then
        request_wait "source-apps needs local executable path conflicts resolved"
        return 0
    fi
    deploy_policy_layer source-apps
    install_policy_sets source-apps
    required_files repair source-apps
}

validate_source_apps() {
    validate_policy_sets source-apps &&
        packaged_commands_are_unshadowed nchat wiki-tui croc || return 1
    local command
    for command in nchat wiki-tui croc; do
        [[ -x "/usr/bin/$command" ]] || return 1
    done
    required_files check source-apps
}

packaged_commands_are_unshadowed() {
    local command path expected
    for command in "$@"; do
        expected="$(readlink -m "/usr/bin/$command")" || return 1
        for path in "$(command -v "$command" || true)" "/usr/local/bin/$command" "/home/$USERNAME/.local/bin/$command" "/home/$USERNAME/.cargo/bin/$command"; do
            [[ -e "$path" || -L "$path" ]] || continue
            if [[ "$(readlink -m "$path")" != "$expected" ]]; then
                warn "$path shadows the packaged executable /usr/bin/$command; preserve/move that local copy before continuing"
                return 1
            fi
        done
    done
}

required_files() {
    local action="$1" layer directory path owners cpv found=0
    shift
    local -A repair=()
    for layer in "$@"; do
        directory="$(policy_layer_directory "$layer")" || return 1
        # Hardware and optional layers may have no additional required outputs.
        [[ -s "$directory/required-files" ]] || continue
        found=1
        while IFS= read -r path || [[ -n "$path" ]]; do
            [[ -n "$path" && "$path" != \#* ]] || continue
            if [[ -s "$path" && ( ( "$path" != /usr/bin/* && "$path" != /usr/sbin/* ) || -x "$path" ) ]]; then
                if [[ "$layer" != binary-apps || "$path" != /usr/bin/* ]] || \
                    elf64_x86_64_is_valid "$(readlink -f -- "$path")"; then
                    continue
                fi
            fi
            [[ "$action" == repair ]] || return 1
            # Ask Portage for the owning package, even when its installed file is missing.
            owners="$(portageq owners / "$path")" || die "no installed package owns required output: $path"
            while IFS= read -r cpv; do
                [[ "$cpv" =~ ^[a-zA-Z0-9+_.-]+/[a-zA-Z0-9+_.-]+$ ]] || continue
                repair["=$cpv"]=1
            done <<<"$owners"
        done <"$directory/required-files"
    done
    ((found)) || return 1
    if ((${#repair[@]})); then emerge_with_resources --oneshot "${!repair[@]}"; fi
    [[ "$action" != repair ]] || required_files check "$@"
}

phase_binary_apps() {
    if ! packaged_commands_are_unshadowed opencode shfmt localsend; then
        request_wait "binary-apps needs local executable path conflicts resolved"
        return 0
    fi
    deploy_policy_layer binary-apps
    install_policy_sets binary-apps
    required_files repair binary-apps
}

validate_binary_apps() {
    validate_policy_sets binary-apps &&
        packaged_commands_are_unshadowed opencode shfmt localsend &&
        [[ -x /usr/bin/opencode && -x /usr/bin/shfmt && -x /usr/bin/localsend ]] &&
        elf64_x86_64_is_valid /usr/bin/opencode &&
        elf64_x86_64_is_valid /usr/bin/shfmt &&
        elf64_x86_64_is_valid /opt/localsend/localsend_app &&
        required_files check binary-apps
}

validate_full_complete() {
    [[ -s /var/lib/install-system/full-complete ]] &&
        [[ "$(state_stage_status dwl-complete)" == "done" ]] &&
        stage_group_complete_before full-complete "${FULL_STAGES[@]}"
}

tier_rank() {
    case "$1" in
        minimal) printf '1' ;;
        dwl|desktop) printf '2' ;;
        full) printf '3' ;;
        *) return 1 ;;
    esac
}

full_tier_approved() {
    [[ "${STATE[approval.dwl-to-full]:-}" == yes || "${STATE[approval.desktop-to-full]:-}" == yes ]]
}

set_tier_features() {
    # Selecting full is not approval to install its payload before the DWL boundary.
    FEATURE_MAIL=false
    full_tier_approved && FEATURE_MAIL=true
    FEATURE_KEEPASS="$FEATURE_MAIL"
    FEATURE_WIREGUARD="$FEATURE_MAIL"
    STATE[feature_mail]="$FEATURE_MAIL"
    STATE[feature_keepass]="$FEATURE_KEEPASS"
    STATE[feature_wireguard]="$FEATURE_WIREGUARD"
}

approve_tier_transition() {
    local approval="$1" target="$2" prompt="$3" answer current_rank target_rank
    log "$prompt"
    if ((NON_INTERACTIVE)); then
        request_wait "tier transition requires interactive approval; resume without --non-interactive"
        return 0
    fi
    while true; do
        printf 'Continue? [y/N] ' >/dev/tty
        IFS= read -r answer </dev/tty
        case "$answer" in
            y|Y|yes|YES|Yes)
                STATE["approval.$approval"]="yes"
                current_rank="$(tier_rank "$TIER")"
                target_rank="$(tier_rank "$target")"
                if ((target_rank > current_rank)); then
                    TIER="$target"
                    STATE[tier]="$target"
                fi
                set_tier_features
                if [[ "$target" == full ]]; then select_torrent; STATE[torrent]="$TORRENT"; fi
                state_write
                return 0
                ;;
            n|N|no|NO|No|'')
                request_wait "tier transition declined; run continue when ready"
                return 0
                ;;
            *)
                printf 'Enter yes or no.\n' >/dev/tty
                ;;
        esac
    done
}

phase_minimal_to_dwl_approval() {
    approve_tier_transition minimal-to-dwl dwl "Minimal Gentoo is complete. Continue with the DWL tier?"
}

validate_minimal_to_dwl_approval() {
    [[ "${STATE["approval.minimal-to-dwl"]:-}" == "yes" ]]
}

phase_dwl_to_full_approval() {
    approve_tier_transition dwl-to-full full "The DWL tier is complete. Continue with the full tier?"
}

validate_dwl_to_full_approval() {
    [[ "${STATE["approval.dwl-to-full"]:-}" == "yes" ]]
}

promote_tier_if_requested() {
    local requested="$1" current_rank requested_rank
    [[ -n "$requested" ]] || return 0
    [[ "$requested" =~ ^(minimal|dwl|desktop|full)$ ]] || die "invalid requested tier"
    [[ "$DISTRIBUTION/$requested" != gentoo/desktop && "$DISTRIBUTION/$requested" != arch/dwl ]] || die "tier does not match distribution"
    [[ "$MODE" != "existing" || "$requested" != "minimal" ]] || die "existing mode cannot use minimal tier"
    current_rank="$(tier_rank "$TIER")"
    requested_rank="$(tier_rank "$requested")"
    ((requested_rank >= current_rank)) || die "tier cannot be downgraded from $TIER to $requested"
    if ((requested_rank > current_rank)); then
        TIER="$requested"
        STATE[tier]="$TIER"
        if [[ "$MODE" == "new" && "$STATE_FILE" == "$TARGET_MOUNT$DEFAULT_STATE_FILE" && $INTERNAL_CHROOT -eq 0 ]]; then
            STATE["stage.chroot-install"]="pending"
        fi
        state_write
    fi
}

apply_runtime_overrides() {
    local changed=0
    if [[ "$TIER" == full ]]; then select_torrent; fi
    if [[ "$TORRENT" != "${STATE[torrent]:-ask}" ]]; then
        STATE[torrent]="$TORRENT"
        STATE[stage.full-packages]=pending
        changed=1
    fi
    if [[ "$PRIVATE_DOTFILES" != "ask" && "$PRIVATE_DOTFILES" != "${STATE[private_dotfiles]:-ask}" ]]; then
        STATE[private_dotfiles]="$PRIVATE_DOTFILES"
        STATE["stage.private-dotfiles"]="pending"
        STATE["stage.full-private-dotfiles"]="pending"
        changed=1
    fi
    if ((EFI_OPTION_SET)) && [[ "$CREATE_EFI_ENTRY" != "${STATE[efi_entry]:-yes}" ]]; then
        STATE[efi_entry]="$CREATE_EFI_ENTRY"
        [[ "$MODE" != "new" ]] || STATE["stage.boot"]="pending"
        changed=1
    fi
    if ((changed)); then
        state_write
    fi
}

run_target_install() {
    prepare_credentials
    if [[ "$DISTRIBUTION" == arch ]]; then arch_run_target; return; fi
    ((KERNEL_CONFIG_READY == 0)) || [[ "$MODE" == new ]] || die "existing mode has no kernel configuration stage"
    if [[ "$MODE" == existing || "$(state_stage_status accounts)" == done ]]; then
        select_existing_user
    fi
    set_tier_features
    ensure_portage_source
    [[ "$MODE" != new ]] || ensure_hardware_plan
    local -a sequence=()
    if [[ "$MODE" == "new" ]]; then
        sequence+=("${MINIMAL_SEQUENCE[@]}")
    else
        sequence+=("${EXISTING_SEQUENCE[@]}")
    fi
    sequence+=("${DWL_SEQUENCE[@]}" "${FULL_SEQUENCE[@]}")
    run_sequence "${sequence[@]}"

    if ((STOP_REQUESTED == 0)); then
        log "Full System is complete."
    fi
}

run_existing() {
    local requested_tier="$TIER" requested_user="$USERNAME"
    MODE="existing"
    select_distribution
    STATE_FILE="${STATE_FILE:-$DEFAULT_STATE_FILE}"
    if ((DRY_RUN)); then
        if [[ -r "$STATE_FILE" ]]; then
            state_load
            [[ "${STATE[mode]}" == "existing" ]] || die "state belongs to a new installation; use continue"
            [[ -z "$requested_user" || "$requested_user" == "${STATE[username]}" ]] || die "username differs from persisted state"
            restore_globals_from_state
            promote_tier_if_requested "$requested_tier"
            apply_runtime_overrides
        else
            select_tier
            [[ "$DISTRIBUTION" != arch ]] || arch_select_install_options
            prompt_identity
        fi
        print_dry_plan
        return 0
    fi
    require_root
    acquire_run_lock
    if [[ -e "$STATE_FILE" ]]; then
        state_load
        [[ "${STATE[mode]}" == "existing" ]] || die "state belongs to a new installation; use continue"
        [[ -z "$requested_user" || "$requested_user" == "${STATE[username]}" ]] || die "username differs from persisted state"
        ((GPU_OPTION_SET == 0 && MACHINE_OPTION_SET == 0 && ARCH_SELECTION_OPTIONS == 0)) || die "resume uses saved hardware, desktop and repository settings"
        restore_globals_from_state
        promote_tier_if_requested "$requested_tier"
        apply_runtime_overrides
    else
        select_tier
        [[ "$DISTRIBUTION" != arch ]] || arch_select_install_options
        prompt_identity
        state_initialize
    fi
    run_target_install
}

run_continue() {
    local requested_tier="$TIER" local_state=0 target_state=0 answer
    discover_arch_mountpoint
    if ((DRY_RUN)); then
        if [[ -z "$STATE_FILE" ]]; then
            [[ -r "$DEFAULT_STATE_FILE" ]] && local_state=1
            [[ -r "$TARGET_MOUNT$DEFAULT_STATE_FILE" ]] && target_state=1
            ((local_state + target_state < 2)) || die "multiple state files found; select one with --state-file"
            if ((local_state)); then
                STATE_FILE="$DEFAULT_STATE_FILE"
            elif ((target_state)); then
                STATE_FILE="$TARGET_MOUNT$DEFAULT_STATE_FILE"
            fi
        fi
        if [[ -n "$STATE_FILE" && -r "$STATE_FILE" ]]; then
            state_load
            restore_globals_from_state
            promote_tier_if_requested "$requested_tier"
            apply_runtime_overrides
        else
            MODE="new"
            TIER="${TIER:-minimal}"
        fi
        print_dry_plan
        return 0
    fi

    require_root
    ((INTERNAL_CHROOT)) || acquire_run_lock
    if ((INTERNAL_CHROOT)); then
        STATE_FILE="${STATE_FILE:-$DEFAULT_STATE_FILE}"
        state_load
        [[ "${STATE[mode]}" == "new" ]] || die "internal chroot requires new-install state"
        current_root_matches_state || die "internal chroot root does not match persisted identity"
        restore_globals_from_state
        promote_tier_if_requested "$requested_tier"
        apply_runtime_overrides
        run_target_install
        return 0
    fi

    if [[ -z "$STATE_FILE" ]]; then
        [[ -r "$DEFAULT_STATE_FILE" ]] && local_state=1
        [[ -r "$TARGET_MOUNT$DEFAULT_STATE_FILE" ]] && target_state=1
        ((local_state + target_state < 2)) || die "multiple state files found; select one with --state-file"
        if ((local_state)); then
            STATE_FILE="$DEFAULT_STATE_FILE"
        elif ((target_state)); then
            STATE_FILE="$TARGET_MOUNT$DEFAULT_STATE_FILE"
        fi
    fi

    if [[ -n "$STATE_FILE" && -r "$STATE_FILE" ]]; then
        state_load
        if [[ "${STATE[mode]}" == "existing" ]]; then
            [[ "$STATE_FILE" == "$DEFAULT_STATE_FILE" ]] || die "existing-mode state is not on the current root"
            restore_globals_from_state
            promote_tier_if_requested "$requested_tier"
            apply_runtime_overrides
            run_target_install
            return 0
        fi
        if [[ "${STATE[mode]}" == "new" && "$STATE_FILE" == "$DEFAULT_STATE_FILE" && \
            "$(state_stage_status mounts)" != "done" ]]; then
            restore_globals_from_state
            promote_tier_if_requested "$requested_tier"
            apply_runtime_overrides
            route_force_stage_to_chroot
            run_new_host_sequence
            return 0
        fi
        if current_root_matches_state; then
            restore_globals_from_state
            promote_tier_if_requested "$requested_tier"
            apply_runtime_overrides
            run_target_install
            return 0
        fi
        [[ "$STATE_FILE" != "$DEFAULT_STATE_FILE" ]] || die "new-install state does not belong to the current root; use --root-partition from the live environment"
    fi
    if ((ROOT_PARTITION_OPTION_SET == 0)) && { [[ -s /etc/gentoo-release && -x /sbin/openrc-init ]] || arch_is_installed_system; }; then
        MODE=existing
        select_distribution
        if ((NON_INTERACTIVE)); then
            [[ -n "$requested_tier" ]] || \
                die "state-less existing-system adoption requires --tier in non-interactive mode"
        else
            printf 'No installer state was found. Adopt this %s system and inspect its stages? [y/N] ' "$DISTRIBUTION" >/dev/tty
            IFS= read -r answer </dev/tty
            if [[ ! "$answer" =~ ^[yY]([eE][sS])?$ ]]; then
                resume_new_from_host "$requested_tier"
                return 0
            fi
        fi
        MODE="existing"
        TIER="$requested_tier"
        select_tier
        [[ "$DISTRIBUTION" != arch ]] || arch_select_install_options
        prompt_identity
        STATE_FILE="$DEFAULT_STATE_FILE"
        state_initialize
        run_target_install
        return 0
    fi
    resume_new_from_host "$requested_tier"
}

configure_sequences() {
    local distribution="$1" group entry
    for group in HOST MINIMAL EXISTING DWL FULL; do
        local -n current="${group}_SEQUENCE" original="GENTOO_${group}_SEQUENCE"
        current=("${original[@]}")
        unset -n current original
    done
    if [[ "$distribution" == arch ]]; then
        HOST_SEQUENCE=(
            host-preflight:arch_host_preflight:arch_validate_host
            disk:partition_target_disk:validate_disk_stage
            filesystems:format_target_filesystems:validate_filesystems_stage
            mounts:phase_mounts:arch_validate_mounts
            bootstrap:arch_bootstrap:arch_validate_bootstrap
            target-setup:arch_target_setup:arch_validate_target_setup
            chroot-mounts:phase_chroot_mounts:validate_chroot_mounts
            chroot-install:phase_chroot_install:validate_chroot_install
        )
        MINIMAL_SEQUENCE=(
            target-preflight:arch_target_preflight:arch_validate_target
            repositories:arch_repositories:arch_validate_repositories
            base-packages:arch_base_packages:arch_validate_base
            system-config:arch_system_config:arch_validate_system
            accounts:arch_accounts:arch_validate_accounts
            account-shell:phase_user_shell:validate_user_shell
            aur-helper:arch_yay:arch_validate_yay
            snapshots:arch_snapshots:arch_validate_snapshots
            boot:arch_boot:arch_validate_boot
            minimal-complete:phase_marker:validate_minimal_complete
        )
        EXISTING_SEQUENCE=(
            existing-preflight:arch_existing_preflight:arch_validate_existing
            aur-helper:arch_yay:arch_validate_yay
        )
        DWL_SEQUENCE=(
            minimal-to-desktop:arch_approve_desktop:arch_desktop_approved
            display-config:phase_display_config:validate_display_config
            desktop-packages:arch_desktop_packages:arch_validate_desktop
            user-shell:phase_user_shell:validate_user_shell
            public-dotfiles:phase_public_dotfiles:validate_public_dotfiles
            librewolf-setup:phase_librewolf_setup:validate_librewolf_setup
            browser-theme:phase_browser_theme:validate_browser_theme
            browser-extensions:phase_browser_extensions:validate_browser_extensions
            private-dotfiles:phase_private_dotfiles:validate_private_dotfiles
            desktop-complete:phase_marker:arch_validate_desktop_complete
        )
        FULL_SEQUENCE=(
            desktop-to-full:arch_approve_full:arch_full_approved
            full-packages:arch_full_packages:arch_validate_full
            full-public-dotfiles:phase_public_dotfiles:validate_public_dotfiles
            full-browser-theme:phase_browser_theme:validate_browser_theme
            full-browser-extensions:phase_browser_extensions:validate_browser_extensions
            full-private-dotfiles:phase_private_dotfiles:validate_private_dotfiles
            full-complete:phase_marker:arch_validate_full_complete
        )
    fi
    for group in HOST MINIMAL EXISTING DWL FULL; do
        local -n sequence="${group}_SEQUENCE" stages="${group}_STAGES"
        stages=()
        for entry in "${sequence[@]}"; do stages+=("${entry%%:*}"); done
        unset -n sequence stages
    done
}

select_distribution() {
    local choice
    if [[ -z "$DISTRIBUTION" ]]; then
        if [[ "$MODE" == existing ]]; then
            if [[ -s /etc/gentoo-release ]]; then
                DISTRIBUTION=gentoo
            elif arch_is_installed_system; then
                DISTRIBUTION=arch
            else
                die "existing mode needs an installed Gentoo or Arch system"
            fi
        else
            ((NON_INTERACTIVE == 0)) || die "--distribution is required for a non-interactive new installation"
            printf '1) Gentoo\n2) Arch Linux\n'
            read -r -p 'Distribution: ' choice
            case "$choice" in 1) DISTRIBUTION=gentoo ;; 2) DISTRIBUTION=arch ;; *) die "invalid distribution" ;; esac
        fi
    fi
    if [[ "$DISTRIBUTION" == gentoo ]]; then
        ((ARCH_SELECTION_OPTIONS == 0)) || die "desktop/filesystem/boot/repository selectors are Arch-only"
        DESKTOP=dwl
        FILESYSTEM=f2fs
        BOOT_METHOD=efistub
    elif ((MOUNTPOINT_OPTION_SET == 0)); then
        TARGET_MOUNT=/mnt/arch
    fi
    configure_sequences "$DISTRIBUTION"
}

discover_arch_mountpoint() {
    if ((MOUNTPOINT_OPTION_SET == 0)); then
        if [[ "$DISTRIBUTION" == arch || ( ! -r "$TARGET_MOUNT$DEFAULT_STATE_FILE" && -r "/mnt/arch$DEFAULT_STATE_FILE" ) ]]; then
            TARGET_MOUNT=/mnt/arch
        fi
    fi
}

arch_is_installed_system() {
    [[ -e /etc/arch-release && ! -e /run/archiso ]] && command -v pacman >/dev/null
}

arch_select_tier() {
    local choice
    [[ "$TIER" != dwl ]] || die "Arch uses --tier desktop --desktop dwl"
    [[ -z "$TIER" ]] || return 0
    ((NON_INTERACTIVE == 0)) || die "--tier is required"
    if [[ "$MODE" == new ]]; then
        printf '1) Minimal Arch\n2) Minimal Arch + desktop\n3) Full System\n'
        read -r -p 'Installation tier: ' choice
        case "$choice" in 1) TIER=minimal ;; 2) TIER=desktop ;; 3) TIER=full ;; *) die "invalid tier" ;; esac
    else
        printf '1) Desktop\n2) Full System\n'
        read -r -p 'Installation tier: ' choice
        case "$choice" in 1) TIER=desktop ;; 2) TIER=full ;; *) die "invalid tier" ;; esac
    fi
}

arch_select_desktop() {
    local choice
    if [[ "$ARCH_OPTION_NAMES" != *' --desktop '* ]]; then
        ((NON_INTERACTIVE == 0)) || die "--desktop dwl|hyprland is required"
        printf '1) DWL\n2) Hyprland\n'
        read -r -p 'Desktop: ' choice
        case "$choice" in 1) DESKTOP=dwl ;; 2) DESKTOP=hyprland ;; *) die "invalid desktop" ;; esac
    fi
    [[ "$DESKTOP" == dwl || "$DESKTOP" == hyprland ]] || die "select DWL or Hyprland"
}

arch_select_install_options() {
    local choice detected
    if [[ "$TIER" == minimal && "$ARCH_OPTION_NAMES" != *' --desktop '* ]]; then
        DESKTOP=none
    else
        arch_select_desktop
    fi
    if [[ "$MODE" == existing ]]; then
        arch_is_installed_system || die "existing Arch mode requires an installed Arch system"
        detected=vanilla
        if pacman-conf --repo-list | grep -q '^cachyos'; then detected=cachyos; fi
        [[ "$ARCH_OPTION_NAMES" != *' --repositories '* || "$REPOSITORIES" == "$detected" ]] || die "existing mode retains the configured repositories"
        [[ "$ARCH_OPTION_NAMES" != *' --filesystem '* && "$ARCH_OPTION_NAMES" != *' --boot-method '* ]] || die "existing mode retains its filesystem and boot setup"
        REPOSITORIES="$detected"
        FILESYSTEM=existing
        BOOT_METHOD=existing
        log "Using the existing $REPOSITORIES repositories and boot setup."
        return
    fi
    if [[ "$ARCH_OPTION_NAMES" != *' --filesystem '* ]]; then
        ((NON_INTERACTIVE == 0)) || die "--filesystem is required"
        printf '1) Btrfs (GRUB + Snapper)\n2) F2FS\n'
        read -r -p 'Root filesystem: ' choice
        case "$choice" in 1) FILESYSTEM=btrfs ;; 2) FILESYSTEM=f2fs ;; *) die "invalid filesystem" ;; esac
    fi
    if [[ "$FILESYSTEM" == btrfs ]]; then
        [[ "$ARCH_OPTION_NAMES" != *' --boot-method '* || "$BOOT_METHOD" == grub ]] || die "Btrfs requires GRUB"
        BOOT_METHOD=grub
    elif [[ "$ARCH_OPTION_NAMES" != *' --boot-method '* ]]; then
        ((NON_INTERACTIVE == 0)) || die "--boot-method is required for F2FS"
        printf '1) GRUB\n2) EFISTUB (unified kernel image)\n'
        read -r -p 'Boot method: ' choice
        case "$choice" in 1) BOOT_METHOD=grub ;; 2) BOOT_METHOD=efistub ;; *) die "invalid boot method" ;; esac
    fi
    if [[ "$ARCH_OPTION_NAMES" != *' --repositories '* ]]; then
        ((NON_INTERACTIVE == 0)) || die "--repositories is required"
        printf '1) Vanilla Arch (linux)\n2) CachyOS first, then Arch (linux-cachyos)\n'
        read -r -p 'Repositories: ' choice
        case "$choice" in 1) REPOSITORIES=vanilla ;; 2) REPOSITORIES=cachyos ;; *) die "invalid repositories" ;; esac
    fi
}

arch_validate_state() {
    [[ "${STATE[tier]}" =~ ^(minimal|desktop|full)$ ]] || die "invalid Arch tier"
    [[ ! -v STATE[arch_policy_ref] ]] || arch_policy_revision_is_valid "${STATE[arch_policy_ref]}" || die "invalid saved Arch policy revision"
    [[ "${STATE[desktop]:-}" =~ ^(none|dwl|hyprland)$ ]] || die "invalid saved desktop"
    if [[ "${STATE[mode]}" == existing ]]; then
        [[ "${STATE[filesystem]:-}" == existing && "${STATE[boot_method]:-}" == existing ]] || die "existing state must retain its boot/filesystem setup"
    else
        [[ "${STATE[filesystem]:-}" =~ ^(btrfs|f2fs)$ ]] || die "invalid saved filesystem"
        [[ "${STATE[boot_method]:-}" =~ ^(grub|efistub)$ ]] || die "invalid saved boot method"
        [[ "${STATE[filesystem]}" != btrfs || "${STATE[boot_method]}" == grub ]] || die "Btrfs must use GRUB"
    fi
    [[ "${STATE[repositories]:-}" =~ ^(vanilla|cachyos)$ ]] || die "invalid saved repositories"
    [[ ! -v STATE[arch_cpu] || "${STATE[arch_cpu]}" =~ ^(intel|amd)$ ]] || die "invalid saved CPU family"
    [[ ! -v STATE[arch_isa] || "${STATE[arch_isa]}" =~ ^(baseline|v3)$ ]] || die "invalid saved ISA"
    [[ ! -v STATE[arch_sof] || "${STATE[arch_sof]}" =~ ^(true|false)$ ]] || die "invalid saved SOF selection"
    [[ ! -v STATE[arch_graphics] || "${STATE[arch_graphics]}" =~ ^(intel-legacy|intel-modern|amd|radeon|nvidia-open|nvidia-closed|virtual)(,(intel-legacy|intel-modern|amd|radeon|nvidia-open|nvidia-closed|virtual))*$ ]] || die "invalid saved graphics selection"
}

arch_policy_revision_is_valid() {
    [[ "$1" =~ ^([0-9a-f]{40}|legacy-[0-9a-f]{64})$ ]]
}

select_arch_snapshot() {
    arch_policy_revision_is_valid "$1" || die "invalid resolved Arch policy revision"
    ARCH_POLICY_REF="$1"
    ARCH_DATA="$NEUROARCH_CACHE/$ARCH_POLICY_REF"
}

arch_payload_is_valid() {
    local source="$1" kind="${2:-published}" file directory
    [[ -d "$source" && ! -L "$source" && ! -e "$source/.git" ]] || return 1
    [[ -z "$(find "$source" ! -type d ! -type f -print -quit)" ]] || return 1
    [[ "$kind" == legacy || "$(cat "$source/schema" 2>/dev/null)" == 1 ]] || return 1
    for file in btrfs-subvolumes packages/minimal.list packages/installer-tools.list \
        packages/aur-build.list packages/aur-helper.list \
        pkgbuilds/dwl-neuroleptic/PKGBUILD pkgbuilds/nchat-git/PKGBUILD; do
        [[ -s "$source/$file" && ! -L "$source/$file" ]] || return 1
    done
    for directory in boot pacman system; do
        [[ -d "$source/$directory" && ! -L "$source/$directory" ]] || return 1
    done
}

validate_arch_source() {
    local source="${1:-$ARCH_DATA}" digest hash origin="$NEUROARCH_URL" kind=published
    arch_policy_revision_is_valid "$ARCH_POLICY_REF" || return 1
    if [[ "$ARCH_POLICY_REF" == legacy-* ]]; then origin=legacy-arch; kind=legacy; fi
    [[ "$(readlink -m "$source")" == "$source" ]] || return 1
    root_controls_directory "$source" && arch_payload_is_valid "$source" "$kind" || return 1
    [[ -z "$(find "$source" \( ! -user root -o -perm /022 \) -print -quit)" ]] || return 1
    [[ -f "$source/.install-system-revision" && -s "$source/.install-system-files.sha256" ]] || return 1
    cmp -s "$source/.install-system-revision" <(printf '%s\n%s\n' "$origin" "$ARCH_POLICY_REF") || return 1
    digest="$(portage_source_digest "$source")" || return 1
    [[ "$digest" == "$(cat "$source/.install-system-files.sha256")" ]] || return 1
    if [[ "$kind" == legacy ]]; then
        hash="$(printf '%s\n' "$digest" | sha256sum)" || return 1
        [[ "$ARCH_POLICY_REF" == "legacy-${hash%% *}" ]] || return 1
    fi
    return 0
}

legacy_arch_source() {
    local source
    local -a candidates=()
    if [[ "$STATE_FILE" == "$TARGET_MOUNT$DEFAULT_STATE_FILE" ]]; then
        candidates+=("$TARGET_MOUNT/usr/local/share/install-system/arch")
    else
        candidates+=(/usr/local/share/install-system/arch)
    fi
    candidates+=("$(dirname "$SCRIPT_PATH")/packaging/arch")
    for source in "${candidates[@]}"; do
        [[ -e "$source" || -L "$source" ]] || continue
        arch_payload_is_valid "$source" legacy || die "saved Arch inputs are incomplete or unsafe: $source"
        printf '%s' "$source"
        return 0
    done
    return 1
}

ensure_arch_source() {
    local save_state="${1:-yes}" source="" ref remote_ref digest
    local origin="$NEUROARCH_URL" kind=published parent work target_source
    if [[ -v STATE[arch_policy_ref] ]]; then
        select_arch_snapshot "${STATE[arch_policy_ref]}"
    elif ((ARCH_LEGACY_STATE)); then
        source="$(legacy_arch_source)" || die "original Arch inputs are missing; restore them before resuming this legacy record"
        digest="$(portage_source_digest "$source")" || die "could not verify original Arch inputs"
        ref="$(printf '%s\n' "$digest" | sha256sum)"
        select_arch_snapshot "legacy-${ref%% *}"
    else
        require_command git
        remote_ref="$(git ls-remote --exit-code "$NEUROARCH_URL" "refs/heads/$NEUROARCH_BRANCH")" || \
            die "could not resolve neuroarch/$NEUROARCH_BRANCH"
        select_arch_snapshot "${remote_ref%%[[:space:]]*}"
    fi
    if [[ "$ARCH_POLICY_REF" == legacy-* ]]; then origin=legacy-arch; kind=legacy; fi
    if ! validate_arch_source; then
        [[ ! -e "$ARCH_DATA" && ! -L "$ARCH_DATA" ]] || \
            die "cached Arch policy has changed; preserve/review it before continuing: $ARCH_DATA"
        target_source="$TARGET_MOUNT$ARCH_DATA"
        if [[ -e "$target_source" || -L "$target_source" ]]; then
            validate_arch_source "$target_source" || die "target Arch policy has changed; preserve/review it before continuing"
            source="$target_source"
        elif [[ "$kind" == legacy ]]; then
            [[ -n "$source" ]] || source="$(legacy_arch_source)" || die "original Arch inputs are missing; restore them before resuming"
            digest="$(portage_source_digest "$source")" || die "could not verify original Arch inputs"
            ref="$(printf '%s\n' "$digest" | sha256sum)"
            [[ "$ARCH_POLICY_REF" == "legacy-${ref%% *}" ]] || die "original Arch inputs differ from the saved policy; preserve/review them"
        fi
        parent="$(dirname "$ARCH_DATA")"
        [[ "$(readlink -m "$parent")" == "$parent" ]] || die "symlinked Arch snapshot parent"
        install -d -m 0755 "$parent"
        root_controls_directory "$parent" || die "Arch snapshot parent is not controlled by root"
        work="$(mktemp -d "$parent/.prepare.XXXXXX")"
        if ! (
            if [[ -n "$source" ]]; then
                mkdir "$work/tree" || exit 1
                cp -a --no-preserve=ownership "$source/." "$work/tree/" || exit 1
            else
                git clone --no-checkout --branch "$NEUROARCH_BRANCH" "$NEUROARCH_URL" "$work/git" || exit 1
                git -C "$work/git" cat-file -e "$ARCH_POLICY_REF^{commit}" 2>/dev/null || \
                    git -C "$work/git" fetch origin "$ARCH_POLICY_REF" || exit 1
                mkdir "$work/tree" || exit 1
                git -C "$work/git" archive "$ARCH_POLICY_REF" | tar -xf - -C "$work/tree" || exit 1
            fi
            arch_payload_is_valid "$work/tree" "$kind" || exit 1
            printf '%s\n%s\n' "$origin" "$ARCH_POLICY_REF" >"$work/tree/.install-system-revision" || exit 1
            portage_source_digest "$work/tree" >"$work/tree/.install-system-files.sha256" || exit 1
            chmod -R u=rwX,go=rX "$work/tree" || exit 1
            validate_arch_source "$work/tree" || exit 1
        ); then
            rm -rf --one-file-system -- "$work"
            die "Arch policy could not be prepared; neuroarch/$NEUROARCH_BRANCH must provide schema 1"
        fi
        mv -T -- "$work/tree" "$ARCH_DATA"
        rm -rf --one-file-system -- "$work"
        validate_arch_source || die "Arch snapshot verification failed"
    fi
    if [[ "$save_state" == yes && ! -v STATE[arch_policy_ref] ]]; then state_set arch_policy_ref "$ARCH_POLICY_REF"; fi
    ARCH_LEGACY_STATE=0
}

copy_arch_source_to_target() (
    local destination="$TARGET_MOUNT$ARCH_DATA" parent temporary
    validate_arch_source || die "host Arch snapshot is invalid"
    if [[ -e "$destination" || -L "$destination" ]]; then
        validate_arch_source "$destination" || die "target Arch snapshot has changed; preserve/review it"
        return 0
    fi
    parent="$(dirname "$destination")"
    [[ "$(readlink -m "$parent")" == "$parent" ]] || die "symlinked target Arch snapshot parent"
    install -d -m 0755 "$parent"
    root_controls_directory "$parent" || die "target Arch snapshot parent is not controlled by root"
    temporary="$(mktemp -d "$parent/.copy.XXXXXX")"
    trap 'rm -rf --one-file-system -- "$temporary"' EXIT
    cp -a --no-preserve=ownership "$ARCH_DATA/." "$temporary" || die "could not copy Arch snapshot"
    validate_arch_source "$temporary" || die "copied Arch snapshot failed verification"
    mv -T -- "$temporary" "$destination"
)

arch_read_list() {
    local file="$ARCH_DATA/$1" line
    [[ -f "$file" && ! -L "$file" ]] || { warn "missing list: $file"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        [[ "$line" =~ ^[[:space:]]*$ ]] || printf '%s\n' "$line"
    done <"$file"
}

arch_package_names() {
    local list entries package extra
    for list in "$@"; do
        entries="$(arch_read_list "packages/$list.list")" || return 1
        [[ -n "$entries" ]] || return 1
        while read -r package extra; do
            [[ "$package" =~ ^[a-zA-Z0-9@_+][a-zA-Z0-9@._+-]*$ && -z "$extra" ]] || return 1
            printf '%s\n' "$package"
        done <<<"$entries"
    done
}

arch_check_lists() {
    local packages package
    packages="$(arch_package_names "$@")" || return 1
    while IFS= read -r package; do
        pacman -Qk "$package" >/dev/null 2>&1 || return 1
    done <<<"$packages"
}

arch_user_command() {
    # AUR builds keep a terminal for interactive makepkg/yay prompts.
    local cpus memory jobs
    user_home_is_safe || die "unsafe target home"
    cpus="$(nproc)"
    memory="$(awk '/^MemTotal:/ {print int(($2 - 1048576) / 2097152)}' /proc/meminfo)"
    jobs=$((memory < cpus ? memory : cpus))
    ((jobs > 0)) || jobs=1
    run runuser -u "$USERNAME" -- env -i HOME="/home/$USERNAME" USER="$USERNAME" LOGNAME="$USERNAME" \
        PATH="/home/$USERNAME/.local/bin:/home/$USERNAME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
        SHELL=/bin/bash TERM="${TERM:-linux}" LANG=C.UTF-8 "MAKEFLAGS=-j$jobs" \
        "CMAKE_BUILD_PARALLEL_LEVEL=$jobs" "CARGO_BUILD_JOBS=$jobs" "GOMAXPROCS=$jobs" "$@"
}

arch_install_lists() {
    local packages package
    local -a native=() aur=()
    packages="$(arch_package_names "$@")" || die "invalid Arch package list"
    while IFS= read -r package; do
        if [[ "${FORCE_STAGE:-none}" != "$CURRENT_STAGE" ]] && pacman -Qk "$package" >/dev/null 2>&1; then continue; fi
        if pacman -Si "$package" >/dev/null 2>&1; then native+=("$package"); else aur+=("$package"); fi
    done <<<"$packages"
    ((${#native[@]} == 0)) || run pacman -S --noconfirm "${native[@]}"
    if ((${#aur[@]})); then
        command -v yay >/dev/null || die "packages require yay before this stage: ${aur[*]}"
        arch_user_command yay -S "${aur[@]}"
    fi
}

arch_local_packages() {
    local packages package build dotfiles_ref rebuild=0
    packages="$(arch_package_names "$@")" || die "invalid local package list"
    arch_local_outputs "$@" || rebuild=1
    while IFS= read -r package; do
        if ((rebuild == 0)) && [[ "${FORCE_STAGE:-none}" != "$CURRENT_STAGE" ]] && pacman -Qk "$package" >/dev/null 2>&1; then continue; fi
        [[ -s "$ARCH_DATA/pkgbuilds/$package/PKGBUILD" ]] || die "missing PKGBUILD for $package"
        build="$(run_as_user mktemp -d "/home/$USERNAME/.cache/install-system/${package}.XXXXXX")"
        install -m 0644 "$ARCH_DATA/pkgbuilds/$package/PKGBUILD" "$build/PKGBUILD"
        chown "$USERNAME:$(id -gn "$USERNAME")" "$build/PKGBUILD"
        if [[ "$package" == dwl-neuroleptic ]]; then
            dotfiles_ref="$(public_dotfiles_revision)" || die "could not resolve the synchronized public dotfiles revision"
            arch_user_command env "DWL_DOTFILES_REF=$dotfiles_ref" \
                bash -c 'cd "$1" && makepkg --syncdeps --install --clean --force' bash "$build"
        else
            arch_user_command bash -c 'cd "$1" && makepkg --syncdeps --install --clean --force' bash "$build"
        fi
    done <<<"$packages"
}

arch_local_outputs() {
    local list files path
    for list in "$@"; do
        files="$(arch_read_list "packages/$list.required")" || return 1
        while IFS= read -r path; do [[ -s "$path" ]] || return 1; done <<<"$files"
    done
}

arch_prepare_hardware() {
    local device
    if [[ ! -v STATE[arch_cpu] ]]; then
        if grep -q GenuineIntel /proc/cpuinfo; then STATE[arch_cpu]=intel;
        elif grep -q AuthenticAMD /proc/cpuinfo; then STATE[arch_cpu]=amd;
        else die "CPU vendor is neither Intel nor AMD"; fi
    fi
    if [[ ! -v STATE[arch_isa] ]]; then
        STATE[arch_isa]=baseline
        if /lib/ld-linux-x86-64.so.2 --help | grep -q 'x86-64-v3 (supported, searched)'; then STATE[arch_isa]=v3; fi
    fi
    if [[ ! -v STATE[arch_sof] ]]; then
        STATE[arch_sof]=false
        for device in /sys/bus/pci/devices/*/driver; do
            [[ "$(basename "$(readlink -f "$device")")" != sof-* ]] || STATE[arch_sof]=true
        done
    fi
    [[ -n "$GRAPHICS" ]] || GRAPHICS="${STATE[arch_graphics]:-}"
    ensure_hardware_plan
    if [[ "$(hardware_field graphics.families)" != '[]' ]]; then
        STATE[arch_graphics]="$(hardware_field graphics.families | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)))')"
    fi
    state_write
}

copy_common_data() {
    local destination="$TARGET_MOUNT/usr/local/share/install-system/common"
    [[ -s "$COMMON_DATA/hardware.py" && -s "$COMMON_DATA/displays.py" && -s "$COMMON_DATA/browser-extensions.sh" ]] || die "keep packaging/common beside the installer"
    install -d -m 0755 "$(dirname "$destination")"
    if [[ -d "$destination" ]]; then
        common_data_matches "$destination" || die "shared installation inputs differ; resume with matching inputs"
    else
        cp -a --no-preserve=ownership "$COMMON_DATA" "$destination"
        chmod -R u=rwX,go=rX "$destination"
    fi
}

common_data_matches() {
    [[ -d "$1" ]] && cmp -s <(portage_source_digest "$COMMON_DATA") <(portage_source_digest "$1")
}

arch_base_lists() {
    printf '%s\n' minimal installer-tools "kernel/$REPOSITORIES" "hardware/${STATE[arch_cpu]}" "filesystem/$FILESYSTEM" "boot/$BOOT_METHOD"
    [[ "${STATE[arch_sof]:-false}" != true ]] || printf '%s\n' hardware/sof
}

arch_desktop_lists() {
    local family
    local -a families=()
    printf '%s\n' desktop "desktop/$DESKTOP"
    IFS=, read -r -a families <<<"${STATE[arch_graphics]}"
    for family in "${families[@]}"; do
        [[ "$family" != amd ]] || family=amd-gpu
        printf '%s\n' "hardware/$family"
    done
    [[ "${STATE[arch_graphics]}" != *nvidia* ]] || printf '%s\n' "kernel/$REPOSITORIES-headers"
}

arch_host_tools() {
    printf '%s\n' pacstrap pacman pacman-key blkid chroot cmp curl diff findmnt flock git \
        lsblk mkfs.vfat mount mountpoint parted partprobe python3 readlink sha256sum \
        tar udevadm umount wipefs "mkfs.$FILESYSTEM"
    [[ "$FILESYSTEM" != btrfs ]] || printf '%s\n' btrfs
}

arch_validate_host() {
    local tool tools
    [[ "$(uname -m)" == x86_64 && -d /sys/firmware/efi ]] || return 1
    tools="$(arch_host_tools)" || return 1
    for tool in $tools; do command -v "$tool" >/dev/null || return 1; done
    validate_arch_source
}

arch_host_preflight() {
    require_root
    ensure_arch_source
    arch_validate_host || die "Arch new mode needs an x86_64 UEFI Arch ISO, arch-install-scripts, filesystem tools and valid neuroarch inputs"
    python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || die "Python 3.9+ is required"
    # Fail on missing/malformed selection files before touching the target disk.
    local lists
    local -a selected=()
    arch_prepare_hardware
    lists="$(arch_base_lists)"
    mapfile -t selected <<<"$lists"
    arch_package_names "${selected[@]}" >/dev/null || die "Arch base package lists are incomplete"
}

arch_mount_root() {
    local subvolume path layout
    if ! mountpoint -q "$TARGET_MOUNT"; then
        target_mount_tree_is_empty || die "target has mounted descendants"
        ensure_target_mount_directory
        if [[ "$FILESYSTEM" == btrfs ]]; then
            run mount -o subvolid=5 "$ROOT_PARTITION" "$TARGET_MOUNT"
            remember_mount "$TARGET_MOUNT"
            layout="$(arch_read_list btrfs-subvolumes)"
            while read -r subvolume path; do
                if ! btrfs subvolume show "$TARGET_MOUNT/$subvolume" >/dev/null 2>&1; then
                    [[ ! -e "$TARGET_MOUNT/$subvolume" ]] || die "Btrfs subvolume path is occupied: $subvolume"
                    run btrfs subvolume create "$TARGET_MOUNT/$subvolume"
                fi
            done <<<"$layout"
            run umount "$TARGET_MOUNT"
            forget_mount "$TARGET_MOUNT"
            run mount -o noatime,compress=zstd,subvol=@ "$ROOT_PARTITION" "$TARGET_MOUNT"
        else
            run mount -o noatime "$ROOT_PARTITION" "$TARGET_MOUNT"
        fi
        remember_mount "$TARGET_MOUNT"
    fi
    [[ "$(findmnt -rn -o UUID -T "$TARGET_MOUNT")" == "${STATE[root_uuid]}" ]] || die "wrong root mounted at $TARGET_MOUNT"
    if [[ "$FILESYSTEM" == btrfs ]]; then
        [[ "$(findmnt -rn -o FSROOT -T "$TARGET_MOUNT")" == /@ ]] || die "target root must be the @ subvolume"
        layout="$(arch_read_list btrfs-subvolumes)"
        while read -r subvolume path; do
            [[ "$path" != / ]] || continue
            install -d -m 0755 "$TARGET_MOUNT$path"
            if ! mountpoint -q "$TARGET_MOUNT$path"; then
                run mount -o "noatime,compress=zstd,subvol=$subvolume" "$ROOT_PARTITION" "$TARGET_MOUNT$path"
                remember_mount "$TARGET_MOUNT$path"
            fi
            [[ "$(findmnt -rn -o FSROOT -T "$TARGET_MOUNT$path")" == "/$subvolume" &&
               "$(findmnt -rn -o UUID -T "$TARGET_MOUNT$path")" == "${STATE[root_uuid]}" ]] || die "wrong subvolume mounted at $path"
        done <<<"$layout"
    fi
}

arch_validate_mounts() {
    local subvolume path layout
    validate_mounts_stage || return 1
    [[ "$(findmnt -rn -o UUID -T "$TARGET_MOUNT")" == "${STATE[root_uuid]}" ]] || return 1
    if [[ "$FILESYSTEM" == btrfs ]]; then
        layout="$(arch_read_list btrfs-subvolumes)" || return 1
        while read -r subvolume path; do
            [[ "$(findmnt -rn -o FSROOT -T "$TARGET_MOUNT${path%/}")" == "/$subvolume" &&
               "$(findmnt -rn -o UUID -T "$TARGET_MOUNT${path%/}")" == "${STATE[root_uuid]}" ]] || return 1
        done <<<"$layout"
    fi
}

arch_pacman_config() {
    local repositories="${1:-$REPOSITORIES}" isa="${2:-${STATE[arch_isa]:-baseline}}"
    cat "$ARCH_DATA/pacman/options.conf"
    if [[ "$repositories" == cachyos ]]; then
        [[ "$isa" != v3 ]] || cat "$ARCH_DATA/pacman/cachyos-v3.conf"
        cat "$ARCH_DATA/pacman/cachyos.conf"
    fi
    cat "$ARCH_DATA/pacman/vanilla.conf"
}

arch_bootstrap() {
    local config packages
    local -a selected=()
    packages="$(arch_package_names minimal installer-tools)" || die "missing bootstrap package list"
    mapfile -t selected <<<"$packages"
    config="$(dirname "$STATE_FILE")/bootstrap-pacman.conf"
    arch_pacman_config vanilla | write_file "$config" 0644
    # Never inherit a live system's repositories or mirror/key configuration.
    run pacstrap -K -M -C "$config" "$TARGET_MOUNT" "${selected[@]}"
}

arch_validate_bootstrap() {
    local packages
    local -a selected=()
    [[ -e "$TARGET_MOUNT/etc/arch-release" && -x "$TARGET_MOUNT/usr/bin/bash" ]] || return 1
    packages="$(arch_package_names minimal installer-tools)" || return 1
    mapfile -t selected <<<"$packages"
    pacman --root "$TARGET_MOUNT" -Qk "${selected[@]}" >/dev/null 2>&1
}

arch_fstab_contents() {
    local subvolume path layout
    if [[ "$FILESYSTEM" == btrfs ]]; then
        layout="$(arch_read_list btrfs-subvolumes)" || return 1
        while read -r subvolume path; do
            printf 'UUID=%s %s btrfs noatime,compress=zstd,subvol=%s 0 0\n' "${STATE[root_uuid]}" "$path" "$subvolume"
        done <<<"$layout"
    else
        printf 'UUID=%s / f2fs defaults,noatime 0 1\n' "${STATE[root_uuid]}"
    fi
    printf 'UUID=%s /efi vfat umask=0077 0 2\n' "${STATE[boot_uuid]}"
}

arch_target_setup() {
    mount_target_boot
    copy_common_data
    copy_arch_source_to_target
    install -d -m 0755 "$TARGET_MOUNT/usr/local/sbin"
    if [[ -f "$TARGET_MOUNT/etc/fstab" ]] && grep -Eq '^[[:space:]]*[^#[:space:]]' "$TARGET_MOUNT/etc/fstab"; then
        cmp -s "$TARGET_MOUNT/etc/fstab" <(arch_fstab_contents) || die "target /etc/fstab differs from the selected layout; review it before continuing"
    fi
    run install -m 0755 "$SCRIPT_PATH" "$TARGET_MOUNT/usr/local/sbin/install-system"
    # The chroot has a private /run. Use the live resolver's contents, never an
    # absolute symlink into a resolved runtime directory that is absent there.
    [[ ! -L "$TARGET_MOUNT/etc/resolv.conf" ]] || rm -- "$TARGET_MOUNT/etc/resolv.conf"
    cp -L /etc/resolv.conf "$TARGET_MOUNT/etc/resolv.conf"
    if [[ ! -f "$TARGET_MOUNT/var/lib/install-system/arch-managed/etc/pacman.conf.sha256" ]]; then
        arch_pacman_config vanilla | write_file "$TARGET_MOUNT/etc/pacman.conf" 0644
    fi
    arch_fstab_contents | write_file "$TARGET_MOUNT/etc/fstab" 0644
}

arch_validate_target_setup() {
    cmp -s "$SCRIPT_PATH" "$TARGET_MOUNT/usr/local/sbin/install-system" &&
        common_data_matches "$TARGET_MOUNT/usr/local/share/install-system/common" &&
        validate_arch_source "$TARGET_MOUNT$ARCH_DATA" &&
        cmp -s "$TARGET_MOUNT/etc/fstab" <(arch_fstab_contents) &&
        findmnt -rn -S "$BOOT_PARTITION" -M "$TARGET_MOUNT/efi" >/dev/null &&
        [[ ! -L "$TARGET_MOUNT/etc/resolv.conf" ]] && cmp -s /etc/resolv.conf "$TARGET_MOUNT/etc/resolv.conf"
}

arch_target_preflight() {
    require_root
    [[ -e /etc/arch-release ]] || die "target is not Arch Linux"
    validate_persisted_devices
    current_root_matches_state || die "target root does not match saved identity"
    state_write
}

arch_validate_target() {
    [[ -e /etc/arch-release ]] && validate_arch_source && command -v pacman >/dev/null && current_root_matches_state
}

arch_managed_file() {
    local path="$1" mode="${2:-0644}" contents hash previous
    local receipt="/var/lib/install-system/arch-managed$1.sha256"
    contents="$(cat)"
    [[ ! -L "$path" ]] || die "managed system file is a symlink: $path"
    if [[ -e "$path" ]] && ! cmp -s "$path" <(printf '%s\n' "$contents"); then
        hash="$(sha256sum "$path")"
        previous="$(cat "$receipt" 2>/dev/null || true)"
        if [[ "$previous" != "${hash%% *}" ]]; then
            [[ "$MODE" == new && ! -e "$receipt" && ! -e "$path.pre-install-system" ]] || die "local configuration differs: $path"
            cp -p -- "$path" "$path.pre-install-system"
        fi
    fi
    printf '%s\n' "$contents" | write_file "$path" "$mode"
    hash="$(sha256sum "$path")"
    printf '%s\n' "${hash%% *}" | write_file "$receipt" 0600
}

arch_system_layer() {
    local action="$1" layer="$2" file relative
    [[ -d "$ARCH_DATA/system/$layer" ]] || return 1
    while IFS= read -r -d '' file; do
        relative="${file#"$ARCH_DATA/system/$layer"}"
        if [[ "$action" == apply ]]; then
            arch_managed_file "$relative" <"$file"
        else
            cmp -s "$file" "$relative" || return 1
        fi
    done < <(find "$ARCH_DATA/system/$layer" -type f ! -name services -print0)
}

arch_services() {
    local action="$1" layer="$2" services service
    services="$(arch_read_list "system/$layer/services")" || return 1
    while IFS= read -r service; do
        if [[ "$action" == apply ]]; then run systemctl --root=/ enable "$service";
        else systemctl --root=/ is-enabled --quiet "$service" || return 1; fi
    done <<<"$services"
}

arch_repositories() {
    local key packages
    local -a selected=()
    if [[ "$REPOSITORIES" == cachyos ]]; then
        key="$(arch_read_list pacman/cachyos-key)"
        [[ "$key" =~ ^[0-9A-F]{40}$ ]] || die "invalid CachyOS key fingerprint"
        run pacman-key --recv-keys "$key" --keyserver hkps://keyserver.ubuntu.com
        run pacman-key --lsign-key "$key"
    fi
    if [[ "$REPOSITORIES" == cachyos ]]; then
        # Bootstrap signing keys and the architecture-aware package manager from
        # the baseline repository before enabling optimized packages.
        arch_pacman_config cachyos baseline | arch_managed_file /etc/pacman.conf
        packages="$(arch_package_names repositories/cachyos)"
        mapfile -t selected <<<"$packages"
        run pacman -Sy --noconfirm "${selected[@]/#/cachyos/}"
        run pacman-key --populate cachyos
    fi
    arch_pacman_config | arch_managed_file /etc/pacman.conf
    run pacman -Syu --noconfirm
}

arch_validate_repositories() {
    cmp -s /etc/pacman.conf <(arch_pacman_config) || return 1
    [[ "$REPOSITORIES" != cachyos ]] || arch_check_lists repositories/cachyos
}

arch_base_packages() {
    local lists
    local -a selected=()
    lists="$(arch_base_lists)"
    mapfile -t selected <<<"$lists"
    arch_install_lists "${selected[@]}"
}

arch_validate_base() {
    local lists
    local -a selected=()
    lists="$(arch_base_lists)" || return 1
    mapfile -t selected <<<"$lists"
    arch_check_lists "${selected[@]}"
}

arch_system_config() {
    printf '%s\n' "$HOSTNAME_VALUE" | arch_managed_file /etc/hostname
    printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' "$HOSTNAME_VALUE" "$HOSTNAME_VALUE" | arch_managed_file /etc/hosts
    [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "timezone does not exist"
    ln -sfn "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    printf 'en_US.UTF-8 UTF-8\n' | arch_managed_file /etc/locale.gen
    printf 'LANG=en_US.UTF-8\n' | arch_managed_file /etc/locale.conf
    run locale-gen
    run hwclock --systohc --utc
    run systemd-machine-id-setup
    arch_system_layer apply minimal
    arch_services apply minimal
    # The external tmpfiles rule selects resolved at boot. Retain the live
    # resolver now, so subsequent chroot package downloads still have DNS.
}

arch_validate_system() {
    [[ "$(cat /etc/hostname)" == "$HOSTNAME_VALUE" &&
       "$(readlink -f /etc/localtime)" == "/usr/share/zoneinfo/$TIMEZONE" && -r /etc/resolv.conf ]] &&
        grep -qx 'LANG=en_US.UTF-8' /etc/locale.conf && locale -a | grep -qi '^en_US.utf8$' &&
        arch_system_layer check minimal && arch_services check minimal &&
        cmp -s /etc/fstab <(arch_fstab_contents) && findmnt --verify --tab-file /etc/fstab >/dev/null
}

arch_accounts() {
    if ! getent passwd "$USERNAME" >/dev/null; then
        run useradd --create-home --user-group --groups wheel --shell /bin/zsh "$USERNAME"
    fi
    user_home_is_safe || die "unsafe target user"
    [[ "$(readlink -f "$(getent passwd "$USERNAME" | cut -d: -f7)")" == "$(readlink -f /bin/zsh)" ]] || die "target shell differs; review the existing account"
    run usermod --append --groups wheel "$USERNAME"
    # Passwordless like Gentoo's doas policy and the user's existing Arch setup.
    printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' | arch_managed_file /etc/sudoers.d/10-install-system 0440
    run visudo -cf /etc/sudoers
    run_as_user install -d -m 0755 "/home/$USERNAME/.local/bin" "/home/$USERNAME/.cache/install-system"
    apply_collected_password
}

arch_validate_accounts() {
    user_home_is_safe && [[ " $(id -nG "$USERNAME") " == *' wheel '* ]] &&
        [[ "$(readlink -f "$(getent passwd "$USERNAME" | cut -d: -f7)")" == "$(readlink -f /bin/zsh)" ]] &&
        [[ -d "/home/$USERNAME/.cache/install-system" ]] &&
        grep -qxF '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' /etc/sudoers.d/10-install-system &&
        visudo -cf /etc/sudoers >/dev/null && account_password_is_set root && account_password_is_set "$USERNAME"
}

arch_yay() {
    local helper build
    arch_install_lists aur-build
    if [[ "${FORCE_STAGE:-none}" != "$CURRENT_STAGE" ]] && arch_check_lists aur-helper && [[ -x /usr/bin/yay ]]; then
        return 0
    fi
    helper="$(arch_package_names aur-helper)"
    if pacman -Si "$helper" >/dev/null 2>&1; then
        run pacman -S --noconfirm "$helper"
    else
        run_as_user install -d -m 0755 "/home/$USERNAME/.cache/install-system"
        build="$(run_as_user mktemp -d "/home/$USERNAME/.cache/install-system/yay.XXXXXX")"
        run_as_user git clone "https://aur.archlinux.org/$helper.git" "$build"
        arch_user_command bash -c 'cd "$1" && makepkg --syncdeps --install --clean' bash "$build"
    fi
}

arch_validate_yay() {
    arch_check_lists aur-build aur-helper && [[ -x /usr/bin/yay ]]
}

arch_snapshots() {
    [[ "$FILESYSTEM" == btrfs ]] || return 0
    arch_install_lists filesystem/btrfs-aur
    # The flat @snapshots subvolume already exists; native configuration avoids
    # create-config trying to create a second, nested .snapshots subvolume.
    arch_system_layer apply btrfs
    printf 'SNAPPER_CONFIGS="root"\n' | arch_managed_file /etc/conf.d/snapper
    cat <<EOF | arch_managed_file /etc/snapper-rollback.conf
[root]
subvol_main = @
subvol_snapshots = @snapshots
mountpoint = /btrfsroot
dev = /dev/disk/by-uuid/${STATE[root_uuid]}
EOF
    chmod 0750 /.snapshots
    arch_services apply btrfs
    run snapper --no-dbus -c root list
}

arch_validate_snapshots() {
    [[ "$FILESYSTEM" == btrfs ]] || return 0
    arch_check_lists filesystem/btrfs-aur && arch_system_layer check btrfs &&
        [[ "$(findmnt -rn -o FSROOT -M /.snapshots)" == /@snapshots &&
           "$(findmnt -rn -o UUID -M /.snapshots)" == "${STATE[root_uuid]}" ]] &&
        grep -qxF 'SNAPPER_CONFIGS="root"' /etc/conf.d/snapper &&
        grep -qxF "dev = /dev/disk/by-uuid/${STATE[root_uuid]}" /etc/snapper-rollback.conf &&
        arch_services check btrfs && snapper --no-dbus -c root list >/dev/null
}

arch_kernel() {
    arch_package_names "kernel/$REPOSITORIES"
}

arch_preset_contents() {
    local kernel
    kernel="$(arch_kernel)" || return 1
    printf 'ALL_config="/etc/mkinitcpio.conf"\nALL_kver="/boot/vmlinuz-%s"\nPRESETS=(default)\n' "$kernel"
    if [[ "$BOOT_METHOD" == efistub ]]; then
        printf 'default_uki="/efi/EFI/BOOT/BOOTX64.EFI"\n'
    else
        printf 'default_image="/boot/initramfs-%s.img"\n' "$kernel"
    fi
}

arch_efi_loader() {
    if [[ "$BOOT_METHOD" == grub ]]; then printf '%s' '\EFI\Arch\grubx64.efi';
    else printf '%s' '\EFI\BOOT\BOOTX64.EFI'; fi
}

arch_efi_entry_exists() {
    local output loader line uuid="${STATE[boot_partuuid],,}"
    loader="$(arch_efi_loader)"
    output="$(efibootmgr -v)" || return 1
    while IFS= read -r line; do
        line="${line,,}"
        [[ "$line" != *arch* || "$line" != *"$uuid"* || "$line" != *"${loader,,}"* ]] || return 0
    done <<<"$output"
    return 1
}

arch_boot() {
    local kernel config=mkinitcpio.conf parent number
    kernel="$(arch_kernel)"
    findmnt -rn -S "$BOOT_PARTITION" -M /efi >/dev/null || die "/efi is not the saved ESP"
    [[ "$FILESYSTEM" != btrfs ]] || config=mkinitcpio-btrfs.conf
    arch_managed_file /etc/mkinitcpio.conf <"$ARCH_DATA/boot/$config"
    arch_preset_contents | arch_managed_file "/etc/mkinitcpio.d/$kernel.preset"
    if [[ "$BOOT_METHOD" == efistub ]]; then
        install -d -m 0755 /efi/EFI/BOOT
        printf 'root=UUID=%s rw rootfstype=f2fs\n' "${STATE[root_uuid]}" | arch_managed_file /etc/kernel/cmdline
    fi
    run mkinitcpio -P
    if [[ "$BOOT_METHOD" == grub ]]; then
        run grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Arch --no-nvram
        run grub-install --target=x86_64-efi --efi-directory=/efi --removable --no-nvram
        arch_system_layer apply grub
        if [[ "$FILESYSTEM" == btrfs ]]; then
            run snapper --no-dbus -c root create --description 'install-system: bootable system' --cleanup-algorithm number
        fi
        run grub-mkconfig -o /boot/grub/grub.cfg
    fi
    if [[ "$CREATE_EFI_ENTRY" == yes ]] && ! arch_efi_entry_exists; then
        parent="$(lsblk -nro PKNAME "$BOOT_PARTITION")"
        number="$(lsblk -nro PARTN "$BOOT_PARTITION")"
        [[ -n "$parent" && "$number" =~ ^[0-9]+$ ]] || die "cannot resolve ESP disk/partition"
        run efibootmgr -c -d "/dev/$parent" -p "$number" -L Arch -l "$(arch_efi_loader)"
    fi
}

arch_validate_boot() {
    local kernel config=mkinitcpio.conf
    kernel="$(arch_kernel)" || return 1
    [[ "$FILESYSTEM" != btrfs ]] || config=mkinitcpio-btrfs.conf
    cmp -s /etc/mkinitcpio.conf "$ARCH_DATA/boot/$config" &&
        cmp -s "/etc/mkinitcpio.d/$kernel.preset" <(arch_preset_contents) &&
        findmnt -rn -S "$BOOT_PARTITION" -M /efi >/dev/null &&
        [[ -s "/boot/vmlinuz-$kernel" ]] &&
        efi_pe_image_is_valid /efi/EFI/BOOT/BOOTX64.EFI || return 1
    if [[ "$BOOT_METHOD" == grub ]]; then
        efi_pe_image_is_valid /efi/EFI/Arch/grubx64.efi &&
            [[ -s "/boot/initramfs-$kernel.img" ]] &&
            grep -qF "vmlinuz-$kernel" /boot/grub/grub.cfg &&
            arch_system_layer check grub || return 1
        if [[ "$FILESYSTEM" == btrfs ]]; then
            grep -q 'grub-btrfs' /boot/grub/grub.cfg || return 1
            [[ -s /boot/grub/grub-btrfs.cfg ]] || return 1
        fi
    else
        cmp -s /etc/kernel/cmdline <(printf 'root=UUID=%s rw rootfstype=f2fs\n' "${STATE[root_uuid]}") || return 1
    fi
    [[ "$CREATE_EFI_ENTRY" != yes ]] || arch_efi_entry_exists
}

arch_existing_packages_ready() {
    local upgrades status=0
    # Do not refresh databases here: -Sy followed by selective installs is unsafe.
    # A separately approved full upgrade may replace the base, kernel and boot files.
    upgrades="$(pacman -Qu 2>&1)" || status=$?
    ((status == 0 || status == 1)) && [[ -z "$upgrades" ]]
}

arch_existing_preflight() {
    require_root
    arch_is_installed_system || die "existing mode requires Arch Linux"
    [[ "$(cat /etc/machine-id)" == "${STATE[system_id]}" ]] || die "state belongs to another system"
    user_home_is_safe || die "unsafe target user"
    validate_arch_source || die "invalid saved Arch policy"
    if ! arch_existing_packages_ready; then
        request_wait 'existing mode does not upgrade the base, kernel or boot setup. Review and perform a full pacman -Syu separately, then continue. Do not use pacman -Sy or a partial upgrade.'
        return 0
    fi
    arch_install_lists installer-tools
    run_as_user install -d -m 0755 "/home/$USERNAME/.local/bin" "/home/$USERNAME/.cache/install-system"
    arch_prepare_hardware
}

arch_validate_existing() {
    arch_is_installed_system && arch_existing_packages_ready && arch_check_lists installer-tools && [[ "$(cat /etc/machine-id)" == "${STATE[system_id]}" ]] &&
        user_home_is_safe && [[ -v STATE[arch_cpu] && -v STATE[arch_graphics] &&
            -d "/home/$USERNAME/.cache/install-system" ]]
}

arch_approve_desktop() {
    approve_tier_transition minimal-to-desktop desktop 'Minimal Arch is ready. Continue with the desktop tier?'
    ((PHASE_WAITING == 0)) || return 0
    if [[ "$DESKTOP" == none ]]; then arch_select_desktop; fi
    STATE[desktop]="$DESKTOP"
    state_write
}

arch_desktop_approved() {
    [[ "${STATE[approval.minimal-to-desktop]:-}" == yes && "$DESKTOP" != none ]]
}

arch_approve_full() {
    approve_tier_transition desktop-to-full full "The $DESKTOP desktop is ready. Continue with the full tier?"
}

arch_full_approved() {
    [[ "${STATE[approval.desktop-to-full]:-}" == yes ]]
}

arch_desktop_packages() {
    local lists launcher="/home/$USERNAME/.local/bin/dwl"
    local -a selected=()
    arch_prepare_hardware
    lists="$(arch_desktop_lists)"
    mapfile -t selected <<<"$lists"
    arch_install_lists "${selected[@]}"
    if [[ "$DESKTOP" == dwl ]]; then
        if ! packaged_commands_are_unshadowed dwl; then
            request_wait 'resolve the local DWL executable conflict before continuing'
            return
        fi
        ensure_public_dotfiles_source
        if validate_dwl_package_inputs; then
            arch_local_packages desktop/dwl-local
        else
            FORCE_STAGE="$CURRENT_STAGE" arch_local_packages desktop/dwl-local
        fi
        validate_dwl_package_inputs || die "DWL package inputs differ from the selected canonical patch/protocol"
        if [[ ! -e "$launcher" && ! -L "$launcher" ]]; then run_as_user ln -s /usr/bin/dwl "$launcher"; fi
    fi
    arch_services apply desktop
    # The driver packages' DKMS hooks run normally. Refresh this installation's
    # image after adding the selected graphics modules.
    [[ "$MODE" != new ]] || arch_boot
}

arch_validate_desktop() {
    local lists
    local -a selected=()
    [[ -v STATE[arch_graphics] && "$DESKTOP" != none ]] || return 1
    lists="$(arch_desktop_lists)" || return 1
    mapfile -t selected <<<"$lists"
    arch_check_lists "${selected[@]}" && arch_services check desktop || return 1
    if [[ "$DESKTOP" == dwl ]]; then
        arch_check_lists desktop/dwl-local && arch_local_outputs desktop/dwl-local && validate_dwl_package_inputs &&
            packaged_commands_are_unshadowed dwl &&
            [[ -L "/home/$USERNAME/.local/bin/dwl" && "$(readlink -f "/home/$USERNAME/.local/bin/dwl")" == /usr/bin/dwl ]] || return 1
    fi
    [[ "$MODE" != new ]] || arch_validate_boot
}

arch_uv_tools() {
    local action="$1" entries spec name version installed
    entries="$(arch_read_list packages/full-uv.list)" || return 1
    installed="$(run_as_user uv tool list)" || return 1
    while IFS= read -r spec; do
        [[ "$spec" =~ ^[a-zA-Z0-9._-]+==[a-zA-Z0-9._+-]+$ ]] || return 1
        name="${spec%%==*}" version="${spec#*==}"
        if [[ -x "/home/$USERNAME/.local/bin/$name" ]] && grep -qxF "$name v$version" <<<"$installed"; then continue; fi
        [[ "$action" == install ]] || return 1
        run_as_user uv tool install --force "$spec"
    done <<<"$entries"
}

arch_full_packages() {
    arch_install_lists full
    [[ "$TORRENT" != yes ]] || arch_install_lists torrent
    arch_local_packages full-local
    arch_uv_tools install
    arch_system_layer apply full
    arch_services apply full
}

arch_validate_full() {
    arch_check_lists full full-local && arch_local_outputs full-local && arch_uv_tools check &&
        arch_system_layer check full && arch_services check full &&
        { [[ "$TORRENT" != yes ]] || arch_check_lists torrent; }
}

arch_validate_desktop_complete() {
    [[ -s /var/lib/install-system/desktop-complete ]] &&
        stage_group_complete_before desktop-complete "${DWL_STAGES[@]}"
}

arch_validate_full_complete() {
    [[ -s /var/lib/install-system/full-complete && "$(state_stage_status desktop-complete)" == done ]] &&
        stage_group_complete_before full-complete "${FULL_STAGES[@]}"
}

arch_run_target() {
    ((KERNEL_CONFIG_READY == 0)) || die "Arch uses the selected packaged kernel; --kernel-config-ready is Gentoo-only"
    ensure_arch_source
    if [[ "$MODE" == existing || "$(state_stage_status accounts)" == done ]]; then select_existing_user; fi
    set_tier_features
    local -a sequence=()
    if [[ "$MODE" == new ]]; then sequence+=("${MINIMAL_SEQUENCE[@]}"); else sequence+=("${EXISTING_SEQUENCE[@]}"); fi
    sequence+=("${DWL_SEQUENCE[@]}" "${FULL_SEQUENCE[@]}")
    run_sequence "${sequence[@]}"
    ((STOP_REQUESTED)) || log "Arch full installation is complete ($DESKTOP)."
}

main() {
    parse_arguments "$@"
    validate_options

    case "$COMMAND" in
        list-stages)
            list_stages
            ;;
        status)
            show_status
            ;;
        new)
            ((INTERNAL_CHROOT == 0)) || die "new cannot be invoked as an internal chroot command"
            run_new_host
            ;;
        existing)
            ((INTERNAL_CHROOT == 0)) || die "existing cannot be invoked as an internal chroot command"
            run_existing
            ;;
        continue)
            run_continue
            ;;
        *)
            die "internal error: unhandled command $COMMAND"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
