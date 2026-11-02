#!/usr/bin/env bash
# Final Russian Debian 13 (Trixie) installer: MangoWM + Noctalia.
# Run as the regular desktop user with sudo rights. This script does not run as root.
# It installs packages, configures greetd, and deploys a validated modular Mango config.

set -Eeuo pipefail

BUTTERREPO_BOOTSTRAP_URL="https://justaguy.dev/drew/butterscripts/raw/branch/main/setup/add_butterrepo.sh"
NOCTALIA_KEYRING_URL="https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb"
NOCTALIA_SOURCES_URL="https://pkg.noctalia.dev/deb/noctalia-trixie.sources"
STAMP="$(date +'%Y%m%d-%H%M%S')"
WORKDIR="$(mktemp -d)"
STAGE="$(mktemp -d)"
BACKUP_DIR="$HOME/.config/mango-backups"
SYSTEM_BACKUP_DIR="/var/backups/mango-noctalia-$STAMP"
CONFIG_DIR="$HOME/.config/mango"

cleanup() { rm -rf "$WORKDIR" "$STAGE"; }
trap cleanup EXIT

fail() { printf '\nОШИБКА: %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -ne 0 ]] || fail "Запусти скрипт от обычного пользователя, не через sudo bash."
command -v sudo >/dev/null 2>&1 || fail "Команда sudo не найдена."
command -v wget >/dev/null 2>&1 || fail "Сначала установи wget."

if [[ ! -r /etc/os-release ]]; then fail "Не найден /etc/os-release."; fi
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" && "${VERSION_CODENAME:-}" == "trixie" ]] || \
  fail "Этот установщик рассчитан именно на Debian 13 (Trixie). Обнаружено: ${PRETTY_NAME:-unknown}."

printf '\n======================================================\n'
printf ' Debian 13 + MangoWM + Noctalia — установщик v7 с автоопределением драйверов\n'
printf '======================================================\n\n'
printf 'Будут установлены MangoWM, Noctalia, greetd и необходимые\n'
printf 'системные компоненты. Конфигурация Mango будет проверена\n'
printf 'командой mango -p до её установки.\n\n'
printf 'Курсор останется обычным: никаких cursor trails / particles.\n'
printf 'Системный полный upgrade не выполняется.\n\n'
read -r -p 'Продолжить? [y/N] ' ANSWER
[[ "$ANSWER" =~ ^[YyДд]$ ]] || { printf 'Отменено.\n'; exit 0; }

sudo -v
sudo install -d -m 0755 "$SYSTEM_BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

backup_system_file() {
    local file="$1"
    if sudo test -f "$file"; then
        sudo cp -a "$file" "$SYSTEM_BACKUP_DIR/$(basename "$file").bak"
    fi
}
backup_system_file /etc/locale.gen
backup_system_file /etc/default/locale
backup_system_file /etc/default/keyboard
backup_system_file /etc/greetd/config.toml

# Refresh package metadata, then add the Butterrepo bootstrap as a local file
# instead of piping a network response directly into bash.
sudo apt-get update
wget -qO "$WORKDIR/add_butterrepo.sh" "$BUTTERREPO_BOOTSTRAP_URL" || fail "Не удалось скачать установщик Butterrepo."
[[ -s "$WORKDIR/add_butterrepo.sh" ]] || fail "Файл Butterrepo пустой."
bash "$WORKDIR/add_butterrepo.sh"
sudo apt-get update

# Install MangoWM and the basic Wayland desktop stack from Debian + Butterrepo.
sudo apt-get install -y \
    mangowc xwayland \
    greetd tuigreet \
    foot thunar thunar-volman firefox-esr firefox-esr-l10n-ru \
    gvfs gvfs-backends udisks2 tumbler file-roller \
    network-manager \
    pipewire-audio wireplumber pavucontrol \
    polkitd lxqt-policykit \
    grim slurp wl-clipboard wlr-randr \
    swaylock brightnessctl \
    xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk \
    dbus-user-session xdg-utils xdg-user-dirs \
    ca-certificates wget curl gnupg locales keyboard-configuration python3 pciutils \
    mesa-vulkan-drivers mesa-va-drivers mesa-vdpau-drivers \
    fonts-noto-core fonts-noto-color-emoji fonts-dejavu-core

# Detect the execution environment and install only matching guest/hardware tools.
# Virtual-machine packages are deliberately not mixed: each hypervisor has its own agent.
VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || true)"
[[ -n "$VIRT_TYPE" ]] || VIRT_TYPE="none"

