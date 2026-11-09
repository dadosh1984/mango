
#!/usr/bin/env bash
# ============================================================
# Debian 13 Trixie
# Umbriel + Noctalia 5.4.1 + Noctalia Greeter
# Full Wayland desktop installation
# ============================================================

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="3.0"
NOCTALIA_VERSION_PREFIX="${NOCTALIA_VERSION_PREFIX:-5.4.1}"
ENABLE_GREETER="${ENABLE_GREETER:-1}"
INSTALL_EXTRA_APPS="${INSTALL_EXTRA_APPS:-1}"

LOG="/var/log/umbriel-noctalia-install.log"
BACKUP="/var/backups/umbriel-noctalia-$(date +%Y%m%d-%H%M%S)"

info() { echo -e "\n[INFO] $*"; }
warn() { echo -e "\n[WARN] $*" >&2; }
die()  { echo -e "\n[ERROR] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запусти через sudo."

mkdir -p /var/log
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

# ------------------------------------------------------------
# 1. System validation
# ------------------------------------------------------------

source /etc/os-release

[[ "$ID" == "debian" ]] || die "Требуется Debian."
[[ "$VERSION_CODENAME" == "trixie" ]] || die "Требуется Debian 13 Trixie."

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64|arm64) ;;
    *) die "Архитектура $ARCH не поддерживается репозиторием Noctalia." ;;
esac

TARGET_USER="${SUDO_USER:-}"

if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(getent passwd 1000 | cut -d: -f1 || true)"
fi

[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] ||
    die "Не удалось определить обычного пользователя."

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
TARGET_UID="$(id -u "$TARGET_USER")"

mkdir -p "$BACKUP"

info "Debian: $PRETTY_NAME"
info "Архитектура: $ARCH"
info "Пользователь: $TARGET_USER"
info "Резервная копия: $BACKUP"

# ------------------------------------------------------------
# 2. Virtual machine detection
# ------------------------------------------------------------

VIRT="none"

if command -v systemd-detect-virt >/dev/null 2>&1; then
    VIRT="$(systemd-detect-virt --vm 2>/dev/null || true)"

    if [[ -z "$VIRT" ]]; then
        VIRT="none"
    fi
fi

info "Тип среды: $VIRT"

# ------------------------------------------------------------
# 3. Hardware detection
# ------------------------------------------------------------

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    gnupg \
    pciutils \
    usbutils \
    lsb-release

GPU_INFO="$(lspci -nn 2>/dev/null |
    grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)"

info "Обнаруженные видеоустройства:"
echo "$GPU_INFO"

GPU_INTEL=0
GPU_AMD=0
GPU_NVIDIA=0

grep -qi 'Intel' <<< "$GPU_INFO" && GPU_INTEL=1
grep -qiE 'AMD|ATI' <<< "$GPU_INFO" && GPU_AMD=1
grep -qi 'NVIDIA' <<< "$GPU_INFO" && GPU_NVIDIA=1

if [[ "$VIRT" == "none" ]]; then
    info "Обнаружена физическая система либо система без признаков VM."
else
    info "Обнаружена виртуальная машина: $VIRT"
fi

# ------------------------------------------------------------
# 4. Debian repositories
# ------------------------------------------------------------

if [[ ! -f /etc/apt/sources.list.d/debian-trixie-backports.sources ]]; then

cat > /etc/apt/sources.list.d/debian-trixie-backports.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

fi

# ------------------------------------------------------------
# 5. Noctalia repository
# ------------------------------------------------------------

info "Подключение репозитория Noctalia..."

wget -q \
    https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb \
    -O /tmp/noctalia-keyring.deb

dpkg -i /tmp/noctalia-keyring.deb

wget -q \
    https://pkg.noctalia.dev/deb/noctalia-trixie.sources \
    -O /etc/apt/sources.list.d/noctalia-trixie.sources

apt-get update

# ------------------------------------------------------------
# 6. Package availability checker
# ------------------------------------------------------------

AVAILABLE=()
MISSING=()

package_available() {
    local package="$1"

    apt-cache policy "$package" 2>/dev/null |
        grep -qE 'Candidate: [^()]'
}

add_package() {
    local package="$1"

    if package_available "$package"; then
        AVAILABLE+=("$package")
    else
        MISSING+=("$package")
        warn "Пакет отсутствует: $package"
    fi
}

