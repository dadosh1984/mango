
#!/usr/bin/env bash
# Fedora 44 + MangoWM + Noctalia v5 + Noctalia Greeter
# Version: 0.2
#
# Запускать от обычного пользователя с правами sudo.
# Скрипт не выполняет полный system upgrade.
# Существующий менеджер входа не отключается без подтверждения.
# Cursor trails / particles не устанавливаются.

set -Eeuo pipefail

SCRIPT_VERSION="0.2"
STAMP="$(date +%Y%m%d-%H%M%S)"

WORKDIR="$(mktemp -d -t mango-fedora.XXXXXXXX)"
STAGE="$(mktemp -d -t mango-stage.XXXXXXXX)"

BACKUP_DIR="$HOME/.config/mango-backups"
SYSTEM_BACKUP_DIR="/var/backups/mango-fedora-$STAMP"
CONFIG_DIR="$HOME/.config/mango"

cleanup() {
    rm -rf "$WORKDIR" "$STAGE"
}
trap cleanup EXIT

log() {
    printf '\033[1;36m[INFO]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

fail() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

confirm() {
    local answer
    read -r -p "$1 [y/N] " answer || answer=""
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss]|[Дд])$ ]]
}

[[ "$EUID" -ne 0 ]] || fail "Запусти скрипт от обычного пользователя, не от root."

command -v sudo >/dev/null 2>&1 || fail "Не найдена команда sudo."
command -v dnf >/dev/null 2>&1 || fail "Не найден DNF."

sudo -v

[[ -r /etc/os-release ]] || fail "Не найден /etc/os-release."
# shellcheck disable=SC1091
. /etc/os-release

[[ "${ID:-}" == "fedora" ]] || fail "Поддерживается только Fedora."
[[ "${VERSION_ID:-}" == "44" ]] || fail "Нужна Fedora 44."

printf '\n'
printf '======================================================\n'
printf ' Fedora 44 + MangoWM + Noctalia — установщик v%s\n' "$SCRIPT_VERSION"
printf '======================================================\n\n'

printf 'Будут установлены:\n'
printf '  MangoWM\n'
printf '  Noctalia Shell v5\n'
printf '  Noctalia Greeter\n'
printf '  greetd\n'
printf '  Qt5 / Qt6 / Kvantum\n'
printf '  Thunar / Firefox / Foot\n'
printf '  PipeWire / Polkit / Wayland utilities\n'
printf '  Русская локаль и раскладка EN/RU\n\n'

printf 'Также будут созданы:\n'
printf '  Модульная конфигурация MangoWM\n'
printf '  Сочетания клавиш\n'
printf '  Русские пользовательские папки\n'
printf '  Закладки Thunar\n'
printf '  Файл с памяткой по сочетаниям клавиш\n'
printf '  Резервные копии настроек\n\n'

printf 'Cursor trails / particles: отключены.\n'
printf 'Полный системный upgrade: не выполняется.\n\n'

confirm "Продолжить установку?" || exit 0

sudo install -d -m 0755 "$SYSTEM_BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

backup_system_file() {
    local file="$1"

    if sudo test -f "$file"; then
        sudo cp -a "$file" \
            "$SYSTEM_BACKUP_DIR/$(basename "$file").bak"
    fi
}

backup_system_file /etc/dnf/dnf.conf
backup_system_file /etc/locale.conf
backup_system_file /etc/greetd/config.toml

# ------------------------------------------------------
# 1. DNF configuration
# ------------------------------------------------------

log "Настройка DNF5."

if sudo test -f /etc/dnf/dnf.conf; then
    sudo sed -i \
        '/^[[:space:]]*max_parallel_downloads[[:space:]]*=/d' \
        /etc/dnf/dnf.conf
fi

printf '\nmax_parallel_downloads=20\n' |
    sudo tee -a /etc/dnf/dnf.conf >/dev/null

# DNF5 Fedora 44 supports a maximum of 20 parallel downloads.

# ------------------------------------------------------
# 2. RPM Fusion
# ------------------------------------------------------

log "Подключение RPM Fusion Free и Nonfree."

FEDORA_VERSION="$(rpm -E %fedora)"

sudo dnf install -y \
    "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm" \
    "https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm"

# ------------------------------------------------------
# 3. Terra repository
# ------------------------------------------------------

log "Подключение Terra repository."

if ! rpm -q terra-release >/dev/null 2>&1; then
    sudo dnf install -y \
        --nogpgcheck \
        --repofrompath \
        "terra,https://repos.fyralabs.com/terra\$releasever" \
        terra-release
