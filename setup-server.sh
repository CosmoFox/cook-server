#!/bin/bash

# Скрипт базовой настройки Ubuntu-сервера
# Обновление репозиториев, установка пакетов, Docker, UFW, swap

set -e

# ==============================
# Цвета для вывода
# ==============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ==============================
# Проверка root-прав
# ==============================
if [ "$(id -u)" -ne 0 ]; then
    log_error "Скрипт требует root-прав. Запустите с sudo."
    exit 1
fi

# ==============================
# Загрузка токенов из внешнего файла
# ==============================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# При запуске через bash <(curl ...) $0 указывает на /dev/fd/ —
# в таком случае сохраняем ключи и .token в текущем каталоге
if [[ "${SCRIPT_DIR}" == /dev/* ]] || [[ "${SCRIPT_DIR}" == /proc/* ]]; then
    SCRIPT_DIR="${PWD}"
fi

TOKEN_FILE="${SCRIPT_DIR}/.token"

if [[ ! -f "${TOKEN_FILE}" ]]; then
    log_warn "Файл ${TOKEN_FILE} не найден."
    echo ""
    echo -e "${CYAN}Хотите сгенерировать новую SSH-связку ключей?${NC}"
    echo -e "  Открытый ключ будет сохранён в ${TOKEN_FILE}"
    echo -e "  Закрытый ключ будет сохранён рядом со скриптом"
    echo ""
    read -p "Сгенерировать ключи? [y/N]: " GENERATE_CHOICE

    if [[ "${GENERATE_CHOICE}" =~ ^[Yy]$ ]]; then
        # Выбор типа ключа
        echo ""
        echo -e "${CYAN}Выберите тип ключа:${NC}"
        echo -e "  1. ED25519 (рекомендуется, быстрее, компактнее)"
        echo -e "  2. RSA 4096-bit (совместимость со старыми системами)"
        echo ""
        read -p "Тип ключа [1/2]: " KEY_TYPE_CHOICE

        case "${KEY_TYPE_CHOICE}" in
            2)
                KEY_TYPE="rsa"
                KEY_BITS="4096"
                KEY_PREFIX="id_rsa"
                KEYGEN_ARGS="-t rsa -b ${KEY_BITS} -m PEM"
                ;;
            *)
                KEY_TYPE="ed25519"
                KEY_BITS=""
                KEY_PREFIX="id_ed25519"
                KEYGEN_ARGS="-t ed25519"
                ;;
        esac

        # Выбор имени ключа
        echo ""
        echo -e "${CYAN}Как назвать файл ключа?${NC}"
        echo -e "  1. По hostname: ${KEY_PREFIX}_$(hostname -s 2>/dev/null || echo 'hostname')"
        echo -e "  2. По IP: ${KEY_PREFIX}_<ip-адрес>"
        echo -e "  3. Hostname + IP: ${KEY_PREFIX}_$(hostname -s 2>/dev/null || echo 'hostname')_<ip>"
        echo -e "  4. Ввести вручную"
        echo ""
        read -p "Вариант [1/2/3/4]: " KEY_NAME_CHOICE

        SERVER_IP=""
        case "${KEY_NAME_CHOICE}" in
            2|3)
                SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
                if [[ -z "${SERVER_IP}" ]]; then
                    read -p "IP-адрес сервера: " SERVER_IP
                fi
                ;;
        esac

        case "${KEY_NAME_CHOICE}" in
            1)
                KEY_NAME="${KEY_PREFIX}_$(hostname -s 2>/dev/null || echo 'server')"
                ;;
            2)
                KEY_NAME="${KEY_PREFIX}_${SERVER_IP}"
                ;;
            3)
                KEY_NAME="${KEY_PREFIX}_$(hostname -s 2>/dev/null || echo 'server')_${SERVER_IP}"
                ;;
            4)
                read -p "Введите имя файла ключа: " KEY_NAME
                KEY_NAME="${KEY_PREFIX}_${KEY_NAME}"
                ;;
            *)
                KEY_NAME="${KEY_PREFIX}_$(hostname -s 2>/dev/null || echo 'server')"
                log_warn "Неверный выбор, используем hostname."
                ;;
        esac

        KEY_PATH="${SCRIPT_DIR}/${KEY_NAME}"

        log_info "Генерация ${KEY_TYPE^^} ключа..."
        ssh-keygen ${KEYGEN_ARGS} -f "${KEY_PATH}" -N "" -C "root@${SERVER_IP:-$(hostname -s 2>/dev/null || echo 'vps')}"

        # Открытый ключ → .token
        cp "${KEY_PATH}.pub" "${TOKEN_FILE}"
        log_info "Открытый ключ сохранён в ${TOKEN_FILE}"

        # Защищаем приватный ключ
        chmod 600 "${KEY_PATH}"
        log_info "Закрытый ключ сохранён в ${KEY_PATH}"

        # Опция генерации .ppk для PuTTY
        echo ""
        read -p "Сгенерировать также .ppk для PuTTY? [y/N]: " PUTTY_CHOICE
        if [[ "${PUTTY_CHOICE}" =~ ^[Yy]$ ]]; then
            if command -v puttygen &>/dev/null; then
                puttygen "${KEY_PATH}" -o "${KEY_PATH}.ppk"
                chmod 600 "${KEY_PATH}.ppk"
                log_info "PuTTY-ключ сохранён в ${KEY_PATH}.ppk"
            else
                log_warn "puttygen не найден. Установите: apt install -y putty-tools"
            fi
        fi

        echo ""
        echo -e "${RED}════════════════════════════════════════${NC}"
        echo -e "${RED}  ⚠  ВНИМАНИЕ! НЕ ПРОДОЛЖАЙТЕ!  ⚠${NC}"
        echo -e "${RED}════════════════════════════════════════${NC}"
        echo ""
        echo -e "  Сейчас скрипт отключит вход по паролю."
        echo -e "  Если вы не скачаете закрытый ключ,"
        echo -e "  вы ${RED}ПОТЕРЯЕТЕ ДОСТУП${NC} к серверу!"
        echo ""
        echo -e "  Файл: ${YELLOW}${KEY_PATH}${NC}"
        echo ""
        echo -e "${RED}════════════════════════════════════════${NC}"
        echo ""
        read -p "Я скачал закрытый ключ, можно продолжить [y/N]: " CONFIRM_KEY
        if [[ ! "${CONFIRM_KEY}" =~ ^[Yy]$ ]]; then
            log_info "Остановлено. Скачайте ключ и запустите скрипт заново."
            exit 0
        fi

        # Удаляем .pub — он больше не нужен, всё есть в .token
        rm -f "${KEY_PATH}.pub"
    else
        log_error "Без SSH-ключа продолжить невозможно."
        exit 1
    fi
fi

SSH_AUTHORIZED_KEY="$(cat "${TOKEN_FILE}" | xargs)"

if [[ -z "${SSH_AUTHORIZED_KEY}" ]]; then
    log_error "Файл ${TOKEN_FILE} пуст."
    exit 1
fi

# ==============================
# Функции шагов
# ==============================

# 1. Обновление системы
step_update() {
    log_info "Обновление списков пакетов..."
    apt update -y

    log_info "Обновление установленных пакетов..."
    apt upgrade -y

    log_info "Удаление ненужных пакетов..."
    apt autoremove -y
    log_info "Система обновлена."
}

# 2. Установка базовых пакетов
step_packages() {
    log_info "Установка базовых пакетов..."
    apt install -y \
        curl \
        htop \
        mcedit \
        fail2ban \
        openssh-server
    log_info "Базовые пакеты установлены."
}

# 3. Установка Docker
step_docker() {
    log_info "Проверка установки Docker..."
    if command -v docker &> /dev/null; then
        log_warn "Docker уже установлен, пропускаем."
        return 0
    fi

    log_info "Установка Docker..."

    apt install -y ca-certificates gnupg lsb-release ufw

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt update -y
    apt install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker
    log_info "Docker успешно установлен."
}

# 4. Настройка swap-файла (2 ГБ)
step_swap() {
    log_info "Настройка swap-файла (2 ГБ)..."

    SWAPFILE="/swapfile"

    if [ -f "${SWAPFILE}" ] && swapon --show | grep -q "${SWAPFILE}"; then
        log_warn "Swap уже активен, пропускаем."
        return 0
    fi

    if [ -f "${SWAPFILE}" ]; then
        log_warn "Найден неактивный swap-файл, удаляем..."
        rm -f "${SWAPFILE}"
    fi

    log_info "Проверка свободного места для swap (нужно > 2 ГБ)..."
    FREE_SPACE=$(df / | tail -1 | awk '{print $4}')
    if [ "$FREE_SPACE" -lt 2097152 ]; then
        log_error "Недостаточно места для создания swap-файла (требуется более 2 ГБ)."
        return 1
    fi
    log_info "Создание swap-файла размером 2 ГБ..."
    dd if=/dev/zero of="${SWAPFILE}" bs=1M count=2048
    chmod 600 "${SWAPFILE}"
    mkswap "${SWAPFILE}"
    swapon "${SWAPFILE}"

    if ! grep -q "${SWAPFILE}" /etc/fstab; then
        echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
    fi

    log_info "Swap-файл создан и активирован."
}

# 5. Настройка UFW
step_ufw() {
    log_info "Настройка UFW..."

    ufw --force reset

    ufw default deny incoming
    ufw default allow outgoing

    ufw allow 2288/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'

    ufw --force enable
    log_info "UFW настроен и активен."
}

# 6. Настройка SSH
step_ssh() {
    log_info "Настройка SSH..."

    SSHD_CONFIG="/etc/ssh/sshd_config"

    cat > "${SSHD_CONFIG}" << EOF
Port 2288
PermitRootLogin yes
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
UsePAM yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    echo "${SSH_AUTHORIZED_KEY}" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    if systemctl is-active --quiet ssh; then
        systemctl restart ssh
    elif systemctl is-active --quiet sshd; then
        systemctl restart sshd
    else
        systemctl restart ssh
    fi
    log_info "SSH настроен: порт 2288, только ключи, root-доступ разрешён."
}

# 7. Настройка fail2ban
step_fail2ban() {
    log_info "Настройка fail2ban..."

    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 24h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port    = 2288
filter  = sshd
logpath = /var/log/auth.log
maxretry = 3
EOF

    systemctl enable --now fail2ban
    log_info "fail2ban настроен."
}

# ==============================
# Массив шагов
# ==============================
STEP_NAMES=(
    "Обновление системы"
    "Установка базовых пакетов"
    "Установка Docker"
    "Настройка swap (2 ГБ)"
    "Настройка UFW"
    "Настройка SSH"
    "Настройка fail2ban"
)

STEP_FUNCS=(
    step_update
    step_packages
    step_docker
    step_swap
    step_ufw
    step_ssh
    step_fail2ban
)

TOTAL_STEPS=${#STEP_NAMES[@]}

# ==============================
# Интерактивное меню
# ==============================
# Массив выбора: 0 = не выбран, 1 = выбран
SELECTED_STATE=()
for ((i = 0; i < TOTAL_STEPS; i++)); do
    SELECTED_STATE+=(0)
done

# Позиция курсора (0-based)
CURSOR=0

render_menu() {
    # Очищаем экран и перемещаем курсор наверх
    clear
    echo -e "${YELLOW}==========================================${NC}"
    echo -e "${YELLOW}   Базовая настройка VPS Ubuntu-сервера   ${NC}"
    echo -e "${YELLOW}==========================================${NC}"
    echo ""
    echo -e "  ${CYAN}Пробел${NC} — отметить/снять  |  ${CYAN}↑↓${NC} — навигация  |  ${CYAN}A${NC} — все  |  ${CYAN}N${NC} — сброс  |  ${CYAN}Enter${NC} — запустить"
    echo ""
    for ((i = 0; i < TOTAL_STEPS; i++)); do
        NUM=$((i + 1))
        if [[ "${SELECTED_STATE[$i]}" == "1" ]]; then
            BOX="[${GREEN}X${NC}]"
        else
            BOX="[ ]"
        fi
        if [[ "$i" == "$CURSOR" ]]; then
            echo -e "  ${YELLOW}▸${NC} ${BOX} ${NUM}. ${STEP_NAMES[$i]}"
        else
            echo -e "    ${BOX} ${NUM}. ${STEP_NAMES[$i]}"
        fi
    done
    echo ""
}

render_menu

while true; do
    # Считываем один символ без Enter, IFS= чтобы не съедать пробел
    IFS= read -rsn1 KEY

    case "$KEY" in
        # Пробел — переключить текущий
        ' ')
            if [[ "${SELECTED_STATE[$CURSOR]}" == "1" ]]; then
                SELECTED_STATE[$CURSOR]=0
            else
                SELECTED_STATE[$CURSOR]=1
            fi
            render_menu
            ;;
        # Стрелка вверх
        $'\x1b')
            read -rsn2 SEQ
            case "$SEQ" in
                '[A') # вверх
                    if [[ "$CURSOR" -gt 0 ]]; then
                        CURSOR=$((CURSOR - 1))
                        render_menu
                    fi
                    ;;
                '[B') # вниз
                    if [[ "$CURSOR" -lt $((TOTAL_STEPS - 1)) ]]; then
                        CURSOR=$((CURSOR + 1))
                        render_menu
                    fi
                    ;;
            esac
            ;;
        # Enter — запуск
        '')
            # Проверяем, есть ли выбранные
            HAS_SELECTED=false
            for s in "${SELECTED_STATE[@]}"; do
                if [[ "$s" == "1" ]]; then
                    HAS_SELECTED=true
                    break
                fi
            done
            if ! $HAS_SELECTED; then
                render_menu
                echo -e "  ${RED}Не выбрано ни одного шага!${NC}"
                continue
            fi
            break
            ;;
        # A — выбрать все
        [Aa])
            for ((i = 0; i < TOTAL_STEPS; i++)); do
                SELECTED_STATE[$i]=1
            done
            render_menu
            ;;
        # N — снять все
        [Nn])
            for ((i = 0; i < TOTAL_STEPS; i++)); do
                SELECTED_STATE[$i]=0
            done
            render_menu
            ;;
    esac
done

# Собираем индексы выбранных шагов
SELECTED_INDICES=()
for ((i = 0; i < TOTAL_STEPS; i++)); do
    if [[ "${SELECTED_STATE[$i]}" == "1" ]]; then
        SELECTED_INDICES+=("$i")
    fi
done

# ==============================
# Подтверждение запуска
# ==============================
echo ""
echo -e "${CYAN}Будут выполнены следующие шаги:${NC}"
for idx in "${SELECTED_INDICES[@]}"; do
    echo -e "  ${GREEN}→${NC} ${STEP_NAMES[$idx]}"
done
echo ""
read -p "Продолжить? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    log_info "Отменено пользователем."
    exit 0
fi

# ==============================
# Запуск выбранных шагов
# ==============================
echo ""
log_info "Запуск выбранных шагов..."
echo ""

for idx in "${SELECTED_INDICES[@]}"; do
    STEP_NUM=$((idx + 1))
    echo -e "${YELLOW}────────────────────────────────────────${NC}"
    log_info "Шаг ${STEP_NUM}: ${STEP_NAMES[$idx]}"
    echo -e "${YELLOW}────────────────────────────────────────${NC}"
    ${STEP_FUNCS[$idx]}
    echo ""
done

# ==============================
# Итоговая информация
# ==============================
log_info "Выбранные шаги выполнены."

# Показываем статус запущенных сервисов
for idx in "${SELECTED_INDICES[@]}"; do
    case "${STEP_NAMES[$idx]}" in
        *"UFW"*)
            echo ""
            log_info "Статус UFW:"
            ufw status verbose
            ;;
        *"Docker"*)
            echo ""
            log_info "Версия Docker:"
            docker --version
            ;;
        *"fail2ban"*)
            echo ""
            log_info "Статус fail2ban:"
            fail2ban-client status
            ;;
    esac
done

# ==============================
# Предложение перезагрузки
# ==============================
echo ""
log_info "Для применения всех обновлений рекомендуется перезагрузка."
read -p "Перезагрузить сервер сейчас? [y/N]: " REBOOT_CHOICE
if [[ "${REBOOT_CHOICE}" =~ ^[Yy]$ ]]; then
    log_info "Перезагрузка..."
    reboot
else
    log_info "Перезагрузка отменена. Перезагрузитесь вручную, когда удобно."
fi
