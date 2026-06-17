#!/bin/bash

# Скрипт для начальной настройки Debian сервера
# Запускать от root на чистой системе

set -euo pipefail  # Прерывать выполнение при ошибке, использовать только объявленные переменные и учитывать ошибки в конвейерах

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка, что скрипт запущен от root
if [[ $EUID -ne 0 ]]; then
   log_error "Этот скрипт должен запускаться от root (sudo)"
   exit 1
fi

# Запрос имени пользователя
read -r -p "Введите имя пользователя для создания [rybnikov]: " USERNAME
USERNAME=${USERNAME:-rybnikov}

if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    log_error "Неверное имя пользователя: $USERNAME. Допустимы только строчные латинские буквы, цифры, дефис и подчёркивание, должно начинаться с буквы или _."
    exit 1
fi

log_info "Начинаем настройку системы для пользователя: $USERNAME"

# Установка базовых пакетов
log_info "Устанавливаем sudo и nano..."
apt update
apt install sudo nano -y

# Обновление системы
log_info "Обновляем пакеты и чистим мусор..."
apt update && apt full-upgrade -y
apt autoremove -y && apt autoclean

# Установка пароля root
log_info "Задаём пароль для root..."
passwd

# Создание пользователя
log_info "Создаём пользователя $USERNAME..."
if id -u "$USERNAME" >/dev/null 2>&1; then
    log_warn "Пользователь $USERNAME уже существует, пропускаем создание"
else
    adduser --gecos "" --disabled-password "$USERNAME"
    log_info "Пользователь $USERNAME создан"
fi
usermod -aG sudo "$USERNAME"
log_info "Пользователь $USERNAME добавлен в группу sudo"

# Настройка sudo без пароля для пользователя
log_info "Настраиваем беспарольный sudo для пользователя $USERNAME..."

# Создаем файл в /etc/sudoers.d/ для пользователя
cat > /etc/sudoers.d/$USERNAME << EOF
# Разрешить пользователю $USERNAME выполнять sudo без пароля
$USERNAME ALL=(ALL) NOPASSWD: ALL
EOF

# Устанавливаем правильные права (должно быть 440)
chmod 440 /etc/sudoers.d/$USERNAME

log_info "✓ Беспарольный sudo настроен для пользователя $USERNAME"

# Настройка SSH
log_info "Настраиваем SSH..."

# Бэкап оригинального конфига
SSH_BACKUP="/etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)"
cp /etc/ssh/sshd_config "$SSH_BACKUP"
log_info "Создан бэкап $SSH_BACKUP"

# Функция для замены или добавления параметра в sshd_config
set_ssh_param() {
    local param=$1
    local value=$2
    local file="/etc/ssh/sshd_config"
    
        # Если параметр существует (даже закомментированный)
    if grep -qE "^[[:space:]]*#?[[:space:]]*${param}[[:space:]]+" "$file"; then
        # Раскомментируем и меняем значение
        sed -i -E "s/^[[:space:]]*#?[[:space:]]*${param}[[:space:]]+.*/${param} ${value}/" "$file"
        log_info "Обновлен параметр: ${param} ${value}"
    else
        # Если параметра нет, добавляем в конец
        echo "${param} ${value}" >> "$file"
        log_info "Добавлен параметр: ${param} ${value}"
    fi
}

log_info "Настраиваем параметры SSH..."

# Основные настройки безопасности
set_ssh_param "PermitRootLogin" "no"
set_ssh_param "PasswordAuthentication" "no"
set_ssh_param "PubkeyAuthentication" "yes"
set_ssh_param "AuthenticationMethods" "publickey"
set_ssh_param "X11Forwarding" "no"

# Настройка разрешенных пользователей
# Сначала удаляем старые AllowUsers если есть
sed -i '/^AllowUsers/d' /etc/ssh/sshd_config
set_ssh_param "AllowUsers" "$USERNAME"

# Дополнительные рекомендованные настройки
set_ssh_param "ChallengeResponseAuthentication" "no"
set_ssh_param "MaxAuthTries" "3"
set_ssh_param "ClientAliveInterval" "300"
set_ssh_param "ClientAliveCountMax" "2"

# Обработка cloud-init конфига если существует
if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
    log_info "Обнаружен cloud-init конфиг, отключаем парольную аутентификацию в нём"
    
    # Бэкап cloud-init конфига
    CLOUD_INIT_BACKUP="/etc/ssh/sshd_config.d/50-cloud-init.conf.backup"
    cp /etc/ssh/sshd_config.d/50-cloud-init.conf "$CLOUD_INIT_BACKUP"
    
    # Отключаем параметры в cloud-init конфиге
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config.d/50-cloud-init.conf
    
    # Если параметров нет - добавляем
    if ! grep -qE '^[[:space:]]*#?[[:space:]]*PasswordAuthentication' /etc/ssh/sshd_config.d/50-cloud-init.conf; then
        echo "PasswordAuthentication no" >> /etc/ssh/sshd_config.d/50-cloud-init.conf
    fi
    if ! grep -qE '^[[:space:]]*#?[[:space:]]*PermitRootLogin' /etc/ssh/sshd_config.d/50-cloud-init.conf; then
        echo "PermitRootLogin no" >> /etc/ssh/sshd_config.d/50-cloud-init.conf
    fi
fi

# Показать изменения
log_info "Изменения в конфигурации SSH:"
echo "----------------------------------------"
echo "=== Основной конфиг (/etc/ssh/sshd_config) ==="
grep -E "PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AuthenticationMethods|X11Forwarding|AllowUsers|ChallengeResponseAuthentication|MaxAuthTries|ClientAlive" /etc/ssh/sshd_config | grep -v "^#"
echo ""
if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
    echo "=== Cloud-init конфиг (/etc/ssh/sshd_config.d/50-cloud-init.conf) ==="
    grep -E "PasswordAuthentication|PermitRootLogin" /etc/ssh/sshd_config.d/50-cloud-init.conf 2>/dev/null | grep -v "^#" || echo "Параметры не найдены"
