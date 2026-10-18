# install-system

An interactive installer for Gentoo and Arch Linux. It installs the base system, a
Wayland desktop with its applications, and the
[dotfiles](https://github.com/Neur0leptic/dotfiles).

| Distribution | Desktop | Tiers |
| --- | --- | --- |
| Gentoo | DWL | minimal, dwl, full |
| Arch | DWL or Hyprland | minimal, desktop, full |

The minimal tier is the base system, the desktop tiers add the desktop and its
applications, and full adds the larger application set; torrent tools are optional.
Gentoo is amd64 without 32-bit libraries, with OpenRC and F2FS, and is compiled from
source. Arch uses Btrfs with GRUB and Snapper, or F2FS with GRUB or EFISTUB, and either
the vanilla or the CachyOS packages and kernel.

## Requirements

- A UEFI x86-64 computer with a disk of at least 26 GB, and internet access.
- The Gentoo or Arch live environment, with Bash, Python 3.9+, Git, curl and GPG.

## Installation

Start the live environment and, as root:

```sh
git clone https://github.com/Neur0leptic/install-system.git
cd install-system
./install_system.sh
```

Choose **New installation**. The questions come first, before the disk is touched:
the distribution, tier and desktop, the account, timezone and disk, the graphics
driver, displays and keyboard, and on Gentoo the kernel. At the disk prompt,
`DELETE_EVERYTHING` erases the chosen disk and `SKIP` uses root and EFI partitions you
formatted yourself.

The installation then runs on its own; on Gentoo it takes many hours. It stops when it
needs you, for example to configure a custom Gentoo kernel in `/usr/src/linux`. Do
that, then run:

```sh
./install_system.sh continue
```

On Gentoo, an application that fails to build is skipped and listed at the end, and
`continue` retries it. On Arch, any failed package stops the installation.

`./install_system.sh status` shows the progress, and `continue --step STAGE` repeats
the work from one stage (`./install_system.sh --list-stages` lists them). In the menu,
**Continue / complete an existing installation** also adds a desktop or the full tier
to an installed Gentoo or Arch system, without touching its disk, kernel or boot setup.
`./install_system.sh --help` lists every option.

## Using the installed system

Log in on the first console; the desktop starts automatically. The account and root
have the password chosen during the installation. The hostname is the username unless
`--hostname` was given.

On Arch with GRUB, the boot menu is hidden: press Esc while the computer starts. On
Btrfs the menu also lists the snapshots; the first one is the finished installation.

## Settings

- Desktop and applications: the [dotfiles](https://github.com/Neur0leptic/dotfiles),
  managed by chezmoi in `~/.local/share/chezmoi`. Their README says where each setting
  is and how to share changes between machines.
- Gentoo firmware: if you chose to install only the firmware this computer's drivers
  use, the list is `/etc/portage/savedconfig/sys-kernel/linux-firmware`. Add files to
  it when you add hardware.

## Private dotfiles and VPN

The private dotfiles belong to the author's `neuroleptic` account, which gets them
unless `--no-private-dotfiles` is given. They need a GitHub SSH key (the installer
creates one and waits until you add it to GitHub) and the GPG key that encrypts them
(the installer stops until you restore it). Other accounts need neither.

In the full tier, the installer can register the computer with your Mullvad account
for WireGuard. The account number is used once and never stored, so a continued
installation asks for it again.

## Related repositories

- [Gentoo packages and policy](https://github.com/Neur0leptic/neurogentoo)
- [Arch packages and policy](https://github.com/Neur0leptic/neuroarch)
- [Dotfiles](https://github.com/Neur0leptic/dotfiles)