apt_candidate_exists() {
    local package="$1" candidate
    candidate="$(apt-cache policy "$package" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

install_available_packages() {
    local package
    local -a available=()
    for package in "$@"; do
        if apt_candidate_exists "$package"; then
            available+=("$package")
        else
            printf 'Пакет %s недоступен в подключённых репозиториях — пропускаю.\n' "$package"
        fi
    done
    if ((${#available[@]})); then
        sudo apt-get install -y "${available[@]}"
    fi
}

printf '\nОбнаруженная платформа: %s\n' "$VIRT_TYPE"
case "$VIRT_TYPE" in
    kvm|qemu)
        printf 'Устанавливаю интеграцию QEMU/KVM и SPICE (включая GNOME Boxes).\n'
        install_available_packages qemu-guest-agent spice-vdagent spice-webdavd
        if dpkg-query -W -f='${Status}' qemu-guest-agent 2>/dev/null | grep -q 'install ok installed'; then
            sudo systemctl enable qemu-guest-agent.service || true
        fi
        ;;
    oracle)
        printf 'Обнаружена Oracle VirtualBox. Проверяю доступность Guest Additions в Debian-репозиториях.\n'
        install_available_packages virtualbox-guest-utils virtualbox-guest-x11
        if ! dpkg-query -W -f='${Status}' virtualbox-guest-utils 2>/dev/null | grep -q 'install ok installed' && \
           ! dpkg-query -W -f='${Status}' virtualbox-guest-x11 2>/dev/null | grep -q 'install ok installed'; then
            printf 'В подключённых репозиториях нет VirtualBox Guest Additions.\n'
            printf 'Не подключаю сторонние репозитории автоматически: используй ISO Guest Additions из меню VirtualBox.\n'
        fi
        ;;
    vmware)
        printf 'Устанавливаю VMware Tools из пакетов Debian.\n'
        install_available_packages open-vm-tools open-vm-tools-desktop
        ;;
    microsoft)
        printf 'Обнаружена виртуальная машина Hyper-V.\n'
        install_available_packages hyperv-daemons
        ;;
    xen)
        printf 'Обнаружена виртуальная машина Xen.\n'
        install_available_packages xe-guest-utilities
        ;;
    none)
        printf 'Обнаружено физическое оборудование (bare metal). Ядро использует встроенные драйверы; подбираю микрокод и firmware по PCI ID.\n'
        PCI_LIST="$(lspci -nn 2>/dev/null || true)"
        GPU_LIST="$(printf '%s\n' "$PCI_LIST" | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)"
        NET_LIST="$(printf '%s\n' "$PCI_LIST" | grep -Ei 'Network controller|Wireless|Ethernet controller' || true)"
        CPU_VENDOR="$(awk -F: '/vendor_id/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
        case "$CPU_VENDOR" in
            GenuineIntel) install_available_packages intel-microcode ;;
            AuthenticAMD) install_available_packages amd64-microcode ;;
        esac
        if [[ "$GPU_LIST" == *"[8086:"* ]]; then
            install_available_packages firmware-intel-graphics
        fi
        if [[ "$GPU_LIST" == *"[1002:"* ]]; then
            install_available_packages firmware-amd-graphics
        fi
        if [[ "$NET_LIST" == *"[8086:"* ]]; then
            install_available_packages firmware-iwlwifi
        fi
        if [[ "$NET_LIST" == *"[10ec:"* ]]; then
            install_available_packages firmware-realtek
        fi
        if [[ "$NET_LIST" == *"[14e4:"* ]]; then
            install_available_packages firmware-brcm80211 firmware-bnx2
        fi
        if [[ "$NET_LIST" == *"[168c:"* ]]; then
            install_available_packages firmware-atheros
        fi
        if [[ "$NET_LIST" == *"[14c3:"* ]]; then
            install_available_packages firmware-mediatek
        fi
        # NVIDIA's proprietary driver can require Secure Boot/MOK enrollment and a reboot.
        if [[ "$PCI_LIST" == *"[10de:"* ]]; then
            printf '\nОбнаружена видеокарта NVIDIA. Драйвер nvidia-driver проприетарный.\n'
            if apt_candidate_exists nvidia-driver; then
                read -r -p 'Установить драйвер NVIDIA из подключённых Debian-репозиториев? [y/N] ' NVIDIA_ANSWER
                if [[ "$NVIDIA_ANSWER" =~ ^[YyДд]$ ]]; then
                    install_available_packages nvidia-driver firmware-nvidia-graphics firmware-misc-nonfree
                else
                    printf 'Драйвер NVIDIA пропущен. Будет использоваться доступный драйвер ядра/Mesa.\n'
                fi
            else
                printf 'Пакет nvidia-driver не найден. Проверь компоненты contrib и non-free в APT sources.\n'
            fi
        fi
        ;;
    *)
        printf 'Неизвестный тип виртуализации (%s). Устанавливаю только общие графические компоненты Mesa.\n' "$VIRT_TYPE"
        ;;