fi

sudo dnf makecache

# ------------------------------------------------------
# 4. Package availability helpers
# ------------------------------------------------------

package_available() {
    local package="$1"

    dnf -q repoquery \
        --available \
        --qf '%{name}' \
        "$package" 2>/dev/null |
        grep -Fxq "$package"
}

install_optional() {
    local package
    local -a available=()

    for package in "$@"; do
        if package_available "$package"; then
            available+=("$package")
        else
            warn "Пакет $package не найден — пропускаю."
        fi
    done

    if ((${#available[@]})); then
        sudo dnf install -y "${available[@]}"
    fi
}

install_required() {
    local package
    local -a missing=()

    for package in "$@"; do
        if ! package_available "$package"; then
            missing+=("$package")
        fi
    done

    if ((${#missing[@]})); then
        printf 'Не найдены обязательные пакеты:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        fail "Проверь Terra и подключённые репозитории."
    fi

    sudo dnf install -y "$@"
}

# ------------------------------------------------------
# 5. Main desktop packages
# ------------------------------------------------------

log "Установка MangoWM, Noctalia и основных компонентов."

install_required \
    mangowm \
    noctalia \
    noctalia-greeter \
    greetd \
    foot \
    Thunar \
    firefox \
    dbus-daemon \
    polkit \
    pipewire \
    wireplumber \
    xdg-user-dirs \
    xdg-utils

# ------------------------------------------------------
# 6. Additional desktop packages
# ------------------------------------------------------

log "Установка дополнительных программ и библиотек."

install_optional \
    xorg-x11-server-Xwayland \
    thunar-volman \
    gvfs \
    gvfs-mtp \
    gvfs-smb \
    gvfs-fuse \
    udisks2 \
    tumbler \
    file-roller \
    unzip \
    p7zip \
    firefox-langpacks \
    network-manager-applet \
    NetworkManager \
    pipewire-pulseaudio \
    pavucontrol \
    lxqt-policykit \
    polkit-gnome \
    grim \
    slurp \
    wl-clipboard \
    wlr-randr \
    swaylock \
    brightnessctl \
    playerctl \
    xdg-desktop-portal \
    xdg-desktop-portal-wlr \
    xdg-desktop-portal-gtk \
    accountsservice \
    fontconfig \
    google-noto-sans-fonts \
    google-noto-emoji-fonts \
    dejavu-sans-fonts \
    mesa-dri-drivers \
    mesa-vulkan-drivers \
    mesa-va-drivers \
    qt5ct \
    qt6ct \
    kvantum \
    kvantum-qt5 \
    kvantum-qt6 \
    papirus-icon-theme \
    adw-gtk3-theme \
    bibata-cursor-themes

# ------------------------------------------------------
# 7. Hardware / VM detection
# ------------------------------------------------------

log "Определение виртуальной машины или физического оборудования."

VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || true)"
[[ -n "$VIRT_TYPE" ]] || VIRT_TYPE="none"

printf 'Обнаруженная платформа: %s\n' "$VIRT_TYPE"

install_optional linux-firmware microcode_ctl

case "$VIRT_TYPE" in
    kvm|qemu)
        log "Обнаружена QEMU/KVM."

        install_optional \
            qemu-guest-agent \
            spice-vdagent

        if rpm -q qemu-guest-agent >/dev/null 2>&1; then
            sudo systemctl enable qemu-guest-agent.service
        fi

        ;;

    oracle)
        log "Обнаружена Oracle VirtualBox."

        install_optional \
            virtualbox-guest-additions

        ;;

    vmware)
        log "Обнаружена VMware."

        install_optional \
            open-vm-tools \
            open-vm-tools-desktop

        if rpm -q open-vm-tools >/dev/null 2>&1; then
            sudo systemctl enable vmtoolsd.service || true
        fi

        ;;

    microsoft)
        log "Обнаружена Hyper-V."

        install_optional hyperv-daemons

        ;;

    xen)
        log "Обнаружена Xen."

        install_optional xe-guest-utilities

        ;;

    none)
        log "Физическое оборудование. Определяю PCI-устройства."

        PCI_LIST="$(lspci -nn 2>/dev/null || true)"

        GPU_LIST="$(
            printf '%s\n' "$PCI_LIST" |
            grep -Ei 'VGA compatible controller|3D controller|Display controller' ||
            true
        )"

        NET_LIST="$(
            printf '%s\n' "$PCI_LIST" |
            grep -Ei 'Network controller|Wireless|Ethernet controller' ||
            true
        )"

        if [[ "$GPU_LIST" == *"[8086:"* ]]; then
            log "Обнаружена Intel Graphics."

            install_optional libva-intel-media-driver
        fi

        if [[ "$GPU_LIST" == *"[1002:"* ]]; then
            log "Обнаружена AMD Graphics."

            install_optional mesa-va-drivers
        fi

        if [[ "$GPU_LIST" == *"[10de:"* ]]; then
            warn "Обнаружена NVIDIA."
            warn "Проприетарный драйвер автоматически не устанавливается."
        fi

        if [[ "$NET_LIST" == *"[8086:"* ]]; then
            install_optional iwlwifi-mvm-firmware
        fi

        ;;

    *)
        warn "Неизвестная платформа: $VIRT_TYPE"
        ;;
