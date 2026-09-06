#!/bin/bash
# =============================================================================
# python/environment.sh — Настройка Python окружения
# =============================================================================

source "$(dirname "$0")/../config/variables.sh"
source "$(dirname "$0")/../utils/logging.sh"

setup_environment() {
    log_step "Настройка Python окружения"
    
    cd "$INSTALL_DIR"
    
    # Исправляем права доступа перед началом работы
    log_info "Проверка прав доступа..."
    chown -R root:root "$INSTALL_DIR"
    
    # Удаляем старое виртуальное окружение если существует
    if [ -d "venv" ]; then
        log_info "Удаление старого виртуального окружения..."
        rm -rf venv
    fi
    
    log_info "Создание виртуального окружения..."
    python3 -m venv venv
    
    log_info "Обновление pip..."
    # Используем --no-cache-dir для избежания проблем с правами кэша
    ./venv/bin/pip install --no-cache-dir --upgrade pip
    
    log_info "Установка зависимостей Python..."
    # Устанавливаем конкретную версию Pillow для поддержки Python 3.14
    ./venv/bin/pip install --no-cache-dir "Pillow>=${PILLOW_VERSION}"
    
    # Устанавливаем Django и остальные зависимости
    if [ -f requirements.txt ]; then
        # Заменяем версию Pillow в requirements.txt если там указана старая
        sed -i 's/Pillow==[0-9.]*/Pillow>=11.0.0/' requirements.txt 2>/dev/null || true
        ./venv/bin/pip install --no-cache-dir -r requirements.txt
    else
        log_warning "Файл requirements.txt не найден"
        ./venv/bin/pip install --no-cache-dir "Django>=${DJANGO_VERSION}"
    fi
    
    # Возвращаем права на директорию приложения
    if id "$APP_USER" &>/dev/null; then
        chown -R "$APP_USER":"$APP_USER" "$INSTALL_DIR"
    fi
    
    check_status "Python окружение настроено" "Ошибка при настройке Python окружения"
}