esac

# Generic firmware bundle is useful for many laptop Wi-Fi/Bluetooth/audio devices.
# Install it only when available; Debian needs the non-free-firmware repository component.
if [[ "$VIRT_TYPE" == "none" ]]; then
    install_available_packages firmware-linux firmware-misc-nonfree
fi

# Install Noctalia from its official Debian Trixie APT repository.
wget -qO "$WORKDIR/nickh-archive-keyring.deb" "$NOCTALIA_KEYRING_URL" || fail "Не удалось скачать Noctalia keyring."
sudo apt-get install -y "$WORKDIR/nickh-archive-keyring.deb"
wget -qO "$WORKDIR/noctalia-trixie.sources" "$NOCTALIA_SOURCES_URL" || fail "Не удалось скачать Noctalia repository file."
sudo install -m 0644 "$WORKDIR/noctalia-trixie.sources" /etc/apt/sources.list.d/noctalia-trixie.sources
sudo apt-get update
sudo apt-get install -y noctalia

command -v mango >/dev/null 2>&1 || fail "Пакет mangowc установлен, но команда mango не найдена."
command -v noctalia >/dev/null 2>&1 || fail "Noctalia установлен, но команда noctalia не найдена."

# Mango 0.18 renamed several configuration keys. Select names according to
# the actual installed Debian package version, rather than guessing.
MANGO_VERSION="$(dpkg-query -W -f='${Version}' mangowc 2>/dev/null || true)"
[[ -n "$MANGO_VERSION" ]] || MANGO_VERSION="0.0.0"
if dpkg --compare-versions "$MANGO_VERSION" ge "0.18.0"; then
    EXEC_ONCE_KEY="exec_once"
    MASTER_FACTOR_KEY="default_master_factor"
    AUTO_RELOAD_LINE="auto_reload_config=1"
else
    EXEC_ONCE_KEY="exec-once"
    MASTER_FACTOR_KEY="default_mfact"
    AUTO_RELOAD_LINE="# auto_reload_config is available in Mango 0.18.0+"
fi

# Noctalia's current CLI supports daemon mode. Use it where available so
# Mango's startup command returns after the shell has initialized.
if noctalia --help 2>&1 | grep -q -- '--daemon'; then
    NOCTALIA_START="noctalia --daemon"
else
    NOCTALIA_START="noctalia"
fi

mkdir -p "$STAGE" "$CONFIG_DIR" "$HOME/.local/bin"

cat > "$STAGE/config.conf" <<'MANGO'
# Главный файл конфигурации. Остальные настройки разделены по файлам.
source=./settings.conf
source=./autostart.conf
source=./keybinds.conf
MANGO

cat > "$STAGE/settings.conf" <<MANGO
# Раскладки: английская и русская; переключение — Alt+Shift.
xkb_rules_layout=us,ru
xkb_rules_options=grp:alt_shift_toggle

# Layout cycle: Tile -> Scroller -> Monocle.
circle_layout=tile,scroller,monocle
new_is_master=1
${MASTER_FACTOR_KEY}=0.55
${AUTO_RELOAD_LINE}
MANGO