fi
echo "----------------------------------------"

# Проверка конфигурации SSH
log_info "Проверяем конфигурацию SSH..."
if sshd -t; then
    log_info "✓ Конфигурация SSH валидна"
else
    log_error "✗ Ошибка в конфигурации SSH!"
    log_info "Восстанавливаем бэкап..."
    cp "$SSH_BACKUP" /etc/ssh/sshd_config 2>/dev/null || true
    if [ -n "${CLOUD_INIT_BACKUP:-}" ] && [ -f "$CLOUD_INIT_BACKUP" ]; then
        cp "$CLOUD_INIT_BACKUP" /etc/ssh/sshd_config.d/50-cloud-init.conf
    fi
    systemctl restart ssh
    exit 1
fi

# === ДОБАВЛЕНИЕ ПУБЛИЧНЫХ КЛЮЧЕЙ ===
log_info "Добавляем публичные SSH ключи для пользователя $USERNAME..."

# Создаем .ssh директорию от имени пользователя
log_info "Создаем директорию /home/$USERNAME/.ssh"
sudo -u "$USERNAME" mkdir -p "/home/$USERNAME/.ssh"

# Создаем файл authorized_keys с ключами
log_info "Добавляем публичные ключи в authorized_keys"

cat > /home/$USERNAME/.ssh/authorized_keys << 'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH38aA2983gNAjYy6JEK35bZivTkMlDOBZfF/ECF7dIb alex@NEXUS
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHoew2zs81jhqm9f/GcFvw3GWW0zwixp6oEOyqCwNmI2 alex@BOOK4PRO
EOF

# Устанавливаем правильные права
log_info "Устанавливаем права доступа..."
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
chmod 700 /home/$USERNAME/.ssh
chmod 600 /home/$USERNAME/.ssh/authorized_keys

log_info "✓ SSH ключи успешно добавлены для пользователя $USERNAME"

# Проверяем, что ключи добавились
KEY_COUNT=$(wc -l < /home/$USERNAME/.ssh/authorized_keys)
log_info "Добавлено ключей: $KEY_COUNT"

# Показываем список добавленных ключей
echo "----------------------------------------"
log_info "Список добавленных публичных ключей:"
cat /home/$USERNAME/.ssh/authorized_keys
echo "----------------------------------------"

# Перезапуск SSH
log_info "Перезапускаем SSH службу..."
systemctl restart ssh

# Проверка статуса SSH
if systemctl is-active --quiet ssh; then
    log_info "✓ SSH служба успешно перезапущена"
else
    log_error "✗ Проблема с перезапуском SSH службы!"
    systemctl status ssh --no-pager
fi

# Проверка итоговых настроек
log_info "Проверяем итоговые настройки SSH:"
echo "----------------------------------------"
sshd -T | egrep "allowusers|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|authenticationmethods|permitrootlogin"
echo "----------------------------------------"

# Проверка, что AllowUsers содержит правильного пользователя
if sshd -T | grep -q "allowusers $USERNAME"; then
    log_info "✓ Пользователь $USERNAME правильно настроен в AllowUsers"
else
    log_error "✗ Ошибка: пользователь $USERNAME не найден в AllowUsers!"
fi

# Проверка, что файл authorized_keys существует и имеет правильные права
if [ -f /home/$USERNAME/.ssh/authorized_keys ]; then
    PERMS=$(stat -c "%a" /home/$USERNAME/.ssh/authorized_keys)
    if [ "$PERMS" = "600" ]; then
        log_info "✓ Права на authorized_keys корректны (600)"
    else
        log_warn "Права на authorized_keys: $PERMS (должно быть 600)"
    fi
    
    DIR_PERMS=$(stat -c "%a" /home/$USERNAME/.ssh)
    if [ "$DIR_PERMS" = "700" ]; then
        log_info "✓ Права на .ssh директорию корректны (700)"
    else
        log_warn "Права на .ssh директорию: $DIR_PERMS (должно быть 700)"
    fi
fi

log_info "========================================="
log_info "✅ Настройка завершена успешно!"
log_info "========================================="
log_info "Настроено:"
log_info "  ✓ Пользователь: $USERNAME"
log_info "  ✓ Добавлено SSH ключей: $KEY_COUNT"
log_info "  ✓ Отключен вход по паролю"
log_info "  ✓ Отключен вход от root"
log_info "  ✓ Разрешен вход только для: $USERNAME"
log_info "========================================="
log_warn "⚠️  ВАЖНО: Текущую SSH сессию НЕ ЗАКРЫВАЙТЕ! ⚠️"
log_info ""
log_info "Перед закрытием сессии обязательно проверьте подключение:"
log_info ""
log_info "1. Откройте НОВЫЙ терминал"
log_info "2. Подключитесь к серверу:"
log_info "   ssh $USERNAME@IP_АДРЕС"
log_info ""
log_info "3. Проверьте работу sudo:"
log_info "   sudo whoami  # Должно показать 'root'"
log_info ""
log_info "4. Если всё работает - можете закрывать старую сессию"
log_info ""
log_warn "Если НЕ получается подключиться - НЕ закрывайте текущую сессию!"
log_warn "Для отката изменений выполните:"
log_warn "  cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config"
log_warn "  systemctl restart ssh"
log_info "========================================="

# Финальная проверка
log_info "Финальная проверка статуса SSH сервера:"
systemctl status ssh --no-pager -l | grep -E "Active|Loaded|Main PID"
log_info "========================================="