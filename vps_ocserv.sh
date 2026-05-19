#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Пути и параметры
OCSERV_CONF='/etc/ocserv/ocserv.conf'
UFW_BEFORE_RULES='/etc/ufw/before.rules'
SYSCTL_CONF='/etc/sysctl.d/99-ocserv.conf'
VPN_PASSWD_FILE='/etc/ocserv/ocserv.passwd'
OPENCONNECT_NETWORK='10.10.10.0/24'

# Функции для вывода
print_error() { printf "%b\n" "${RED}[ОШИБКА]${NC} $1"; }
print_success() { printf "%b\n" "${GREEN}[УСПЕХ]${NC} $1"; }
print_info() { printf "%b\n" "${YELLOW}[ИНФО]${NC} $1"; }

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

# Функция для изменения параметра в конфигурационном файле
# Раскомментирует и изменит значение, не трогая остальные строки
update_ocserv_param() {
    local param_name="$1"
    local param_value="$2"
    
    if [ ! -f "$OCSERV_CONF" ]; then
        print_error "Файл $OCSERV_CONF не существует"
        return 1
    fi
    
    # Создаем бэкап только если его нет
    if [ ! -f "${OCSERV_CONF}.bak" ]; then
        sudo cp "$OCSERV_CONF" "${OCSERV_CONF}.bak"
        print_info "Создан бэкап ${OCSERV_CONF}.bak"
    fi
    
    # Экранируем спецсимволы для sed
    local escaped_value=$(printf '%s\n' "$param_value" | sed -e 's/[\/&]/\\&/g')
    
    # Проверяем наличие параметра (закомментированного или нет)
    if sudo grep -q "^[[:space:]]*#\{0,\}[[:space:]]*${param_name}[[:space:]]*=" "$OCSERV_CONF"; then
        # Параметр существует - раскомментируем и обновим значение
        sudo sed -i -E "s/^([[:space:]]*#\{0,\}[[:space:]]*)${param_name}[[:space:]]*=[[:space:]]*.*/${param_name} = ${escaped_value}/" "$OCSERV_CONF"
        print_info "✓ Параметр ${param_name} обновлен"
    elif sudo grep -q "^[[:space:]]*#\{0,\}[[:space:]]*${param_name}[[:space:]]" "$OCSERV_CONF"; then
        # Параметр без знака = 
        sudo sed -i -E "s/^([[:space:]]*#\{0,\}[[:space:]]*)${param_name}[[:space:]]+.*/${param_name} = ${escaped_value}/" "$OCSERV_CONF"
        print_info "✓ Параметр ${param_name} обновлен"
    else
        print_info "⚠ Параметр ${param_name} не найден в конфигурации (пропускаем)"
    fi
}

# Функция для добавления параметра если его нет
add_ocserv_param_if_missing() {
    local param_name="$1"
    local param_value="$2"
    
    if ! sudo grep -q "^[[:space:]]*${param_name}[[:space:]]*=" "$OCSERV_CONF" && \
       ! sudo grep -q "^[[:space:]]*${param_name}[[:space:]]" "$OCSERV_CONF"; then
        echo "${param_name} = ${param_value}" | sudo tee -a "$OCSERV_CONF" > /dev/null
        print_info "✓ Добавлен параметр ${param_name}"
    fi
}

# Проверка прав
if [ "$EUID" -eq 0 ]; then
    print_error "Не запускайте скрипт от root. Используйте пользователя с правами sudo"
    exit 1
fi

if ! command -v sudo &> /dev/null; then
    print_error "sudo не установлен"
    exit 1
fi

# Запрос домена
printf '\n'
prompt "Введите доменное имя вашего VPS (например, vpn.example.com): " DOMAIN

if [ -z "${DOMAIN}" ]; then
    print_error "Домен не может быть пустым"
    exit 1
fi

# Санитизация домена
DOMAIN="$(printf '%s' "${DOMAIN}" | tr -d '\r')"
DOMAIN="${DOMAIN//$'\xef\xbb\xbf'/}"
DOMAIN="$(printf '%s' "${DOMAIN}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
DOMAIN="$(printf '%s' "${DOMAIN}" | tr '[:upper:]' '[:lower:]')"