cat > "$STAGE/autostart.conf" <<MANGO
# Перед запуском Noctalia передаём переменные окружения Wayland-сессии.
${EXEC_ONCE_KEY}=dbus-update-activation-environment --systemd WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP MANGO_INSTANCE_SIGNATURE LANG LANGUAGE LC_MESSAGES && ${NOCTALIA_START}
# Графические запросы пароля администратора (монтирование дисков и т. п.).
${EXEC_ONCE_KEY}=lxqt-policykit-agent
MANGO

cat > "$STAGE/keybinds.conf" <<'MANGO'
# Сочетания клавиш MangoWM. Описания и памятка для пользователя — на русском.
# Анимация курсора и следы за курсором НЕ устанавливаются.

# --- Приложения и оболочка Noctalia ---
bind=SUPER,Return,spawn,foot
bind=SUPER,space,spawn,noctalia msg panel-toggle launcher
bind=SUPER,s,spawn,noctalia msg panel-toggle control-center
bind=SUPER+ALT,comma,spawn,noctalia msg settings-toggle
bind=SUPER,e,spawn,thunar
bind=SUPER,b,spawn,firefox-esr
bind=SUPER+SHIFT,b,spawn,firefox-esr --private-window
bind=SUPER+CTRL,l,spawn,swaylock -f

# --- Управление окнами ---
bind=SUPER,q,killclient,
bind=SUPER+SHIFT,q,quit
bind=SUPER+SHIFT,r,reload_config
bind=SUPER+SHIFT,space,togglefloating,
bind=SUPER+SHIFT,f,togglefullscreen,
bind=SUPER,Tab,toggleoverview,
bind=ALT,Tab,focusstack,next
bind=ALT+SHIFT,Tab,focusstack,prev

# Переключение фокуса между окнами: Super + стрелки или H/J/K/L.
bind=SUPER,Left,focusdir,left
bind=SUPER,Down,focusdir,down
bind=SUPER,Up,focusdir,up
bind=SUPER,Right,focusdir,right
bind=SUPER,h,focusdir,left
bind=SUPER,j,focusdir,down
bind=SUPER,k,focusdir,up
bind=SUPER,l,focusdir,right

# Перемещение окон.
bind=SUPER+SHIFT,Left,exchange_client,left
bind=SUPER+SHIFT,Down,exchange_client,down
bind=SUPER+SHIFT,Up,exchange_client,up
bind=SUPER+SHIFT,Right,exchange_client,right
bind=SUPER+SHIFT,h,exchange_client,left
bind=SUPER+SHIFT,j,exchange_client,down
bind=SUPER+SHIFT,k,exchange_client,up
bind=SUPER+SHIFT,l,exchange_client,right

# Размер основной области и количество основных окон.
bind=SUPER+CTRL,Left,setmfact,-0.02
bind=SUPER+CTRL,Right,setmfact,+0.02
bind=SUPER+CTRL,Up,incnmaster,+1
bind=SUPER+CTRL,Down,incnmaster,-1

# --- Раскладки окон ---
bind=SUPER,t,switch_layout
bind=SUPER+ALT,t,setlayout,tile
bind=SUPER+ALT,s,setlayout,scroller
bind=SUPER+ALT,m,setlayout,monocle
bind=SUPER,w,setlayout,monocle
bind=SUPER+ALT,g,togglegaps
bind=SUPER+ALT,minus,incgaps,-1
bind=SUPER+ALT,equal,incgaps,+1

# --- Рабочие пространства 1–9 ---
bind=SUPER,1,view,1
bind=SUPER,2,view,2
bind=SUPER,3,view,3
bind=SUPER,4,view,4
bind=SUPER,5,view,5
bind=SUPER,6,view,6
bind=SUPER,7,view,7
bind=SUPER,8,view,8
bind=SUPER,9,view,9
bind=SUPER+SHIFT,1,tag,1
bind=SUPER+SHIFT,2,tag,2
bind=SUPER+SHIFT,3,tag,3
bind=SUPER+SHIFT,4,tag,4
bind=SUPER+SHIFT,5,tag,5
bind=SUPER+SHIFT,6,tag,6
bind=SUPER+SHIFT,7,tag,7
bind=SUPER+SHIFT,8,tag,8
bind=SUPER+SHIFT,9,tag,9
bind=SUPER,bracketleft,viewtoleft
bind=SUPER,bracketright,viewtoright