esac

# ------------------------------------------------------
# 8. Check installed commands
# ------------------------------------------------------

log "Проверка исполняемых файлов."

MANGO_BIN="$(command -v mango || true)"
NOCTALIA_BIN="$(command -v noctalia || true)"
GREETER_SESSION="$(command -v noctalia-greeter-session || true)"

[[ -n "$MANGO_BIN" ]] || fail "Команда mango не найдена."
[[ -n "$NOCTALIA_BIN" ]] || fail "Команда noctalia не найдена."
[[ -n "$GREETER_SESSION" ]] || fail "noctalia-greeter-session не найдена."

MANGO_VERSION="$(rpm -q --qf '%{VERSION}-%{RELEASE}' mangowm)"
NOCTALIA_VERSION="$(rpm -q --qf '%{VERSION}-%{RELEASE}' noctalia)"

printf 'MangoWM: %s\n' "$MANGO_VERSION"
printf 'Noctalia: %s\n' "$NOCTALIA_VERSION"

# ------------------------------------------------------
# 9. Stage MangoWM configuration
# ------------------------------------------------------

log "Создание модульной конфигурации MangoWM."

mkdir -p "$STAGE"

cat > "$STAGE/config.conf" <<'MANGO'
# Главный файл MangoWM.
# Все дополнительные настройки находятся в отдельных файлах.

source=./settings.conf
source=./autostart.conf
source=./keybinds.conf
MANGO

cat > "$STAGE/settings.conf" <<'SETTINGS'
# ----------------------------------------------------
# Keyboard
# ----------------------------------------------------

xkb_rules_layout=us,ru
xkb_rules_options=grp:alt_shift_toggle

# ----------------------------------------------------
# Layout
# ----------------------------------------------------

new_is_master=1
default_master_factor=0.55
default_master_count=1

tag_num=9

# ----------------------------------------------------
# Animations
# ----------------------------------------------------

animations=1
layer_animations=0

animation_type_open=slide
animation_type_close=slide

animation_fade_in=1
animation_fade_out=1

animation_duration_move=400
animation_duration_open=350
animation_duration_tag=300
animation_duration_close=350

# ----------------------------------------------------
# Window appearance
# ----------------------------------------------------

blur=1
blur_layer=0
blur_optimized=1

blur_params_num_passes=2
blur_params_radius=5
blur_params_noise=0.02
blur_params_brightness=0.9
blur_params_contrast=0.9
blur_params_saturation=1.0

shadows=1
layer_shadows=0

shadow_only_floating=1
shadows_size=10
shadows_blur=15
shadows_position_x=2
shadows_position_y=2
shadows_color=0x00000088

border_radius=8
border_px=3

gap_inner_horizontal=6
gap_inner_vertical=6
gap_outer_horizontal=10
gap_outer_vertical=10

root_color=0x1e1e2eff
border_color=0x45475aff
focus_color=0xcba6f7ff
urgent_color=0xf38ba8ff

# ----------------------------------------------------
# Scroller
# ----------------------------------------------------

scroller_structs=20
scroller_default_proportion=0.8
scroller_focus_center=0
scroller_prefer_center=0
scroller_default_proportion_single=1.0
scroller_proportion_preset=0.5,0.8,1.0

# ----------------------------------------------------
# Input
# ----------------------------------------------------

repeat_rate=25
repeat_delay=600
numlock_on=0

tap_to_click=1
tap_and_drag=1
trackpad_disable_while_typing=1

mouse_natural_scrolling=0

