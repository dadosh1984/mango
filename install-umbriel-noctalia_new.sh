#!/usr/bin/env bash
# ============================================================
# Debian 13 Trixie
# Umbriel + Noctalia 5.4.1 + Noctalia Greeter
# Full Wayland desktop installation
# ============================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="3.1"
NOCTALIA_VERSION_PREFIX="${NOCTALIA_VERSION_PREFIX:-5.4.1}"
ENABLE_GREETER="${ENABLE_GREETER:-1}"
INSTALL_EXTRA_APPS="${INSTALL_EXTRA_APPS:-1}"

LOG="/var/log/umbriel-noctalia-install.log"
BACKUP="/var/backups/umbriel-noctalia-$(date +%Y%m%d-%H%M%S)"

# Never stop for debconf/needrestart prompts during an unattended install.
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
export NEEDRESTART_SUSPEND=1

APT_OPTS=(
    -y
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    -o DPkg::Lock::Timeout=120
    -o Acquire::Retries=3
)

info() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

run_apt() {
    apt-get "${APT_OPTS[@]}" "$@"
}

apt_update() {
    run_apt update ||
        die "apt-get update завершился с ошибкой. Проверь /etc/apt/sources.list, /etc/apt/sources.list.d и подключение к сети."
}

# IMPORTANT: apt-cache output is localized. Force the C locale, otherwise a
# Russian locale prints "Кандидат:" instead of "Candidate:" and every package
# is wrongly reported as missing.
package_available() {
    local package="$1"
    local candidate

    candidate="$(
        LC_ALL=C apt-cache policy "$package" 2>/dev/null |
            awk '/^[[:space:]]*Candidate:/ { print $2; exit }' || true
    )"

    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

install_optional() {
    local packages=("$@")
    local selected=()
    local package

    for package in "${packages[@]}"; do
        if package_available "$package"; then
            selected+=("$package")
        else
            warn "Необязательный пакет недоступен, пропускаю: $package"
        fi
    done

    if ((${#selected[@]} == 0)); then
        return 0
    fi

    if ! run_apt install "${selected[@]}"; then
        warn "Групповая установка не удалась. Пробую установить пакеты по одному..."
        for package in "${selected[@]}"; do
            run_apt install "$package" ||
                warn "Не удалось установить необязательный пакет: $package"
        done
    fi
}

install_required() {
    run_apt install "$@" ||
        die "Не удалось установить обязательные пакеты: $*"
}

# ------------------------------------------------------------
# 1. System validation
# ------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "Запусти через sudo."

mkdir -p /var/log
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1

# shellcheck source=/dev/null
source /etc/os-release

[[ "${ID:-}" == "debian" ]] || die "Требуется Debian."
[[ "${VERSION_CODENAME:-}" == "trixie" ]] ||
    die "Требуется Debian 13 Trixie."

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64|arm64) ;;
    *) die "Архитектура $ARCH не поддерживается репозиторием Noctalia." ;;
esac

TARGET_USER="${SUDO_USER:-}"

if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(logname 2>/dev/null || true)"
fi

if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(
        getent passwd |
            awk -F: '$3 >= 1000 && $3 < 60000 { print $1; exit }' ||
            true
    )"
fi

[[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]] ||
    die "Не удалось определить обычного пользователя."

getent passwd "$TARGET_USER" >/dev/null 2>&1 ||
    die "Пользователь $TARGET_USER не существует."

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || true)"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || true)"

[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] ||
    die "Не удалось определить домашний каталог пользователя $TARGET_USER."

[[ -n "$TARGET_GROUP" && -n "$TARGET_UID" ]] ||
    die "Не удалось определить группу или UID пользователя $TARGET_USER."

mkdir -p "$BACKUP"

info "Debian: ${PRETTY_NAME:-unknown}"
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
# 3. APT source preparation
# ------------------------------------------------------------

