# VPS Scripts

Набор скриптов для настройки Debian/Ubuntu VPS сервера:

- **`vps_init.sh`** — начальная настройка сервера и безопасность SSH
- **`vps_ocserv.sh`** — развёртывание OpenConnect VPN сервера
- **`vps_nginx.sh`** — хостинг статических сайтов (Nginx + SSL)

## Возможности

✅ Установка базовых пакетов и обновление системы  
✅ Создание нового пользователя с sudo доступом  
✅ Беспарольный sudo для администратора  
✅ Безопасная настройка SSH:
  - Отключение входа от root
  - Отключение парольной аутентификации
  - Включение аутентификации по SSH ключам
  - Ограничение доступа только для конкретного пользователя
  - Бэкапирование оригинальной конфигурации

✅ Добавление публичных SSH ключей  
✅ Комплексная валидация всех изменений  
✅ Информативный лог выполнения со справками

## 🚀 Быстрый старт

Запустите `vps_init.sh` в одну строку:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/rybnikov-aa/vps/main/vps_init.sh)
```

Для быстрого запуска скрипта `vps_ocserv.sh` используйте:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/rybnikov-aa/vps/main/vps_ocserv.sh)
```

Для быстрого запуска скрипта `vps_nginx.sh` используйте:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/rybnikov-aa/vps/main/vps_nginx.sh)
```

## 🔹 vps_init.sh

### Требования

- Debian/Ubuntu сервер
- Доступ к root (или sudo с полными привилегиями)
- Интернет соединение

### Использование

#### 1. Скачивание скрипта

```bash
wget https://your-repo-url/vps_init.sh
chmod +x vps_init.sh
```

#### 2. Запуск скрипта

```bash
sudo ./vps_init.sh
```

**ВАЖНО:** Скрипт должен быть запущен от root!

#### 3. Интерактивный ввод

Скрипт попросит вас ввести:
- **Имя пользователя** (по умолчанию: `rybnikov`)
  - Допускаются только строчные латинские буквы, цифры, дефис и подчёркивание
  - Должно начинаться с буквы или _

## 🔹 vps_ocserv.sh

### Возможности

✅ Установка и настройка OpenConnect VPN (ocserv)  
✅ Автоматическое получение SSL сертификата Let's Encrypt  
✅ Регулярное автообновление сертификатов через certbot.timer  
✅ Настройка UFW фаервола с NAT/MASQUERADE для VPN сети  
✅ Включение IP forwarding (IPv4 и IPv6)  
✅ Оптимизация сети: TCP BBR, qdisc fq  
✅ Интерактивное создание VPN пользователей с паролем  
✅ Управление пользователями ocserv

### Описание скрипта

Запускает полноценный OpenConnect VPN сервер с:

1. **SSL сертификатами**
   - Автоматическое получение через Certbot (HTTP-челлендж)
   - Автоматическое обновление через deploy-хук
   - Сертификаты хранятся в `/etc/ocserv/certs/`

2. **Сетевая конфигурация**
   - IP forwarding включён через sysctl
   - UFW правила для NAT (MASQUERADE) из VPN-сети
   - Forwarding для закрытой VPN сети
   - Оптимизация: `net.core.default_qdisc = fq`, `net.ipv4.tcp_congestion_control = bbr`

3. **VPN пользователи**
   - Создают пароль в `/etc/ocserv/ocserv.passwd`
   - Управление: `ocpasswd`, `sudo ocpasswd`

### Использование

#### 1. Скачивание скрипта

```bash
wget https://your-repo-url/vps_ocserv.sh
chmod +x vps_ocserv.sh
```

#### 2. Запуск скрипта

```bash
sudo ./vps_ocserv.sh
```

#### 3. Интерактивный ввод

Скрипт попросит вас ввести:
- **Доменное имя** сервера (для SSL сертификата)
- **Email** для Let's Encrypt
- **Сеть OpenConnect** (по умолчанию `10.10.10.0/24`)
- **Имя пользователя VPN**
- **Пароль** (дважды для подтверждения)

### После установки

**Управление пользователями:**
```bash
# Добавить пользователя
sudo ocpasswd -c /etc/ocserv/ocserv.passwd username

