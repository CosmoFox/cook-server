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
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ==============================
# Аргументы командной строки
# ==============================
ARGS_ALL=false
ARGS_YES=false
ARGS_STEPS=""

print_help() {
	cat <<'EOF'
Использование: setup-server.sh [ОПЦИИ]

Без опций — интерактивное меню выбора шагов.

Опции:
  --all          Выполнить все шаги без меню
  --steps=СПИСОК Выполнить указанные шаги без меню (например: --steps=1,3,5)
  --yes, -y      Не запрашивать подтверждение перед запуском шагов
                 и не перезагружать сервер в конце
  --help, -h     Показать эту справку

Примеры:
  setup-server.sh                  интерактивное меню
  setup-server.sh --all            все шаги с подтверждением перед стартом
  setup-server.sh --all --yes      полностью неинтерактивный прогон
  setup-server.sh --steps=2,6      только базовые пакеты и настройка SSH

Примечание: в неинтерактивном режиме файл .token должен уже существовать —
скрипт никогда не подтверждает за пользователя загрузку закрытого ключа.
EOF
}

for arg in "$@"; do
	case "${arg}" in
	--all) ARGS_ALL=true ;;
	--yes | -y) ARGS_YES=true ;;
	--steps=*) ARGS_STEPS="${arg#--steps=}" ;;
	--steps)
		log_error "Опция --steps требует список шагов: --steps=1,3,5"
		exit 1
		;;
	--help | -h)
		print_help
		exit 0
		;;
	*)
		log_error "Неизвестная опция: ${arg}"
		echo ""
		print_help
		exit 1
		;;
	esac
done

if [[ "${ARGS_ALL}" == true && -n "${ARGS_STEPS}" ]]; then
	log_warn "Указаны одновременно --all и --steps — приоритет у --all."
	ARGS_STEPS=""
fi

# ==============================
# Проверка root-прав
# ==============================
if [ "$(id -u)" -ne 0 ]; then
	log_error "Скрипт требует root-прав. Запустите с sudo."
	exit 1
fi

# ==============================
# Проверка операционной системы
# ==============================
OS_ID=""
OS_VERSION=""
OS_PRETTY="неизвестна"
if [[ -r /etc/os-release ]]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	OS_ID="${ID:-}"
	OS_VERSION="${VERSION_ID:-}"
	OS_PRETTY="${PRETTY_NAME:-неизвестна}"
fi

OS_SUPPORTED=false
case "${OS_ID}" in
# Только LTS-релизы Ubuntu
ubuntu)
	if [[ " 20.04 22.04 24.04 26.04 " == *" ${OS_VERSION} "* ]]; then
		OS_SUPPORTED=true
	fi
	;;
debian)
	# Debian 11 (bullseye) исключён намеренно: LTS закончилась 2026-08-31
	if [[ " 12 13 " == *" ${OS_VERSION} "* ]]; then
		OS_SUPPORTED=true
	fi
	;;
esac

if [[ "${OS_SUPPORTED}" != true ]]; then
	log_warn "Обнаружена неподдерживаемая ОС: ${OS_PRETTY}."
	log_warn "Скрипт рассчитан на Ubuntu 20.04 / 22.04 / 24.04 / 26.04 и Debian 12 / 13."
	if [[ "${ARGS_YES}" != true ]]; then
		read -p "Продолжить на свой страх и риск? [y/N]: " OS_CONFIRM
		if [[ ! "${OS_CONFIRM}" =~ ^[Yy]$ ]]; then
			log_info "Отменено."
			exit 0
		fi
	else
		log_warn "Режим --yes: продолжаю без подтверждения."
	fi
fi