# --- Несколько мониторов ---
bind=SUPER,comma,focusmon,left
bind=SUPER,period,focusmon,right
bind=SUPER+SHIFT,comma,tagmon,left
bind=SUPER+SHIFT,period,tagmon,right

# --- Звук, мультимедиа и яркость через Noctalia ---
bind=NONE,XF86AudioRaiseVolume,spawn,noctalia msg volume-up
bind=NONE,XF86AudioLowerVolume,spawn,noctalia msg volume-down
bind=NONE,XF86AudioMute,spawn,noctalia msg volume-mute
bind=NONE,XF86AudioPlay,spawn,noctalia msg media toggle
bind=NONE,XF86AudioPause,spawn,noctalia msg media toggle
bind=NONE,XF86AudioNext,spawn,noctalia msg media next
bind=NONE,XF86AudioPrev,spawn,noctalia msg media previous
bind=NONE,XF86MonBrightnessUp,spawn,noctalia msg brightness-up
bind=NONE,XF86MonBrightnessDown,spawn,noctalia msg brightness-down

# --- Снимки экрана средствами Noctalia ---
bind=NONE,Print,spawn,noctalia msg screenshot-fullscreen
bind=SHIFT,Print,spawn,noctalia msg screenshot-region --annotate
bind=CTRL,Print,spawn,noctalia msg screenshot-region --no-annotate --copy-to-clipboard --no-save-to-file
bind=SUPER+SHIFT,a,spawn,noctalia msg screenshot-annotate

# --- Управление мышью ---
mousebind=SUPER,btn_left,moveresize,curmove
mousebind=SUPER,btn_right,moveresize,curresize
axisbind=SUPER,UP,viewtoleft
axisbind=SUPER,DOWN,viewtoright
MANGO

# Stage and validate every sourced file before replacing the user's config.
if ! mango -c "$STAGE/config.conf" -p; then
    printf '\nMangoWM отклонил тестовую конфигурацию. Старые файлы не заменены.\n' >&2
    printf 'Версия пакета mangowc: %s\n' "$MANGO_VERSION" >&2
    fail "Проверь вывод mango -p выше; установленные пакеты останутся на месте."
fi

# Back up any existing Mango configuration before installing the new one.
if [[ -d "$CONFIG_DIR" ]] && find "$CONFIG_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    tar -czf "$BACKUP_DIR/mango-config-$STAMP.tar.gz" -C "$HOME/.config" mango
    printf 'Пользовательская резервная копия: %s/mango-config-%s.tar.gz\n' "$BACKUP_DIR" "$STAMP"
fi

install -m 0644 "$STAGE/config.conf" "$CONFIG_DIR/config.conf"
install -m 0644 "$STAGE/settings.conf" "$CONFIG_DIR/settings.conf"
install -m 0644 "$STAGE/autostart.conf" "$CONFIG_DIR/autostart.conf"
install -m 0644 "$STAGE/keybinds.conf" "$CONFIG_DIR/keybinds.conf"

# Russian locale and console keyboard layout.
if ! grep -qE '^ru_RU\.UTF-8 UTF-8$' /etc/locale.gen; then
    if grep -qE '^# *ru_RU\.UTF-8 UTF-8$' /etc/locale.gen; then
        sudo sed -i 's/^# *ru_RU\.UTF-8 UTF-8$/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
    else
        printf '\nru_RU.UTF-8 UTF-8\n' | sudo tee -a /etc/locale.gen >/dev/null
    fi
fi
sudo locale-gen
sudo update-locale LANG=ru_RU.UTF-8 LANGUAGE=ru_RU:ru LC_MESSAGES=ru_RU.UTF-8
sudo tee /etc/default/keyboard >/dev/null <<'KBD'
XKBMODEL="pc105"
XKBLAYOUT="us,ru"
XKBVARIANT=""
XKBOPTIONS="grp:alt_shift_toggle"
BACKSPACE="guess"
KBD

