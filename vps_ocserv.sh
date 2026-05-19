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

# Функция для изменения параметра в конфигурационном файле
update_config_param() {
    local config_file="$1"
    local param_name="$2"
    local param_value="$3"
    local section="$4"  # опционально, для группировки
    
    if [ ! -f "$config_file" ]; then
        print_error "Файл конфигурации $config_file не существует"
        return 1
    fi
    
    # Создаем бэкап только если его нет
    if [ ! -f "${config_file}.bak" ]; then
        sudo cp "$config_file" "${config_file}.bak"
        print_info "Создан бэкап ${config_file}.bak"
    fi
    
    # Экранируем спецсимволы в значении
    local escaped_value=$(printf '%s\n' "$param_value" | sed -e 's/[\/&]/\\&/g')
    
    # Проверяем, существует ли параметр (в т.ч. закомментированный)
    if sudo grep -q "^[#[:space:]]*${param_name}[[:space:]]*=" "$config_file" || sudo grep -q "^[#[:space:]]*${param_name}[[:space:]]" "$config_file"; then
        # Если параметр существует (даже закомментированный), обновляем его
        sudo sed -i -E "s/^([#[:space:]]*)${param_name}[[:space:]]*=[[:space:]]*.*/${param_name} = ${escaped_value}/" "$config_file"
        sudo sed -i -E "s/^([#[:space:]]*)${param_name}[[:space:]]+.*/${param_name} = ${escaped_value}/" "$config_file"
        print_info "Параметр ${param_name} обновлен в ${config_file}"
    else
        # Если параметра нет, добавляем его
        if [ -n "$section" ] && ! sudo grep -q "^${section}$" "$config_file"; then
            echo "" | sudo tee -a "$config_file" > /dev/null
            echo "# ${section}" | sudo tee -a "$config_file" > /dev/null
        fi
        echo "${param_name} = ${param_value}" | sudo tee -a "$config_file" > /dev/null
        print_info "Параметр ${param_name} добавлен в ${config_file}"
    fi
}