install_available() {
    local packages=("$@")
    local selected=()

    for package in "${packages[@]}"; do
        if package_available "$package"; then
            selected+=("$package")
        else
            MISSING+=("$package")
            warn "Пропускаю недоступный пакет: $package"
        fi
    done

    if ((${#selected[@]})); then
        apt-get install -y "${selected[@]}"
    fi
}

# ------------------------------------------------------------
# 7. Core desktop packages
# ------------------------------------------------------------

CORE=(
    umbriel
    noctalia
    xdg-desktop-portal-umbriel

    greetd
    dbus-user-session

    xdg-desktop-portal
    xdg-desktop-portal-gtk

    polkitd
    lxqt-policykit

    pipewire
    pipewire-audio
    pipewire-pulse
    pipewire-alsa
    wireplumber
    libspa-0.2-bluetooth

    network-manager
    bluez
    blueman

    foot

    thunar
    thunar-volman
    thunar-archive-plugin
    gvfs
    gvfs-backends
    gvfs-fuse
    tumbler
    file-roller

    firefox-esr

    xwayland
    xdg-utils
    xdg-user-dirs

    fonts-dejavu
    fonts-noto-core
    fonts-noto-extra
    fonts-noto-color-emoji
    fonts-noto-cjk
    fonts-liberation2

    mesa-utils
    mesa-vulkan-drivers
    mesa-va-drivers

    brightnessctl
    playerctl
    pavucontrol
    wl-clipboard

    btop
    htop
    fastfetch
    jq
    git
    curl
    wget
    unzip
    zip
    p7zip-full

    adwaita-icon-theme
    papirus-icon-theme

    man-db
    sudo
)

info "Проверка обязательных компонентов..."

for package in "${CORE[@]}"; do
    add_package "$package"
done

# Critical packages must be available.
for package in umbriel noctalia xdg-desktop-portal-umbriel; do
    if ! package_available "$package"; then
        die "Критический пакет $package недоступен. Установка остановлена."
    fi
done

# ------------------------------------------------------------
# 8. Noctalia version selection
# ------------------------------------------------------------

info "Проверка версии Noctalia..."

NOCTALIA_VERSION="$(
    apt-cache madison noctalia |
    awk -v prefix="$NOCTALIA_VERSION_PREFIX" '
        $3 ~ "^" prefix { print $3; exit }
    '
)"

if [[ -z "$NOCTALIA_VERSION" ]]; then
    die "Noctalia $NOCTALIA_VERSION_PREFIX не найден в репозитории. Проверь apt-cache madison noctalia. Для другой версии запусти с NOCTALIA_VERSION_PREFIX."
fi

info "Будет установлена Noctalia: $NOCTALIA_VERSION"

# ------------------------------------------------------------
# 9. Firmware and GPU support
# ------------------------------------------------------------

FIRMWARE=(
    firmware-linux
    firmware-linux-nonfree
    firmware-misc-nonfree
    firmware-realtek
    firmware-iwlwifi
    firmware-mediatek
    firmware-atheros
    firmware-sof-signed
)

if (( GPU_INTEL )); then
    FIRMWARE+=(firmware-intel-graphics)
    FIRMWARE+=(intel-media-va-driver)
fi

if (( GPU_AMD )); then
    FIRMWARE+=(firmware-amd-graphics)
fi

if (( GPU_NVIDIA )); then
    FIRMWARE+=(firmware-nvidia-graphics)

    warn "NVIDIA обнаружена."
    warn "Проприетарный драйвер NVIDIA автоматически не устанавливается."
    warn "Для гибридной графики и passthrough требуется отдельная проверка."
fi

install_available "${FIRMWARE[@]}"

# ------------------------------------------------------------
# 10. Virtual machine guest packages
# ------------------------------------------------------------

case "$VIRT" in

    kvm|qemu)
        install_available \
            qemu-guest-agent \
            spice-vdagent
        ;;

    vmware)
        install_available \
            open-vm-tools \
            open-vm-tools-desktop
        ;;

    oracle)
        install_available \
            virtualbox-guest-utils
        ;;

    microsoft)
        install_available \
            hyperv-daemons
        ;;

    none)
        info "Гостевые дополнения VM не требуются."
        ;;

    *)
        warn "Неизвестная виртуальная среда: $VIRT"
        ;;

