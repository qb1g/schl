#!/bin/bash
# =============================================================================
# database/postgresql.sh — Настройка PostgreSQL
# =============================================================================

source "$(dirname "$0")/../config/variables.sh"
source "$(dirname "$0")/../utils/logging.sh"

setup_postgresql() {
    log_step "Настройка PostgreSQL"
    
    # Загружаем учетные данные если они были сохранены ранее
    load_db_credentials
    
    # Сохраняем учетные данные для последующих скриптов
    save_db_credentials
    
    log_info "Запуск PostgreSQL..."
    systemctl start postgresql
    systemctl enable postgresql
    
    log_info "Создание базы данных и пользователя..."
    
    # Проверяем, что переменные не пустые
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
        log_error "Переменные DB_NAME или DB_USER пусты"
        exit 1
    fi
    
    sudo -u postgres psql << EOF
-- Создаём пользователя если не существует
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$DB_USER') THEN
      CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASSWORD';
   END IF;
END
\$\$;

-- Создаём базу данных если не существует
SELECT 'CREATE DATABASE $DB_NAME OWNER $DB_USER'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\gexec

-- Предоставляем права
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
EOF
    
    check_status "База данных создана" "Ошибка при создании базы данных"
    
    # Настраиваем доступ к базе данных
    log_info "Настройка доступа PostgreSQL..."
    
    # Добавляем настройку подключения в pg_hba.conf
    local pg_hba="/etc/postgresql/*/main/pg_hba.conf"
    if [ -f $(ls $pg_hba 2>/dev/null | head -1) ]; then
        local hba_file=$(ls $pg_hba 2>/dev/null | head -1)
        if ! grep -q "host $DB_NAME $DB_USER 127.0.0.1/32 md5" "$hba_file"; then
            echo "host $DB_NAME $DB_USER 127.0.0.1/32 md5" >> "$hba_file"
        fi
        if ! grep -q "host $DB_NAME $DB_USER ::1/128 md5" "$hba_file"; then
            echo "host $DB_NAME $DB_USER ::1/128 md5" >> "$hba_file"
        fi
        
        # Перезагружаем PostgreSQL для применения настроек
        systemctl reload postgresql
    fi
    
    log_success "PostgreSQL настроен"
}
