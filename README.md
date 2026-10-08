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
- GitHub SSH and GPG access only if private dotfiles are accepted. Without an
  SSH key, the installer creates one for the machine and waits until it is added
  to GitHub.

## Usage

Clone the repository and keep the script and shared helpers together.
Gentoo and Arch package inputs are fetched automatically from their repositories:

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

## Configuration and dotfiles

The installer asks for account, display and input preferences and saves the
selected settings for reuse. Chezmoi manages the dotfiles; new accounts use Zsh.

Prepared root and EFI partitions can be reused without formatting. Disk changes
require confirmation. Package-tier upgrades and switching an existing account to
Zsh also require confirmation. The Gentoo kernel must be configured manually
before compilation.

Browser setup applies themes and configures automatic extension installation for
LibreWolf and Helium. It also runs LibreWolf's setup script.

## Related repositories

- [Gentoo packages and policy](https://github.com/Neur0leptic/neurogentoo)
- [Arch packages and policy](https://github.com/Neur0leptic/neuroarch)
- [Chezmoi dotfiles](https://github.com/Neur0leptic/dotfiles)