# ----------------------------------------------------
# Layout assignment
# ----------------------------------------------------

tag_rule=id:1,layout_name:tile
tag_rule=id:2,layout_name:tile
tag_rule=id:3,layout_name:tile
tag_rule=id:4,layout_name:tile
tag_rule=id:5,layout_name:tile
tag_rule=id:6,layout_name:tile
tag_rule=id:7,layout_name:tile
tag_rule=id:8,layout_name:tile
tag_rule=id:9,layout_name:tile
SETTINGS

cat > "$STAGE/autostart.conf" <<'AUTOSTART'
# Noctalia Shell v5.
exec-once=noctalia

# Environment for Wayland desktop applications.
exec-once=dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP LANG LANGUAGE

# PolicyKit agent.
AUTOSTART

if command -v lxqt-policykit-agent >/dev/null 2>&1; then
    printf 'exec-once=lxqt-policykit-agent\n' >> "$STAGE/autostart.conf"
elif command -v polkit-gnome-authentication-agent-1 >/dev/null 2>&1; then
    printf 'exec-once=polkit-gnome-authentication-agent-1\n' >> "$STAGE/autostart.conf"
else
    warn "Не найден PolicyKit agent. Проверь доступные пакеты polkit."
fi

cat > "$STAGE/keybinds.conf" <<'KEYBINDS'
# ====================================================
# MangoWM + Noctalia — сочетания клавиш
# Super = клавиша с логотипом Windows
# ====================================================

# ----------------------------------------------------
# Applications and Noctalia
# ----------------------------------------------------

bind=SUPER,Return,spawn,foot
bind=SUPER,space,spawn,noctalia msg panel-toggle launcher
bind=SUPER,s,spawn,noctalia msg panel-toggle control-center
bind=SUPER+ALT,comma,spawn,noctalia msg settings-toggle

bind=SUPER,e,spawn,thunar
bind=SUPER,b,spawn,firefox
bind=SUPER+SHIFT,b,spawn,firefox --private-window

bind=SUPER+CTRL,l,spawn,swaylock -f

# ----------------------------------------------------
# Window management
# ----------------------------------------------------

bind=SUPER,q,killclient,
bind=SUPER+SHIFT,q,quit
bind=SUPER,m,quit

bind=SUPER+SHIFT,r,reload_config

bind=SUPER+SHIFT,space,togglefloating,
bind=SUPER+SHIFT,f,togglefullscreen,

bind=SUPER,Tab,togglejump,

bind=ALT,Tab,focusstack,next
bind=ALT+SHIFT,Tab,focusstack,prev

# ----------------------------------------------------
# Focus
# ----------------------------------------------------

bind=SUPER,Left,focusdir,left
bind=SUPER,Down,focusdir,down
bind=SUPER,Up,focusdir,up
bind=SUPER,Right,focusdir,right

bind=SUPER,h,focusdir,left
bind=SUPER,j,focusdir,down
bind=SUPER,k,focusdir,up
bind=SUPER,l,focusdir,right

# ----------------------------------------------------
# Move windows
# ----------------------------------------------------

bind=SUPER+SHIFT,Left,move_client,left
bind=SUPER+SHIFT,Down,move_client,down
bind=SUPER+SHIFT,Up,move_client,up
bind=SUPER+SHIFT,Right,move_client,right

bind=SUPER+SHIFT,h,move_client,left
bind=SUPER+SHIFT,j,move_client,down
bind=SUPER+SHIFT,k,move_client,up
bind=SUPER+SHIFT,l,move_client,right

# ----------------------------------------------------
# Master area
# ----------------------------------------------------

bind=SUPER+CTRL,Left,setmfact,-0.02
bind=SUPER+CTRL,Right,setmfact,+0.02
bind=SUPER+CTRL,Up,incnmaster,+1
bind=SUPER+CTRL,Down,incnmaster,-1

# ----------------------------------------------------
# Layouts
# ----------------------------------------------------

bind=SUPER,t,switch_layout

bind=SUPER+ALT,t,setlayout,tile
bind=SUPER+ALT,s,setlayout,scroller
bind=SUPER+ALT,m,setlayout,monocle
bind=SUPER,w,setlayout,monocle

bind=SUPER+ALT,g,togglegaps
bind=SUPER+ALT,minus,incgaps,-1
bind=SUPER+ALT,equal,incgaps,+1

# ----------------------------------------------------
# Workspaces 1-9
# ----------------------------------------------------