# A fresh Debian DVD install can leave a "deb cdrom:" entry. If the disc is
# not mounted, every apt-get update fails. Disable such entries safely.
disable_cdrom_sources() {
    local file

    shopt -s nullglob

    for file in \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d/*.list \
        /etc/apt/sources.list.d/*.sources
    do
        [[ -f "$file" ]] || continue

        if grep -qE '^[[:space:]]*(deb[[:space:]]+cdrom:|URIs:[[:space:]]*cdrom:)' "$file"; then
            cp -a "$file" "$BACKUP/$(basename "$file").bak"

            if [[ "$file" == *.sources ]]; then
                mv "$file" "$BACKUP/$(basename "$file").disabled"
            else
                sed -i -E 's|^([[:space:]]*deb[[:space:]]+)cdrom:|\1# cdrom:|' "$file"
            fi

            warn "Отключён CD-ROM источник: $file"
        fi
    done

    shopt -u nullglob
}

# Firmware packages live in non-free-firmware. Make sure the standard Debian
# sources expose the needed components.
ensure_debian_components() {
    local file

    for file in \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d/debian.sources \
        /etc/apt/sources.list.d/debian.list
    do
        [[ -f "$file" ]] || continue

        if [[ "$file" == *.sources ]]; then
            if grep -q '^Components:' "$file" &&
               ! grep -qE '^Components:.*non-free-firmware' "$file"
            then
                cp -a "$file" "$BACKUP/$(basename "$file").bak"
                sed -i -E '/^Components:/ s/$/ contrib non-free non-free-firmware/' "$file"
                info "Добавлены компоненты contrib/non-free/non-free-firmware в $file"
            fi
        else
            if grep -qE '^[[:space:]]*deb[[:space:]].*[[:space:]]main[[:space:]]*$' "$file"; then
                cp -a "$file" "$BACKUP/$(basename "$file").bak"
                sed -i -E 's|^([[:space:]]*deb[[:space:]].*[[:space:]]main)([[:space:]]*)$|\1 contrib non-free non-free-firmware\2|' "$file"
                info "Добавлены компоненты contrib/non-free/non-free-firmware в $file"
            fi
        fi
    done
}

disable_cdrom_sources
ensure_debian_components

# ------------------------------------------------------------
# 4. Hardware detection / bootstrap
# ------------------------------------------------------------

info "Обновление списков пакетов..."
apt_update

info "Установка базовых утилит..."
install_required \
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
printf '%s\n' "$GPU_INFO"

GPU_INTEL=0
GPU_AMD=0
GPU_NVIDIA=0

if grep -qi 'Intel' <<< "$GPU_INFO"; then GPU_INTEL=1; fi
if grep -qiE 'AMD|ATI' <<< "$GPU_INFO"; then GPU_AMD=1; fi
if grep -qi 'NVIDIA' <<< "$GPU_INFO"; then GPU_NVIDIA=1; fi

if [[ "$VIRT" == "none" ]]; then
    info "Обнаружена физическая система либо система без признаков VM."
else
    info "Обнаружена виртуальная машина: $VIRT"
fi

# ------------------------------------------------------------
# 5. Debian repositories
# ------------------------------------------------------------

if [[ ! -f /etc/apt/sources.list.d/debian-trixie-backports.sources ]]; then
    cat > /etc/apt/sources.list.d/debian-trixie-backports.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

    info "Добавлен репозиторий Debian trixie-backports."
fi

# ------------------------------------------------------------
# 6. Noctalia repository
# ------------------------------------------------------------

info "Подключение репозитория Noctalia..."

KEYRING_URL="https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb"
SOURCES_URL="https://pkg.noctalia.dev/deb/noctalia-trixie.sources"

wget --timeout=60 --tries=3 -q "$KEYRING_URL" \
    -O /tmp/noctalia-keyring.deb ||
    die "Не удалось скачать ключ репозитория Noctalia."

dpkg -i /tmp/noctalia-keyring.deb ||
    die "Не удалось установить ключ репозитория Noctalia."

wget --timeout=60 --tries=3 -q "$SOURCES_URL" \
    -O /etc/apt/sources.list.d/noctalia-trixie.sources ||
    die "Не удалось скачать файл репозитория Noctalia."

# The upstream trixie .sources file currently says "Architectures: amd64".
# The repository actually ships arm64 packages too, so allow the current arch.
if [[ -f /etc/apt/sources.list.d/noctalia-trixie.sources ]]; then
    sed -i -E "s/^Architectures:.*/Architectures: ${ARCH}/" \
        /etc/apt/sources.list.d/noctalia-trixie.sources
fi

apt_update

# ------------------------------------------------------------
# 7. Core desktop packages
# ------------------------------------------------------------

CRITICAL=(
    umbriel
    noctalia
    xdg-desktop-portal-umbriel
)

info "Проверка обязательных компонентов..."

for package in "${CRITICAL[@]}"; do
    package_available "$package" ||
        die "Критический пакет $package недоступен. Проверь репозитории и trixie-backports."
done

CORE=(
    greetd
    dbus-user-session

    xdg-desktop-portal
    xdg-desktop-portal-gtk

    polkitd

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

info "Установка основных пакетов рабочего стола..."
install_optional "${CORE[@]}"

# ------------------------------------------------------------
# 8. Noctalia version selection
# ------------------------------------------------------------

info "Проверка версии Noctalia..."

NOCTALIA_VERSION="$(
    LC_ALL=C apt-cache madison noctalia 2>/dev/null |
        awk -v prefix="$NOCTALIA_VERSION_PREFIX" '
            $3 == prefix ||
            index($3, prefix "-") == 1 ||
            index($3, prefix "+") == 1 { print $3; exit }
        ' || true
)"

if [[ -z "$NOCTALIA_VERSION" ]]; then
    NOCTALIA_VERSION="$(
        LC_ALL=C apt-cache policy noctalia 2>/dev/null |
            awk '/^[[:space:]]*Candidate:/ { print $2; exit }' || true
    )"

    if [[ -n "$NOCTALIA_VERSION" && "$NOCTALIA_VERSION" != "(none)" ]]; then
        warn "Noctalia $NOCTALIA_VERSION_PREFIX не найден. Будет установлена доступная версия: $NOCTALIA_VERSION"
    fi