# Функция для управления комментариями
uncomment_param() {
    local config_file="$1"
    local param_name="$2"
    
    if [ ! -f "$config_file" ]; then
        return 1
    fi
    
    # Раскомментировать параметр если он закомментирован
    sudo sed -i -E "s/^#([[:space:]]*${param_name}[[:space:]]*=[[:space:]]*.*)/\1/" "$config_file"
    sudo sed -i -E "s/^#([[:space:]]*${param_name}[[:space:]]+.*)/\1/" "$config_file"
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
DOMAIN="${DOMAIN//$'\xef\xbb\xbf'/}"
DOMAIN="$(printf '%s' "${DOMAIN}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
DOMAIN="$(printf '%s' "${DOMAIN}" | tr '[:upper:]' '[:lower:]')"
CLEAN_DOMAIN="$(printf '%s' "${DOMAIN}" | sed 's/[^a-z0-9.-]//g')"
if [ "${CLEAN_DOMAIN}" != "${DOMAIN}" ]; then
    print_info "Санитизация доменного имени: '${DOMAIN}' -> '${CLEAN_DOMAIN}'"
    DOMAIN="${CLEAN_DOMAIN}"
fi

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
if sudo test -f "${LIVE_DIR}/cert.pem" && sudo test -f "${LIVE_DIR}/privkey.pem" && sudo test -f "${LIVE_DIR}/fullchain.pem"; then
    :
else
    CERT_NAME=$(sudo certbot certificates 2>/dev/null | awk -v d="${DOMAIN}" '
        /^[[:space:]]*Certificate Name:/ {name=$3}
        /^[[:space:]]*Domains:/ { if ($0 ~ d) print name }
    ' | head -n1)
    if [ -n "${CERT_NAME}" ] && [ -d "/etc/letsencrypt/live/${CERT_NAME}" ]; then
        LIVE_DIR="/etc/letsencrypt/live/${CERT_NAME}"
    fi
    if ! sudo test -f "${LIVE_DIR}/cert.pem" || ! sudo test -f "${LIVE_DIR}/privkey.pem" || ! sudo test -f "${LIVE_DIR}/fullchain.pem"; then
        print_error "Файл сертификата не найден"
        exit 1
    fi
fi

# Создание директории для сертификатов
sudo install -d -m 755 /etc/ocserv/certs

# Копирование сертификатов
print_info "Установка сертификатов..."
sudo cp "${LIVE_DIR}/cert.pem" /etc/ocserv/certs/cert.pem
sudo cp "${LIVE_DIR}/privkey.pem" /etc/ocserv/certs/key.pem
sudo cp "${LIVE_DIR}/fullchain.pem" /etc/ocserv/certs/fullchain.pem

sudo chmod 644 /etc/ocserv/certs/cert.pem
sudo chmod 640 /etc/ocserv/certs/key.pem
sudo chown root:ssl-cert /etc/ocserv/certs/key.pem

# Настройка ocserv - только изменение конкретных параметров
print_info "Настройка ocserv..."

# Создаем базовую конфигурацию если файла нет
if [ ! -f "$OCSERV_CONF" ]; then
    sudo touch "$OCSERV_CONF"
fi

# Обновляем параметры конфигурации
update_config_param "$OCSERV_CONF" "auth" "\"plain[passwd=/etc/ocserv/ocserv.passwd]\"" "AUTHENTICATION"
update_config_param "$OCSERV_CONF" "server-cert" "/etc/ocserv/certs/cert.pem" "SSL CERTIFICATES"
update_config_param "$OCSERV_CONF" "server-key" "/etc/ocserv/certs/key.pem" "SSL CERTIFICATES"
update_config_param "$OCSERV_CONF" "ca-cert" "/etc/ocserv/certs/fullchain.pem" "SSL CERTIFICATES"
update_config_param "$OCSERV_CONF" "tcp-port" "443" "PORTS"
update_config_param "$OCSERV_CONF" "udp-port" "443" "PORTS"
update_config_param "$OCSERV_CONF" "max-clients" "16" "GENERAL"
update_config_param "$OCSERV_CONF" "max-same-clients" "8" "GENERAL"
update_config_param "$OCSERV_CONF" "compression" "true" "COMPRESSION"
update_config_param "$OCSERV_CONF" "no-compress-limit" "256" "COMPRESSION"
update_config_param "$OCSERV_CONF" "tls-priorities" "\"NORMAL:%SERVER_PRECEDENCE:%COMPAT:-RSA:-VERS-ALL:+VERS-TLS1.2:+VERS-TLS1.3:-ARCFOUR-128\"" "SECURITY"
update_config_param "$OCSERV_CONF" "max-ban-score" "80" "SECURITY"
update_config_param "$OCSERV_CONF" "ban-reset-time" "300" "SECURITY"
update_config_param "$OCSERV_CONF" "ban-points-wrong-password" "10" "SECURITY"
update_config_param "$OCSERV_CONF" "ban-points-connection" "1" "SECURITY"
update_config_param "$OCSERV_CONF" "ipv4-network" "10.10.10.0" "NETWORK"
update_config_param "$OCSERV_CONF" "ipv4-netmask" "255.255.255.0" "NETWORK"
update_config_param "$OCSERV_CONF" "tunnel-all-dns" "true" "DNS"
update_config_param "$OCSERV_CONF" "dns" "8.8.8.8" "DNS"
update_config_param "$OCSERV_CONF" "dns" "8.8.4.4" "DNS"
update_config_param "$OCSERV_CONF" "dns" "9.9.9.9" "DNS"
update_config_param "$OCSERV_CONF" "dns" "1.1.1.1" "DNS"
update_config_param "$OCSERV_CONF" "route" "default" "ROUTING"
update_config_param "$OCSERV_CONF" "isolate-workers" "true" "PERFORMANCE"
update_config_param "$OCSERV_CONF" "keepalive" "32400" "PERFORMANCE"
update_config_param "$OCSERV_CONF" "dpd" "90" "PERFORMANCE"
update_config_param "$OCSERV_CONF" "mobile-dpd" "1800" "PERFORMANCE"
update_config_param "$OCSERV_CONF" "try-mtu-discovery" "true" "PERFORMANCE"
update_config_param "$OCSERV_CONF" "cisco-client-compat" "true" "COMPATIBILITY"

# Настройка sysctl
print_info "Настройка IP forwarding..."
sudo tee "$SYSCTL_CONF" > /dev/null <<EOF
# Настройки для VPN
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

if sudo sysctl --system >/dev/null 2>&1; then
    print_info "sysctl применён через --system"
else
    sudo sysctl -p "$SYSCTL_CONF"
fi

# Настройка UFW
print_info "Настройка файрвола UFW..."

INTERFACE=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
[ -z "${INTERFACE}" ] && INTERFACE="eth0"
print_info "Используем сетевой интерфейс: ${INTERFACE}"

# Разрешаем порты
sudo ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
sudo ufw allow 80/tcp comment 'HTTP' 2>/dev/null || true
sudo ufw allow 443/tcp comment 'HTTPS' 2>/dev/null || true
sudo ufw allow 443/udp comment 'OpenConnect UDP' 2>/dev/null || true

# Настройка NAT и форвардинга в UFW
if [ -f "$UFW_BEFORE_RULES" ]; then
    # Создаем бэкап если нет
    [ ! -f "${UFW_BEFORE_RULES}.bak" ] && sudo cp "$UFW_BEFORE_RULES" "${UFW_BEFORE_RULES}.bak"
    
    # Проверяем и добавляем forward rules
    if ! sudo grep -q "### BEGIN ocserv forward rules" "$UFW_BEFORE_RULES"; then
        # Находим строку COMMIT и вставляем перед ней
        sudo sed -i "/^COMMIT$/i\\
### BEGIN ocserv forward rules\\
-A ufw-before-forward -s ${OPENCONNECT_NETWORK} -j ACCEPT\\
-A ufw-before-forward -d ${OPENCONNECT_NETWORK} -j ACCEPT\\
### END ocserv forward rules" "$UFW_BEFORE_RULES"
        print_info "Forward rules добавлены в $UFW_BEFORE_RULES"
    fi
    
    # Проверяем и добавляем NAT rules
    if ! sudo grep -q "### BEGIN ocserv NAT rules" "$UFW_BEFORE_RULES"; then
        sudo tee -a "$UFW_BEFORE_RULES" > /dev/null <<EOF

### BEGIN ocserv NAT rules
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${OPENCONNECT_NETWORK} -o ${INTERFACE} -j MASQUERADE
COMMIT
### END ocserv NAT rules
EOF
        print_info "NAT rules добавлены в $UFW_BEFORE_RULES"
    fi
else
    print_error "Файл $UFW_BEFORE_RULES не найден"
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

if sudo systemctl is-active --quiet ocserv; then
    print_success "ocserv успешно запущен"
else
    print_error "Проблема с запуском ocserv"
    sudo systemctl status ocserv
    exit 1
fi

# Настройка автообновления сертификатов
print_info "Настройка автоматического обновления сертификатов..."
sudo systemctl enable --now certbot.timer

sudo tee /etc/letsencrypt/renewal-hooks/deploy/ocserv-restart.sh > /dev/null <<'EOF'
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
echo "==========================================="

print_info "Проверка открытых портов..."
sudo ufw status verbose