bind=SUPER,1,view,1,0
bind=SUPER,2,view,2,0
bind=SUPER,3,view,3,0
bind=SUPER,4,view,4,0
bind=SUPER,5,view,5,0
bind=SUPER,6,view,6,0
bind=SUPER,7,view,7,0
bind=SUPER,8,view,8,0
bind=SUPER,9,view,9,0

bind=SUPER+SHIFT,1,tag,1,0
bind=SUPER+SHIFT,2,tag,2,0
bind=SUPER+SHIFT,3,tag,3,0
bind=SUPER+SHIFT,4,tag,4,0
bind=SUPER+SHIFT,5,tag,5,0
bind=SUPER+SHIFT,6,tag,6,0
bind=SUPER+SHIFT,7,tag,7,0
bind=SUPER+SHIFT,8,tag,8,0
bind=SUPER+SHIFT,9,tag,9,0

bind=SUPER,bracketleft,viewtoleft,0
bind=SUPER,bracketright,viewtoright,0

# ----------------------------------------------------
# Monitors
# ----------------------------------------------------

bind=SUPER,comma,focusmon,left
bind=SUPER,period,focusmon,right

bind=SUPER+SHIFT,comma,tagmon,left
bind=SUPER+SHIFT,period,tagmon,right

# ----------------------------------------------------
# Audio and brightness
# ----------------------------------------------------

bind=NONE,XF86AudioRaiseVolume,spawn,noctalia msg volume-up
bind=NONE,XF86AudioLowerVolume,spawn,noctalia msg volume-down
bind=NONE,XF86AudioMute,spawn,noctalia msg volume-mute

bind=NONE,XF86AudioPlay,spawn,noctalia msg media toggle
bind=NONE,XF86AudioPause,spawn,noctalia msg media toggle
bind=NONE,XF86AudioNext,spawn,noctalia msg media next
bind=NONE,XF86AudioPrev,spawn,noctalia msg media previous

bind=NONE,XF86MonBrightnessUp,spawn,noctalia msg brightness-up
bind=NONE,XF86MonBrightnessDown,spawn,noctalia msg brightness-down

# ----------------------------------------------------
# Screenshots
# ----------------------------------------------------

bind=NONE,Print,spawn,noctalia msg screenshot-fullscreen
bind=SHIFT,Print,spawn,noctalia msg screenshot-region
bind=SUPER+SHIFT,a,spawn,noctalia msg screenshot-annotate

# ----------------------------------------------------
# Mouse
# ----------------------------------------------------

mousebind=SUPER,btn_left,moveresize,curmove
mousebind=SUPER,btn_right,moveresize,curresize

axisbind=SUPER,UP,viewtoleft
axisbind=SUPER,DOWN,viewtoright
KEYBINDS

# ------------------------------------------------------
# 10. Validate staged MangoWM configuration
# ------------------------------------------------------

log "Проверка конфигурации MangoWM."

if ! mango -c "$STAGE/config.conf" -p; then
    fail "MangoWM отклонил конфигурацию. Старые настройки не заменены."
fi

# ------------------------------------------------------
# 11. Backup and install Mango configuration
# ------------------------------------------------------

if [[ -d "$CONFIG_DIR" ]] &&
   find "$CONFIG_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then

    mkdir -p "$BACKUP_DIR"

    tar -czf "$BACKUP_DIR/mango-config-$STAMP.tar.gz" \
        -C "$HOME/.config" mango

    log "Старая конфигурация сохранена в $BACKUP_DIR."
fi

mkdir -p "$CONFIG_DIR"

install -m 0644 "$STAGE/config.conf" "$CONFIG_DIR/config.conf"
install -m 0644 "$STAGE/settings.conf" "$CONFIG_DIR/settings.conf"
install -m 0644 "$STAGE/autostart.conf" "$CONFIG_DIR/autostart.conf"
install -m 0644 "$STAGE/keybinds.conf" "$CONFIG_DIR/keybinds.conf"

# ------------------------------------------------------
# 12. Russian locale and keyboard
# ------------------------------------------------------

log "Настройка русской локали."

sudo localectl set-locale LANG=ru_RU.UTF-8

# MangoWM handles the Wayland session keyboard layouts.
# The system console remains US by default.

# ------------------------------------------------------
# 13. Russian XDG directories
# ------------------------------------------------------

log "Создание стандартных пользовательских папок."

mkdir -p "$HOME/.config"

LANG=ru_RU.UTF-8 \
LANGUAGE=ru_RU:ru \
xdg-user-dirs-update --force

