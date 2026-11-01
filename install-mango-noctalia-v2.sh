#!/usr/bin/env bash
# Minimal Debian 13 + MangoWM (Butterrepo) + Noctalia installer.
# Run as the normal user with sudo privileges. Do not run as root.

set -e

BUTTERREPO_BOOTSTRAP_URL="https://justaguy.dev/drew/butterscripts/raw/branch/main/setup/add_butterrepo.sh"
NOCTALIA_KEYRING_URL="https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb"
NOCTALIA_SOURCES_URL="https://pkg.noctalia.dev/deb/noctalia-trixie.sources"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

printf '\nDebian 13: MangoWM + Noctalia\n\n'

# Debian update, as in the MangoButter installer.
sudo apt-get update
sudo apt-get upgrade -y

# Add the official JustAGuyLinux Butterrepo using the same bootstrap
# command as the original MangoButter installer.
wget -qO- "$BUTTERREPO_BOOTSTRAP_URL" | bash
sudo apt-get update

# Minimal desktop packages. MangoWM and its wlroots/SceneFX dependencies
# are provided by Butterrepo; the remaining packages are from Debian.
sudo apt-get install -y \
    mangowc xwayland \
    greetd tuigreet \
    foot thunar firefox-esr \
    network-manager \
    pipewire-audio wireplumber pavucontrol \
    polkitd lxqt-policykit \
    grim slurp wl-clipboard wlr-randr \
    swaylock swayidle brightnessctl playerctl \
    xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk \
    dbus-user-session xdg-utils xdg-user-dirs \
    ca-certificates wget curl gnupg locales keyboard-configuration \
    fonts-noto-core fonts-noto-color-emoji fonts-dejavu-core

# Install Noctalia from its official Debian 13 APT repository.
wget -O "$WORKDIR/nickh-archive-keyring.deb" "$NOCTALIA_KEYRING_URL"
sudo apt install -y "$WORKDIR/nickh-archive-keyring.deb"
wget -O "$WORKDIR/noctalia-trixie.sources" "$NOCTALIA_SOURCES_URL"
sudo install -m 0644 "$WORKDIR/noctalia-trixie.sources" /etc/apt/sources.list.d/noctalia-trixie.sources
sudo apt-get update
sudo apt-get install -y noctalia

# Russian locale.
sudo sed -i 's/^# *ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
sudo locale-gen
sudo update-locale LANG=ru_RU.UTF-8

# Keyboard layout: English/Russian, Alt+Shift.
sudo tee /etc/default/keyboard >/dev/null <<'KBD'
XKBMODEL="pc105"
XKBLAYOUT="us,ru"
XKBVARIANT=""
XKBOPTIONS="grp:alt_shift_toggle"
BACKSPACE="guess"
KBD

# MangoWM configuration. Keep the D-Bus environment update and Noctalia
# startup in one exec-once command because Mango starts exec-once commands
# concurrently.
mkdir -p "$HOME/.config/mango" "$HOME/.config/xdg-desktop-portal"
cat > "$HOME/.config/mango/config.conf" <<'MANGO'
# MangoWM + Noctalia
exec-once=dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP MANGO_INSTANCE_SIGNATURE && noctalia
exec-once=lxqt-policykit-agent

xkb_rules_layout=us,ru
xkb_rules_options=grp:alt_shift_toggle

# Applications
bind=SUPER,Return,spawn,foot
bind=SUPER,space,spawn,noctalia msg panel-toggle launcher
bind=SUPER,s,spawn,noctalia msg panel-toggle control-center
bind=SUPER,comma,spawn,noctalia msg settings-toggle
bind=SUPER,e,spawn,thunar
bind=SUPER,b,spawn,firefox-esr

# Window management
bind=SUPER,q,killclient,
bind=SUPER+SHIFT,q,quit
bind=SUPER+CTRL,l,spawn,swaylock -f

# Audio and brightness
bind=NONE,XF86AudioRaiseVolume,spawn,noctalia msg volume-up
bind=NONE,XF86AudioLowerVolume,spawn,noctalia msg volume-down
bind=NONE,XF86AudioMute,spawn,noctalia msg volume-mute
bind=NONE,XF86MonBrightnessUp,spawn,noctalia msg brightness-up
bind=NONE,XF86MonBrightnessDown,spawn,noctalia msg brightness-down
MANGO

# Portal preference: wlroots for screencast, GTK for file chooser/settings.
cat > "$HOME/.config/xdg-desktop-portal/portals.conf" <<'PORTAL'
[preferred]
default=wlr;gtk
org.freedesktop.impl.portal.FileChooser=gtk
org.freedesktop.impl.portal.Settings=gtk
PORTAL

# greetd login screen, starting MangoWM.
sudo install -d -m 0755 /etc/greetd
sudo tee /etc/greetd/config.toml >/dev/null <<'GREETD'
[terminal]
vt = 7

[default_session]
command = "tuigreet --time --cmd mango"
user = "_greetd"
GREETD

# Enable the system services used by the desktop session.
sudo systemctl enable NetworkManager
sudo systemctl enable greetd

printf '\nInstallation commands completed.\n'
printf 'MangoWM config: %s/.config/mango/config.conf\n' "$HOME"
printf 'Noctalia IPC help: noctalia msg --help\n'
printf 'Reboot: sudo reboot\n'