fi

[[ -n "$NOCTALIA_VERSION" && "$NOCTALIA_VERSION" != "(none)" ]] ||
    die "Noctalia не найден в репозитории. Проверь apt-cache madison noctalia."

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

if ((GPU_INTEL)); then
    FIRMWARE+=(firmware-intel-graphics)
    FIRMWARE+=(intel-media-va-driver)
fi

if ((GPU_AMD)); then
    FIRMWARE+=(firmware-amd-graphics)
fi

if ((GPU_NVIDIA)); then
    FIRMWARE+=(firmware-nvidia-graphics)

    warn "NVIDIA обнаружена."
    warn "Проприетарный драйвер NVIDIA автоматически не устанавливается."
    warn "Для гибридной графики и passthrough требуется отдельная проверка."
fi

install_optional "${FIRMWARE[@]}"

# ------------------------------------------------------------
# 10. Virtual machine guest packages
# ------------------------------------------------------------

case "$VIRT" in

    kvm|qemu)
        install_optional \
            qemu-guest-agent \
            spice-vdagent
        ;;

    vmware)
        install_optional \
            open-vm-tools \
            open-vm-tools-desktop
        ;;

    oracle)
        warn "VirtualBox Guest Additions не входят в Debian 13."
        warn "Установи их вручную из ISO VirtualBox Guest Additions."
        ;;

    microsoft)
        install_optional \
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

    info "Установка дополнительных приложений..."
    install_optional "${EXTRA[@]}"

fi

# ------------------------------------------------------------
# 12. Install Noctalia and Umbriel
# ------------------------------------------------------------

info "Установка Noctalia и Umbriel..."

if ! run_apt install "noctalia=$NOCTALIA_VERSION"; then
    warn "Не удалось установить Noctalia $NOCTALIA_VERSION. Пробую последнюю доступную версию."
    install_required noctalia
fi

# Umbriel and its newer wlroots/libdisplay-info dependencies live in the
# Noctalia trixie-backports suite. Without -t, apt refuses to pull them in.
install_required -t trixie-backports umbriel
install_required xdg-desktop-portal-umbriel

# ------------------------------------------------------------
# 13. Install Noctalia Greeter
# ------------------------------------------------------------

if [[ "$ENABLE_GREETER" == "1" ]]; then

    info "Установка Noctalia Greeter..."

    if package_available noctalia-greeter; then
        install_required -t trixie-backports noctalia-greeter

        if command -v noctalia-greeter-apply-appearance >/dev/null 2>&1; then
            noctalia-greeter-apply-appearance --setup-system ||
                warn "Не удалось выполнить noctalia-greeter-apply-appearance --setup-system."
        else
            warn "Не найдена команда настройки Greeter."
        fi
    else
        warn "noctalia-greeter недоступен. Greeter не будет установлен."
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
autostart = ["noctalia"]
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
"Mod+Escape" = "session-quit"
"Mod+Shift+D" = "spawn noctalia msg panel-toggle muhammadessam/umbriel-monitor-control:panel"

"XF86AudioRaiseVolume" = { action = "spawn noctalia msg volume-up", allow_when_locked = true }
"XF86AudioLowerVolume" = { action = "spawn noctalia msg volume-down", allow_when_locked = true }
"XF86AudioMute" = { action = "spawn noctalia msg volume-mute", allow_when_locked = true, repeat = false }
"XF86AudioPlay" = { action = "spawn noctalia msg media toggle", allow_when_locked = true, repeat = false }
"XF86AudioNext" = { action = "spawn noctalia msg media next", allow_when_locked = true }
"XF86AudioPrev" = { action = "spawn noctalia msg media previous", allow_when_locked = true }
"XF86MonBrightnessUp" = { action = "spawn noctalia msg brightness-up", allow_when_locked = true }
"XF86MonBrightnessDown" = { action = "spawn noctalia msg brightness-down", allow_when_locked = true }
EOF

    else

cat > "$UCFG/config.toml" <<'EOF'
[general]
autostart = ["noctalia"]
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
"Mod+Escape" = "session-quit"
"Mod+Shift+D" = "spawn noctalia msg panel-toggle muhammadessam/umbriel-monitor-control:panel"