DESKTOP_DIR="$(xdg-user-dir DESKTOP)"
DOWNLOAD_DIR="$(xdg-user-dir DOWNLOAD)"
DOCUMENTS_DIR="$(xdg-user-dir DOCUMENTS)"
MUSIC_DIR="$(xdg-user-dir MUSIC)"
PICTURES_DIR="$(xdg-user-dir PICTURES)"
VIDEOS_DIR="$(xdg-user-dir VIDEOS)"
TEMPLATES_DIR="$(xdg-user-dir TEMPLATES)"
PUBLIC_DIR="$(xdg-user-dir PUBLICSHARE)"

mkdir -p \
    "$DESKTOP_DIR" \
    "$DOWNLOAD_DIR" \
    "$DOCUMENTS_DIR" \
    "$MUSIC_DIR" \
    "$PICTURES_DIR" \
    "$VIDEOS_DIR" \
    "$TEMPLATES_DIR" \
    "$PUBLIC_DIR" \
    "$PICTURES_DIR/Screenshots"

printf 'ru_RU\n' > "$HOME/.config/user-dirs.locale"

# ------------------------------------------------------
# 14. Thunar GTK bookmarks
# ------------------------------------------------------

log "Настройка закладок Thunar."

python3 - \
    "$HOME" \
    "$DESKTOP_DIR" \
    "$DOCUMENTS_DIR" \
    "$DOWNLOAD_DIR" \
    "$MUSIC_DIR" \
    "$PICTURES_DIR" \
    "$VIDEOS_DIR" \
    "$TEMPLATES_DIR" \
    "$PUBLIC_DIR" <<'PYBOOKMARKS'

from pathlib import Path
from urllib.parse import quote
import sys

home = Path(sys.argv[1])

entries = [
    (Path(sys.argv[2]), "Рабочий стол"),
    (Path(sys.argv[3]), "Документы"),
    (Path(sys.argv[4]), "Загрузки"),
    (Path(sys.argv[5]), "Музыка"),
    (Path(sys.argv[6]), "Изображения"),
    (Path(sys.argv[7]), "Видео"),
    (Path(sys.argv[8]), "Шаблоны"),
    (Path(sys.argv[9]), "Общий доступ"),
]

bookmarks = home / ".config/gtk-3.0/bookmarks"
bookmarks.parent.mkdir(parents=True, exist_ok=True)

existing = (
    bookmarks.read_text(encoding="utf-8").splitlines()
    if bookmarks.exists()
    else []
)

existing_uris = {
    line.split()[0]
    for line in existing
    if line.strip()
}

for directory, label in entries:
    if directory == home:
        continue

    uri = "file://" + quote(str(directory), safe="/")

    if uri not in existing_uris:
        existing.append(f"{uri} {label}")

bookmarks.write_text(
    "\n".join(existing).rstrip() + "\n",
    encoding="utf-8"
)

PYBOOKMARKS

# ------------------------------------------------------
# 15. Qt environment
# ------------------------------------------------------

log "Подготовка Qt/Kvantum."

mkdir -p \
    "$HOME/.config/Kvantum" \
    "$HOME/.config/environment.d"

# Kvantum is installed as an available Qt style.
# Qt5ct and Qt6ct remain separately available for configuration.
cat > "$HOME/.config/environment.d/90-qt-theme.conf" <<'QTENV'
QT_STYLE_OVERRIDE=kvantum
QT_AUTO_SCREEN_SCALE_FACTOR=1
QT_ENABLE_HIGHDPI_SCALING=1
QTENV

# ------------------------------------------------------
# 16. XDG desktop portals
# ------------------------------------------------------

mkdir -p "$HOME/.config/xdg-desktop-portal"

cat > "$HOME/.config/xdg-desktop-portal/portals.conf" <<'PORTAL'
[preferred]
default=wlr;gtk
org.freedesktop.impl.portal.FileChooser=gtk
org.freedesktop.impl.portal.Settings=gtk
PORTAL

# ------------------------------------------------------
# 17. Mango Wayland session
# ------------------------------------------------------

log "Регистрация MangoWM Wayland session."

MANGO_DESKTOP="/usr/share/wayland-sessions/mango.desktop"

if ! sudo test -f "$MANGO_DESKTOP"; then
    sudo install -d -m 0755 /usr/share/wayland-sessions

    sudo tee "$MANGO_DESKTOP" >/dev/null <<EOF
