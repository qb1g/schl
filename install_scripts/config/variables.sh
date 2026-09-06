#!/bin/bash
# =============================================================================
# config/variables.sh — Глобальные переменные и настройки
# =============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Пути и имена
INSTALL_DIR="${1:-/opt/schoolcrm}"
APP_NAME="schoolcrm"
APP_USER="schoolcrm"
LOG_FILE="/tmp/schoolcrm_install_$(date +%Y%m%d_%H%M%S).log"

# Счётчики статистики
FILES_CREATED=0
DIRS_CREATED=0

# Опции установки
INSTALL_TEST_DATA=false
INSTALL_JITSI=false
INSTALL_MATTERMOST=false
INSTALL_CERTBOT=false

# Переменные базы данных (экспортируются для использования в других скриптах)
export DB_NAME="schoolcrm"
export DB_USER="schoolcrm"
export DB_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
export REDIS_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

# Версии зависимостей (обновлённые для поддержки Python 3.14)
PYTHON_VERSION="3"
PILLOW_VERSION="11.0.0"
DJANGO_VERSION="5.1"

# Сохранение чувствительных данных во временный файл
save_db_credentials() {
    cat > /tmp/.db_password << EOF
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
EOF
    chmod 600 /tmp/.db_password
}

# Загрузка чувствительных данных из временного файла
load_db_credentials() {
    if [ -f /tmp/.db_password ]; then
        source /tmp/.db_password
        export DB_NAME DB_USER DB_PASSWORD REDIS_PASSWORD
    fi
}
