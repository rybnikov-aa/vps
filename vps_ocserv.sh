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

# Функция для изменения параметра в ocserv.conf
update_ocserv_param() {
    local param_name="$1"
    local param_value="$2"
    
    if [ ! -f "$OCSERV_CONF" ]; then
        print_error "Файл $OCSERV_CONF не существует"
        return 1
    fi
    
    if [ ! -f "${OCSERV_CONF}.bak" ]; then
        sudo cp "$OCSERV_CONF" "${OCSERV_CONF}.bak"
        print_info "Создан бэкап ${OCSERV_CONF}.bak"
    fi
    
    local escaped_value=$(printf '%s\n' "$param_value" | sed -e 's/[\/&]/\\&/g')
    
    if sudo grep -q "^[[:space:]]*#\{0,\}[[:space:]]*${param_name}[[:space:]]*=" "$OCSERV_CONF"; then
        sudo sed -i -E "s/^([[:space:]]*#\{0,\}[[:space:]]*)${param_name}[[:space:]]*=[[:space:]]*.*/${param_name} = ${escaped_value}/" "$OCSERV_CONF"
        print_info "✓ Параметр ${param_name} обновлен"
    elif sudo grep -q "^[[:space:]]*#\{0,\}[[:space:]]*${param_name}[[:space:]]" "$OCSERV_CONF"; then
        sudo sed -i -E "s/^([[:space:]]*#\{0,\}[[:space:]]*)${param_name}[[:space:]]+.*/${param_name} = ${escaped_value}/" "$OCSERV_CONF"
        print_info "✓ Параметр ${param_name} обновлен"
    else
        print_info "⚠ Параметр ${param_name} не найден (пропускаем)"
    fi
}

# Функция для правильной настройки UFW before.rules
setup_ufw_nat() {
    local interface="$1"
    local network="$2"
    
    if [ ! -f "$UFW_BEFORE_RULES" ]; then
        print_error "Файл $UFW_BEFORE_RULES не существует"
        return 1
    fi
    
    # Создаем бэкап
    if [ ! -f "${UFW_BEFORE_RULES}.bak" ]; then
        sudo cp "$UFW_BEFORE_RULES" "${UFW_BEFORE_RULES}.bak"
        print_info "Создан бэкап ${UFW_BEFORE_RULES}.bak"
    fi
    
    # Удаляем предыдущие добавленные правила если они есть
    sudo sed -i '/### BEGIN ocserv forward rules/,/### END ocserv forward rules/d' "$UFW_BEFORE_RULES"
    sudo sed -i '/### BEGIN ocserv NAT rules/,/### END ocserv NAT rules/d' "$UFW_BEFORE_RULES"
    
    # Создаем временный файл с правильной структурой
    local temp_file=$(mktemp)
    
    # Копируем содержимое до первого COMMIT (секция filter)
    sudo awk '/^COMMIT$/ {exit} {print}' "$UFW_BEFORE_RULES" > "$temp_file"
    
    # Добавляем forward rules перед COMMIT
    cat >> "$temp_file" << EOF

### BEGIN ocserv forward rules
-A ufw-before-forward -s ${network} -j ACCEPT
-A ufw-before-forward -d ${network} -j ACCEPT
### END ocserv forward rules

COMMIT
EOF
    
    # Добавляем секцию nat ПОСЛЕ filter (как требует UFW)
    cat >> "$temp_file" << EOF

### BEGIN ocserv NAT rules
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${network} -o ${interface} -j MASQUERADE
COMMIT
### END ocserv NAT rules
EOF
    
    # Копируем обратно
    sudo cp "$temp_file" "$UFW_BEFORE_RULES"
    rm -f "$temp_file"
    
    print_info "✓ Правила UFW настроены корректно"
}

# Проверка прав
if [ "$EUID" -eq 0 ]; then
    print_error "Не запускайте скрипт от root"
    exit 1
fi

if ! command -v sudo &> /dev/null; then
    print_error "sudo не установлен"
    exit 1
fi

# Запрос домена
printf '\n'
prompt "Введите доменное имя вашего VPS: " DOMAIN

if [ -z "${DOMAIN}" ]; then
    print_error "Домен не может быть пустым"
    exit 1
fi

DOMAIN="$(printf '%s' "${DOMAIN}" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"