# Создаём стандартные пользовательские каталоги с русскими названиями.
# xdg-user-dirs выбирает переводы по ru_RU.UTF-8 и сохраняет их в user-dirs.dirs.
mkdir -p "$HOME/.config"
LANG=ru_RU.UTF-8 LANGUAGE=ru_RU:ru xdg-user-dirs-update --force
DESKTOP_DIR="$(xdg-user-dir DESKTOP)"
DOWNLOAD_DIR="$(xdg-user-dir DOWNLOAD)"
TEMPLATES_DIR="$(xdg-user-dir TEMPLATES)"
PUBLIC_DIR="$(xdg-user-dir PUBLICSHARE)"
DOCUMENTS_DIR="$(xdg-user-dir DOCUMENTS)"
MUSIC_DIR="$(xdg-user-dir MUSIC)"
PICTURES_DIR="$(xdg-user-dir PICTURES)"
VIDEOS_DIR="$(xdg-user-dir VIDEOS)"
mkdir -p "$DESKTOP_DIR" "$DOWNLOAD_DIR" "$TEMPLATES_DIR" "$PUBLIC_DIR" \
         "$DOCUMENTS_DIR" "$MUSIC_DIR" "$PICTURES_DIR" "$VIDEOS_DIR" \
         "$PICTURES_DIR/Screenshots"
printf 'ru_RU\n' > "$HOME/.config/user-dirs.locale"

# Добавляем стандартные каталоги в боковую панель Thunar через GTK-закладки.
python3 - "$HOME" "$DESKTOP_DIR" "$DOCUMENTS_DIR" "$DOWNLOAD_DIR" \
    "$MUSIC_DIR" "$PICTURES_DIR" "$VIDEOS_DIR" "$TEMPLATES_DIR" "$PUBLIC_DIR" <<'PYBOOKMARKS'
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
]
bookmarks = home / ".config/gtk-3.0/bookmarks"
bookmarks.parent.mkdir(parents=True, exist_ok=True)
existing = bookmarks.read_text(encoding="utf-8").splitlines() if bookmarks.exists() else []
existing_uris = {line.split()[0] for line in existing if line.strip()}
for directory, label in entries:
    if directory == home:
        continue
    uri = "file://" + quote(str(directory), safe="/")
    if uri not in existing_uris:
        existing.append(f"{uri} {label}")
bookmarks.write_text("\n".join(existing).rstrip() + "\n", encoding="utf-8")
PYBOOKMARKS

# Памятка по сочетаниям клавиш сохраняется в папке «Документы».
cat > "$DOCUMENTS_DIR/Сочетания клавиш MangoWM.txt" <<'KEYS'
СОЧЕТАНИЯ КЛАВИШ MANGOWM + NOCTALIA

Обозначения:
Super — клавиша с логотипом Windows.
Alt, Ctrl, Shift — соответствующие клавиши клавиатуры.
Alt + Shift                    Переключить язык ввода (EN/RU)

ПРИЛОЖЕНИЯ
Super + Enter                 Открыть терминал
Super + Пробел                Открыть меню приложений
Super + S                     Открыть центр управления Noctalia
Super + Alt + ,               Открыть настройки Noctalia
Super + E                     Открыть файловый менеджер
Super + B                     Открыть браузер
Super + Shift + B             Открыть приватное окно браузера
Super + Ctrl + L              Заблокировать экран

УПРАВЛЕНИЕ ОКНАМИ
Super + Q                     Закрыть активное окно
Super + Shift + Q             Завершить MangoWM (выход из сеанса)
Super + Shift + R             Перезагрузить конфигурацию MangoWM
Super + Shift + Пробел        Переключить плавающий режим окна
Super + Shift + F             Полноэкранный режим
Super + Tab                   Обзор окон
Alt + Tab                     Следующее окно
Alt + Shift + Tab             Предыдущее окно
Super + Стрелки               Переключить фокус между окнами
Super + H/J/K/L               Переключить фокус между окнами
Super + Shift + Стрелки       Переместить окно
Super + Shift + H/J/K/L       Переместить окно
Super + Ctrl + Влево/Вправо   Изменить размер основной области
Super + Ctrl + Вверх/Вниз     Изменить число основных окон

РАСКЛАДКИ ОКОН
Super + T                     Переключать раскладки по кругу
Super + Alt + T               Мозаичная раскладка
Super + Alt + S               Прокручиваемая раскладка
Super + Alt + M               Одно окно на весь экран
Super + W                     Одно окно на весь экран
Super + Alt + G               Включить/выключить промежутки между окнами
Super + Alt + - / =           Уменьшить/увеличить промежутки

