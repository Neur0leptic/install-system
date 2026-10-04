# Gentoo and Arch installer

An interactive installer for new Gentoo and Arch systems, with support for
completing existing installations and resuming interrupted work.

Packages are organized into selectable tiers. Desktop preferences and dotfiles
are managed through Chezmoi.

## Supported setups

| Distribution | Desktop | Tiers |
| --- | --- | --- |
| Gentoo | DWL | minimal, dwl, full |
| Arch | DWL or Hyprland | minimal, desktop, full |

New Gentoo installations use amd64 no-multilib, OpenRC, F2FS and direct EFI boot.
Arch supports vanilla or CachyOS packages, with Btrfs/GRUB/Snapper or F2FS.

The minimal tier provides the base system. Desktop tiers add the selected
desktop and its applications; full adds the broader application set.
Torrent tools are optional and selected separately.

## Requirements

- Internet access and root privileges.
- Bash, Python 3.9+, Git, curl and GPG.
- The corresponding Gentoo or Arch UEFI live environment for new installations.
- SSH/GPG access only if private dotfiles are accepted.

## Usage

Clone the repository and keep the script and packaging directories together:

```sh
git clone https://github.com/Neur0leptic/install-system.git
cd install-system
```

Run as root to open the interactive menu:

```sh
./install_system.sh
```

The menu provides:

- **New installation:** choose the distribution, package tier and target partitions.
- **Continue / complete an existing installation:** resume saved work or add the
  selected desktop and applications to an existing system.
- **Status:** inspect saved progress.

Existing-system mode does not replace the base system, filesystem, kernel or
boot configuration.

## Resuming work

A failed build stops the installer. Repair the problem manually, then resume:

```sh
./install_system.sh continue
```

To repeat work from a selected stage:

```sh
./install_system.sh continue --step STAGE
```

Completed stages are validated before reuse. Retrying a failed compiler stage
preserves its manual configuration repairs.

Available options:

```sh
./install_system.sh --help
```

## Confirmations and dotfiles

Disk changes and package-tier upgrades require confirmation. Prepared root and
EFI partitions can be reused without formatting. Gentoo kernel configuration
remains manual and requires readiness confirmation before compilation.

Display and input preferences are collected interactively and saved for reuse.

## Related repositories

- [Gentoo packages and policy](https://github.com/Neur0leptic/neurogentoo)
- [Chezmoi dotfiles](https://github.com/Neur0leptic/dotfiles)
