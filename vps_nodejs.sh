#!/usr/bin/env bash
#
# vps_nodejs.sh — provisioning Node.js + необходимые пакеты
# для проекта family (семейный сайт family.rybnikov.su).
#
# Предназначен для ЧИСТОЙ VPS (Ubuntu/Debian). Устанавливает:
#   - базовые пакеты: curl, ca-certificates, gnupg, git, build-essential,
#     python3 (нужны для компиляции нативных модулей node-gyp)
#   - Node.js 24 LTS (официальный репозиторий NodeSource, система, а не nvm)
#   - pm2 глобально (менеджер процессов; деплой-скрипт запускает через
#     него бэкенд: `pm2 start dist/app.cjs --name family-backend`)
#
# Запуск:
#   sudo bash vps_nodejs.sh
#
# Переопределение версии Node:
#   NODE_MAJOR=22 sudo bash vps_nodejs.sh
#
# После установки:
#   git clone <repo-url> family && cd family
#   npm run deploy          (зальёт фронтенд/бэкенд и перезапустит pm2)
#
set -euo pipefail

# ---------- Проверка прав root ----------
if [ "$(id -u)" -ne 0 ]; then
  echo "Нужны права root. Запустите: sudo bash $0"
  exit 1
fi

# ---------- Определение ОС ----------
if [ -f /etc/os-release ]; then
  . /etc/os-release
else
  echo "Ошибка: не найден /etc/os-release — не удалось определить ОС."
  exit 1
fi

case "${ID:-}" in
  ubuntu | debian)
    echo ">> Обнаружена ОС: ${PRETTY_NAME:-$ID}"
    ;;
  *)
    echo "Скрипт поддерживает только Ubuntu/Debian, обнаружено: ${PRETTY_NAME:-$ID}"
    exit 1
    ;;
esac

# ---------- Базовые пакеты ----------
export DEBIAN_FRONTEND=noninteractive

echo ">> Обновление списка пакетов..."
apt-get update -y

echo ">> Установка базовых пакетов..."
apt-get install -y --no-install-recommends \
  curl \
  ca-certificates \
  gnupg \
  git \
  build-essential \
  python3 \
  make \
  g++ \
  unzip

# ---------- Node.js (NodeSource) ----------
NODE_MAJOR="${NODE_MAJOR:-24}" # проект требует >=20.19.0; по умолчанию 24 LTS

echo ">> Добавление репозитория NodeSource (Node.js ${NODE_MAJOR})..."
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" |
  gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list

echo ">> Установка Node.js ${NODE_MAJOR}..."
apt-get update -y
apt-get install -y nodejs

echo ">> Версии: node $(node --version), npm $(npm --version)"

# ---------- pm2 ----------
echo ">> Установка pm2 (глобально)..."
npm install -g pm2

echo ">> pm2: $(pm2 --version)"

# ---------- Итог ----------
echo ""
echo "======================================================================"
echo " Готово! Установлено:"
echo "   node  $(node --version)"
echo "   npm   $(npm --version)"
echo "   pm2   $(pm2 --version)"
echo ""
echo " Дальнейшие шаги:"
echo "   1) Скопировать SSH-ключ разработчика, чтобы деплой ходил без пароля:"
echo "        ssh-copy-id user@<ip>"
echo "   2) Клонировать проект: git clone <repo-url> family && cd family"
echo "   3) Настроить nginx (шаблон: family.rybnikov.su.example) и применить"
echo "      конфиг (nginx -t && systemctl reload nginx)"
echo "   4) Задеплоить: npm run deploy"
echo "======================================================================"
