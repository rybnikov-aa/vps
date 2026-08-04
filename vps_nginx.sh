#!/bin/bash
# ======================================================
# Скрипт настройки VPS сервера для хостинга статических сайтов
# Версия: 2.0
# ======================================================

set -e  # Остановка при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для красивого вывода
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
    print_error "Скрипт нужно запускать с правами root (sudo)"
    exit 1
fi

# Очистка экрана
clear

# ======================================================
# 1. ЗАПРОС ДАННЫХ
# ======================================================

echo "======================================================"
echo "  НАСТРОЙКА VPS СЕРВЕРА (NGINX + SSL)"
echo "======================================================"
echo ""

# Запрос имени сайта
read -p "Введите имя сайта (например: example.com): " SITE_NAME

if [ -z "$SITE_NAME" ]; then
    print_error "Имя сайта не может быть пустым!"
    exit 1
fi

if ! [[ "$SITE_NAME" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    print_error "Имя сайта содержит недопустимые символы (допустимы буквы, цифры, точки и дефисы)"
    exit 1
fi

# Запрос email для Let's Encrypt
read -p "Введите email для SSL сертификатов (Let's Encrypt): " SSL_EMAIL

if [ -z "$SSL_EMAIL" ]; then
    print_warning "Email не указан, будет использован admin@$SITE_NAME"
    SSL_EMAIL="admin@$SITE_NAME"
fi

# Запрос адреса бэкенда для /api/ (необязательно)
read -p "Бэкенд для /api/ (адрес:порт, например 127.0.0.1:3000; пусто — без бэкенда): " BACKEND_ADDR

echo ""
echo "======================================================"
echo "Параметры настройки:"
echo "  - Сайт: $SITE_NAME"
echo "  - Email для SSL: $SSL_EMAIL"
if [ -n "$BACKEND_ADDR" ]; then
    echo "  - Бэкенд /api/: http://$BACKEND_ADDR"
else
    echo "  - Бэкенд /api/: не настроен"
fi
echo "======================================================"
echo ""

read -p "Продолжить настройку? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_error "Настройка отменена"
    exit 1
fi

# ======================================================
# 2. ОБНОВЛЕНИЕ СИСТЕМЫ
# ======================================================

print_status "Обновление системы..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y -o Dpkg::Options::="--force-confold" --force-confdef upgrade
apt-get install -y curl wget git ufw

# ======================================================
# 3. УСТАНОВКА NGINX
# ======================================================

print_status "Установка Nginx..."
apt-get install -y nginx

# Настройка server_names_hash_bucket_size
if ! grep -qE '^\s*server_names_hash_bucket_size' /etc/nginx/nginx.conf; then
    sed -i '/http {/a \    server_names_hash_bucket_size 64;' /etc/nginx/nginx.conf
    print_success "Добавлена настройка server_names_hash_bucket_size"
fi

# ======================================================
# 4. СОЗДАНИЕ ДИРЕКТОРИЙ
# ======================================================

print_status "Создание директорий для сайта..."
WEB_ROOT="/var/www/$SITE_NAME"
mkdir -p "$WEB_ROOT/public_html"

# ======================================================
# 4.1 СОЗДАНИЕ ДЕПЛОЙ-ПОЛЬЗОВАТЕЛЯ
# ======================================================

DEPLOY_USER="rybnikov"
print_status "Проверка деплой-пользователя $DEPLOY_USER..."

# Создаём пользователя, если его ещё нет
if ! id "$DEPLOY_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$DEPLOY_USER"
    print_success "Создан деплой-пользователь $DEPLOY_USER"
else
    print_success "Деплой-пользователь $DEPLOY_USER уже существует"
fi

# Добавляем в группу www-data (совместный доступ к файлам сайта)
usermod -aG www-data "$DEPLOY_USER"

# ======================================================
# 5. НАСТРОЙКА ПРАВ
# ======================================================

print_status "Настройка прав доступа..."

# Владелец — деплой-пользователь, группа — www-data (Nginx)
chown -R "$DEPLOY_USER":www-data "$WEB_ROOT"

# Права: владелец (деплой) может писать, группа www-data — читать
chmod 755 "$WEB_ROOT"
chmod 755 "$WEB_ROOT/public_html"

# ======================================================
# 6. НАСТРОЙКА NGINX
# ======================================================

print_status "Настройка Nginx для сайта $SITE_NAME..."

cat > "/etc/nginx/sites-available/$SITE_NAME" << EOF
server {
    listen 80;
    server_name $SITE_NAME;
    root $WEB_ROOT/public_html;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    access_log /var/log/nginx/${SITE_NAME}_access.log;
    error_log /var/log/nginx/${SITE_NAME}_error.log;
}
EOF

# Активируем сайт
ln -sf "/etc/nginx/sites-available/$SITE_NAME" "/etc/nginx/sites-enabled/"

# Удаляем дефолтный сайт
rm -f /etc/nginx/sites-enabled/default

# Проверяем конфигурацию (полный путь, т.к. /usr/sbin может не быть в PATH)
/usr/sbin/nginx -t

systemctl reload nginx
print_success "Nginx настроен"

# ======================================================
# 7. УСТАНОВКА SSL СЕРТИФИКАТОВ (Let's Encrypt)
# ======================================================

print_status "Установка SSL сертификатов..."

# Устанавливаем certbot
apt-get install -y certbot python3-certbot-nginx

# Получаем сертификат
print_status "Запрос SSL сертификата для $SITE_NAME..."

if certbot --nginx -d "$SITE_NAME" --non-interactive --agree-tos --email "$SSL_EMAIL" --redirect; then
    print_success "SSL сертификат успешно установлен"

    # Перезаписываем конфигурацию сайта на HTTPS (HTTP → HTTPS редирект)
    print_status "Настройка HTTPS-конфигурации для $SITE_NAME..."

    # Блок проксирования /api/ на бэкенд (если адрес указан)
    BACKEND_LOCATION=""
    if [ -n "$BACKEND_ADDR" ]; then
        print_status "Добавляю проксирование /api/ → http://$BACKEND_ADDR"
        BACKEND_LOCATION="
    location /api/ {
        proxy_pass http://$BACKEND_ADDR/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
"
    fi

    cat > "/etc/nginx/sites-available/$SITE_NAME" << EOF
server {
    listen 80;
    server_name $SITE_NAME;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $SITE_NAME;
    root $WEB_ROOT/public_html;
    index index.html index.htm;

    ssl_certificate /etc/letsencrypt/live/$SITE_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SITE_NAME/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    location / {
        try_files \$uri \$uri/ =404;
    }
$BACKEND_LOCATION
    access_log /var/log/nginx/${SITE_NAME}_access.log;
    error_log /var/log/nginx/${SITE_NAME}_error.log;
}
EOF

    # Проверяем и применяем конфигурацию
    /usr/sbin/nginx -t
    systemctl reload nginx

    # Настраиваем автоматическое обновление сертификатов (systemd-таймер)
    systemctl enable certbot.timer
    systemctl start certbot.timer

    print_success "Настроено автоматическое обновление сертификатов"
else
    print_error "Не удалось установить SSL сертификат"
    print_warning "Проверьте, что домен $SITE_NAME указывает на этот сервер"
    print_warning "Вы можете запустить установку позже командой: certbot --nginx -d $SITE_NAME --redirect"
fi

# ======================================================
# 8. НАСТРОЙКА БРАНДМАУЭРА
# ======================================================

print_status "Настройка брандмауэра..."

# Определяем порт SSH, чтобы не заблокировать себе доступ
SSH_PORT=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n 1)
SSH_PORT=${SSH_PORT:-22}

ufw allow ${SSH_PORT}/tcp  # SSH
ufw allow 80/tcp  # HTTP
ufw allow 443/tcp # HTTPS
ufw --force enable

print_success "Брандмауэр настроен"

# ======================================================
# 9. СОЗДАНИЕ ТЕСТОВОЙ СТРАНИЦЫ
# ======================================================

print_status "Создание тестовой страницы..."

cat > "$WEB_ROOT/public_html/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>$SITE_NAME</title>
    <meta charset="UTF-8">
    <style>
        body {
            font-family: 'Segoe UI', Arial, sans-serif;
            max-width: 800px;
            margin: 50px auto;
            padding: 20px;
            background: #f5f7fa;
        }
        .container {
            background: white;
            padding: 40px;
            border-radius: 10px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            text-align: center;
        }
        h1 { color: #2c3e50; }
        .success { color: #27ae60; font-size: 20px; }
        .info { color: #7f8c8d; margin-top: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 Сервер работает</h1>
        <p class="success">✅ Nginx успешно настроен</p>
        <p>Сайт: <strong>$SITE_NAME</strong></p>
        <div class="info">
            <p>📅 $(date)</p>
            <p>🔒 Соединение защищено SSL/TLS</p>
        </div>
    </div>
</body>
</html>
EOF

chown "$DEPLOY_USER":www-data "$WEB_ROOT/public_html/index.html"
chmod 644 "$WEB_ROOT/public_html/index.html"

# ======================================================
# 10. ЗАВЕРШЕНИЕ
# ======================================================

echo ""
echo "======================================================"
print_success "НАСТРОЙКА ЗАВЕРШЕНА!"
echo "======================================================"
echo ""
echo "📌 ИНФОРМАЦИЯ О САЙТЕ:"
echo ""
echo "   Сайт: https://$SITE_NAME/"
echo "   Корневая директория: $WEB_ROOT/public_html"
if [ -n "$BACKEND_ADDR" ]; then
    echo "   Бэкенд (/api/): http://$BACKEND_ADDR"
fi
echo ""
echo "📁 ДЛЯ РАЗМЕЩЕНИЯ ФАЙЛОВ:"
echo ""
echo "   Загружайте файлы в: $WEB_ROOT/public_html"
echo ""
echo "   Команда для загрузки (с локального компьютера):"
echo "   scp -r /путь/к/файлам/* $DEPLOY_USER@$SITE_NAME:$WEB_ROOT/public_html/"
echo ""
echo "🔧 УПРАВЛЕНИЕ:"
echo ""
echo "   Проверить статус Nginx: systemctl status nginx"
echo "   Перезагрузить Nginx: systemctl reload nginx"
echo "   Просмотр логов: tail -f /var/log/nginx/${SITE_NAME}_error.log"
echo "   Обновление сертификатов: certbot renew"
echo ""
echo "======================================================"

# ======================================================
# 11. ПРОВЕРКА РАБОТЫ
# ======================================================

print_status "Проверка работоспособности..."

# Проверяем Nginx
if systemctl is-active --quiet nginx; then
    print_success "Nginx работает"
else
    print_error "Nginx не работает"
fi

# Проверяем SSL
if [ -d "/etc/letsencrypt/live/$SITE_NAME" ]; then
    print_success "SSL сертификат установлен"
    
    # Проверяем доступность через HTTPS
    if curl -s -o /dev/null -w "%{http_code}" "https://$SITE_NAME" | grep -q "200"; then
        print_success "Сайт доступен по HTTPS: https://$SITE_NAME"
    fi
else
    print_warning "SSL сертификат не установлен"
fi

print_success "Готово!"