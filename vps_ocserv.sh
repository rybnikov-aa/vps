#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Пути и параметры
UFW_BEFORE_RULES='/etc/ufw/before.rules'
SYSCTL_CONF='/etc/sysctl.d/99-ocserv.conf'
VPN_PASSWD_FILE='/etc/ocserv/ocserv.passwd'
OPENCONNECT_NETWORK='10.10.10.0/24'

# Функции для вывода
print_error() {
    printf "%b\n" "${RED}[ОШИБКА]${NC} $1"
}

print_success() {
    printf "%b\n" "${GREEN}[УСПЕХ]${NC} $1"
}

print_info() {
    printf "%b\n" "${YELLOW}[ИНФО]${NC} $1"
}

prompt() {
    local prompt="$1"
    shift
    if [ -t 0 ]; then
        read -rp "${prompt}" "$@"
    else
        read -rp "${prompt}" "$@" < /dev/tty
    fi
}

prompt_secret() {
    local prompt="$1"
    shift
    if [ -t 0 ]; then
        read -rsp "${prompt}" "$@"
    else
        read -rsp "${prompt}" "$@" < /dev/tty
    fi
}

# Проверка прав sudo
if [ "$EUID" -eq 0 ]; then
    print_error "Не запускайте скрипт от root. Используйте пользователя с правами sudo"
    exit 1
fi

# Проверка наличия sudo
if ! command -v sudo &> /dev/null; then
    print_error "sudo не установлен. Установите sudo и добавьте пользователя в группу sudo"
    exit 1
fi

# Запрос домена у пользователя
printf '\n'
prompt "Введите доменное имя вашего VPS (например, vpn.example.com): " DOMAIN

if [ -z "${DOMAIN}" ]; then
    print_error "Домен не может быть пустым"
    exit 1
fi

# Санитизация и валидация введённого домена
DOMAIN="$(printf '%s' "${DOMAIN}" | tr -d '\r')"
# Удаляем UTF-8 BOM если есть
DOMAIN="${DOMAIN//$'\xef\xbb\xbf'/}"
# Обрезаем пробелы
DOMAIN="$(printf '%s' "${DOMAIN}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
# Приводим к нижнему регистру
DOMAIN="$(printf '%s' "${DOMAIN}" | tr '[:upper:]' '[:lower:]')"
# Удаляем недопустимые символы, оставляем только a-z0-9.-
CLEAN_DOMAIN="$(printf '%s' "${DOMAIN}" | sed 's/[^a-z0-9.-]//g')"
if [ "${CLEAN_DOMAIN}" != "${DOMAIN}" ]; then
    print_info "Санитизация доменного имени: '${DOMAIN}' -> '${CLEAN_DOMAIN}'"
    DOMAIN="${CLEAN_DOMAIN}"
fi