if ! [[ "${DOMAIN}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    print_error "Недопустимое доменное имя: ${DOMAIN}"
    exit 1
fi

print_info "Начинаем настройку OpenConnect для домена: ${DOMAIN}"

prompt "Введите email для Let's Encrypt: " EMAIL
if [ -z "${EMAIL}" ]; then
    print_error "Email обязателен"
    exit 1
fi

# Обновление и установка
print_info "Обновление системы..."
sudo apt update

print_info "Установка пакетов..."
sudo apt install -y ocserv ufw curl ca-certificates certbot

# Остановка сервисов
print_info "Остановка конфликтующих сервисов..."
sudo systemctl stop nginx apache2 2>/dev/null || true
sudo systemctl stop ocserv 2>/dev/null || true

# Получение сертификата
print_info "Получение SSL сертификата для ${DOMAIN}..."
if ! sudo certbot certonly --standalone --preferred-challenges http --agree-tos --email "${EMAIL}" -d "${DOMAIN}" --non-interactive; then
    print_error "Ошибка получения сертификата"
    exit 1
fi

# Определение директории с сертификатами
LIVE_DIR="/etc/letsencrypt/live/${DOMAIN}"
if ! sudo test -f "${LIVE_DIR}/fullchain.pem"; then
    CERT_NAME=$(sudo certbot certificates 2>/dev/null | grep -A1 "Certificate Name" | tail -1 | tr -d ' ')
    if [ -n "${CERT_NAME}" ] && [ -d "/etc/letsencrypt/live/${CERT_NAME}" ]; then
        LIVE_DIR="/etc/letsencrypt/live/${CERT_NAME}"
    fi
fi

# Копирование сертификатов
print_info "Установка сертификатов..."
sudo mkdir -p /etc/ocserv/certs
sudo cp "${LIVE_DIR}/fullchain.pem" /etc/ocserv/certs/server-cert.pem
sudo cp "${LIVE_DIR}/privkey.pem" /etc/ocserv/certs/server-key.pem
sudo chmod 644 /etc/ocserv/certs/server-cert.pem
sudo chmod 640 /etc/ocserv/certs/server-key.pem
sudo chown root:ssl-cert /etc/ocserv/certs/server-key.pem

# НАСТРОЙКА OCSERV - только изменение существующих параметров
print_info "Настройка ocserv (обновление параметров)..."

# Обновляем только те параметры, которые уже есть в конфиге
update_ocserv_param "auth" "\"plain[passwd=/etc/ocserv/ocserv.passwd]\""
update_ocserv_param "server-cert" "/etc/ocserv/certs/server-cert.pem"
update_ocserv_param "server-key" "/etc/ocserv/certs/server-key.pem"
update_ocserv_param "tcp-port" "443"
update_ocserv_param "udp-port" "443"
update_ocserv_param "max-clients" "16"
update_ocserv_param "max-same-clients" "8"
update_ocserv_param "compression" "true"
update_ocserv_param "no-compress-limit" "256"
update_ocserv_param "keepalive" "32400"
update_ocserv_param "dpd" "90"
update_ocserv_param "mobile-dpd" "1800"
update_ocserv_param "max-ban-score" "80"
update_ocserv_param "ban-reset-time" "1200"
update_ocserv_param "ipv4-network" "10.10.10.0"
update_ocserv_param "ipv4-netmask" "255.255.255.0"
update_ocserv_param "tunnel-all-dns" "true"
update_ocserv_param "route" "default"
update_ocserv_param "cisco-client-compat" "true"
update_ocserv_param "isolate-workers" "true"

# Добавляем DNS сервера
for dns in "8.8.8.8" "8.8.4.4" "1.1.1.1" "9.9.9.9"; do
    if ! sudo grep -q "^dns = ${dns}$" "$OCSERV_CONF"; then
        # Если нет ни одного DNS, добавляем
        if ! sudo grep -q "^dns =" "$OCSERV_CONF"; then
            echo "dns = ${dns}" | sudo tee -a "$OCSERV_CONF" > /dev/null
        fi
    fi
done

# Проверяем наличие критических параметров
add_ocserv_param_if_missing "socket-file" "/run/ocserv-socket"
add_ocserv_param_if_missing "run-as-user" "ocserv"
add_ocserv_param_if_missing "run-as-group" "ocserv"
add_ocserv_param_if_missing "pid-file" "/run/ocserv.pid"
add_ocserv_param_if_missing "device" "vpns"
add_ocserv_param_if_missing "predictable-ips" "true"
add_ocserv_param_if_missing "auth-timeout" "240"
add_ocserv_param_if_missing "min-reauth-time" "300"
add_ocserv_param_if_missing "cookie-timeout" "300"
add_ocserv_param_if_missing "deny-roaming" "false"
add_ocserv_param_if_missing "rekey-time" "172800"
add_ocserv_param_if_missing "rekey-method" "ssl"
add_ocserv_param_if_missing "use-occtl" "true"
add_ocserv_param_if_missing "log-level" "1"
add_ocserv_param_if_missing "rate-limit-ms" "100"

# Настройка sysctl
print_info "Настройка IP forwarding..."
sudo tee "$SYSCTL_CONF" > /dev/null <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sudo sysctl -p "$SYSCTL_CONF" 2>/dev/null || sudo sysctl --system

# Настройка UFW
print_info "Настройка файрвола UFW..."

INTERFACE=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
[ -z "${INTERFACE}" ] && INTERFACE=$(ip link show | grep -oP '^[0-9]+: \K[^:]+' | head -1)
print_info "Сетевой интерфейс: ${INTERFACE}"

# Разрешаем порты
sudo ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
sudo ufw allow 80/tcp comment 'HTTP' 2>/dev/null || true
sudo ufw allow 443/tcp comment 'HTTPS' 2>/dev/null || true
sudo ufw allow 443/udp comment 'OpenConnect UDP' 2>/dev/null || true

# Настройка NAT
if [ -f "$UFW_BEFORE_RULES" ]; then
    [ ! -f "${UFW_BEFORE_RULES}.bak" ] && sudo cp "$UFW_BEFORE_RULES" "${UFW_BEFORE_RULES}.bak"
    
    if ! sudo grep -q "### BEGIN ocserv forward rules" "$UFW_BEFORE_RULES"; then
        sudo sed -i "/^COMMIT$/i\\
### BEGIN ocserv forward rules\\
-A ufw-before-forward -s ${OPENCONNECT_NETWORK} -j ACCEPT\\
-A ufw-before-forward -d ${OPENCONNECT_NETWORK} -j ACCEPT\\
### END ocserv forward rules" "$UFW_BEFORE_RULES"
    fi
    
    if ! sudo grep -q "### BEGIN ocserv NAT rules" "$UFW_BEFORE_RULES"; then
        sudo tee -a "$UFW_BEFORE_RULES" > /dev/null <<EOF

### BEGIN ocserv NAT rules
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${OPENCONNECT_NETWORK} -o ${INTERFACE} -j MASQUERADE
COMMIT
### END ocserv NAT rules
EOF
    fi
fi

sudo ufw --force enable
sudo systemctl restart ufw

# Включение IP forwarding
if ! sudo grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi

# Создание пользователя
print_info "Создание пользователя VPN..."
prompt "Введите имя пользователя VPN: " VPN_USER

if [ -n "${VPN_USER}" ]; then
    prompt_secret "Введите пароль: " VPN_PASS
    printf '\n'
    prompt_secret "Подтвердите пароль: " VPN_PASS_CONFIRM
    printf '\n'

    if [ "${VPN_PASS}" = "${VPN_PASS_CONFIRM}" ] && [ -n "${VPN_PASS}" ]; then
        sudo bash -c "printf '%s\n%s\n' \"${VPN_PASS}\" \"${VPN_PASS}\" | ocpasswd -c '${VPN_PASSWD_FILE}' '${VPN_USER}'" && \
            print_success "Пользователь ${VPN_USER} создан"
    else
        print_error "Пароли не совпадают"
    fi
fi

# Запуск ocserv
print_info "Запуск ocserv..."
sudo systemctl daemon-reload
sudo systemctl enable ocserv
sudo systemctl restart ocserv

sleep 2
if sudo systemctl is-active --quiet ocserv; then
    print_success "ocserv успешно запущен"
else
    print_error "Ошибка запуска ocserv"
    sudo journalctl -u ocserv -n 20 --no-pager
    exit 1
fi

# Автообновление сертификатов
sudo systemctl enable --now certbot.timer
sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/ocserv-restart.sh > /dev/null <<'EOF'
#!/bin/bash
cp /etc/letsencrypt/live/*/fullchain.pem /etc/ocserv/certs/server-cert.pem 2>/dev/null || true
cp /etc/letsencrypt/live/*/privkey.pem /etc/ocserv/certs/server-key.pem 2>/dev/null || true
chmod 640 /etc/ocserv/certs/server-key.pem
chown root:ssl-cert /etc/ocserv/certs/server-key.pem
systemctl restart ocserv
EOF
sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/ocserv-restart.sh

# Вывод информации
clear
print_success "Настройка OpenConnect завершена!"
echo ""
echo "==========================================="
echo "Домен: $DOMAIN"
echo "Порт: 443 (TCP/UDP)"
echo "Адрес: https://$DOMAIN:443"
echo "==========================================="