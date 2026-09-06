#!/bin/bash
# =============================================================================
# permissions/ownership.sh — Управление правами доступа
# =============================================================================

source "$(dirname "$0")/../config/variables.sh"
source "$(dirname "$0")/../utils/logging.sh"

fix_permissions() {
    log_step "Настройка прав доступа"
    
    cd "$INSTALL_DIR"
    
    # Создаём пользователя приложения если не существует
    if ! id "$APP_USER" &>/dev/null; then
        log_info "Создание пользователя $APP_USER..."
        useradd -r -s /bin/false -d "$INSTALL_DIR" "$APP_USER" 2>/dev/null || true
    fi
    
    # Устанавливаем владельца на директорию приложения
    log_info "Установка владельца директории..."
    chown -R "$APP_USER":"$APP_USER" "$INSTALL_DIR"
    
    # Устанавливаем правильные права на файлы
    log_info "Настройка прав на файлы..."
    
    # Директории должны быть доступны для записи приложению
    find "$INSTALL_DIR" -type d -exec chmod 755 {} \;
    
    # Файлы только для чтения
    find "$INSTALL_DIR" -type f -exec chmod 644 {} \;
    
    # Скрипты должны быть исполняемыми
    find "$INSTALL_DIR" -name "*.sh" -exec chmod 755 {} \;
    find "$INSTALL_DIR" -name "manage.py" -exec chmod 755 {} \;
    
    # Особые права для медиа и статики
    if [ -d "$INSTALL_DIR/media" ]; then
        chmod -R 775 "$INSTALL_DIR/media"
    fi
    
    if [ -d "$INSTALL_DIR/static" ]; then
        chmod -R 755 "$INSTALL_DIR/static"
    fi
    
    # Права для логов
    if [ -d "$INSTALL_DIR/logs" ]; then
        chmod -R 775 "$INSTALL_DIR/logs"
    fi
    
    check_status "Права доступа настроены" "Ошибка при настройке прав доступа"
}

verify_permissions() {
    log_info "Проверка прав доступа..."
    
    local errors=0
    
    # Проверяем владельца
    if [ "$(stat -c '%U' "$INSTALL_DIR")" != "$APP_USER" ]; then
        log_error "Неверный владелец: $(stat -c '%U' "$INSTALL_DIR") (ожидалось: $APP_USER)"
        ((errors++))
    fi
    
    # Проверяем права на директорию
    local perms=$(stat -c '%a' "$INSTALL_DIR")
    if [ "$perms" != "755" ]; then
        log_warning "Неверные права на директорию: $perms (ожидалось: 755)"
    fi
    
    if [ $errors -eq 0 ]; then
        log_success "Права доступа проверены"
        return 0
    else
        log_error "Обнаружено ошибок: $errors"
        return 1
    fi
}
