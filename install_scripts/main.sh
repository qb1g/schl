#!/bin/bash
# =============================================================================
# main.sh — Главный скрипт установки School CRM
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Импортируем все модули
source "$SCRIPT_DIR/config/variables.sh"
source "$SCRIPT_DIR/utils/logging.sh"
source "$SCRIPT_DIR/system/dependencies.sh"
source "$SCRIPT_DIR/database/postgresql.sh"
source "$SCRIPT_DIR/database/redis.sh"
source "$SCRIPT_DIR/python/environment.sh"
source "$SCRIPT_DIR/django/migrations.sh"
source "$SCRIPT_DIR/permissions/ownership.sh"

# =============================================================================
# Проверки окружения
# =============================================================================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Скрипт должен быть запущен с правами root"
        log_info "Используйте: sudo $0 $INSTALL_DIR"
        exit 1
    fi
}

check_os() {
    log_step "Проверка операционной системы"
    
    if [ ! -f /etc/os-release ]; then
        log_error "Не удалось определить ОС"
        exit 1
    fi
    
    . /etc/os-release
    log_info "ОС: $PRETTY_NAME"
    
    case "$ID" in
        ubuntu)
            if [ "${VERSION_ID%%.*}" -lt 20 ]; then
                log_error "Требуется Ubuntu 20.04 или новее"
                exit 1
            fi
            ;;
        debian)
            if [ "${VERSION_ID%%.*}" -lt 11 ]; then
                log_error "Требуется Debian 11 или новее"
                exit 1
            fi
            ;;
        *)
            log_warning "Неподдерживаемая ОС: $NAME. Продолжаем на свой риск..."
            ;;
    esac
    
    log_success "ОС проверена"
}

check_resources() {
    log_step "Проверка системных ресурсов"
    
    local available_ram=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$available_ram" -lt 2 ]; then
        log_warning "Мало RAM: ${available_ram}GB (рекомендуется 4GB)"
    else
        log_success "RAM: ${available_ram}GB"
    fi
    
    local parent_dir=$(dirname "$INSTALL_DIR")
    local free_space=$(df -BG "$parent_dir" | awk 'NR==2{print $4}' | tr -d 'G')
    if [ "$free_space" -lt 10 ]; then
        log_warning "Мало места: ${free_space}GB (требуется минимум 10GB)"
    else
        log_success "Диск: ${free_space}GB свободно"
    fi
}

# =============================================================================
# Создание структуры проекта
# =============================================================================

create_structure() {
    log_step "Создание структуры проекта"
    
    # Основные директории
    local dirs=(
        "$INSTALL_DIR"
        "$INSTALL_DIR/apps"
        "$INSTALL_DIR/config"
        "$INSTALL_DIR/templates"
        "$INSTALL_DIR/static"
        "$INSTALL_DIR/media"
        "$INSTALL_DIR/logs"
    )
    
    for dir in "${dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            ((DIRS_CREATED++))
        fi
    done
    
    log_success "Структура создана ($DIRS_CREATED директорий)"
}

# =============================================================================
# Настройка веб-сервера и процессов
# =============================================================================

setup_nginx() {
    log_step "Настройка Nginx"
    
    cat > /etc/nginx/sites-available/$APP_NAME << EOF
server {
    listen 80;
    server_name _;
    
    location /static/ {
        alias $INSTALL_DIR/static/;
    }
    
    location /media/ {
        alias $INSTALL_DIR/media/;
    }
    
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    
    ln -sf /etc/nginx/sites-available/$APP_NAME /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    nginx -t && systemctl restart nginx
    
    check_status "Nginx настроен" "Ошибка при настройке Nginx"
}

setup_supervisor() {
    log_step "Настройка Supervisor"
    
    cat > /etc/supervisor/conf.d/$APP_NAME.conf << EOF
[program:$APP_NAME]
command=$INSTALL_DIR/venv/bin/gunicorn --workers 3 --bind 127.0.0.1:8000 config.wsgi:application
directory=$INSTALL_DIR
user=$APP_USER
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=$INSTALL_DIR/logs/gunicorn.log
stopwaitsecs=60

[program:$APP_NAME-celery]
command=$INSTALL_DIR/venv/bin/celery -A config worker --loglevel=info
directory=$INSTALL_DIR
user=$APP_USER
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=$INSTALL_DIR/logs/celery.log
stopwaitsecs=60
EOF
    
    supervisorctl reread
    supervisorctl update
    
    check_status "Supervisor настроен" "Ошибка при настройке Supervisor"
}

start_services() {
    log_step "Запуск сервисов"
    
    systemctl restart postgresql
    systemctl restart redis-server
    systemctl restart nginx
    supervisorctl restart all
    
    sleep 3
    
    # Проверяем статус сервисов
    local services=("postgresql" "redis-server" "nginx")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log_success "$service запущен"
        else
            log_error "$service не запущен"
        fi
    done
}

# =============================================================================
# Главная функция
# =============================================================================

main() {
    log_step "Установка School CRM"
    log_info "Директория установки: $INSTALL_DIR"
    log_info "Версия скрипта: 2.0.0 (модульная)"
    
    # Предварительные проверки
    check_root
    check_os
    check_resources
    
    # Создание структуры
    create_structure
    
    # Установка зависимостей
    install_system_dependencies
    
    # Настройка баз данных
    setup_postgresql
    setup_redis
    
    # Настройка Python окружения
    setup_environment
    
    # Настройка прав доступа
    fix_permissions
    
    # Миграции Django
    run_migrations
    collect_static
    create_superuser
    
    # Настройка веб-сервера
    setup_nginx
    setup_supervisor
    
    # Запуск сервисов
    start_services
    
    # Финальная проверка
    verify_permissions
    
    log_step "Установка завершена"
    log_success "School CRM успешно установлена!"
    echo ""
    log_info "URL: http://$(hostname -I | awk '{print $1}')"
    log_info "Логин: admin"
    log_info "Пароль администратора сохранён в логе установки"
    echo ""
    log_info "Лог установки: $LOG_FILE"
}

# Запуск главной функции
main "$@"
