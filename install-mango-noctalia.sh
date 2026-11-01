#!/usr/bin/env bash
# Minimal Debian 13 + MangoWM (Butterrepo) + Noctalia installer.
# Target: clean Debian 13 (trixie), amd64. Run as the normal sudo-capable user.
# The Butterrepo bootstrap is downloaded, displayed, syntax-checked and requires
# explicit confirmation before execution. This script does not run MangoButter's
# full installer and does not build/replace Wayland, wlroots or SceneFX manually.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0"
BUTTERREPO_BOOTSTRAP_URL="https://justaguy.dev/drew/butterscripts/raw/branch/main/setup/add_butterrepo.sh"
NOCTALIA_KEYRING_URL="https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb"
NOCTALIA_SOURCES_URL="https://pkg.noctalia.dev/deb/noctalia-trixie.sources"
MIN_MANGO_VERSION="0.14.4-4"

WORKDIR="$(mktemp -d -t mango-noctalia.XXXXXXXX)"
LOG_FILE="$HOME/mango-noctalia-install.log"
BACKUP_DIR="$HOME/.local/state/mango-noctalia-backups/$(date +%Y%m%d-%H%M%S)"

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

log()  { printf '\033[1;36m[INFO]\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2; exit 1; }

backup_file() {
    local src="$1"
    if [[ -e "$src" ]]; then
        mkdir -p "$BACKUP_DIR$(dirname "$src")"
        cp -a "$src" "$BACKUP_DIR$src"
        log "Резервная копия: $src -> $BACKUP_DIR$src"
    fi
}

confirm() {
    local prompt="$1" answer
    read -r -p "$prompt [y/N] " answer || answer=""
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

printf '\nMangoWM + Noctalia для Debian 13 — установщик %s\n' "$SCRIPT_VERSION"
printf 'Журнал: %s\n\n' "$LOG_FILE"

# Run as a regular user so user-specific configuration is written to the right HOME.
[[ "$EUID" -ne 0 ]] || die "Не запускайте скрипт от root. Запустите его обычным пользователем с sudo."
[[ -n "${SUDO_USER:-}" ]] || true
command -v sudo >/dev/null 2>&1 || die "Не найден sudo. Установите sudo и добавьте пользователя в группу sudo."
sudo -v || die "Не удалось получить права sudo."

[[ -r /etc/os-release ]] || die "Не найден /etc/os-release."
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "Поддерживается только Debian, обнаружено: ${PRETTY_NAME:-неизвестно}."
[[ "${VERSION_ID:-}" == 13* ]] || die "Нужен Debian 13 Trixie, обнаружено: ${PRETTY_NAME:-неизвестно}."
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "Этот установщик рассчитан на amd64."

if systemctl is-active --quiet display-manager 2>/dev/null; then
    die "Уже работает display-manager. Скрипт рассчитан на чистый Debian без графического менеджера входа; сначала разберитесь с текущим DM."
fi

if ! id -nG "$USER" | grep -qw sudo; then
    warn "Пользователь $USER не отображается в группе sudo. Продолжаю, поскольку sudo уже сработал; проверьте права после установки."
fi

mkdir -p "$BACKUP_DIR"

log "Шаг 1/8: обновление индексов Debian и установка базовых инструментов."
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    ca-certificates wget curl gnupg sudo locales keyboard-configuration \
    dbus-user-session xdg-utils

# Butterrepo bootstrap: show the exact downloaded script before executing it.
log "Шаг 2/8: подготовка Butterrepo (сторонний репозиторий JustAGuyLinux)."
wget -O "$WORKDIR/add_butterrepo.sh" "$BUTTERREPO_BOOTSTRAP_URL" \
    || die "Не удалось скачать установщик Butterrepo: $BUTTERREPO_BOOTSTRAP_URL"
bash -n "$WORKDIR/add_butterrepo.sh" \
    || die "Скрипт Butterrepo не прошёл проверку bash -n. Ничего не выполнено."
printf '\n----- Содержимое add_butterrepo.sh (перед запуском) -----\n'
cat "$WORKDIR/add_butterrepo.sh"
printf '\n----- Конец add_butterrepo.sh -----\n\n'
warn "Butterrepo — сторонний репозиторий, не репозиторий Debian. Его пакеты будут обновляться через APT."
confirm "Вы просмотрели скрипт и согласны подключить Butterrepo?" \
    || die "Пользователь отменил подключение Butterrepo. Система не переведена на MangoWM."
bash "$WORKDIR/add_butterrepo.sh" \
    || die "Не удалось подключить Butterrepo. Проверьте вывод выше."

log "Обновление индексов после подключения Butterrepo."
sudo apt-get update
MANGO_POLICY="$(apt-cache policy mangowc 2>/dev/null || true)"
printf '%s\n' "$MANGO_POLICY"
grep -q 'apt\.justaguy\.dev' <<<"$MANGO_POLICY" \
    || die "APT не видит пакет mangowc из apt.justaguy.dev. Установка остановлена."
MANGO_CANDIDATE="$(awk '/Candidate:/ {print $2; exit}' <<<"$MANGO_POLICY")"
[[ -n "$MANGO_CANDIDATE" && "$MANGO_CANDIDATE" != "(none)" ]] \
    || die "У mangowc нет доступной версии-кандидата."
dpkg --compare-versions "$MANGO_CANDIDATE" ge "$MIN_MANGO_VERSION" \
    || die "В Butterrepo найден mangowc $MANGO_CANDIDATE, но требуется не ниже $MIN_MANGO_VERSION."

# Keep the JustAGuy repository low-priority for unrelated packages, while
# allowing the Mango compositor stack itself to receive APT updates.
log "Ограничение приоритета Butterrepo: обновления только для Mango-пакетов автоматически."
backup_file /etc/apt/preferences.d/limit-butterrepo-mango
sudo tee /etc/apt/preferences.d/limit-butterrepo-mango >/dev/null <<'PIN'
Package: mangowc libwlroots-0.19* libscenefx-0.4*
Pin: origin apt.justaguy.dev
Pin-Priority: 500

Package: *
Pin: origin apt.justaguy.dev
Pin-Priority: 100
PIN

log "Шаг 3/8: установка MangoWM и минимальных системных программ из Debian/Butterrepo."
sudo apt-get update
sudo apt-get install -y --no-install-recommends --no-remove \
    mangowc xwayland \
    greetd tuigreet \
    foot thunar firefox-esr \
    network-manager \
    pipewire-audio wireplumber \
    polkitd lxqt-policykit \
    grim slurp wl-clipboard wlr-randr \
    swaylock swayidle brightnessctl playerctl \
    xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk \
    pavucontrol \
    fonts-noto-core fonts-noto-color-emoji fonts-dejavu-core \
    xdg-user-dirs

# Confirm the package installed the compositor and (where supplied) the session wrapper.
command -v mango >/dev/null 2>&1 || die "Пакет mangowc установлен, но исполняемая команда mango не найдена."
if command -v mango-session >/dev/null 2>&1; then
    MANGO_SESSION_CMD="$(command -v mango-session)"
else
    MANGO_SESSION_CMD="$(command -v mango)"
    warn "Команда mango-session не найдена; greetd будет запускать mango напрямую."
fi

# Restrict render-node access to the current user when the group exists.
if getent group render >/dev/null 2>&1; then
    if ! id -nG "$USER" | tr ' ' '\n' | grep -qx render; then
        sudo usermod -aG render "$USER"
        warn "Пользователь добавлен в группу render. Изменение вступит в силу после нового входа."
    fi
fi

# Do not run two seat managers at once; MangoButter documents logind as the seat manager.
if systemctl is-active --quiet seatd 2>/dev/null; then
    warn "Обнаружен активный seatd. Отключаю его, чтобы Mango использовал systemd-logind."
    sudo systemctl disable --now seatd || true
fi

log "Шаг 4/8: установка Noctalia из официального APT-репозитория."
wget -O "$WORKDIR/nickh-archive-keyring.deb" "$NOCTALIA_KEYRING_URL" \
    || die "Не удалось скачать официальный keyring Noctalia."
sudo apt install -y "$WORKDIR/nickh-archive-keyring.deb"
backup_file /etc/apt/sources.list.d/noctalia-trixie.sources
wget -O "$WORKDIR/noctalia-trixie.sources" "$NOCTALIA_SOURCES_URL" \
    || die "Не удалось скачать официальный source-файл Noctalia."
sudo install -m 0644 "$WORKDIR/noctalia-trixie.sources" /etc/apt/sources.list.d/noctalia-trixie.sources
sudo apt-get update
NOCTALIA_CANDIDATE="$(apt-cache policy noctalia | awk '/Candidate:/ {print $2; exit}')"
[[ -n "$NOCTALIA_CANDIDATE" && "$NOCTALIA_CANDIDATE" != "(none)" ]] \
    || die "Официальный репозиторий Noctalia не предоставил пакет noctalia."
sudo apt-get install -y --no-install-recommends --no-remove noctalia
command -v noctalia >/dev/null 2>&1 || die "Пакет noctalia установлен, но команда noctalia не найдена."

log "Шаг 5/8: русская локаль и раскладки клавиатуры."
backup_file /etc/locale.gen
backup_file /etc/default/keyboard
if grep -qE '^#\s*ru_RU\.UTF-8 UTF-8' /etc/locale.gen; then
    sudo sed -i 's/^#\s*\(ru_RU\.UTF-8 UTF-8\)/\1/' /etc/locale.gen
elif ! grep -qE '^ru_RU\.UTF-8 UTF-8' /etc/locale.gen; then
    echo 'ru_RU.UTF-8 UTF-8' | sudo tee -a /etc/locale.gen >/dev/null
fi
sudo locale-gen ru_RU.UTF-8
sudo update-locale LANG=ru_RU.UTF-8
sudo tee /etc/default/keyboard >/dev/null <<'KBD'
XKBMODEL="pc105"
XKBLAYOUT="us,ru"
XKBVARIANT=""
XKBOPTIONS="grp:alt_shift_toggle"
BACKSPACE="guess"
KBD

log "Шаг 6/8: минимальная конфигурация MangoWM + Noctalia."
mkdir -p "$HOME/.config/mango" "$HOME/.config/xdg-desktop-portal"
MANGO_CONFIG="$HOME/.config/mango/config.conf"
if [[ -e "$MANGO_CONFIG" ]]; then
    cp -a "$MANGO_CONFIG" "$BACKUP_DIR/mango-config.conf"
    warn "Существующий Mango config сохранён в $BACKUP_DIR/mango-config.conf"
    if ! grep -q 'BEGIN NOCTALIA-MINIMAL' "$MANGO_CONFIG"; then
        cat >>"$MANGO_CONFIG" <<'MANGO_BLOCK'

# BEGIN NOCTALIA-MINIMAL
exec-once=dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP
exec-once=noctalia
xkb_rules_layout=us,ru
xkb_rules_options=grp:alt_shift_toggle
bind=SUPER,Return,spawn,foot
bind=SUPER,space,spawn,noctalia msg panel-toggle launcher
bind=SUPER,s,spawn,noctalia msg panel-toggle control-center
bind=SUPER,comma,spawn,noctalia msg settings-toggle
bind=SUPER,e,spawn,thunar
bind=SUPER,b,spawn,firefox-esr
bind=SUPER+CTRL,l,spawn,swaylock -f
bind=NONE,XF86AudioRaiseVolume,spawn,noctalia msg volume-up
bind=NONE,XF86AudioLowerVolume,spawn,noctalia msg volume-down
bind=NONE,XF86AudioMute,spawn,noctalia msg volume-mute
bind=NONE,XF86MonBrightnessUp,spawn,noctalia msg brightness-up
bind=NONE,XF86MonBrightnessDown,spawn,noctalia msg brightness-down
# END NOCTALIA-MINIMAL
MANGO_BLOCK
    fi
else
    cat >"$MANGO_CONFIG" <<'MANGO_CONFIG_EOF'
# Minimal MangoWM configuration for Noctalia v5.
# Super+Enter: terminal | Super+Space: launcher | Super+S: control center
exec-once=dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP
exec-once=noctalia
xkb_rules_layout=us,ru
xkb_rules_options=grp:alt_shift_toggle
bind=SUPER,Return,spawn,foot
bind=SUPER,space,spawn,noctalia msg panel-toggle launcher
bind=SUPER,s,spawn,noctalia msg panel-toggle control-center
bind=SUPER,comma,spawn,noctalia msg settings-toggle
bind=SUPER,e,spawn,thunar
bind=SUPER,b,spawn,firefox-esr
bind=SUPER,q,killclient
bind=SUPER+SHIFT,q,quit
bind=SUPER+CTRL,l,spawn,swaylock -f
bind=NONE,XF86AudioRaiseVolume,spawn,noctalia msg volume-up
bind=NONE,XF86AudioLowerVolume,spawn,noctalia msg volume-down
bind=NONE,XF86AudioMute,spawn,noctalia msg volume-mute
bind=NONE,XF86MonBrightnessUp,spawn,noctalia msg brightness-up
bind=NONE,XF86MonBrightnessDown,spawn,noctalia msg brightness-down
MANGO_CONFIG_EOF
fi

# Start a PolicyKit authentication agent in the Mango session if available.
if command -v lxqt-policykit-agent >/dev/null 2>&1; then
    if ! grep -q '^exec-once=lxqt-policykit-agent$' "$MANGO_CONFIG"; then
        printf '\nexec-once=lxqt-policykit-agent\n' >>"$MANGO_CONFIG"
    fi
fi

# Portal preference: wlroots backend for screencast/screenshot, GTK for file chooser/settings.
backup_file "$HOME/.config/xdg-desktop-portal/portals.conf"
cat >"$HOME/.config/xdg-desktop-portal/portals.conf" <<'PORTAL'
[preferred]
default=wlr;gtk
org.freedesktop.impl.portal.FileChooser=gtk
org.freedesktop.impl.portal.Settings=gtk
PORTAL

log "Проверка синтаксиса MangoWM."
if ! mango -c "$MANGO_CONFIG" -p; then
    die "MangoWM сообщил об ошибке в $MANGO_CONFIG. greetd оставлен выключенным; исправьте конфигурацию перед входом."
fi

log "Шаг 7/8: включение базовых системных служб."
sudo systemctl enable NetworkManager
# PipeWire is user-session software. Enable user units only when the user manager is reachable.
if [[ -n "${XDG_RUNTIME_DIR:-}" ]] && [[ -S "${XDG_RUNTIME_DIR}/bus" ]]; then
    systemctl --user enable pipewire.socket pipewire-pulse.socket wireplumber.service || \
        warn "Не удалось включить пользовательские службы PipeWire сейчас; они могут быть включены после нового входа."
else
    log "Пользовательская systemd-сессия недоступна в этом запуске; PipeWire включится при входе пользователя."
fi

# Configure greetd but keep it disabled until the user explicitly opts in.
backup_file /etc/greetd/config.toml
sudo install -d -m 0755 /etc/greetd
sudo tee /etc/greetd/config.toml >/dev/null <<GREETD
[terminal]
vt = 7

[default_session]
command = "tuigreet --time --cmd $MANGO_SESSION_CMD"
user = "_greetd"
GREETD
sudo systemctl disable --now greetd >/dev/null 2>&1 || true

log "Шаг 8/8: завершающая проверка."
printf '\nУстановленные версии:\n'
dpkg-query -W -f='${Package} ${Version}\n' mangowc noctalia greetd tuigreet 2>/dev/null || true
printf '\nMango session command: %s\n' "$MANGO_SESSION_CMD"
printf 'Mango config: %s\n' "$MANGO_CONFIG"
printf 'Backup directory: %s\n' "$BACKUP_DIR"
printf 'Log file: %s\n\n' "$LOG_FILE"

warn "Butterrepo — сторонний источник. Для Mango-пакетов настроен отдельный APT-приоритет; Noctalia обновляется из своего официального репозитория."
if confirm "Включить greetd сейчас? После этого следующий графический вход будет через tuigreet."; then
    sudo systemctl enable greetd
    if confirm "Запустить greetd прямо сейчас (переключит на экран входа VT7)?"; then
        sudo systemctl start greetd
    else
        log "greetd включён и запустится при следующей загрузке."
    fi
else
    log "greetd настроен, но оставлен выключенным. Включите позже: sudo systemctl enable --now greetd"
fi

printf '\n\033[1;32mГотово.\033[0m Перезагрузитесь после проверки конфигурации: sudo reboot\n'
printf 'Проверка обновлений: sudo apt update && sudo apt upgrade\n'
printf 'Noctalia IPC: noctalia msg --help\n'
printf 'Mango конфигурация: %s\n' "$MANGO_CONFIG"
