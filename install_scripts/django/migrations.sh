#!/bin/bash
# =============================================================================
# django/migrations.sh — Миграции и команды Django
# =============================================================================

source "$(dirname "$0")/../config/variables.sh"
source "$(dirname "$0")/../utils/logging.sh"

run_migrations() {
    log_step "Применение миграций Django"
    
    cd "$INSTALL_DIR"
    
    # Загружаем учетные данные базы данных
    load_db_credentials
    
    export DJANGO_SETTINGS_MODULE="config.settings"
    export DATABASE_URL="postgres://${DB_USER}:${DB_PASSWORD}@127.0.0.1:5432/${DB_NAME}"
    
    log_info "Применение миграций..."
    ./venv/bin/python manage.py migrate --noinput
    
    check_status "Миграции применены" "Ошибка при применении миграций"
}

create_superuser() {
    log_step "Создание суперпользователя"
    
    cd "$INSTALL_DIR"
    
    load_db_credentials
    
    export DJANGO_SETTINGS_MODULE="config.settings"
    
    local superuser_password=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    
    # Создаём суперпользователя если не существует
    if ! ./venv/bin/python manage.py shell -c "from django.contrib.auth.models import User; User.objects.filter(username='admin').exists()" 2>/dev/null | grep -q "True"; then
        ./venv/bin/python manage.py shell << EOF
from django.contrib.auth.models import User
if not User.objects.filter(username='admin').exists():
    User.objects.create_superuser('admin', 'admin@schoolcrm.local', '$superuser_password')
    print('Суперпользователь создан')
else:
    print('Суперпользователь уже существует')
EOF
        echo ""
        log_info "Логин: admin"
        log_info "Пароль: $superuser_password"
        log_warning "Сохраните пароль суперпользователя!"
    else
        log_info "Суперпользователь уже существует"
    fi
}

collect_static() {
    log_step "Сбор статических файлов"
    
    cd "$INSTALL_DIR"
    
    load_db_credentials
    export DJANGO_SETTINGS_MODULE="config.settings"
    
    log_info "Сбор статических файлов..."
    ./venv/bin/python manage.py collectstatic --noinput
    
    check_status "Статические файлы собраны" "Ошибка при сборе статических файлов"
}