# ==============================
# Неинтерактивные apt-операции
# ==============================
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ==============================
# Загрузка токенов из внешнего файла
# ==============================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# При запуске через bash <(curl ...) $0 указывает на /dev/fd/ —
# в таком случае сохраняем ключи и .token в текущем каталоге
if [[ "${SCRIPT_DIR}" == /dev/* ]] || [[ "${SCRIPT_DIR}" == /proc/* ]]; then
	SCRIPT_DIR="${PWD}"
fi

# Весь прогон дублируется в лог для разбора проблем постфактум
LOG_FILE="${SCRIPT_DIR}/setup-server-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1
log_info "Лог прогона сохраняется в ${LOG_FILE}"

TOKEN_FILE="${SCRIPT_DIR}/.token"

if [[ ! -f "${TOKEN_FILE}" ]]; then
	log_warn "Файл ${TOKEN_FILE} не найден."
	echo ""
	echo -e "${CYAN}Хотите сгенерировать новую SSH-связку ключей?${NC}"
	echo -e "  Открытый ключ будет сохранён в ${TOKEN_FILE}"
	echo -e "  Закрытый ключ будет сохранён рядом со скриптом"
	echo ""

	if [[ "${ARGS_YES}" == true ]]; then
		log_error "В неинтерактивном режиме (--yes) файл .token должен существовать заранее."
		log_error "Запустите скрипт без --yes, чтобы сгенерировать ключи в интерактивном режиме."
		exit 1
	fi

	read -p "Сгенерировать ключи? [y/N]: " GENERATE_CHOICE

	if [[ "${GENERATE_CHOICE}" =~ ^[Yy]$ ]]; then
		# ssh-keygen входит в openssh-client — гарантируем его наличие
		if ! command -v ssh-keygen &>/dev/null; then
			log_warn "ssh-keygen не найден, устанавливаю openssh-client..."
			apt update -y
			apt install -y openssh-client
		fi

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
		2 | 3)
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
		# KEYGEN_ARGS намеренно разбивается на слова
		# shellcheck disable=SC2086
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
				log_warn "puttygen не найден."
				echo ""
				read -p "Установить putty-tools? [y/N]: " INSTALL_PUTTY
				if [[ "${INSTALL_PUTTY}" =~ ^[Yy]$ ]]; then
					apt install -y putty-tools
					puttygen "${KEY_PATH}" -o "${KEY_PATH}.ppk"
					chmod 600 "${KEY_PATH}.ppk"
					log_info "PuTTY-ключ сохранён в ${KEY_PATH}.ppk"
				else
					log_warn "Удаление созданных ключей для безопасного перезапуска..."
					rm -f "${KEY_PATH}" "${KEY_PATH}.pub" "${TOKEN_FILE}"
					log_error "Запустите скрипт заново, когда puttygen будет доступен."
					exit 1
				fi
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

SSH_AUTHORIZED_KEY="$(xargs <"${TOKEN_FILE}")"

if [[ -z "${SSH_AUTHORIZED_KEY}" ]]; then
	log_error "Файл ${TOKEN_FILE} пуст."
	exit 1
fi

# ==============================
# Функции шагов
# ==============================

# 1. Обновление системы
step_update() {
	# Возвращаем errexit: шаг вызывается из "if !", где set -e отключён,
	# без этого падение промежуточной команды не считалось бы ошибкой шага
	set -e

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
	set -e

	log_info "Установка базовых пакетов..."

	# На Debian mcedit — виртуальный пакет, его предоставляет mc
	EDITOR_PKG="mcedit"
	if [[ "${OS_ID}" == "debian" ]]; then
		EDITOR_PKG="mc"
	fi

	apt install -y \
		curl \
		htop \
		"${EDITOR_PKG}" \
		fail2ban \
		openssh-server \
		openssh-client
	log_info "Базовые пакеты установлены."
}

# 3. Установка Docker
step_docker() {
	set -e

	log_info "Проверка установки Docker..."
	if command -v docker &>/dev/null; then
		log_warn "Docker уже установлен, пропускаем."
		return 0
	fi

	log_info "Установка Docker..."

	apt install -y ca-certificates gnupg lsb-release ufw

	# Репозиторий Docker общий для debian-семейства: /linux/ubuntu или /linux/debian
	install -m 0755 -d /etc/apt/keyrings
	curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
		-o /etc/apt/keyrings/docker.asc
	chmod a+r /etc/apt/keyrings/docker.asc

	echo \
		"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/${OS_ID} \
        $(lsb_release -cs) stable" |
		tee /etc/apt/sources.list.d/docker.list >/dev/null

	apt update -y
	apt install -y docker-ce docker-ce-cli containerd.io \
		docker-buildx-plugin docker-compose-plugin

	systemctl enable --now docker
	log_info "Docker успешно установлен."
}

# 4. Настройка swap-файла (2 ГБ)
step_swap() {
	set -e

	log_info "Настройка swap..."

	# Умеренное свопирование при активном swap-файле
	cat >/etc/sysctl.d/99-swap.conf <<'EOF'
vm.swappiness=10
EOF
	if command -v sysctl &>/dev/null; then
		# Не критично: значение всё равно применится после перезагрузки
		sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null 2>&1 ||
			log_warn "vm.swappiness применится после перезагрузки."
		log_info "vm.swappiness=10 настроен."
	fi

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
	if [ "${FREE_SPACE}" -lt 2097152 ]; then
		log_error "Недостаточно места для создания swap-файла (требуется более 2 ГБ)."
		return 1
	fi
	log_info "Создание swap-файла размером 2 ГБ..."
	dd if=/dev/zero of="${SWAPFILE}" bs=1M count=2048
	chmod 600 "${SWAPFILE}"
	mkswap "${SWAPFILE}"
	swapon "${SWAPFILE}"

	if ! grep -q "${SWAPFILE}" /etc/fstab; then
		echo "${SWAPFILE} none swap sw 0 0" >>/etc/fstab
	fi

	log_info "Swap-файл создан и активирован."
}

# 5. Настройка UFW
step_ufw() {
	set -e

	log_info "Настройка UFW..."

	# UFW откроет порт 2288 — убеждаемся, что SSH там действительно слушает,
	# иначе новые подключения станут невозможны
	SSHD_BIN="$(command -v sshd || true)"
	if [[ -z "${SSHD_BIN}" && -x /usr/sbin/sshd ]]; then
		SSHD_BIN="/usr/sbin/sshd"
	fi

	if [[ -n "${SSHD_BIN}" ]] && "${SSHD_BIN}" -T 2>/dev/null | grep -qiE '^port[[:space:]]+2288'; then
		SSH_ON_2288=true
	else
		SSH_ON_2288=false
	fi

	if [[ "${SSH_ON_2288}" != true ]]; then
		if [[ "${SSH_STEP_SELECTED}" == true ]]; then
			log_warn "SSH ещё не слушает порт 2288, но шаг 6 выбран — он настроится сразу после UFW."
		else
			log_error "SSH не настроен на порт 2288 — включение UFW закроет доступ к серверу."
			log_error "Выполните шаг 6 (Настройка SSH) вместе с этим шагом или до него."
			return 1
		fi
	fi

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
	set -e

	log_info "Настройка SSH..."

	# Без валидного ключа отключение пароля заблокирует сервер —
	# проверяем ключ до любых изменений
	if ! grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]' <<<"${SSH_AUTHORIZED_KEY}"; then
		log_error "Содержимое ${TOKEN_FILE} не похоже на SSH-публичный ключ."
		log_error "Парольная аутентификация НЕ отключена, доступ к серверу сохранён."
		return 1
	fi

	SSHD_CONFIG="/etc/ssh/sshd_config"

	cat >"${SSHD_CONFIG}" <<'EOF'
Port 2288
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
# Без VERBOSE sshd не пишет неудачные входы по ключу — fail2ban (шаг 7) слеп
LogLevel VERBOSE
UsePAM yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

	mkdir -p /root/.ssh
	chmod 700 /root/.ssh
	touch /root/.ssh/authorized_keys
	chmod 600 /root/.ssh/authorized_keys

	# Дописываем ключ, не затирая ключи, добавленные вручную после прошлого прогона
	if grep -qxF "${SSH_AUTHORIZED_KEY}" /root/.ssh/authorized_keys; then
		log_warn "Ключ уже есть в authorized_keys, пропускаем."
	else
		echo "${SSH_AUTHORIZED_KEY}" >>/root/.ssh/authorized_keys
		log_info "Ключ добавлен в /root/.ssh/authorized_keys."
	fi

	# Каталог privilege separation: без него sshd -t падает на минимальных системах
	mkdir -p /run/sshd

	# Проверяем конфигурацию до перезапуска — при ошибке сервис останется на старой
	SSHD_BIN="$(command -v sshd || true)"
	if [[ -z "${SSHD_BIN}" && -x /usr/sbin/sshd ]]; then
		SSHD_BIN="/usr/sbin/sshd"
	fi
	if [[ -n "${SSHD_BIN}" ]]; then
		if ! "${SSHD_BIN}" -t; then
			log_error "Конфигурация sshd не прошла проверку (sshd -t)."
			log_error "Сервис НЕ перезапущен, действует прежняя конфигурация."
			return 1
		fi
	else
		log_warn "Бинарник sshd не найден — проверка конфигурации пропущена."
	fi

	if systemctl is-active --quiet ssh; then
		SSH_SERVICE="ssh"
	elif systemctl is-active --quiet sshd; then
		SSH_SERVICE="sshd"
	else
		SSH_SERVICE="ssh"
	fi

	if ! systemctl restart "${SSH_SERVICE}"; then
		log_error "Не удалось перезапустить сервис ${SSH_SERVICE}."
		log_error "Проверьте вручную: systemctl status ${SSH_SERVICE}"
		return 1
	fi
	log_info "SSH настроен: порт 2288, только ключи, root по ключу."
}

# 7. Настройка fail2ban
step_fail2ban() {
	set -e

	log_info "Настройка fail2ban..."

	if [ -f /var/log/auth.log ]; then
		# Классический путь: rsyslog пишет auth.log — читаем файл,
		# детерминированно и без зависимости от journald
		SSHD_BACKEND="polling"
		SSHD_LOGSOURCE="logpath = /var/log/auth.log"
	else
		# Минимальные системы без rsyslog: читаем journal напрямую.
		# На Debian/Ubuntu sshd логирует под юнитом ssh.service, не sshd.service
		SSHD_BACKEND="systemd"
		SSHD_LOGSOURCE="journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd"
	fi

	cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 24h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port    = 2288
# publickey=any: неудачные входы по ключу считаются нарушениями.
# По умолчанию фильтр их игнорирует — и при парольном входе, отключённом
# в шаге 6, бан вообще не срабатывал бы
filter  = sshd[publickey=any]
backend = ${SSHD_BACKEND}
${SSHD_LOGSOURCE}

[recidive]
enabled  = true
backend  = auto
logpath  = /var/log/fail2ban.log
bantime  = 1w
findtime = 1d
maxretry = 3
EOF

	systemctl enable --now fail2ban
	log_info "fail2ban настроен (бэкенд: ${SSHD_BACKEND})."
}

# 8. Автообновления безопасности
step_autoupdate() {
	set -e

	log_info "Настройка автоматических обновлений безопасности..."

	apt install -y unattended-upgrades

	cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

	# Только обновления безопасности
	cat >/etc/apt/apt.conf.d/51unattended-upgrades-security <<'EOF'
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

	systemctl restart unattended-upgrades 2>/dev/null || true
	log_info "Автообновления безопасности включены."
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
	"Автообновления безопасности"
)

STEP_FUNCS=(
	step_update
	step_packages
	step_docker
	step_swap
	step_ufw
	step_ssh
	step_fail2ban
	step_autoupdate
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
	echo -e "  ${CYAN}Пробел${NC} — отметить/снять  |  ${CYAN}↑↓${NC} — навигация  |  ${CYAN}A${NC} — все  |  ${CYAN}N${NC} — сброс  |  ${CYAN}Q${NC} — выход  |  ${CYAN}Enter${NC} — запустить"
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

if [[ "${ARGS_ALL}" == true || -n "${ARGS_STEPS}" ]]; then
	# Неинтерактивный выбор шагов
	if [[ "${ARGS_ALL}" == true ]]; then
		for ((i = 0; i < TOTAL_STEPS; i++)); do
			SELECTED_STATE[$i]=1
		done
	else
		IFS=',' read -ra REQ_STEPS <<<"${ARGS_STEPS}"
		for num in "${REQ_STEPS[@]}"; do
			if [[ ! "${num}" =~ ^[0-9]+$ ]] || ((num < 1 || num > TOTAL_STEPS)); then
				log_error "Неверный номер шага: '${num}'. Допустимые значения: 1-${TOTAL_STEPS}."
				exit 1
			fi
			SELECTED_STATE[$((num - 1))]=1
		done
	fi
else
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
		# Стрелка вверх/вниз
		$'\x1b')
			SEQ=""
			# Таймаут, чтобы одиночный Esc не зависал в ожидании продолжения
			read -rsn2 -t 0.1 SEQ || SEQ=""
			case "${SEQ}" in
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
		# Q — выход без изменений
		[Qq])
			log_info "Выход без изменений."
			exit 0
			;;
		esac
	done
fi

# Собираем индексы выбранных шагов
SELECTED_INDICES=()
SSH_STEP_SELECTED=false
for ((i = 0; i < TOTAL_STEPS; i++)); do
	if [[ "${SELECTED_STATE[$i]}" == "1" ]]; then
		SELECTED_INDICES+=("$i")
		if [[ "${STEP_FUNCS[$i]}" == "step_ssh" ]]; then
			SSH_STEP_SELECTED=true
		fi
	fi
done

# ==============================
# Подтверждение запуска
# ==============================
if [[ "${ARGS_YES}" == true ]]; then
	log_info "Режим --yes: подтверждение не требуется."
	echo ""
	echo -e "${CYAN}Будут выполнены следующие шаги:${NC}"
	for idx in "${SELECTED_INDICES[@]}"; do
		echo -e "  ${GREEN}→${NC} ${STEP_NAMES[$idx]}"
	done
	echo ""
else
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
fi

# ==============================
# Запуск выбранных шагов
# ==============================
echo ""
log_info "Запуск выбранных шагов..."
echo ""

# Падение одного шага не обрывает прогон — фиксируем и идём дальше
FAILED_STEPS=()

for idx in "${SELECTED_INDICES[@]}"; do
	STEP_NUM=$((idx + 1))
	echo -e "${YELLOW}────────────────────────────────────────${NC}"
	log_info "Шаг ${STEP_NUM}: ${STEP_NAMES[$idx]}"
	echo -e "${YELLOW}────────────────────────────────────────${NC}"
	if ! "${STEP_FUNCS[$idx]}"; then
		log_error "Шаг ${STEP_NUM} (${STEP_NAMES[$idx]}) завершился с ошибкой — перехожу к следующему."
		FAILED_STEPS+=("${STEP_NUM}. ${STEP_NAMES[$idx]}")
	fi
	echo ""
done

# ==============================
# Итоговая информация
# ==============================
if ((${#FAILED_STEPS[@]} > 0)); then
	echo ""
	log_error "Не выполнены шаги:"
	for s in "${FAILED_STEPS[@]}"; do
		echo -e "  ${RED}✗${NC} ${s}"
	done
	echo ""
	log_warn "Система может быть настроена частично — проверьте лог: ${LOG_FILE}"
else
	log_info "Все выбранные шаги завершились успешно."
fi

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
if [[ "${ARGS_YES}" == true ]]; then
	echo ""
	log_info "Перезагрузка в режиме --yes пропускается. Перезагрузите сервер вручную, когда удобно."
else
	echo ""
	log_info "Для применения всех обновлений рекомендуется перезагрузка."
	read -p "Перезагрузить сервер сейчас? [y/N]: " REBOOT_CHOICE
	if [[ "${REBOOT_CHOICE}" =~ ^[Yy]$ ]]; then
		log_info "Перезагрузка..."
		reboot
	else
		log_info "Перезагрузка отменена. Перезагрузитесь вручную, когда удобно."
	fi
fi

if ((${#FAILED_STEPS[@]} > 0)); then
	exit 1
fi