[Desktop Entry]
Name=MangoWM
Comment=Mango Wayland Compositor
Exec=$MANGO_BIN
Type=Application
DesktopNames=Mango
EOF
fi

# ------------------------------------------------------
# 18. Noctalia Greeter account and configuration
# ------------------------------------------------------

log "Настройка Noctalia Greeter."

if ! getent passwd greeter >/dev/null 2>&1; then
    sudo useradd \
        --system \
        --no-create-home \
        --home-dir /var/lib/noctalia-greeter \
        --shell /sbin/nologin \
        greeter
fi

sudo install -d \
    -o greeter \
    -g greeter \
    -m 0750 \
    /var/lib/noctalia-greeter

sudo install -d -m 0755 /etc/greetd

backup_system_file /etc/greetd/config.toml

sudo tee /etc/greetd/config.toml >/dev/null <<EOF
[terminal]
vt = 7

[default_session]
command = "$GREETER_SESSION"
user = "greeter"
EOF

if command -v noctalia-greeter-apply-appearance >/dev/null 2>&1; then
    sudo noctalia-greeter-apply-appearance --setup-system
else
    warn "Не найдена noctalia-greeter-apply-appearance."
    warn "Проверь пакет noctalia-greeter и его post-install настройки."
fi

# ------------------------------------------------------
# 19. Enable essential system services
# ------------------------------------------------------

log "Включение базовых системных служб."

if systemctl list-unit-files NetworkManager.service >/dev/null 2>&1; then
    sudo systemctl enable NetworkManager.service
fi

# PipeWire is a per-user service.
# --global enables it for subsequently created user sessions.

sudo systemctl --global enable \
    pipewire.socket \
    pipewire-pulse.socket \
    wireplumber.service 2>/dev/null || \
    warn "Не удалось включить все глобальные пользовательские службы PipeWire."

# ------------------------------------------------------
# 20. Final checks
# ------------------------------------------------------

log "Финальная проверка."

mango -c "$CONFIG_DIR/config.conf" -p ||
    fail "Установленная конфигурация MangoWM не прошла проверку."

printf '\n'
printf '======================================================\n'
printf ' Установка компонентов завершена.\n'
printf '======================================================\n\n'

printf 'Fedora: %s\n' "$PRETTY_NAME"
printf 'Virtualization: %s\n' "$VIRT_TYPE"
printf 'MangoWM: %s\n' "$MANGO_VERSION"
printf 'Noctalia: %s\n' "$NOCTALIA_VERSION"
printf 'Noctalia Greeter: %s\n' "$GREETER_SESSION"

printf '\nMangoWM configuration:\n%s\n' "$CONFIG_DIR"

printf '\nSystem backups:\n%s\n' "$SYSTEM_BACKUP_DIR"

printf '\nUser backups:\n%s\n' "$BACKUP_DIR"

printf '\nKeyboard layout: EN / RU\n'
printf 'Switch: Alt + Shift\n'

printf '\nKey combinations:\n'
printf '  Super + Enter                 Terminal\n'
printf '  Super + Space                 Noctalia launcher\n'
printf '  Super + S                     Control Center\n'
printf '  Super + Alt + ,               Noctalia settings\n'
printf '  Super + T                     Cycle layouts\n'
printf '  Super + Alt + T/S/M           Select layout\n'
printf '  Super + H/J/K/L               Focus windows\n'
printf '  Super + Shift + H/J/K/L       Move windows\n'
printf '  Super + 1...9                 Workspaces\n'
printf '  Super + Shift + 1...9         Move window to workspace\n'
printf '  Super + , / .                 Change monitor focus\n'
printf '  Print                         Fullscreen screenshot\n'
printf '  Shift + Print                 Region screenshot\n'
printf '  Super + Shift + A             Screenshot annotation\n'

printf '\n'
printf 'Подробная памятка будет создана далее.\n'

# ------------------------------------------------------
# 21. Keyboard shortcut help file
# ------------------------------------------------------

cat > "$DOCUMENTS_DIR/Сочетания клавиш MangoWM.txt" <<'KEYS'

СОЧЕТАНИЯ КЛАВИШ MANGOWM + NOCTALIA

Super — клавиша с логотипом Windows.

ЯЗЫК
Alt + Shift                    Переключить EN/RU