# Простейшая валидация: должен начинаться и заканчиваться на букву/цифру
if ! [[ "${DOMAIN}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    print_error "Недопустимое доменное имя: ${DOMAIN}"
    exit 1
fi

print_info "Начинаем установку OpenConnect для домена: ${DOMAIN}"

# Запрос email для Let's Encrypt
prompt "Введите email для Let's Encrypt (для уведомлений): " EMAIL

if [ -z "${EMAIL}" ]; then
    print_error "Email обязателен для Let's Encrypt"
    exit 1
fi

# Обновление системы
print_info "Обновление списка пакетов..."
sudo apt update

# Установка необходимых пакетов
print_info "Установка необходимых пакетов..."
sudo apt install -y ocserv ufw curl ca-certificates certbot

# Остановка сервисов, которые могут занимать порт 80/443
print_info "Остановка потенциально конфликтующих сервисов..."
sudo systemctl stop nginx apache2 2>/dev/null || true
sudo systemctl stop ocserv 2>/dev/null || true

# Получение SSL сертификата через certbot
print_info "Получение SSL сертификата для ${DOMAIN} через Let's Encrypt..."
if ! sudo certbot certonly --standalone --preferred-challenges http --agree-tos --email "${EMAIL}" -d "${DOMAIN}" --non-interactive; then
    print_error "certbot вернул ошибку при получении сертификата"
    exit 1
fi

# Проверяем, что сертификаты действительно созданы или ищем существующий сертификат
LIVE_DIR="/etc/letsencrypt/live/${DOMAIN}"
print_info "Проверяем сертификаты в каталоге: ${LIVE_DIR}"
print_info "Ожидаемые файлы: ${LIVE_DIR}/cert.pem, ${LIVE_DIR}/privkey.pem, ${LIVE_DIR}/fullchain.pem"
if sudo test -f "${LIVE_DIR}/cert.pem" && sudo test -f "${LIVE_DIR}/privkey.pem" && sudo test -f "${LIVE_DIR}/fullchain.pem"; then
    :
else
    print_info "Сертификаты по ожидаемому пути не найдены, ищем существующий сертификат через certbot..."
    print_info "Будем искать в каталоге /etc/letsencrypt/live/*"
    CERT_NAME=$(sudo certbot certificates 2>/dev/null | awk -v d="${DOMAIN}" '
        /^[[:space:]]*Certificate Name:/ {name=$3}
        /^[[:space:]]*Domains:/ { if ($0 ~ d) print name }
    ' | head -n1)
    if [ -n "${CERT_NAME}" ] && [ -d "/etc/letsencrypt/live/${CERT_NAME}" ]; then
        print_info "Найден сертификат '${CERT_NAME}', используем /etc/letsencrypt/live/${CERT_NAME}"
        LIVE_DIR="/etc/letsencrypt/live/${CERT_NAME}"
    fi
    if ! sudo test -f "${LIVE_DIR}/cert.pem" || ! sudo test -f "${LIVE_DIR}/privkey.pem" || ! sudo test -f "${LIVE_DIR}/fullchain.pem"; then
        print_error "Файл сертификата ${LIVE_DIR}/cert.pem не найден"
        exit 1
    fi
fi

# Создание директории для сертификатов
sudo install -d -m 755 /etc/ocserv/certs

# Копирование сертификатов в директорию ocserv
print_info "Установка сертификатов..."
sudo cp "${LIVE_DIR}/cert.pem" /etc/ocserv/certs/cert.pem
sudo cp "${LIVE_DIR}/privkey.pem" /etc/ocserv/certs/key.pem
sudo cp "${LIVE_DIR}/fullchain.pem" /etc/ocserv/certs/fullchain.pem

# Настройка прав доступа к сертификатам
sudo chmod 644 /etc/ocserv/certs/cert.pem
sudo chmod 640 /etc/ocserv/certs/key.pem
sudo chown root:ssl-cert /etc/ocserv/certs/key.pem

# Создание бэкапа конфигурации
if [ -f /etc/ocserv/ocserv.conf ]; then
    sudo cp -n /etc/ocserv/ocserv.conf /etc/ocserv/ocserv.conf.bak
fi

# Настройка ocserv
print_info "Настройка ocserv..."
sudo tee /etc/ocserv/ocserv.conf > /dev/null <<EOF
# Аутентификация
auth = "plain[passwd=/etc/ocserv/ocserv.passwd]"

# SSL сертификаты
server-cert = /etc/ocserv/certs/cert.pem
server-key = /etc/ocserv/certs/key.pem
ca-cert = /etc/ocserv/certs/fullchain.pem

# Порты
tcp-port = 443
udp-port = 443

# Количество подключений
max-clients = 16
max-same-clients = 8

# Сжатие
compression = true
no-compress-limit = 256

# Безопасность TLS
tls-priorities = "NORMAL:%SERVER_PRECEDENCE:%COMPAT:-RSA:-VERS-ALL:+VERS-TLS1.2:+VERS-TLS1.3:-ARCFOUR-128"

# Защита от брутфорса
max-ban-score = 80
ban-reset-time = 300
ban-points-wrong-password = 10
ban-points-connection = 1

# Сетевые настройки
ipv4-network = 10.10.10.0/24
ipv4-netmask = 255.255.255.0

# DNS настройки
tunnel-all-dns = true
dns = 8.8.8.8
dns = 8.8.4.4
dns = 9.9.9.9
dns = 1.1.1.1

# Маршрутизация всего трафика
route = default

# Прочие настройки
isolate-workers = true
keepalive = 32400
dpd = 90
mobile-dpd = 1800
try-mtu-discovery = true
cisco-client-compat = true
EOF

# Настройка sysctl для IP forwarding
print_info "Настройка IP forwarding..."
sudo tee "${SYSCTL_CONF}" > /dev/null <<EOF
# Настройки для VPN
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

# Применение настроек sysctl: сначала пробуем --system, иначе пускаем конкретный файл
if sudo sysctl --system >/dev/null 2>&1; then
    print_info "sysctl применён через --system"
else
    sudo sysctl -p "${SYSCTL_CONF}"
fi

# Настройка UFW
print_info "Настройка файрвола UFW..."

# Определение основного сетевого интерфейса
INTERFACE=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')

if [ -z "${INTERFACE}" ]; then
    INTERFACE="eth0"
    print_info "Используем интерфейс по умолчанию: ${INTERFACE}"
else
    print_info "Обнаружен сетевой интерфейс: ${INTERFACE}"
fi

# Разрешаем необходимые порты
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw allow 443/udp comment 'OpenConnect UDP'

# Настройка NAT и форвардинга в UFW
if ! sudo grep -q '### BEGIN ocserv NAT rules' "${UFW_BEFORE_RULES}"; then
    if [ -f "${UFW_BEFORE_RULES}" ]; then
        sudo cp "${UFW_BEFORE_RULES}" "${UFW_BEFORE_RULES}.bak"
    else
        sudo touch "${UFW_BEFORE_RULES}"
    fi
    
    # Сначала добавляем forward rules перед первым COMMIT (в таблицу filter)
    sudo sed -i '/^COMMIT$/i\
### BEGIN ocserv forward rules\
-A ufw-before-forward -s '"${OPENCONNECT_NETWORK}"' -j ACCEPT\
-A ufw-before-forward -d '"${OPENCONNECT_NETWORK}"' -j ACCEPT\
### END ocserv forward rules' "${UFW_BEFORE_RULES}"
    
    # Затем добавляем NAT правила в конец файла
    sudo tee -a "${UFW_BEFORE_RULES}" > /dev/null <<EOF

### BEGIN ocserv NAT rules
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${OPENCONNECT_NETWORK} -o ${INTERFACE} -j MASQUERADE
COMMIT
### END ocserv NAT rules
EOF
fi

sudo ufw --force enable
sudo systemctl restart ufw

# Создание тестового пользователя
print_info "Создание пользователя VPN..."
prompt "Введите имя пользователя VPN: " VPN_USER

if [ -n "${VPN_USER}" ]; then
    prompt_secret "Введите пароль для ${VPN_USER}: " VPN_PASS
    printf '\n'
    prompt_secret "Подтвердите пароль: " VPN_PASS_CONFIRM
    printf '\n'

    if [ "${VPN_PASS}" = "${VPN_PASS_CONFIRM}" ] && [ -n "${VPN_PASS}" ]; then
        if sudo bash -c "printf '%s\n%s\n' \"${VPN_PASS}\" \"${VPN_PASS}\" | ocpasswd -c '${VPN_PASSWD_FILE}' '${VPN_USER}'"; then
            print_success "Пользователь ${VPN_USER} создан"
        else
            print_error "Не удалось создать пользователя ${VPN_USER}"
        fi
    else
        print_error "Пароли не совпадают или пустые"
    fi
fi

# Перезапуск ocserv
print_info "Перезапуск ocserv..."
sudo systemctl enable --now ocserv
sudo systemctl restart ocserv

# Проверка статуса
if sudo systemctl is-active --quiet ocserv; then
    print_success "ocserv успешно запущен"
else
    print_error "Проблема с запуском ocserv"
    sudo systemctl status ocserv
    exit 1
fi

# Настройка автоматического обновления сертификатов через systemd таймер certbot
print_info "Настройка автоматического обновления сертификатов..."
sudo systemctl enable --now certbot.timer

# Создание скрипта для обновления сертификатов с перезапуском ocserv
sudo tee /etc/letsencrypt/renewal-hooks/deploy/ocserv-restart.sh > /dev/null <<EOF
#!/bin/bash
systemctl restart ocserv
EOF

sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/ocserv-restart.sh

# Вывод информации
clear
print_success "Установка OpenConnect завершена!"
echo ""
echo "==========================================="
echo "ИНФОРМАЦИЯ О НАСТРОЙКЕ:"
echo "==========================================="
echo "Домен: $DOMAIN"
echo "Порт: 443 (TCP и UDP)"
echo "Сетевой диапазон: 10.10.10.0/24"
echo "DNS: 8.8.8.8, 8.8.4.4, 9.9.9.9, 1.1.1.1"
echo ""
echo "Пользователи VPN:"
if sudo ocpasswd -c "${VPN_PASSWD_FILE}" -l >/dev/null 2>&1; then
    sudo ocpasswd -c "${VPN_PASSWD_FILE}" -l
else
    print_info "Команда 'ocpasswd -l' недоступна — показываю содержимое файла паролей"
    sudo cat "${VPN_PASSWD_FILE}" || true
fi
echo ""
echo "Для подключения используйте:"
echo "Cisco AnyConnect или OpenConnect клиент"
echo "Адрес сервера: https://$DOMAIN:443"
echo ""
echo "Для добавления новых пользователей выполните:"
echo "sudo ocpasswd -c /etc/ocserv/ocserv.passwd ИМЯ_ПОЛЬЗОВАТЕЛЯ"
echo ""
echo "Для удаления пользователя:"
echo "sudo ocpasswd -c /etc/ocserv/ocserv.passwd -d ИМЯ_ПОЛЬЗОВАТЕЛЯ"
echo ""
echo "Проверка статуса: systemctl status ocserv"
echo "Просмотр логов: sudo journalctl -u ocserv -f"
echo "Обновление сертификатов: sudo certbot renew"
echo "==========================================="

# Проверка открытых портов
print_info "Проверка открытых портов..."
sudo ufw status verbose