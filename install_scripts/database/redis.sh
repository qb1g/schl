#!/bin/bash
# =============================================================================
# database/redis.sh — Настройка Redis
# =============================================================================

source "$(dirname "$0")/../config/variables.sh"
source "$(dirname "$0")/../utils/logging.sh"

setup_redis() {
    log_step "Настройка Redis"
    
    # Загружаем учетные данные
    load_db_credentials
    
    log_info "Запуск Redis..."
    systemctl start redis-server
    systemctl enable redis-server
    
    log_info "Настройка безопасности Redis..."
    
    # Устанавливаем пароль для Redis
    if ! grep -q "^requirepass" /etc/redis/redis.conf; then
        echo "requirepass $REDIS_PASSWORD" >> /etc/redis/redis.conf
    else
        sed -i "s/^requirepass.*/requirepass $REDIS_PASSWORD/" /etc/redis/redis.conf
    fi
    
    # Перезапускаем Redis для применения настроек
    systemctl restart redis-server
    
    check_status "Redis настроен" "Ошибка при настройке Redis"
}
