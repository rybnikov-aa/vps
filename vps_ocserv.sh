#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Пути и параметры
ACME_HOME="$HOME/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"
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
read -rp "Введите доменное имя вашего VPS (например, vpn.example.com): " DOMAIN

if [ -z "${DOMAIN}" ]; then
    print_error "Домен не может быть пустым"
    exit 1
fi

print_info "Начинаем установку OpenConnect для домена: ${DOMAIN}"

# Запрос email для Let's Encrypt
read -rp "Введите email для Let's Encrypt (для уведомлений): " EMAIL

if [ -z "${EMAIL}" ]; then
    print_info "Email не указан. acme.sh может запросить его позже."
fi

# Обновление системы
print_info "Обновление списка пакетов..."
sudo apt update

# Установка необходимых пакетов
print_info "Установка необходимых пакетов..."
sudo apt install -y ocserv ufw curl ca-certificates

# Установка acme.sh
print_info "Установка acme.sh..."
curl -fsSL https://get.acme.sh | sh -s email="${EMAIL}"

if [ ! -x "${ACME_BIN}" ]; then
    print_error "Не удалось найти acme.sh в ${ACME_BIN}. Проверьте установку."
    exit 1
fi

# Получение SSL сертификата
print_info "Получение SSL сертификата для ${DOMAIN}..."
"${ACME_BIN}" --issue --standalone -d "${DOMAIN}" --force

# Создание директории для сертификатов
sudo install -d -m 755 /etc/ocserv/certs

# Установка сертификатов
print_info "Установка сертификатов..."
"${ACME_BIN}" --install-cert -d "${DOMAIN}" \
    --cert-file /etc/ocserv/certs/cert.pem \
    --key-file /etc/ocserv/certs/key.pem \
    --fullchain-file /etc/ocserv/certs/fullchain.pem

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

# Применение настроек sysctl
sudo sysctl -p "${SYSCTL_CONF}"

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
    sudo cp "${UFW_BEFORE_RULES}" "${UFW_BEFORE_RULES}.bak"
    sudo tee -a "${UFW_BEFORE_RULES}" > /dev/null <<EOF
### BEGIN ocserv NAT rules
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${OPENCONNECT_NETWORK} -o ${INTERFACE} -j MASQUERADE
COMMIT

-A ufw-before-forward -s ${OPENCONNECT_NETWORK} -j ACCEPT
-A ufw-before-forward -d ${OPENCONNECT_NETWORK} -j ACCEPT
### END ocserv NAT rules
EOF
fi

sudo ufw --force enable
sudo systemctl restart ufw

# Создание тестового пользователя
print_info "Создание пользователя VPN..."
read -rp "Введите имя пользователя VPN: " VPN_USER

if [ -n "${VPN_USER}" ]; then
    read -rsp "Введите пароль для ${VPN_USER}: " VPN_PASS
    printf '\n'
    read -rsp "Подтвердите пароль: " VPN_PASS_CONFIRM
    printf '\n'

    if [ "${VPN_PASS}" = "${VPN_PASS_CONFIRM}" ] && [ -n "${VPN_PASS}" ]; then
        printf '%s\n%s\n' "${VPN_PASS}" "${VPN_PASS}" | sudo ocpasswd -c "${VPN_PASSWD_FILE}" "${VPN_USER}"
        print_success "Пользователь ${VPN_USER} создан"
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

# Настройка автоматического обновления сертификатов
print_info "Настройка автоматического обновления сертификатов..."
cat <<EOF | sudo tee /etc/cron.monthly/renew-ocserv-cert.sh > /dev/null
#!/bin/bash
"${ACME_BIN}" --renew -d "${DOMAIN}" --force
"${ACME_BIN}" --install-cert -d "${DOMAIN}" \
    --cert-file /etc/ocserv/certs/cert.pem \
    --key-file /etc/ocserv/certs/key.pem \
    --fullchain-file /etc/ocserv/certs/fullchain.pem
systemctl restart ocserv
EOF

sudo chmod 755 /etc/cron.monthly/renew-ocserv-cert.sh

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
sudo ocpasswd -c /etc/ocserv/ocserv.passwd -l
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
echo "==========================================="

# Проверка открытых портов
print_info "Проверка открытых портов..."
sudo ufw status verbose