esac

# ------------------------------------------------------------
# 11. Optional applications
# ------------------------------------------------------------

if [[ "$INSTALL_EXTRA_APPS" == "1" ]]; then

    EXTRA=(
        chromium

        mousepad
        geany
        yazi

        mpv
        vlc
        ffmpeg

        gstreamer1.0-libav
        gstreamer1.0-plugins-good
        gstreamer1.0-plugins-bad
        gstreamer1.0-plugins-ugly

        libreoffice-writer
        libreoffice-calc
        libreoffice-impress

        evince
        gnome-disk-utility
        gparted

        cups
        system-config-printer

        remmina
        filezilla
    )

    install_available "${EXTRA[@]}"

fi

# ------------------------------------------------------------
# 12. Install Noctalia and Umbriel
# ------------------------------------------------------------

info "Установка Noctalia и Umbriel..."

apt-get install -y \
    "noctalia=$NOCTALIA_VERSION" \
    umbriel \
    xdg-desktop-portal-umbriel

# ------------------------------------------------------------
# 13. Install Noctalia Greeter
# ------------------------------------------------------------

if [[ "$ENABLE_GREETER" == "1" ]]; then

    info "Установка Noctalia Greeter..."

    if ! package_available noctalia-greeter; then
        die "noctalia-greeter недоступен. Проверь репозитории и trixie-backports."
    fi

    apt-get install -y -t trixie-backports \
        noctalia-greeter

    if command -v noctalia-greeter-apply-appearance >/dev/null 2>&1; then
        noctalia-greeter-apply-appearance --setup-system
    else
        warn "Не найдена команда настройки Greeter."
    fi

fi

# ------------------------------------------------------------
# 14. Umbriel configuration
# ------------------------------------------------------------

UCFG="$TARGET_HOME/.config/umbriel"
mkdir -p "$UCFG"

if [[ -f "$UCFG/config.toml" ]]; then

    cp -a "$UCFG/config.toml" \
        "$BACKUP/umbriel-config.toml"

    warn "Существующая конфигурация Umbriel сохранена."
    warn "Она не будет перезаписана."

else

    TRAIL_FILE=""

    for candidate in \
        /usr/share/umbriel/effects/cursor/trail/effect.toml \
        /usr/local/share/umbriel/effects/cursor/trail/effect.toml
    do
        if [[ -f "$candidate" ]]; then
            TRAIL_FILE="$candidate"
            break
        fi
    done

    [[ -n "$TRAIL_FILE" ]] ||
        warn "Эффект trail не найден в стандартных каталогах."

    if [[ -n "$TRAIL_FILE" ]]; then

cat > "$UCFG/config.toml" <<EOF
[general]
autostart = ["noctalia", "lxqt-policykit-agent"]
mod_key = "Super"
xwayland = true
show_cheatsheet = true

[include]
files = ["$TRAIL_FILE"]

[effects]
cursor = "trail"

[keybinds]
"Mod" = "spawn noctalia msg panel-toggle launcher"
"Mod+Return" = "spawn foot"
"Mod+T" = "spawn foot"
"Mod+E" = "spawn thunar"
"Mod+Q" = "window-close"
"Mod+O" = "overview-toggle"
"Mod+Shift+D" = "spawn noctalia msg panel-toggle muhammadessam/umbriel-monitor-control:panel"
EOF

    else

cat > "$UCFG/config.toml" <<'EOF'
[general]
autostart = ["noctalia", "lxqt-policykit-agent"]
mod_key = "Super"
xwayland = true
show_cheatsheet = true

[keybinds]
"Mod" = "spawn noctalia msg panel-toggle launcher"
"Mod+Return" = "spawn foot"
"Mod+T" = "spawn foot"
"Mod+E" = "spawn thunar"
"Mod+Q" = "window-close"
"Mod+O" = "overview-toggle"
"Mod+Shift+D" = "spawn noctalia msg panel-toggle muhammadessam/umbriel-monitor-control:panel"
EOF

    fi

fi

chown -R "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.config"

# ------------------------------------------------------------
# 15. Optional plugin installer
# ------------------------------------------------------------