"XF86AudioRaiseVolume" = { action = "spawn noctalia msg volume-up", allow_when_locked = true }
"XF86AudioLowerVolume" = { action = "spawn noctalia msg volume-down", allow_when_locked = true }
"XF86AudioMute" = { action = "spawn noctalia msg volume-mute", allow_when_locked = true, repeat = false }
"XF86AudioPlay" = { action = "spawn noctalia msg media toggle", allow_when_locked = true, repeat = false }
"XF86AudioNext" = { action = "spawn noctalia msg media next", allow_when_locked = true }
"XF86AudioPrev" = { action = "spawn noctalia msg media previous", allow_when_locked = true }
"XF86MonBrightnessUp" = { action = "spawn noctalia msg brightness-up", allow_when_locked = true }
"XF86MonBrightnessDown" = { action = "spawn noctalia msg brightness-down", allow_when_locked = true }
EOF

    fi

fi

chown -R "$TARGET_USER:$TARGET_GROUP" "$UCFG"

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

if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    runuser -u "$TARGET_USER" -- \
        env HOME="$TARGET_HOME" \
            XDG_CONFIG_HOME="$TARGET_HOME/.config" \
            xdg-user-dirs-update ||
        warn "xdg-user-dirs-update завершился с ошибкой."
else
    warn "xdg-user-dirs-update не найден."
fi

# ------------------------------------------------------------
# 17. System services
# ------------------------------------------------------------

enable_service() {
    local service="$1"

    if systemctl list-unit-files --type=service 2>/dev/null |
        grep -q "^${service}"
    then
        systemctl enable "$service" ||
            warn "Не удалось включить $service."
    fi
}

if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    enable_service NetworkManager.service
    enable_service bluetooth.service
    enable_service cups.service

    if ! systemctl is-enabled NetworkManager.service >/dev/null 2>&1; then
        warn "NetworkManager.service не включён."
    fi

    if ! systemctl is-enabled bluetooth.service >/dev/null 2>&1; then
        warn "bluetooth.service не включён."
    fi
else
    warn "systemd не запущен. Включи NetworkManager, bluetooth и cups вручную."
fi

# ------------------------------------------------------------
# 18. Umbriel validation
# ------------------------------------------------------------

if command -v umbriel >/dev/null 2>&1; then

    info "Проверка конфигурации Umbriel..."

    UMBRIEL_RUNTIME="$(mktemp -d /tmp/umbriel-validate.XXXXXX)"
    chown "$TARGET_USER:$TARGET_GROUP" "$UMBRIEL_RUNTIME"
    chmod 700 "$UMBRIEL_RUNTIME"

    if ! runuser -u "$TARGET_USER" -- \
        env HOME="$TARGET_HOME" \
            XDG_CONFIG_HOME="$TARGET_HOME/.config" \
            XDG_RUNTIME_DIR="$UMBRIEL_RUNTIME" \
            umbriel config validate
    then
        warn "Конфигурация Umbriel не прошла проверку."
        warn "Не включай Greeter до исправления ошибки."
    fi

    rm -rf "$UMBRIEL_RUNTIME"
fi

# ------------------------------------------------------------
# 19. Greeter activation
# ------------------------------------------------------------

if [[ "$ENABLE_GREETER" == "1" ]]; then

    if ! command -v systemctl >/dev/null 2>&1 ||
       [[ ! -d /run/systemd/system ]]
    then
        warn "systemd не запущен. Включи greetd вручную."

    elif systemctl is-enabled greetd.service >/dev/null 2>&1; then
        info "greetd уже включён."

    elif systemctl is-enabled display-manager.service >/dev/null 2>&1; then
        warn "Обнаружен другой display-manager."
        warn "Автоматическое переключение не выполнено."
        warn "Отключи его и включи greetd вручную:"
        warn "  systemctl disable --now <display-manager>"
        warn "  systemctl enable greetd.service"

    elif systemctl list-unit-files --type=service 2>/dev/null |
        grep -q '^greetd.service'
    then
        if systemctl enable greetd.service; then
            info "greetd включён для следующей загрузки."
        else
            warn "Не удалось включить greetd.service."
        fi

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

echo "Версия скрипта: $SCRIPT_VERSION"
echo "Debian: ${PRETTY_NAME:-unknown}"
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
echo "Super         - Launcher"
echo "Super+Enter   - Foot"
echo "Super+T       - Foot"
echo "Super+E       - Thunar"
echo "Super+Q       - Закрыть окно"
echo "Super+O       - Overview"
echo "Super+Escape  - Завершить сессию"
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
echo "5. yazi отсутствует в Debian 13; при необходимости установи вручную."
echo "6. VirtualBox Guest Additions устанавливаются вручную."
echo "7. Скрипт не устанавливает Quickshell."

echo
echo "=================================================="
