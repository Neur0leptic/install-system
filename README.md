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
The passphrase of that GPG key is asked only once; root's kernel keyring keeps it
until the installation completes, the computer restarts or a day passes unused.

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

DWL keeps its editable settings in `~/.local/src/dwl/config.h` (Super+C opens it).
The installer fills it once from the initial answers; continuing does not overwrite
local edits. Edit that file, then run `update_dwl.sh` to rebuild through the native
package manager. Use `--no-restart` to leave the current session running. The feature
patch and protocol remain shared dotfiles, not another personal settings file.

Prepared root and EFI partitions can be reused without formatting. Disk changes
require confirmation. Choosing a tier approves all of its stages; switching an
existing account to Zsh is confirmed at the start. New Gentoo installations use
either Gentoo's prebuilt distribution kernel, which needs no configuration, or a
custom kernel that you configure in `/usr/src/linux` before compilation.

On Gentoo, linux-firmware can be limited to the files this computer's drivers use. The
list is kept as `/etc/portage/savedconfig/sys-kernel/linux-firmware`, which applies to
every linux-firmware version.

Gentoo's `package.*`, repository and local-profile settings are single files.
Packages are selected normally in `world`; installer package lists stay in its policy
snapshot, not `/etc/portage/sets`. Continuing an older installation migrates its
fragment directories and installer sets, preserving local settings and package choices.
Originals are backed up under `/var/lib/install-system/portage-backups`.
From the installer directory, validate first, then migrate without running installation
stages or package transactions. Do not run this alongside another installer or emerge:

```sh
doas python3 -B packaging/common/portage_policy.py migrate --check-only
doas python3 -B packaging/common/portage_policy.py migrate
```

Browser setup applies themes and configures automatic extension installation for
LibreWolf and Helium. It also runs LibreWolf's setup script.

In the full tier, the installer can register the machine as a new device of your
Mullvad account for the WireGuard scripts. The account number is asked at the start,
used once and never stored or logged; a resumed installation asks for it again.

## Related repositories

- [Gentoo packages and policy](https://github.com/Neur0leptic/neurogentoo)
- [Arch packages and policy](https://github.com/Neur0leptic/neuroarch)
- [Chezmoi dotfiles](https://github.com/Neur0leptic/dotfiles)