# Удалить пользователя
sudo ocpasswd -c /etc/ocserv/ocserv.passwd -d username
```

**Статус и логи:**
```bash
sudo systemctl status ocserv
sudo journalctl -u ocserv -f
```

**Подключение клиента:**
```bash
openconnect https://your-domain:443 --user=username
```

## 🔹 vps_nginx.sh

Скрипт для быстрого развёртывания хостинга статических сайтов: Nginx + SSL (Let's Encrypt) + брандмауэр.

### Возможности

✅ Установка и настройка Nginx  
✅ Автоматическое получение SSL сертификата Let's Encrypt (`certbot --nginx`)  
✅ Автообновление сертификатов через `certbot.timer`  
✅ Настройка UFW фаервола с автоопределением порта SSH  
✅ Проксирование `/api/` на бэкенд веб-приложения (опционально)  
✅ Создание отдельного деплой-пользователя для загрузки файлов (без root)  
✅ Создание структуры и прав для `/var/www/{SITE}/public_html`  
✅ Создание тестовой страницы  
✅ Проверка работоспособности после установки  

### Требования

- Debian/Ubuntu сервер
- Доступ к root (или sudo)
- Домен должен указывать (DNS A-запись) на IP этого сервера — иначе SSL-сертификат не выдастся
- Интернет соединение

### Использование

#### 1. Скачивание скрипта

```bash
wget https://your-repo-url/vps_nginx.sh
chmod +x vps_nginx.sh
```

#### 2. Запуск скрипта

```bash
sudo ./vps_nginx.sh
```

**ВАЖНО:** Скрипт должен быть запущен от root!

#### 3. Интерактивный ввод

Скрипт попросит вас ввести:
- **Имя сайта** (домен, например `example.com`)
- **Email** для Let's Encrypt (по умолчанию `admin@{домен}`)
- **Адрес бэкенда** для `/api/` (например `127.0.0.1:3000`; пусто — без бэкенда)
- Подтверждение начала настройки

### После установки

**Размещение файлов сайта:**
```bash
scp -r /путь/к/файлам/* rybnikov@{SITE}:/var/www/{SITE}/public_html/
```

**Управление Nginx:**
```bash
sudo systemctl status nginx
sudo systemctl reload nginx
tail -f /var/log/nginx/{SITE}_error.log
```

**Обновление сертификатов вручную:**
```bash
sudo certbot renew
```

### Устранение проблем

**SSL-сертификат не установился:**
- Проверьте, что DNS A-запись домена указывает на IP сервера
- Дождитесь обновления DNS и запустите: `sudo certbot --nginx -d {SITE} --redirect`

**Пропал доступ по SSH после включения UFW:**
- Скрипт автоматически определяет порт SSH из `/etc/ssh/sshd_config`
- Проверить правила: `sudo ufw status`

## Что изменяется на сервере

### Системные изменения

1. **Обновление пакетов**
   - `apt update && apt full-upgrade -y`
   - Очистка неиспользуемых пакетов

2. **Создание пользователя**
   - Новый пользователь с доступом в группу `sudo`
   - Беспарольный sudo для удобства

3. **SSH конфигурация** (`/etc/ssh/sshd_config`)
   ```
   PermitRootLogin no              # Запретить вход от root
   PasswordAuthentication no       # Только ключи, не пароли
   PubkeyAuthentication yes        # Включить аутентификацию по ключам
   AuthenticationMethods publickey # Только публичный ключ
   X11Forwarding no                # Отключить X11
   MaxAuthTries 3                  # Макс 3 попытки входа
   ClientAliveInterval 300         # Проверка живого соединения каждые 5 минут
   ```

4. **SSH ключи**
   - Директория `/home/{USERNAME}/.ssh` с правами 700
   - Файл `authorized_keys` с правами 600
   - Добавляются предконфигурированные публичные ключи

### Изменения от vps_nginx.sh

5. **Деплой-пользователь**
   - Создаётся пользователь `rybnikov` (если ещё нет) и добавляется в группу `www-data`
   - Файлы загружаются через SSH без прав root

6. **Структура сайта**
   - Корневая директория: `/var/www/{SITE}/public_html`
   - Владелец: деплой-пользователь `rybnikov`, группа `www-data`

7. **Nginx**
   - Конфиг сайта: `/etc/nginx/sites-available/{SITE}`
   - Дефолтный сайт отключается
   - После получения сертификата конфигурация перезаписывается на HTTPS:
     - HTTP → HTTPS редирект (301) на `listen 80`
     - HTTPS-сервер на `listen 443 ssl http2` с сертификатами Let's Encrypt
   - Проксирование `/api/` на бэкенд (если адрес указан при настройке)

8. **SSL**
   - Сертификаты: `/etc/letsencrypt/live/{SITE}/`
   - Автообновление: `certbot.timer`

9. **Брандмауэр (UFW)**
   - Разрешено: `{SSH_PORT}/tcp`, `80/tcp`, `443/tcp`
   - Порт SSH определяется автоматически из `/etc/ssh/sshd_config`

## Важные замечания

⚠️ **ПЕРЕД ЗАКРЫТИЕМ СЕССИИ:**
- Не закрывайте текущую SSH сессию до проверки подключения!
- Откройте НОВЫЙ терминал и проверьте подключение:
  ```bash
  ssh {USERNAME}@{IP_АДРЕС}
  sudo whoami  # Должно показать 'root'
  ```

🔄 **Откат изменений (в случае необходимости):**
```bash
# Восстановить оригинальную конфигурацию SSH
sudo cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config
sudo systemctl restart ssh
```

## Внесение изменений SSH ключей

Чтобы добавить или изменить SSH ключи:

1. Отредактируйте файл `authorized_keys`:
   ```bash
   sudo nano /home/{USERNAME}/.ssh/authorized_keys
   ```

2. Добавьте/удалите публичные ключи (каждый ключ на отдельной строке)

3. Проверьте права:
   ```bash
   sudo chmod 600 /home/{USERNAME}/.ssh/authorized_keys
   ```

## Логирование

Скрипт предоставляет цветной логирование:
- 🟢 **[INFO]** - информационные сообщения
- 🟡 **[WARN]** - предупреждения
- 🔴 **[ERROR]** - ошибки (прерывают выполнение)

## Безопасность

✅ Автоматическая валидация конфигурации SSH (`sshd -t`)  
✅ Проверка прав доступа на критические файлы  
✅ Бэкапирование оригинальных конфигов перед изменениями  
✅ Расширенные параметры безопасности SSH  
✅ Ограничение максимального количества попыток входа  

## Устранение проблем

### Не могу подключиться по SSH после запуска скрипта

1. **Проверьте, используете ли вы правильное имя пользователя** (по умолчанию `rybnikov`)
   ```bash
   ssh rybnikov@IP_АДРЕС
   ```

2. **Убедитесь, что SSH ключ правильно загружен**
   ```bash
   ssh -v rybnikov@IP_АДРЕС  # Подробный лог подключения
   ```

3. **Проверьте статус SSH сервиса**
   ```bash
   sudo systemctl status ssh
   ```

4. **Восстановите оригинальную конфигурацию** (если нужен откат)
   ```bash
   sudo cp /etc/ssh/sshd_config.backup.* /etc/ssh/sshd_config
   sudo systemctl restart ssh
   ```

### Скрипт требует запуска от root

```bash
# Неправильно:
./vps_init.sh

# Правильно:
sudo ./vps_init.sh
```

## Дополнительная информация

- **SSH конфигурация:** `/etc/ssh/sshd_config`
- **SSH ключи пользователя:** `/home/{USERNAME}/.ssh/`
- **Sudoers конфиг:** `/etc/sudoers.d/{USERNAME}`
- **Системные логи:** `journalctl -u ssh`
- **Конфигурация сайта:** `/etc/nginx/sites-available/{SITE}`
- **Файлы сайта:** `/var/www/{SITE}/public_html`
- **Сертификаты SSL:** `/etc/letsencrypt/live/{SITE}/`
- **Логи Nginx:** `/var/log/nginx/`

## Лицензия

Используется на свой риск.

## Автор

Created for secure Debian/Ubuntu server initialization.
