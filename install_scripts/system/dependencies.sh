#!/bin/bash
# =============================================================================
# system/dependencies.sh — Установка системных зависимостей
# =============================================================================

source "$(dirname "$0")/../config/variables.sh"
source "$(dirname "$0")/../utils/logging.sh"

install_system_dependencies() {
    log_step "Установка системных зависимостей"
    
    log_info "Обновление системы..."
    apt-get update -qq
    
    log_info "Установка системных зависимостей..."
    
    # Используем системную версию Python вместо конкретной версии
    local python_pkg="python3"
    local python_venv_pkg="python3-venv"
    local python_dev_pkg="python3-dev"
    
    # Пакеты для сборки Pillow и других зависимостей
    apt-get install -y \
        $python_pkg \
        $python_venv_pkg \
        $python_dev_pkg \
        build-essential \
        libpq-dev \
        libjpeg-dev \
        libzstd-dev \
        libopenjp2-7 \
        libtiff5-dev \
        libfreetype6-dev \
        libfribidi-dev \
        libharfbuzz-dev \
        zlib1g-dev \
        libpng-dev \
        libwebp-dev \
        postgresql \
        postgresql-contrib \
        redis-server \
        nginx \
        supervisor \
        git \
        curl \
        wget \
        openssl \
        libssl-dev \
        pkg-config \
        libffi-dev \
        software-properties-common \
        gnupg \
        lsb-release \
        ca-certificates
    
    check_status "Системные зависимости установлены" "Ошибка при установке системных зависимостей"
}

check_dependencies() {
    log_step "Проверка установленных зависимостей"
    
    local deps=("python3" "pip3" "postgresql" "redis-server" "nginx" "supervisor")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Отсутствуют зависимости: ${missing[*]}"
        log_info "Запустите установку зависимостей: $0 --install-deps"
        return 1
    fi
    
    log_success "Все зависимости установлены"
    return 0
}