if ! [[ "${DOMAIN}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    print_error "Недопустимое доменное имя"
    exit 1
fi

print_info "Настройка OpenConnect для домена: ${DOMAIN}"

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
print_info "Получение SSL сертификата..."
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

# Убеждаемся что файл ocserv.conf существует
if [ ! -f "$OCSERV_CONF" ]; then
    print_error "Файл $OCSERV_CONF не найден. Установите ocserv сначала."
    exit 1
fi

# Настройка ocserv
print_info "Настройка ocserv..."

# Обновляем параметры
update_ocserv_param "auth" "\"plain[passwd=/etc/ocserv/ocserv.passwd]\""
update_ocserv_param "server-cert" "/etc/ocserv/certs/server-cert.pem"
update_ocserv_param "server-key" "/etc/ocserv/certs/server-key.pem"
update_ocserv_param "tcp-port" "443"
update_ocserv_param "udp-port" "443"
update_ocserv_param "max-clients" "16"
update_ocserv_param "max-same-clients" "8"
update_ocserv_param "keepalive" "32400"
update_ocserv_param "dpd" "90"
update_ocserv_param "mobile-dpd" "1800"
update_ocserv_param "max-ban-score" "80"
update_ocserv_param "ipv4-network" "10.10.10.0"
update_ocserv_param "ipv4-netmask" "255.255.255.0"
update_ocserv_param "route" "default"
update_ocserv_param "cisco-client-compat" "true"

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

# Определяем интерфейс
INTERFACE=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
[ -z "${INTERFACE}" ] && INTERFACE=$(ip link show | grep -oP '^[0-9]+: \K[^:]+' | head -1)
print_info "Сетевой интерфейс: ${INTERFACE}"

# Разрешаем порты
sudo ufw allow 22/tcp comment 'SSH' 2>/dev/null || true
sudo ufw allow 80/tcp comment 'HTTP' 2>/dev/null || true
sudo ufw allow 443/tcp comment 'HTTPS' 2>/dev/null || true
sudo ufw allow 443/udp comment 'OpenConnect UDP' 2>/dev/null || true

# Настраиваем NAT правила
setup_ufw_nat "$INTERFACE" "$OPENCONNECT_NETWORK"

# Включаем ufw
sudo ufw --force disable 2>/dev/null || true
sudo ufw --force enable

# Проверяем статус ufw
if sudo ufw status | grep -q "Status: active"; then
    print_success "UFW успешно настроен и активен"
else
    print_error "Проблема с UFW"
    sudo ufw status
fi

# Включаем IP forwarding в sysctl.conf
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
    echo ""
    print_info "Логи ocserv:"
    sudo journalctl -u ocserv -n 20 --no-pager
    echo ""
    print_info "Проверьте конфигурацию:"
    echo "  sudo nano $OCSERV_CONF"
    echo "  sudo systemctl restart ocserv"
    exit 1
fi

# Автообновление сертификатов
sudo systemctl enable --now certbot.timer
sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/ocserv-restart.sh > /dev/null <<'EOF'
#!/bin/bash
if [ -f /etc/letsencrypt/live/*/fullchain.pem ]; then
    cp /etc/letsencrypt/live/*/fullchain.pem /etc/ocserv/certs/server-cert.pem 2>/dev/null
    cp /etc/letsencrypt/live/*/privkey.pem /etc/ocserv/certs/server-key.pem 2>/dev/null
    chmod 640 /etc/ocserv/certs/server-key.pem
    chown root:ssl-cert /etc/ocserv/certs/server-key.pem
    systemctl restart ocserv
fi
EOF
sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/ocserv-restart.sh

# Вывод информации
clear
print_success "Настройка OpenConnect завершена!"
echo ""
echo "==========================================="
echo "VPN сервер: https://${DOMAIN}:443"
echo "Пользователь: ${VPN_USER:-не создан}"
echo ""
echo "Управление пользователями:"
echo "  Добавить: sudo ocpasswd -c /etc/ocserv/ocserv.passwd ИМЯ"
echo "  Удалить:  sudo ocpasswd -c /etc/ocserv/ocserv.passwd -d ИМЯ"
echo ""
echo "Статус: sudo systemctl status ocserv"
echo "Логи:   sudo journalctl -u ocserv -f"
echo "==========================================="