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
Arch supports vanilla or CachyOS packages, with Btrfs/GRUB/Snapper or F2FS. On Btrfs,
Snapper starts when the installation is finished: its first snapshot is the finished
system, kept until you delete it and offered in the GRUB menu. The menu stays hidden;
press Esc while the computer starts to show it.

The minimal tier provides the base system. Desktop tiers add the selected
desktop and its applications; full adds the broader application set.
Torrent tools are optional and selected separately.

## Requirements

- Internet access and root privileges.
- Bash, Python 3.9+, Git, curl and GPG.
- The corresponding Gentoo or Arch UEFI live environment for new installations.
- GitHub SSH and GPG access only for the private dotfiles, which the `neuroleptic`
  account receives unless `--no-private-dotfiles` is given. Without an SSH key, the
  installer creates one for the machine and waits until it is added to GitHub.

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

Every question of the chosen tier is asked at the start and recorded, so the
installation then runs on its own. It stops only for manual work, such as configuring
a custom kernel or restoring the GPG key of the private dotfiles, or for a repair.

## Resuming work

On Gentoo, the installer adds missing packages. An installed package is rebuilt only
when the installer's USE flags require it; on an existing system the installer stops
first if Portage would change that package's version. If an application fails to
build, the installer continues without it and lists it at the end; a failed core
package or compiler pass stops it. On Arch, any failed package stops the installer.
After a repair, resume; only the missing work is retried:

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
require confirmation. Choosing a tier approves all of its stages; switching an
existing account to Zsh is confirmed at the start. New Gentoo installations use
either Gentoo's prebuilt distribution kernel, which needs no configuration, or a
custom kernel that you configure in `/usr/src/linux` before compilation.

On Gentoo, linux-firmware can be limited to the files this computer's drivers use. The
list is kept as `/etc/portage/savedconfig/sys-kernel/linux-firmware`, which applies to
every linux-firmware version.

Browser setup applies themes and configures automatic extension installation for
LibreWolf and Helium. It also runs LibreWolf's setup script.

In the full tier, the installer can register the machine as a new device of your
Mullvad account for the WireGuard scripts. The account number is asked at the start,
used once and never stored or logged; a resumed installation asks for it again.

## Related repositories

- [Gentoo packages and policy](https://github.com/Neur0leptic/neurogentoo)
- [Arch packages and policy](https://github.com/Neur0leptic/neuroarch)
- [Chezmoi dotfiles](https://github.com/Neur0leptic/dotfiles)