ПРИЛОЖЕНИЯ
Super + Enter                  Открыть терминал
Super + Пробел                 Открыть меню приложений
Super + S                      Центр управления Noctalia
Super + Alt + ,                Настройки Noctalia
Super + E                      Файловый менеджер
Super + B                      Браузер
Super + Shift + B              Приватное окно браузера
Super + Ctrl + L               Заблокировать экран

ОКНА
Super + Q                      Закрыть активное окно
Super + Shift + Q              Завершить MangoWM
Super + M                      Завершить MangoWM
Super + Shift + R              Перезагрузить конфигурацию
Super + Shift + Пробел         Переключить плавающий режим
Super + Shift + F              Полноэкранный режим
Super + Tab                    Обзор окон
Alt + Tab                      Следующее окно
Alt + Shift + Tab              Предыдущее окно

ФОКУС
Super + Стрелки                Переключить фокус
Super + H/J/K/L                Переключить фокус

ПЕРЕМЕЩЕНИЕ ОКОН
Super + Shift + Стрелки        Переместить окно
Super + Shift + H/J/K/L        Переместить окно

РАСКЛАДКИ
Super + T                      Переключать раскладки
Super + Alt + T                Tile
Super + Alt + S                Scroller
Super + Alt + M                Monocle
Super + W                      Monocle
Super + Alt + G                Включить/выключить промежутки
Super + Alt + - / =            Уменьшить/увеличить промежутки

РАБОЧИЕ ПРОСТРАНСТВА
Super + 1...9                  Перейти на пространство
Super + Shift + 1...9          Переместить окно на пространство
Super + [ / ]                  Предыдущее / следующее пространство

МОНИТОРЫ
Super + , / .                  Переключить фокус монитора
Super + Shift + , / .          Переместить окно на другой монитор

ЗВУК И ЯРКОСТЬ
Клавиши мультимедиа            Управление воспроизведением
Клавиши громкости              Управление громкостью
Клавиши яркости                Яркость дисплея

СНИМКИ ЭКРАНА
Print                          Снимок всего экрана
Shift + Print                  Снимок области
Super + Shift + A              Редактор снимков

МЫШЬ
Super + Левая кнопка           Переместить окно
Super + Правая кнопка          Изменить размер окна
Super + Колесо вверх/вниз      Переключить пространство

KEYS

printf 'Памятка: %s/Сочетания клавиш MangoWM.txt\n' "$DOCUMENTS_DIR"

# ------------------------------------------------------
# 22. Safe display-manager handoff
# ------------------------------------------------------

printf '\n'
printf '======================================================\n'
printf ' Noctalia Greeter подготовлен.\n'
printf '======================================================\n\n'

printf 'Текущий display manager:\n'

DM_LINK="/etc/systemd/system/display-manager.service"
DM_UNIT=""

if [[ -L "$DM_LINK" ]]; then
    DM_TARGET="$(readlink -f "$DM_LINK" || true)"
    DM_UNIT="$(basename "$DM_TARGET")"
    printf '  %s\n' "$DM_UNIT"
else
    printf '  Не обнаружен активный display-manager alias.\n'
fi

printf '\n'
printf 'Перед переключением убедись, что можешь открыть TTY:\n'
printf '  Ctrl + Alt + F3\n\n'

if confirm "Сделать Noctalia Greeter экраном входа по умолчанию?"; then

    if [[ -n "$DM_UNIT" && "$DM_UNIT" != "greetd.service" ]]; then
        printf '\nБудет отключён текущий менеджер входа: %s\n' "$DM_UNIT"

        confirm "Подтвердить отключение $DM_UNIT?" ||
            fail "Переключение отменено. greetd оставлен выключенным."

        sudo systemctl disable "$DM_UNIT"
    fi

    sudo systemctl enable greetd.service

    printf '\nNoctalia Greeter включён.\n'
    printf 'После перезагрузки должен появиться новый экран входа.\n'

else
    warn "greetd оставлен выключенным."
    printf 'Для включения позже:\n'
    printf '  sudo systemctl enable greetd.service\n'
fi

printf '\n'
printf '======================================================\n'
printf ' ГОТОВО\n'
printf '======================================================\n'

printf '\nПроверка конфигурации:\n'
printf '  mango -c ~/.config/mango/config.conf -p\n'

printf '\nПерезагрузка:\n'
printf '  sudo reboot\n'

printf '\nРезервные копии:\n'
printf '  %s\n' "$SYSTEM_BACKUP_DIR"
printf '  %s\n' "$BACKUP_DIR"

printf '\nNoctalia IPC:\n'
printf '  noctalia msg --help\n'

printf '\n'

