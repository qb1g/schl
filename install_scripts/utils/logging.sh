#!/bin/bash
# =============================================================================
# utils/logging.sh — Функции логирования и вывода
# =============================================================================

source "$(dirname "$0")/../config/variables.sh"

log_info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}      $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC}    $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $1"; }
log_step()    { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }

# Логирование с временной меткой
log_timestamp() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Вывод прогресс бара
show_progress() {
    local current=$1
    local total=$2
    local percent=$((current * 100 / total))
    local filled=$((percent / 5))
    local empty=$((20 - filled))
    
    printf "\r["
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "] %3d%%" "$percent"
}

# Проверка успешности последней команды
check_status() {
    if [ $? -eq 0 ]; then
        log_success "$1"
        return 0
    else
        log_error "$2"
        return 1
    fi
}