PLUGIN_HELPER="$TARGET_HOME/.local/bin/noctalia-enable-plugins"

mkdir -p "$TARGET_HOME/.local/bin"

cat > "$PLUGIN_HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

command -v noctalia >/dev/null ||
    { echo "Noctalia CLI не найден."; exit 1; }

echo "Установка плагина управления мониторами..."

noctalia msg plugins enable muhammadessam/umbriel-monitor-control

echo
echo "Плагин включён."
echo
echo "Открыть панель мониторов:"
echo "noctalia msg panel-toggle muhammadessam/umbriel-monitor-control:panel"
echo
echo "Добавь виджет monitor на панель Noctalia."
echo "В Control Center можно добавить shortcut display."
EOF

chmod +x "$PLUGIN_HELPER"

chown -R "$TARGET_USER:$TARGET_GROUP" \
    "$TARGET_HOME/.local"

# ------------------------------------------------------------
# 16. User folders
# ------------------------------------------------------------

runuser -u "$TARGET_USER" -- \
    xdg-user-dirs-update || true

# ------------------------------------------------------------
# 17. System services
# ------------------------------------------------------------

systemctl enable NetworkManager.service
systemctl enable bluetooth.service

if systemctl list-unit-files cups.service >/dev/null 2>&1; then
    systemctl enable cups.service || true
fi

# ------------------------------------------------------------
# 18. Umbriel validation
# ------------------------------------------------------------

if command -v umbriel >/dev/null 2>&1; then

    info "Проверка конфигурации Umbriel..."

    if ! runuser -u "$TARGET_USER" -- \
        env HOME="$TARGET_HOME" \
        umbriel config validate
    then
        warn "Конфигурация Umbriel не прошла проверку."
        warn "Не включай Greeter до исправления ошибки."
    fi

fi

# ------------------------------------------------------------
# 19. Greeter activation
# ------------------------------------------------------------

if [[ "$ENABLE_GREETER" == "1" ]]; then

    if systemctl is-enabled display-manager.service \
        >/dev/null 2>&1
    then

        warn "Обнаружен действующий display-manager."
        warn "Автоматическое переключение не выполнено."
        warn "Проверь текущий менеджер входа вручную."

    elif systemctl list-unit-files greetd.service \
        | grep -q greetd.service
    then

        systemctl enable greetd.service

        info "greetd включён для следующей загрузки."

    else

        warn "greetd.service не найден."

    fi

fi

# ------------------------------------------------------------
# 20. Final report
# ------------------------------------------------------------

echo
echo "=================================================="
echo " УСТАНОВКА ЗАВЕРШЕНА"
echo "=================================================="

echo "Версия скрипта: $VERSION"
echo "Debian: $PRETTY_NAME"
echo "Архитектура: $ARCH"
echo "Виртуализация: $VIRT"
echo "Пользователь: $TARGET_USER"

echo
echo "Noctalia:"
dpkg-query -W -f='${Version}\n' noctalia 2>/dev/null || true

echo
echo "Umbriel:"
dpkg-query -W -f='${Version}\n' umbriel 2>/dev/null || true

echo
echo "Greeter:"
dpkg-query -W -f='${Version}\n' noctalia-greeter 2>/dev/null || true

echo
echo "Горячие клавиши:"
echo "Super       - Launcher"
echo "Super+Enter - Foot"
echo "Super+T     - Foot"
echo "Super+E     - Thunar"
echo "Super+Q     - Закрыть окно"
echo "Super+O     - Overview"
echo "Super+Shift+D - Управление мониторами"

echo
echo "После первого входа выполни:"
echo "$PLUGIN_HELPER"

echo
echo "Проверка мониторов:"
echo "umbriel outputs"

echo
echo "Проверка конфигурации:"
echo "umbriel config validate"

echo
echo "Резервные копии: $BACKUP"
echo "Журнал: $LOG"

echo
echo "ВАЖНО:"
echo "1. Перед перезагрузкой убедись, что доступен TTY."
echo "2. Проверь конфигурацию Umbriel."
echo "3. Убедись, что Greeter видит сессию Umbriel."
echo "4. NVIDIA proprietary driver автоматически не устанавливался."
echo "5. Скрипт не устанавливает Quickshell."

echo
echo "=================================================="