РАБОЧИЕ ПРОСТРАНСТВА
Super + 1…9                   Перейти на рабочее пространство 1…9
Super + Shift + 1…9           Переместить окно на пространство 1…9
Super + [ / ]                 Предыдущее / следующее пространство

МОНИТОРЫ
Super + , / .                 Предыдущий / следующий монитор
Super + Shift + , / .         Переместить окно на предыдущий / следующий монитор

ЗВУК И ЭКРАН
Клавиши мультимедиа          Громкость и управление воспроизведением
Клавиши яркости              Яркость экрана
Print                         Снимок всего экрана
Shift + Print                 Снимок выбранной области с аннотацией
Ctrl + Print                  Скопировать снимок области в буфер обмена
Super + Shift + A             Редактор снимков экрана

МЫШЬ
Super + Левая кнопка          Переместить окно
Super + Правая кнопка         Изменить размер окна
Super + Колесо вверх/вниз     Переключить рабочее пространство
KEYS

# XDG portals: GTK file chooser; wlroots portal for screen capture.
mkdir -p "$HOME/.config/xdg-desktop-portal"
cat > "$HOME/.config/xdg-desktop-portal/portals.conf" <<'PORTAL'
[preferred]
default=wlr;gtk
org.freedesktop.impl.portal.FileChooser=gtk
org.freedesktop.impl.portal.Settings=gtk
PORTAL

# greetd + tuigreet login screen. Backups of pre-existing system files were made above.
sudo install -d -m 0755 /etc/greetd
sudo tee /etc/greetd/config.toml >/dev/null <<'GREETD'
[terminal]
vt = 7

[default_session]
command = "tuigreet --time --cmd mango"
user = "_greetd"
GREETD

sudo systemctl enable NetworkManager
sudo systemctl enable greetd

printf '\n======================================================\n'
printf 'Установка завершена.\n'
printf 'Debian: %s\n' "$PRETTY_NAME"
printf 'Платформа: %s\n' "$VIRT_TYPE"
printf 'MangoWM package: %s\n' "$MANGO_VERSION"
printf 'Noctalia: %s\n' "$(dpkg-query -W -f='${Version}' noctalia 2>/dev/null || echo installed)"
printf 'Mango config: %s\n' "$CONFIG_DIR"
printf 'System config backups: %s\n' "$SYSTEM_BACKUP_DIR"
printf '\nОсновные сочетания клавиш (Super — клавиша с логотипом Windows):\n'
printf '  Super + Enter                 Открыть терминал\n'
printf '  Super + Пробел                Открыть меню приложений\n'
printf '  Super + S                     Открыть центр управления\n'
printf '  Super + Alt + ,               Настройки Noctalia\n'
printf '  Super + T                     Переключать раскладки окон\n'
printf '  Super + Alt + T/S/M           Выбрать раскладку окон\n'
printf '  Super + H/J/K/L или стрелки   Переключить фокус окна\n'
printf '  Super + Shift + H/J/K/L       Переместить окно\n'
printf '  Super + 1…9                   Рабочие пространства\n'
printf '  Super + Shift + 1…9           Переместить окно на пространство\n'
printf '  Super + , / .                 Предыдущий / следующий монитор\n'
printf '  Super + Shift + R             Перезагрузить конфигурацию\n'
printf '  Print                         Снимок всего экрана\n'
printf '  Shift + Print                 Снимок области с аннотацией\n'
printf '  Ctrl + Print                  Скопировать снимок области\n'
printf '\nЯзык системы: русский (ru_RU.UTF-8). Alt + Shift — переключение EN/RU.\n'
printf 'Стандартные папки созданы и добавлены в закладки Thunar.\n'
printf 'Драйверы/гостевые агенты подобраны по платформе и обнаруженному оборудованию (см. вывод выше).\n'
printf 'Памятка по всем сочетаниям: %s/Сочетания клавиш MangoWM.txt\n' "$DOCUMENTS_DIR"
printf 'Перезагрузка компьютера: sudo reboot\n'
printf 'После входа MangoWM запустит Noctalia автоматически.\n'
printf 'Проверка конфигурации: mango -c ~/.config/mango/config.conf -p\n'
printf 'Резервная копия системных настроек: %s\n' "$SYSTEM_BACKUP_DIR"
printf 'Резервная копия MangoWM: %s\n' "$BACKUP_DIR"
