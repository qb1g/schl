#!/bin/bash
# =============================================================================
# install.sh — Единый скрипт развёртывания School CRM
# =============================================================================
# Версия: 1.0.0
# Дата: 2025
#
# Использование:
#   chmod +x install.sh
#   sudo ./install.sh [ДИРЕКТОРИЯ_УСТАНОВКИ]
#
# Пример:
#   sudo ./install.sh /opt/schoolcrm
#
# Что делает скрипт:
#   1. Проверяет системные требования (ОС, память, диск)
#   2. Создаёт полную структуру проекта
#   3. Записывает ВСЕ файлы проекта (встроенное содержимое)
#   4. Устанавливает системные зависимости
#   5. Настраивает PostgreSQL, Redis
#   6. Настраивает Nginx и Supervisor
#   7. Применяет миграции, создаёт суперпользователя
#   8. Запускает все сервисы
#
# Поддерживаемые ОС:
#   - Ubuntu 20.04 LTS / 22.04 LTS / 24.04 LTS
#   - Debian 11 / 12
#
# Требования:
#   - root права
#   - минимум 2 GB RAM
#   - минимум 10 GB свободного места
# =============================================================================

set -e
set -o pipefail

# =============================================================================
# Цвета и логирование
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}      $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC}    $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $1"; }
log_step()    { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }

# =============================================================================
# Глобальные переменные
# =============================================================================
INSTALL_DIR="${1:-/opt/schoolcrm}"
APP_NAME="schoolcrm"
APP_USER="schoolcrm"
APP_GROUP="schoolcrm"
LOG_FILE="/tmp/schoolcrm_install_$(date +%Y%m%d_%H%M%S).log"

# Переменные базы данных
DB_NAME="schoolcrm"
DB_USER="schoolcrm"

# Счётчики для статистики
FILES_CREATED=0
DIRS_CREATED=0

# Опции установки (по умолчанию false)
INSTALL_TEST_DATA=false
INSTALL_JITSI=false
INSTALL_MATTERMOST=false
INSTALL_CERTBOT=false

# =============================================================================
# Парсинг аргументов командной строки
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --test-data)
                INSTALL_TEST_DATA=true
                shift
                ;;
            --jitsi)
                INSTALL_JITSI=true
                shift
                ;;
            --mattermost)
                INSTALL_MATTERMOST=true
                shift
                ;;
            --certbot)
                INSTALL_CERTBOT=true
                shift
                ;;
            --all)
                INSTALL_TEST_DATA=true
                INSTALL_JITSI=true
                INSTALL_MATTERMOST=true
                INSTALL_CERTBOT=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                # Если аргумент не распознан, считаем его директорией установки
                if [[ ! "$1" =~ ^-- ]]; then
                    INSTALL_DIR="$1"
                fi
                shift
                ;;
        esac
    done
}

show_help() {
    echo "Использование: sudo ./install.sh [ОПЦИИ] [ДИРЕКТОРИЯ_УСТАНОВКИ]"
    echo ""
    echo "Опции:"
    echo "  --test-data       Установить тестовые данные (пользователи, классы, расписание)"
    echo "  --jitsi           Установить собственный Jitsi Meet сервер для видеоконференций"
    echo "  --mattermost      Установить Mattermost сервер для внутренней коммуникации"
    echo "  --certbot         Установить SSL сертификат (Let's Encrypt или самоподписанный)"
    echo "  --all             Применить все опции установки (--test-data --jitsi --mattermost --certbot)"
    echo "  -h, --help        Показать эту справку"
    echo ""
    echo "Примеры:"
    echo "  sudo ./install.sh /opt/schoolcrm"
    echo "  sudo ./install.sh --test-data /opt/schoolcrm"
    echo "  sudo ./install.sh --jitsi --test-data /opt/schoolcrm"
    echo "  sudo ./install.sh --mattermost /opt/schoolcrm"
    echo "  sudo ./install.sh --certbot /opt/schoolcrm"
    echo "  sudo ./install.sh --all /opt/schoolcrm"
    echo ""
    echo "Роли в Mattermost:"
    echo "  - teacher   - учитель"
    echo "  - parent    - родитель"
    echo "  - student   - ученик"
    echo "  - admin     - администрация (директор, зам. директора)"
    echo ""
}

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

    # Проверка оперативной памяти
    local available_ram=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$available_ram" -lt 2 ]; then
        log_warning "Мало RAM: ${available_ram}GB (рекомендуется 4GB)"
    else
        log_success "RAM: ${available_ram}GB"
    fi

    # Проверка свободного места
    local parent_dir=$(dirname "$INSTALL_DIR")
    mkdir -p "$parent_dir"
    local available_space=$(df -BG "$parent_dir" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$available_space" -lt 10 ]; then
        log_error "Недостаточно места: ${available_space}GB (требуется 10GB)"
        exit 1
    fi
    log_success "Свободное место: ${available_space}GB"

    # Проверка количества ядер
    local cpu_cores=$(nproc)
    log_success "CPU ядер: $cpu_cores"
}

# =============================================================================
# Функции создания файлов и директорий
# =============================================================================

# Создать директорию и увеличить счётчик
mk_dir() {
    mkdir -p "$1"
    DIRS_CREATED=$((DIRS_CREATED + 1))
}

# Записать файл из heredoc
# Использование:
#   write_file "путь/к/файлу" << 'FILE_EOF'
#   содержимое
#   FILE_EOF
write_file() {
    local path="$1"
    # Если путь не абсолютный, добавляем INSTALL_DIR
    if [[ "$path" != /* ]]; then
        path="$INSTALL_DIR/$path"
    fi
    local dir=$(dirname "$path")
    mkdir -p "$dir"
    cat > "$path"
    FILES_CREATED=$((FILES_CREATED + 1))
}

# =============================================================================
# ШАГ 1: Создание структуры директорий
# =============================================================================

create_structure() {
    log_step "Шаг 1/9: Создание структуры директорий"

    # Корневые директории
    mk_dir "$INSTALL_DIR"
    mk_dir "$INSTALL_DIR/config/settings"
    mk_dir "$INSTALL_DIR/middleware"
    mk_dir "$INSTALL_DIR/tests/e2e"
    mk_dir "$INSTALL_DIR/scripts"
    mk_dir "$INSTALL_DIR/docs"
    mk_dir "$INSTALL_DIR/fixtures"
    mk_dir "$INSTALL_DIR/logs"

    # Статика
    mk_dir "$INSTALL_DIR/static/css"
    mk_dir "$INSTALL_DIR/static/js"
    mk_dir "$INSTALL_DIR/static/img"

    # Шаблоны
    mk_dir "$INSTALL_DIR/templates/users"
    mk_dir "$INSTALL_DIR/templates/management"
    mk_dir "$INSTALL_DIR/templates/references"
    mk_dir "$INSTALL_DIR/templates/schedule"
    mk_dir "$INSTALL_DIR/templates/grades"
    mk_dir "$INSTALL_DIR/templates/analytics"
    mk_dir "$INSTALL_DIR/templates/integrations"
    mk_dir "$INSTALL_DIR/templates/core"
    mk_dir "$INSTALL_DIR/templates/errors"

    # Приложения и их поддиректории
    local apps=(
        "core" "tenants" "users" "stubs" "management"
        "references" "schedule" "grades" "lessons"
        "groups" "exams" "calendar_app" "news" "nutrition"
        "chats" "notifications" "video" "analytics" "reports"
        "api_external" "webhooks" "integrations"
    )

    for app in "${apps[@]}"; do
        mk_dir "$INSTALL_DIR/apps/$app/migrations"
        mk_dir "$INSTALL_DIR/apps/$app/tests"
    done

    # Специфичные поддиректории для отдельных приложений
    mk_dir "$INSTALL_DIR/apps/core/management/commands"
    mk_dir "$INSTALL_DIR/apps/users/services"
    mk_dir "$INSTALL_DIR/apps/schedule/services"
    mk_dir "$INSTALL_DIR/apps/schedule/templatetags"
    mk_dir "$INSTALL_DIR/apps/analytics/services"
    mk_dir "$INSTALL_DIR/apps/integrations/connectors"

    # Файлы __init__.py для всех пакетов
    touch "$INSTALL_DIR/apps/__init__.py"
    for app in "${apps[@]}"; do
        touch "$INSTALL_DIR/apps/$app/__init__.py"
        touch "$INSTALL_DIR/apps/$app/migrations/__init__.py"
        touch "$INSTALL_DIR/apps/$app/tests/__init__.py"
    done
    touch "$INSTALL_DIR/middleware/__init__.py"
    touch "$INSTALL_DIR/tests/__init__.py"
    touch "$INSTALL_DIR/tests/e2e/__init__.py"
    touch "$INSTALL_DIR/apps/core/management/__init__.py"
    touch "$INSTALL_DIR/apps/core/management/commands/__init__.py"
    touch "$INSTALL_DIR/apps/users/services/__init__.py"
    touch "$INSTALL_DIR/apps/schedule/services/__init__.py"
    touch "$INSTALL_DIR/apps/schedule/templatetags/__init__.py"
    touch "$INSTALL_DIR/apps/analytics/services/__init__.py"

    log_success "Создано директорий: $DIRS_CREATED"
}

# =============================================================================
# ШАГ 2: Запись файлов конфигурации (корневые)
# =============================================================================

write_root_files() {
    log_step "Шаг 2/9: Запись корневых файлов"

    # -------------------------------------------------------------------------
    # manage.py
    # -------------------------------------------------------------------------
    write_file "manage.py" << 'FILE_EOF'
#!/usr/bin/env python
"""Django's command-line utility for administrative tasks."""
import os
import sys


def main():
    """Run administrative tasks."""
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings.development')
    try:
        from django.core.management import execute_from_command_line
    except ImportError as exc:
        raise ImportError(
            "Couldn't import Django. Are you sure it's installed and "
            "available on your PYTHONPATH environment variable?"
        ) from exc
    execute_from_command_line(sys.argv)


if __name__ == '__main__':
    main()
FILE_EOF
    chmod +x "$INSTALL_DIR/manage.py"

    # -------------------------------------------------------------------------
    # requirements.txt
    # -------------------------------------------------------------------------
    write_file "requirements.txt" << 'FILE_EOF'
# Django и базовые зависимости
Django==5.0.1
psycopg[binary]>=3.2.0
djangorestframework==3.14.0
drf-spectacular==0.27.0

# Celery и Redis
celery==5.3.6
redis==5.0.1

# Аутентификация
djangorestframework-simplejwt==5.3.1

# CORS
django-cors-headers==4.3.1

# WebSocket
channels==4.0.0
channels-redis==4.1.0
daphne==4.0.0

# WSGI сервер
gunicorn==21.2.0

# Утилиты
Pillow>=10.4.0
python-dotenv==1.0.0
openpyxl==3.1.2
WeasyPrint>=60.2
requests==2.31.0

# Безопасность
cryptography==41.0.7

# Тесты
pytest==7.4.4
pytest-django==4.7.0
pytest-cov==4.1.0
factory-boy==3.3.0
FILE_EOF

    # -------------------------------------------------------------------------
    # pytest.ini
    # -------------------------------------------------------------------------
    write_file "pytest.ini" << 'FILE_EOF'
[pytest]
DJANGO_SETTINGS_MODULE = config.settings.development
python_files = tests.py test_*.py *_tests.py
python_classes = Test* *Test *TestCase
python_functions = test_*

markers =
    unit: unit tests (fast)
    integration: integration tests (medium speed)
    e2e: end-to-end tests (slow)
    slow: slow tests
    tenant_isolation: tests for tenant isolation

addopts = 
    -v
    --tb=short
    --strict-markers
    --cov=apps
    --cov-report=term-missing
    --cov-fail-under=70

testpaths = 
    apps
    tests
FILE_EOF

    # -------------------------------------------------------------------------
    # .env.example
    # -------------------------------------------------------------------------
    write_file ".env.example" << 'FILE_EOF'
# Конфигурация School CRM
DEBUG=True
SECRET_KEY=change-me-in-production
ALLOWED_HOSTS=localhost,127.0.0.1

# База данных
DB_NAME=schoolcrm
DB_USER=schoolcrm
DB_PASSWORD=schoolcrm
DB_HOST=localhost
DB_PORT=5432
DB_SSL_MODE=prefer

# Redis
REDIS_URL=redis://localhost:6379/0

# Тенанты
TENANT_BASE_DOMAIN=localhost

# Email
EMAIL_BACKEND=django.core.mail.backends.console.EmailBackend
DEFAULT_FROM_EMAIL=noreply@localhost

# Jitsi
JITSI_DOMAIN=meet.jit.si
FILE_EOF

    # -------------------------------------------------------------------------
    # .gitignore
    # -------------------------------------------------------------------------
    write_file ".gitignore" << 'FILE_EOF'
# Python
__pycache__/
*.py[cod]
*$py.class
*.so
.Python
build/
dist/
*.egg-info/

# Виртуальное окружение
venv/
env/
ENV/

# Django
*.log
local_settings.py
db.sqlite3
/media/
/staticfiles/
/static_collected/

# Environment
.env
.env.local

# IDE
.vscode/
.idea/
*.swp

# Тесты
.coverage
htmlcov/
.pytest_cache/

# Бэкапы
*.bak
*.backup
FILE_EOF

    log_success "Корневые файлы записаны"
}

# =============================================================================
# ШАГ 3: Запись конфигурации Django
# =============================================================================

write_config_files() {
    log_step "Шаг 3/9: Запись конфигурации Django"

    # -------------------------------------------------------------------------
    # config/__init__.py
    # -------------------------------------------------------------------------
    write_file "config/__init__.py" << 'FILE_EOF'
# Импорт Celery приложения при старте Django
from .celery import app as celery_app

__all__ = ('celery_app',)
FILE_EOF

    # -------------------------------------------------------------------------
    # config/settings/__init__.py
    # -------------------------------------------------------------------------
    write_file "config/settings/__init__.py" << 'FILE_EOF'
# Пакет настроек
FILE_EOF

    # -------------------------------------------------------------------------
    # config/celery.py
    # -------------------------------------------------------------------------
    write_file "config/celery.py" << 'FILE_EOF'
"""
Конфигурация Celery для School CRM
"""
import os
from celery import Celery
from celery.schedules import crontab

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings.development')

app = Celery('schoolcrm')
app.config_from_object('django.conf:settings', namespace='CELERY')
app.autodiscover_tasks()

# Периодические задачи
app.conf.beat_schedule = {
    'cleanup-old-logs': {
        'task': 'apps.core.tasks.cleanup_old_logs',
        'schedule': crontab(hour=3, minute=0),
    },
}

app.conf.timezone = 'Europe/Moscow'
app.conf.task_track_started = True
app.conf.task_acks_late = True
app.conf.worker_concurrency = 4
app.conf.task_time_limit = 600
app.conf.task_soft_time_limit = 540
app.conf.accept_content = ['json']
app.conf.task_serializer = 'json'
app.conf.result_serializer = 'json'
FILE_EOF

    # -------------------------------------------------------------------------
    # config/wsgi.py
    # -------------------------------------------------------------------------
    write_file "config/wsgi.py" << 'FILE_EOF'
"""
WSGI конфигурация для School CRM
"""
import os
import sys
from pathlib import Path
from django.core.wsgi import get_wsgi_application

BASE_DIR = Path(__file__).resolve().parent.parent
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings.development')

application = get_wsgi_application()
FILE_EOF

    # -------------------------------------------------------------------------
    # config/asgi.py
    # -------------------------------------------------------------------------
    write_file "config/asgi.py" << 'FILE_EOF'
"""
ASGI конфигурация для School CRM (WebSocket)
"""
import os
import sys
import django
from pathlib import Path
from django.core.asgi import get_asgi_application

BASE_DIR = Path(__file__).resolve().parent.parent
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings.development')
django.setup()

from channels.routing import ProtocolTypeRouter, URLRouter
from channels.auth import AuthMiddlewareStack
from channels.security.websocket import AllowedHostsOriginValidator

# Импорт всех WebSocket маршрутов
websocket_urlpatterns = []

try:
    from apps.chats.routing import websocket_urlpatterns as chats_ws
    websocket_urlpatterns += chats_ws
except ImportError:
    pass

try:
    from apps.notifications.routing import websocket_urlpatterns as notifications_ws
    websocket_urlpatterns += notifications_ws
except ImportError:
    pass

application = ProtocolTypeRouter({
    "http": get_asgi_application(),
    "websocket": AllowedHostsOriginValidator(
        AuthMiddlewareStack(
            URLRouter(websocket_urlpatterns)
        )
    ),
})
FILE_EOF

    # -------------------------------------------------------------------------
    # config/urls.py
    # -------------------------------------------------------------------------
    write_file "config/urls.py" << 'FILE_EOF'
"""
Главный URL-конфигуратор для School CRM
"""
from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from django.views.generic import TemplateView
from drf_spectacular.views import SpectacularAPIView, SpectacularSwaggerView
from apps.core.views import placeholder_view, handler404, handler500, handler403

urlpatterns = [
    # Админ-панель
    path('admin/', admin.site.urls),

    # API документация
    path('api/schema/', SpectacularAPIView.as_view(), name='schema'),
    path('api-docs/', SpectacularSwaggerView.as_view(url_name='schema'), name='swagger-ui'),

    # Основные разделы (заглушки, реализуются в приложениях)
    path('', TemplateView.as_view(template_name='core/placeholder.html'), name='home'),
    path('dashboard/', placeholder_view, {'section_name': 'dashboard'}, name='dashboard'),
    path('learning/', placeholder_view, {'section_name': 'learning'}, name='learning'),
    path('tools/', placeholder_view, {'section_name': 'tools'}, name='tools'),

    # Подключение приложений
    path('users/', include('apps.users.urls')),
    path('tenants/', include('apps.tenants.urls')),
    path('management/', include('apps.management.urls')),
    path('references/', include('apps.references.urls')),
    path('schedule/', include('apps.schedule.urls')),
    path('grades/', include('apps.grades.urls')),
    path('lessons/', include('apps.lessons.urls')),
    path('groups/', include('apps.groups.urls')),
    path('exams/', include('apps.exams.urls')),
    path('calendar/', include('apps.calendar_app.urls')),
    path('news/', include('apps.news.urls')),
    path('nutrition/', include('apps.nutrition.urls')),
    path('chats/', include('apps.chats.urls')),
    path('notifications/', include('apps.notifications.urls')),
    path('video/', include('apps.video.urls')),
    path('analytics/', include('apps.analytics.urls')),
    path('integrations/', include('apps.integrations.urls')),

    # Внешний API (версионирование)
    path('api/v1/', include('apps.api_external.urls')),
]

# Статика в режиме разработки
if settings.DEBUG:
    urlpatterns += static(settings.STATIC_URL, document_root=settings.STATIC_ROOT)
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)

# Обработчики ошибок
handler404 = 'apps.core.views.handler404'
handler500 = 'apps.core.views.handler500'
handler403 = 'apps.core.views.handler403'
FILE_EOF

    log_success "Файлы конфигурации Django записаны"
}

# =============================================================================
# Точка входа (продолжение на следующих страницах)
# =============================================================================

# Функция вывода статистики
print_stats() {
    log_step "Статистика установки"
    log_success "Создано директорий: $DIRS_CREATED"
    log_success "Создано файлов: $FILES_CREATED"
    log_info "Директория установки: $INSTALL_DIR"
    log_info "Лог установки: $LOG_FILE"
}

# =============================================================================
# СТРАНИЦА 2 / СТРАНИЦА 5
# =============================================================================
# Содержимое этой страницы:
#   Шаг 4: Настройки проекта (base, development, production)
#   Шаг 5: Middleware (tenant, tenant_isolation)
# =============================================================================

# =============================================================================
# ШАГ 4: Запись настроек проекта
# =============================================================================

write_settings_files() {
    log_step "Шаг 4/9: Запись настроек проекта"

    # -------------------------------------------------------------------------
    # config/settings/base.py
    # -------------------------------------------------------------------------
    write_file "config/settings/base.py" << 'FILE_EOF'
"""
Базовые настройки для School CRM
"""
import os
from pathlib import Path
from dotenv import load_dotenv

# Загрузка переменных окружения из .env файла
load_dotenv()

BASE_DIR = Path(__file__).resolve().parent.parent.parent

# Безопасность
SECRET_KEY = os.environ.get('SECRET_KEY', 'django-insecure-change-me')
DEBUG = os.environ.get('DEBUG', 'False') == 'True'
ALLOWED_HOSTS = os.environ.get('ALLOWED_HOSTS', 'localhost').split(',')

# Приложения
INSTALLED_APPS = [
    # Стандартные
    'django.contrib.admin',
    'django.contrib.auth',
    'django.contrib.contenttypes',
    'django.contrib.sessions',
    'django.contrib.messages',
    'django.contrib.staticfiles',

    # Сторонние
    'rest_framework',
    'drf_spectacular',
    'corsheaders',
    'channels',

    # Наши приложения
    'apps.core',
    'apps.tenants',
    'apps.users',
    'apps.stubs',
    'apps.management',
    'apps.references',
    'apps.schedule',
    'apps.grades',
    'apps.lessons',
    'apps.groups',
    'apps.exams',
    'apps.calendar_app',
    'apps.news',
    'apps.nutrition',
    'apps.chats',
    'apps.notifications',
    'apps.video',
    'apps.analytics',
    'apps.reports',
    'apps.api_external',
    'apps.webhooks',
    'apps.integrations',
]

# Middleware (порядок важен!)
MIDDLEWARE = [
    'django.middleware.security.SecurityMiddleware',
    'corsheaders.middleware.CorsMiddleware',
    'django.contrib.sessions.middleware.SessionMiddleware',
    'django.middleware.common.CommonMiddleware',
    'django.middleware.csrf.CsrfViewMiddleware',
    'django.contrib.auth.middleware.AuthenticationMiddleware',
    # Идентификация тенанта
    'middleware.tenant.TenantMiddleware',
    # Проверка изоляции
    'middleware.tenant_isolation.TenantIsolationMiddleware',
    'django.contrib.messages.middleware.MessageMiddleware',
    'django.middleware.clickjacking.XFrameOptionsMiddleware',
]

ROOT_URLCONF = 'config.urls'

TEMPLATES = [
    {
        'BACKEND': 'django.template.backends.django.DjangoTemplates',
        'DIRS': [BASE_DIR / 'templates'],
        'APP_DIRS': True,
        'OPTIONS': {
            'context_processors': [
                'django.template.context_processors.debug',
                'django.template.context_processors.request',
                'django.contrib.auth.context_processors.auth',
                'django.contrib.messages.context_processors.messages',
            ],
        },
    },
]

WSGI_APPLICATION = 'config.wsgi.application'
ASGI_APPLICATION = 'config.asgi.application'

# База данных
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.environ.get('DB_NAME', 'schoolcrm'),
        'USER': os.environ.get('DB_USER', 'schoolcrm'),
        'PASSWORD': os.environ.get('DB_PASSWORD', 'schoolcrm'),
        'HOST': os.environ.get('DB_HOST', 'localhost'),
        'PORT': os.environ.get('DB_PORT', '5432'),
        'CONN_MAX_AGE': 600,
        'OPTIONS': {
            'connect_timeout': 10,
            'sslmode': os.environ.get('DB_SSL_MODE', 'prefer'),
        },
    }
}

# Пользовательская модель
AUTH_USER_MODEL = 'users.User'

AUTH_PASSWORD_VALIDATORS = [
    {'NAME': 'django.contrib.auth.password_validation.UserAttributeSimilarityValidator'},
    {'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator',
     'OPTIONS': {'min_length': 8}},
    {'NAME': 'django.contrib.auth.password_validation.CommonPasswordValidator'},
    {'NAME': 'django.contrib.auth.password_validation.NumericPasswordValidator'},
]

# Хеширование паролей
PASSWORD_HASHERS = [
    'django.contrib.auth.hashers.Argon2PasswordHasher',
    'django.contrib.auth.hashers.PBKDF2PasswordHasher',
    'django.contrib.auth.hashers.PBKDF2SHA1PasswordHasher',
    'django.contrib.auth.hashers.BCryptSHA256PasswordHasher',
]

# Интернационализация
LANGUAGE_CODE = 'ru-ru'
TIME_ZONE = 'Europe/Moscow'
USE_I18N = True
USE_TZ = True

# Статика и медиа
STATIC_URL = '/static/'
STATIC_ROOT = BASE_DIR / 'staticfiles'
STATICFILES_DIRS = [BASE_DIR / 'static']
STATICFILES_STORAGE = 'django.contrib.staticfiles.storage.ManifestStaticFilesStorage'

MEDIA_URL = '/media/'
MEDIA_ROOT = os.environ.get('MEDIA_ROOT', '/var/media')

DEFAULT_AUTO_FIELD = 'django.db.models.BigAutoField'

# Celery
CELERY_BROKER_URL = os.environ.get('REDIS_URL', 'redis://localhost:6379/0')
CELERY_RESULT_BACKEND = os.environ.get('REDIS_URL', 'redis://localhost:6379/0')
CELERY_ACCEPT_CONTENT = ['json']
CELERY_TASK_SERIALIZER = 'json'
CELERY_RESULT_SERIALIZER = 'json'
CELERY_TIMEZONE = 'Europe/Moscow'
CELERY_TASK_TRACK_STARTED = True
CELERY_TASK_TIME_LIMIT = 600

# Channels (WebSocket)
CHANNEL_LAYERS = {
    'default': {
        'BACKEND': 'channels_redis.core.RedisChannelLayer',
        'CONFIG': {
            'hosts': [os.environ.get('REDIS_URL', 'redis://localhost:6379/2')],
            'capacity': 1500,
            'expiry': 60,
        },
    },
}

# Кэширование
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.redis.RedisCache',
        'LOCATION': os.environ.get('REDIS_URL', 'redis://localhost:6379/1'),
        'KEY_PREFIX': 'schoolcrm',
        'TIMEOUT': 300,
    }
}

# REST Framework
REST_FRAMEWORK = {
    'DEFAULT_AUTHENTICATION_CLASSES': [
        'rest_framework.authentication.SessionAuthentication',
        'rest_framework_simplejwt.authentication.JWTAuthentication',
    ],
    'DEFAULT_PERMISSION_CLASSES': [
        'rest_framework.permissions.IsAuthenticated',
    ],
    'DEFAULT_SCHEMA_CLASS': 'drf_spectacular.openapi.AutoSchema',
    'DEFAULT_PAGINATION_CLASS': 'rest_framework.pagination.PageNumberPagination',
    'PAGE_SIZE': 50,
}

# OpenAPI
SPECTACULAR_SETTINGS = {
    'TITLE': 'School CRM API',
    'DESCRIPTION': 'Мульти-тенантная система управления школой',
    'VERSION': '1.0.0',
    'SERVE_INCLUDE_SCHEMA': False,
}

# CORS
CORS_ALLOWED_ORIGINS = os.environ.get(
    'CORS_ALLOWED_ORIGINS', 'http://localhost:8000'
).split(',')
CORS_ALLOW_CREDENTIALS = True

# Сессии
SESSION_COOKIE_AGE = 86400
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_SAMESITE = 'Lax'

# Тенанты
TENANT_BASE_DOMAIN = os.environ.get('TENANT_BASE_DOMAIN', 'localhost')
RESERVED_SUBDOMAINS = [
    'www', 'mail', 'ftp', 'admin', 'api',
    'static', 'media', 'test', 'dev', 'staging',
]

# Jitsi
JITSI_DOMAIN = os.environ.get('JITSI_DOMAIN', 'meet.jit.si')

# Email
EMAIL_BACKEND = os.environ.get(
    'EMAIL_BACKEND',
    'django.core.mail.backends.console.EmailBackend'
)
EMAIL_HOST = os.environ.get('EMAIL_HOST', 'smtp.gmail.com')
EMAIL_PORT = int(os.environ.get('EMAIL_PORT', '587'))
EMAIL_HOST_USER = os.environ.get('EMAIL_HOST_USER', '')
EMAIL_HOST_PASSWORD = os.environ.get('EMAIL_HOST_PASSWORD', '')
DEFAULT_FROM_EMAIL = os.environ.get('DEFAULT_FROM_EMAIL', 'noreply@localhost')

# Логирование
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'verbose': {
            'format': '{levelname} {asctime} {module} {message}',
            'style': '{',
        },
    },
    'handlers': {
        'console': {
            'class': 'logging.StreamHandler',
            'formatter': 'verbose',
        },
        'file': {
            'class': 'logging.FileHandler',
            'filename': BASE_DIR / 'logs' / 'django.log',
            'formatter': 'verbose',
        },
    },
    'loggers': {
        'django': {
            'handlers': ['console', 'file'],
            'level': 'INFO',
            'propagate': False,
        },
        'apps': {
            'handlers': ['console', 'file'],
            'level': 'INFO',
            'propagate': False,
        },
        'middleware': {
            'handlers': ['console', 'file'],
            'level': 'INFO',
            'propagate': False,
        },
    },
}
FILE_EOF

    # -------------------------------------------------------------------------
    # config/settings/development.py
    # -------------------------------------------------------------------------
    write_file "config/settings/development.py" << 'FILE_EOF'
"""
Настройки для разработки
"""
from .base import *

DEBUG = True
ALLOWED_HOSTS = ['*']

# Безопасность (отключаем для разработки)
SECURE_SSL_REDIRECT = False
SESSION_COOKIE_SECURE = False
CSRF_COOKIE_SECURE = False
SECURE_HSTS_SECONDS = 0

# Логирование
LOGGING['loggers']['django']['level'] = 'DEBUG'

# Email в консоль
EMAIL_BACKEND = 'django.core.mail.backends.console.EmailBackend'

# Упрощённое хранилище статики
STATICFILES_STORAGE = 'django.contrib.staticfiles.storage.StaticFilesStorage'

# Celery в синхронном режиме (для тестов)
CELERY_TASK_ALWAYS_EAGER = True
CELERY_TASK_EAGER_PROPAGATES = True
FILE_EOF

    # -------------------------------------------------------------------------
    # config/settings/production.py
    # -------------------------------------------------------------------------
    write_file "config/settings/production.py" << 'FILE_EOF'
"""
Настройки для продакшена
"""
from .base import *

DEBUG = False

# Принудительный HTTPS
SECURE_SSL_REDIRECT = True
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True

# HSTS
SECURE_HSTS_SECONDS = 31536000
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_HSTS_PRELOAD = True

# Дополнительные заголовки безопасности
X_FRAME_OPTIONS = 'DENY'
SECURE_CONTENT_TYPE_NOSNIFF = True
SECURE_BROWSER_XSS_FILTER = True
SECURE_REFERRER_POLICY = 'strict-origin-when-cross-origin'

# Email через SMTP
EMAIL_BACKEND = 'django.core.mail.backends.smtp.EmailBackend'

# Манифест для статики
STATICFILES_STORAGE = 'django.contrib.staticfiles.storage.ManifestStaticFilesStorage'

# Логирование только предупреждений и ошибок
LOGGING['loggers']['django']['level'] = 'WARNING'
LOGGING['loggers']['apps']['level'] = 'INFO'
FILE_EOF

    log_success "Настройки проекта записаны"
}

# =============================================================================
# ШАГ 5: Запись middleware
# =============================================================================

write_middleware_files() {
    log_step "Шаг 5/9: Запись middleware"

    # -------------------------------------------------------------------------
    # middleware/tenant.py
    # -------------------------------------------------------------------------
    write_file "middleware/tenant.py" << 'FILE_EOF'
"""
Middleware для идентификации тенанта

Определяет текущий тенант по:
1. Поддомену (school1.rksh41.ru)
2. Заголовку X-Tenant-ID
3. Пути /t/school1/...
4. Сессии (для имперсонации админа)
"""
from django.http import Http404
from django.utils.deprecation import MiddlewareMixin
import logging

logger = logging.getLogger(__name__)


class TenantMiddleware(MiddlewareMixin):
    """Middleware для идентификации тенанта."""

    def process_request(self, request):
        # Пропускаем служебные пути
        skip_paths = ('/health/', '/static/', '/admin/', '/api-docs/')
        if request.path.startswith(skip_paths):
            return None

        # PLATFORM_ADMIN может работать через имперсонацию
        if hasattr(request, 'user') and request.user.is_authenticated:
            if getattr(request.user, 'is_platform_admin', False):
                impersonated = request.session.get('impersonated_tenant')
                if impersonated:
                    from apps.tenants.models import Tenant
                    try:
                        request.tenant = Tenant.objects.get(id=impersonated)
                        return None
                    except Tenant.DoesNotExist:
                        logger.warning(f"Impersonated tenant {impersonated} not found")
                else:
                    request.tenant = None
                    request.is_platform_admin_context = True
                    return None

        # Определяем тенант
        tenant = self._resolve_tenant(request)

        if tenant is None:
            logger.warning(f"Tenant not found for: {request.path}")
            raise Http404("Tenant not found")

        request.tenant = tenant
        return None

    def _resolve_tenant(self, request):
        """Определить тенант по приоритету источников."""
        from apps.tenants.models import Tenant

        # 1. Поддомен
        host = request.get_host().split(':')[0]
        if '.' in host:
            subdomain = host.split('.')[0]
            if subdomain not in ('www', 'mail', 'api'):
                tenant = Tenant.objects.filter(
                    subdomain=subdomain,
                    status__in=['ACTIVE', 'TRIAL']
                ).first()
                if tenant:
                    return tenant

        # 2. Заголовок X-Tenant-ID
        tenant_id = request.META.get('HTTP_X_TENANT_ID')
        if tenant_id:
            tenant = Tenant.objects.filter(
                id=tenant_id,
                status__in=['ACTIVE', 'TRIAL']
            ).first()
            if tenant:
                return tenant

        # 3. Путь /t/{subdomain}/...
        path = request.path
        if path.startswith('/t/'):
            parts = path.split('/')
            if len(parts) >= 3:
                subdomain = parts[2]
                tenant = Tenant.objects.filter(
                    subdomain=subdomain,
                    status__in=['ACTIVE', 'TRIAL']
                ).first()
                if tenant:
                    return tenant

        return None
FILE_EOF

    # -------------------------------------------------------------------------
    # middleware/tenant_isolation.py
    # -------------------------------------------------------------------------
    write_file "middleware/tenant_isolation.py" << 'FILE_EOF'
"""
Middleware для проверки изоляции тенантов

Проверяет, что пользователь имеет доступ к текущему тенанту.
"""
from django.http import HttpResponseForbidden
import logging

logger = logging.getLogger(__name__)


class TenantIsolationMiddleware:
    """Middleware для проверки изоляции."""

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        # Пропускаем неаутентифицированных
        if not hasattr(request, 'user') or not request.user.is_authenticated:
            return self.get_response(request)

        # Супер-админ имеет доступ ко всем тенантам
        if getattr(request.user, 'role', None) == 'PLATFORM_ADMIN':
            return self.get_response(request)

        # Пропускаем, если тенант не установлен
        if not hasattr(request, 'tenant') or request.tenant is None:
            return self.get_response(request)

        # Проверяем принадлежность пользователя к тенанту
        if hasattr(request.user, 'tenant_id') and request.user.tenant_id:
            if request.user.tenant_id != request.tenant.id:
                logger.warning(
                    f"Cross-tenant access attempt: user {request.user.id} "
                    f"(tenant {request.user.tenant_id}) -> tenant {request.tenant.id}"
                )
                return HttpResponseForbidden(
                    "Access denied: user does not belong to this tenant"
                )

        return self.get_response(request)
FILE_EOF

    log_success "Middleware записаны"
}

# =============================================================================
# Обновление главной функции для страницы 2
# =============================================================================

# Добавляем вызов новых функций в main()
# (на последней странице будет полная версия)

main_page2() {
    write_settings_files
    write_middleware_files
}

# =============================================================================
# СТРАНИЦА 2 ЗАВЕРШЕНА
# =============================================================================
#!/bin/bash
# =============================================================================
# СТРАНИЦА 3 / СТРАНИЦА 11
# =============================================================================
# Содержимое этой страницы:
#   Шаг 6: Приложение apps/core (заглушки)
#   Шаг 7: Приложение apps/tenants (мульти-тенантность)
#   Шаг 8: Приложение apps/users (пользователи, RBAC)
# =============================================================================

# =============================================================================
# ШАГ 6: Приложение apps/core
# =============================================================================

write_core_app() {
    log_step "Шаг 6/9: Приложение apps/core"

    # -------------------------------------------------------------------------
    # apps/core/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/core/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class CoreConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.core'
    verbose_name = 'Ядро'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/core/views.py
    # -------------------------------------------------------------------------
    write_file "apps/core/views.py" << 'FILE_EOF'
"""
Базовые представления: заглушки и обработчики ошибок
"""
from django.shortcuts import render
from django.contrib.auth.decorators import login_required


@login_required
def placeholder_view(request, section_name):
    """Заглушка для разделов в разработке."""
    section_names = {
        'dashboard': 'Главная',
        'learning': 'Обучение',
        'tools': 'Инструменты',
        'academe': 'Академ',
        'analytics': 'Аналитика',
        'references': 'Справочники',
        'calendar': 'Календарь',
        'news': 'Новости',
        'management': 'Управление',
        'messenger': 'Мессенджер',
        'integrations': 'Интеграции',
    }

    display_name = section_names.get(section_name, section_name.title())

    return render(request, 'core/placeholder.html', {
        'section_name': display_name,
        'section_code': section_name,
    })


def handler404(request, exception):
    """Страница не найдена."""
    return render(request, 'errors/404.html', status=404)


def handler500(request):
    """Внутренняя ошибка сервера."""
    return render(request, 'errors/500.html', status=500)


def handler403(request, exception):
    """Доступ запрещён."""
    return render(request, 'errors/403.html', status=403)
FILE_EOF

    log_success "apps/core записано"
}

# =============================================================================
# ШАГ 7: Приложение apps/tenants
# =============================================================================

write_tenants_app() {
    log_step "Шаг 7/9: Приложение apps/tenants"

    # -------------------------------------------------------------------------
    # apps/tenants/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/tenants/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class TenantsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.tenants'
    verbose_name = 'Тенанты (Школы)'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/tenants/managers.py
    # -------------------------------------------------------------------------
    write_file "apps/tenants/managers.py" << 'FILE_EOF'
"""
Tenant-aware менеджеры и базовые классы моделей
"""
from django.db import models


class TenantQuerySet(models.QuerySet):
    """QuerySet с фильтрацией по тенанту."""

    def for_tenant(self, tenant):
        return self.filter(tenant=tenant)

    def exclude_tenant(self, tenant):
        return self.exclude(tenant=tenant)


class TenantManager(models.Manager):
    """Manager с автоматической фильтрацией по тенанту."""

    def get_queryset(self):
        return TenantQuerySet(self.model, using=self._db)

    def for_tenant(self, tenant):
        return self.get_queryset().filter(tenant=tenant)

    def create_for_tenant(self, tenant, **kwargs):
        kwargs['tenant'] = tenant
        return self.create(**kwargs)


class TenantAwareModel(models.Model):
    """
    Абстрактная модель для всех бизнес-сущностей.
    Все модели, наследующие её, получают поле tenant.
    """

    tenant = models.ForeignKey(
        'tenants.Tenant',
        on_delete=models.CASCADE,
        related_name='%(class)s_set',
        verbose_name='Тенант'
    )

    objects = TenantManager()

    class Meta:
        abstract = True
        indexes = [
            models.Index(fields=['tenant']),
        ]

    def save(self, *args, **kwargs):
        if not self.tenant_id:
            raise ValueError("tenant_id is required for tenant-aware models")
        super().save(*args, **kwargs)
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/tenants/models.py
    # -------------------------------------------------------------------------
    write_file "apps/tenants/models.py" << 'FILE_EOF'
"""
Модели тенантов (школ)
"""
import uuid
from django.db import models
from django.core.validators import MinValueValidator
from django.utils.translation import gettext_lazy as _


class Tenant(models.Model):
    """Тенант (школа)."""

    class Status(models.TextChoices):
        ACTIVE = 'ACTIVE', _('Активный')
        SUSPENDED = 'SUSPENDED', _('Приостановлен')
        TRIAL = 'TRIAL', _('Пробный период')
        ONBOARDING = 'ONBOARDING', _('Онбординг')

    class PlanType(models.TextChoices):
        FREE = 'FREE', _('Бесплатный')
        BASIC = 'BASIC', _('Базовый')
        PREMIUM = 'PREMIUM', _('Премиум')
        ENTERPRISE = 'ENTERPRISE', _('Корпоративный')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название школы'), max_length=255)
    subdomain = models.CharField(
        _('Поддомен'),
        max_length=63,
        unique=True,
        help_text=_('Например: school1 для school1.rksh41.ru')
    )
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.ONBOARDING
    )
    plan_type = models.CharField(
        _('Тип тарифа'),
        max_length=20,
        choices=PlanType.choices,
        default=PlanType.FREE
    )
    max_students = models.PositiveIntegerField(
        _('Максимум учеников'),
        default=100,
        validators=[MinValueValidator(1)]
    )
    settings = models.JSONField(_('Настройки'), default=dict, blank=True)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Тенант')
        verbose_name_plural = _('Тенанты')
        ordering = ['name']
        indexes = [
            models.Index(fields=['subdomain']),
            models.Index(fields=['status']),
        ]

    def __str__(self):
        return f"{self.name} ({self.subdomain})"

    def get_domain(self, base_domain=None):
        if base_domain is None:
            from django.conf import settings
            base_domain = settings.TENANT_BASE_DOMAIN
        return f"{self.subdomain}.{base_domain}"

    @property
    def is_active(self):
        return self.status == self.Status.ACTIVE


class TenantFeature(models.Model):
    """Функции тарифа тенанта."""

    FEATURE_CHOICES = [
        ('SCHEDULE_MANAGEMENT', _('Управление расписанием')),
        ('GRADE_BOOK', _('Электронный журнал')),
        ('ATTENDANCE_TRACKING', _('Учёт посещаемости')),
        ('MESSENGER', _('Мессенджер')),
        ('VIDEO_CONFERENCING', _('Видеоконференции')),
        ('ANALYTICS', _('Аналитика')),
        ('REPORTS', _('Отчёты')),
        ('INTEGRATIONS', _('Интеграции')),
        ('API_ACCESS', _('Доступ к API')),
    ]

    tenant = models.ForeignKey(
        Tenant,
        on_delete=models.CASCADE,
        related_name='features',
        verbose_name=_('Тенант')
    )
    feature_code = models.CharField(
        _('Код функции'),
        max_length=50,
        choices=FEATURE_CHOICES
    )
    is_enabled = models.BooleanField(_('Включена'), default=True)

    class Meta:
        unique_together = ['tenant', 'feature_code']
        verbose_name = _('Функция тенанта')
        verbose_name_plural = _('Функции тенантов')

    def __str__(self):
        return f"{self.tenant.name} - {self.get_feature_code_display()}"
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/tenants/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/tenants/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.tenants.models import Tenant, TenantFeature


class TenantFeatureInline(admin.TabularInline):
    model = TenantFeature
    extra = 0


@admin.register(Tenant)
class TenantAdmin(admin.ModelAdmin):
    list_display = ['name', 'subdomain', 'status', 'plan_type', 'max_students', 'created_at']
    list_filter = ['status', 'plan_type', 'created_at']
    search_fields = ['name', 'subdomain']
    readonly_fields = ['id', 'created_at', 'updated_at']
    inlines = [TenantFeatureInline]


@admin.register(TenantFeature)
class TenantFeatureAdmin(admin.ModelAdmin):
    list_display = ['tenant', 'feature_code', 'is_enabled']
    list_filter = ['is_enabled', 'feature_code']
    search_fields = ['tenant__name', 'feature_code']
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/tenants/views.py
    # -------------------------------------------------------------------------
    write_file "apps/tenants/views.py" << 'FILE_EOF'
"""
Представления для тенантов
"""
from django.shortcuts import render
from django.contrib.auth.decorators import login_required
from django.http import JsonResponse
from apps.tenants.models import Tenant


@login_required
def tenant_info_view(request):
    """Информация о текущем тенанте."""
    tenant = getattr(request, 'tenant', None)

    if tenant is None:
        return JsonResponse({'error': 'No tenant context'}, status=400)

    return JsonResponse({
        'id': str(tenant.id),
        'name': tenant.name,
        'subdomain': tenant.subdomain,
        'status': tenant.status,
        'plan_type': tenant.plan_type,
        'domain': tenant.get_domain(),
    })


def health_check_view(request):
    """Health-check эндпоинт."""
    from django.db import connection

    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            db_status = "ok"
    except Exception as e:
        db_status = f"error: {str(e)}"

    return JsonResponse({
        'status': 'healthy' if db_status == 'ok' else 'unhealthy',
        'database': db_status,
    })
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/tenants/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/tenants/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.tenants import views

app_name = 'tenants'

urlpatterns = [
    path('info/', views.tenant_info_view, name='info'),
    path('health/', views.health_check_view, name='health'),
]
FILE_EOF

    log_success "apps/tenants записано"
}

# =============================================================================
# ШАГ 8: Приложение apps/users
# =============================================================================

write_users_app() {
    log_step "Шаг 8/9: Приложение apps/users"

    # -------------------------------------------------------------------------
    # apps/users/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/users/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class UsersConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.users'
    verbose_name = 'Пользователи'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/users/models.py
    # -------------------------------------------------------------------------
    write_file "apps/users/models.py" << 'FILE_EOF'
"""
Пользовательская модель с ролями
"""
import uuid
from django.contrib.auth.models import AbstractUser, BaseUserManager
from django.db import models
from django.utils.translation import gettext_lazy as _


class UserManager(BaseUserManager):
    """Кастомный менеджер для пользователей."""

    def create_user(self, email, password=None, **extra_fields):
        if not email:
            raise ValueError(_('Email обязателен'))
        email = self.normalize_email(email)
        user = self.model(email=email, **extra_fields)
        user.set_password(password)
        user.save(using=self._db)
        return user

    def create_superuser(self, email, password=None, **extra_fields):
        extra_fields.setdefault('is_staff', True)
        extra_fields.setdefault('is_superuser', True)
        extra_fields.setdefault('role', User.Role.PLATFORM_ADMIN)
        return self.create_user(email, password, **extra_fields)


class User(AbstractUser):
    """Пользователь системы с ролями."""

    class Role(models.TextChoices):
        PLATFORM_ADMIN = 'PLATFORM_ADMIN', _('Супер-администратор')
        ADMIN = 'ADMIN', _('Администратор школы')
        DIRECTOR = 'DIRECTOR', _('Директор')
        DEPUTY = 'DEPUTY', _('Заместитель директора')
        CLASS_TEACHER = 'CLASS_TEACHER', _('Классный руководитель')
        TEACHER = 'TEACHER', _('Учитель')
        PARENT = 'PARENT', _('Родитель')
        STUDENT = 'STUDENT', _('Ученик')

    # Иерархия ролей
    ROLE_HIERARCHY = {
        Role.PLATFORM_ADMIN: 100,
        Role.ADMIN: 90,
        Role.DIRECTOR: 80,
        Role.DEPUTY: 70,
        Role.CLASS_TEACHER: 60,
        Role.TEACHER: 50,
        Role.PARENT: 40,
        Role.STUDENT: 30,
    }

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    email = models.EmailField(_('Email'), unique=True)
    username = None

    tenant = models.ForeignKey(
        'tenants.Tenant',
        on_delete=models.CASCADE,
        null=True,
        blank=True,
        related_name='users',
        verbose_name=_('Тенант')
    )
    role = models.CharField(
        _('Роль'),
        max_length=20,
        choices=Role.choices,
        default=Role.STUDENT
    )
    phone = models.CharField(_('Телефон'), max_length=20, blank=True)
    avatar = models.ImageField(_('Аватар'), upload_to='avatars/', blank=True, null=True)

    USERNAME_FIELD = 'email'
    REQUIRED_FIELDS = ['first_name', 'last_name']

    objects = UserManager()

    class Meta:
        verbose_name = _('Пользователь')
        verbose_name_plural = _('Пользователи')
        indexes = [
            models.Index(fields=['tenant', 'role']),
            models.Index(fields=['email']),
        ]

    def __str__(self):
        return f"{self.get_display_name()} ({self.get_role_display()})"

    @property
    def is_platform_admin(self):
        return self.role == self.Role.PLATFORM_ADMIN

    @property
    def is_local_admin(self):
        return self.role in [self.Role.ADMIN, self.Role.DIRECTOR, self.Role.DEPUTY]

    @property
    def is_teacher(self):
        return self.role in [self.Role.TEACHER, self.Role.CLASS_TEACHER]

    def get_role_level(self):
        return self.ROLE_HIERARCHY.get(self.role, 0)

    def has_role_or_higher(self, required_role):
        if isinstance(required_role, str):
            try:
                required_role = self.Role(required_role)
            except ValueError:
                return False

        required_level = self.ROLE_HIERARCHY.get(required_role, 0)
        return self.get_role_level() >= required_level

    def get_display_name(self):
        if self.first_name or self.last_name:
            return f"{self.first_name} {self.last_name}".strip()
        return self.email
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/users/permissions.py
    # -------------------------------------------------------------------------
    write_file "apps/users/permissions.py" << 'FILE_EOF'
"""
RBAC: декораторы для проверки прав
"""
from functools import wraps
from django.http import HttpResponseForbidden
from django.shortcuts import redirect
from django.contrib import messages
from django.contrib.auth.mixins import LoginRequiredMixin
from apps.users.models import User


def _resolve_role(role):
    """Конвертировать строку роли в значение перечисления."""
    if isinstance(role, str):
        try:
            return User.Role(role)
        except ValueError:
            return None
    return role


def role_required(*allowed_roles):
    """Декоратор для проверки роли."""
    def decorator(view_func):
        @wraps(view_func)
        def _wrapped_view(request, *args, **kwargs):
            if not request.user.is_authenticated:
                return redirect('users:login')

            resolved = [_resolve_role(r) for r in allowed_roles]
            resolved = [r for r in resolved if r is not None]

            if request.user.role not in resolved:
                messages.error(request, 'Недостаточно прав.')
                return HttpResponseForbidden('Доступ запрещён.')

            return view_func(request, *args, **kwargs)
        return _wrapped_view
    return decorator


def role_or_higher(minimum_role):
    """Декоратор для проверки иерархии ролей."""
    def decorator(view_func):
        @wraps(view_func)
        def _wrapped_view(request, *args, **kwargs):
            if not request.user.is_authenticated:
                return redirect('users:login')

            resolved = _resolve_role(minimum_role)
            if resolved is None or not request.user.has_role_or_higher(resolved):
                messages.error(request, 'Недостаточно прав.')
                return HttpResponseForbidden('Доступ запрещён.')

            return view_func(request, *args, **kwargs)
        return _wrapped_view
    return decorator


def admin_required(view_func):
    """Декоратор для администраторов школы и выше."""
    @wraps(view_func)
    def _wrapped_view(request, *args, **kwargs):
        if not request.user.is_authenticated:
            return redirect('users:login')

        if not (request.user.is_local_admin or request.user.is_platform_admin):
            messages.error(request, 'Доступ только для администраторов.')
            return HttpResponseForbidden('Доступ запрещён.')

        return view_func(request, *args, **kwargs)
    return _wrapped_view


def teacher_required(view_func):
    """Декоратор для учителей и выше."""
    return role_or_higher(User.Role.TEACHER)(view_func)


class AdminRequiredMixin(LoginRequiredMixin):
    """Миксин для администраторов."""
    def dispatch(self, request, *args, **kwargs):
        if request.user.is_authenticated:
            if not (request.user.is_local_admin or request.user.is_platform_admin):
                return HttpResponseForbidden('Доступ запрещён.')
        return super().dispatch(request, *args, **kwargs)
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/users/forms.py
    # -------------------------------------------------------------------------
    write_file "apps/users/forms.py" << 'FILE_EOF'
"""
Формы аутентификации
"""
from django import forms
from django.contrib.auth import authenticate
from apps.users.models import User


class LoginForm(forms.Form):
    """Форма входа."""

    email = forms.EmailField(
        label='Email',
        widget=forms.EmailInput(attrs={
            'class': 'form-input',
            'placeholder': 'Введите ваш email',
            'autofocus': True,
        })
    )
    password = forms.CharField(
        label='Пароль',
        widget=forms.PasswordInput(attrs={
            'class': 'form-input',
            'placeholder': 'Введите пароль',
        })
    )
    remember_me = forms.BooleanField(
        label='Запомнить меня',
        required=False,
        widget=forms.CheckboxInput(attrs={'class': 'form-checkbox'})
    )

    def __init__(self, request=None, *args, **kwargs):
        self.request = request
        self.user_cache = None
        super().__init__(*args, **kwargs)

    def clean(self):
        email = self.cleaned_data.get('email')
        password = self.cleaned_data.get('password')

        if email and password:
            self.user_cache = authenticate(
                self.request,
                username=email,
                password=password
            )

            if self.user_cache is None:
                raise forms.ValidationError('Неверные учётные данные.')
            elif not self.user_cache.is_active:
                raise forms.ValidationError('Аккаунт деактивирован.')

        return self.cleaned_data

    def get_user(self):
        return self.user_cache
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/users/views.py
    # -------------------------------------------------------------------------
    write_file "apps/users/views.py" << 'FILE_EOF'
"""
Представления аутентификации
"""
from django.shortcuts import render, redirect
from django.contrib import messages
from django.contrib.auth import login, logout
from django.contrib.auth.decorators import login_required
from django.views import View
from apps.users.forms import LoginForm


class LoginView(View):
    """Вход в систему."""
    template_name = 'users/login.html'

    def get(self, request):
        if request.user.is_authenticated:
            return redirect('dashboard')
        form = LoginForm()
        return render(request, self.template_name, {'form': form})

    def post(self, request):
        form = LoginForm(request, data=request.POST)

        if form.is_valid():
            user = form.get_user()
            login(request, user)

            remember_me = form.cleaned_data.get('remember_me', False)
            if not remember_me:
                request.session.set_expiry(0)
            else:
                request.session.set_expiry(86400)

            messages.success(request, f'Добро пожаловать, {user.get_display_name()}!')
            return redirect('dashboard')

        return render(request, self.template_name, {'form': form})


class LogoutView(View):
    """Выход из системы."""

    def get(self, request):
        logout(request)
        messages.info(request, 'Вы вышли из системы.')
        return redirect('users:login')

    def post(self, request):
        return self.get(request)


@login_required
def profile_view(request):
    """Профиль пользователя."""
    return render(request, 'users/profile.html', {'user': request.user})
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/users/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/users/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.users import views

app_name = 'users'

urlpatterns = [
    path('login/', views.LoginView.as_view(), name='login'),
    path('logout/', views.LogoutView.as_view(), name='logout'),
    path('profile/', views.profile_view, name='profile'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/users/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/users/admin.py" << 'FILE_EOF'
from django.contrib import admin
from django.contrib.auth.admin import UserAdmin as BaseUserAdmin
from apps.users.models import User


@admin.register(User)
class UserAdmin(BaseUserAdmin):
    list_display = ['email', 'first_name', 'last_name', 'role', 'tenant', 'is_active']
    list_filter = ['role', 'tenant', 'is_active']
    search_fields = ['email', 'first_name', 'last_name']
    ordering = ['-date_joined']

    fieldsets = (
        (None, {'fields': ('email', 'password')}),
        ('Персональная информация', {'fields': ('first_name', 'last_name', 'phone', 'avatar')}),
        ('Тенант и роль', {'fields': ('tenant', 'role')}),
        ('Права', {'fields': ('is_active', 'is_staff', 'is_superuser', 'groups', 'user_permissions')}),
        ('Даты', {'fields': ('last_login', 'date_joined')}),
    )

    add_fieldsets = (
        (None, {
            'classes': ('wide',),
            'fields': ('email', 'password1', 'password2', 'tenant', 'role'),
        }),
    )
FILE_EOF

    log_success "apps/users записано"
}

# =============================================================================
# СТРАНИЦА 3 ЗАВЕРШЕНА
# =============================================================================
#!/bin/bash
# =============================================================================
# СТРАНИЦА 4 / СТРАНИЦА 11
# =============================================================================
# Содержимое этой страницы:
#   Шаг 9: Приложение apps/stubs (Student, ClassGroup, AuditLog)
#   Шаг 10: Приложение apps/management (управление)
#   Шаг 11: Приложение apps/references (справочники)
# =============================================================================

# =============================================================================
# ШАГ 9: Приложение apps/stubs
# =============================================================================

write_stubs_app() {
    log_step "Шаг 9/9: Приложение apps/stubs"

    # -------------------------------------------------------------------------
    # apps/stubs/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/stubs/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class StubsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.stubs'
    verbose_name = 'Временные модели'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/stubs/models.py
    # -------------------------------------------------------------------------
    write_file "apps/stubs/models.py" << 'FILE_EOF'
"""
Временные модели-заглушки

Будут перенесены в полноценные приложения на соответствующих этапах.
"""
import uuid
from django.db import models
from django.conf import settings
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class Student(TenantAwareModel):
    """Ученик."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)

    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='student_profile',
        verbose_name=_('Аккаунт')
    )

    class_group = models.ForeignKey(
        'stubs.ClassGroup',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='students',
        verbose_name=_('Класс')
    )

    first_name = models.CharField(_('Имя'), max_length=100)
    last_name = models.CharField(_('Фамилия'), max_length=100)
    middle_name = models.CharField(_('Отчество'), max_length=100, blank=True)
    date_of_birth = models.DateField(_('Дата рождения'), null=True, blank=True)
    enrollment_number = models.CharField(_('Номер записи'), max_length=50, blank=True)

    parents = models.ManyToManyField(
        settings.AUTH_USER_MODEL,
        blank=True,
        related_name='children_students',
        verbose_name=_('Родители')
    )

    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Ученик')
        verbose_name_plural = _('Ученики')
        ordering = ['last_name', 'first_name']
        indexes = [
            models.Index(fields=['tenant', 'class_group']),
        ]

    def __str__(self):
        return f"{self.last_name} {self.first_name}"

    @property
    def display_name(self):
        return f"{self.last_name} {self.first_name}"

    def get_full_name(self):
        if self.middle_name:
            return f"{self.last_name} {self.first_name} {self.middle_name}"
        return f"{self.last_name} {self.first_name}"


class ClassGroup(TenantAwareModel):
    """Класс учеников (например, 5А)."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название класса'), max_length=100)
    grade = models.PositiveIntegerField(
        _('Класс обучения'),
        help_text=_('Номер класса: 1-11')
    )
    letter = models.CharField(
        _('Буква класса'),
        max_length=5,
        blank=True,
        help_text=_('Например: А, Б, В')
    )
    class_teacher = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='homeroom_classes',
        verbose_name=_('Классный руководитель')
    )
    academic_year = models.ForeignKey(
        'references.AcademicYear',
        on_delete=models.PROTECT,
        related_name='class_groups',
        verbose_name=_('Учебный год')
    )
    student_count = models.PositiveIntegerField(
        _('Количество учеников'),
        default=0
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Класс учеников')
        verbose_name_plural = _('Классы учеников')
        unique_together = ['tenant', 'name', 'academic_year']
        ordering = ['grade', 'letter', 'name']

    def __str__(self):
        return self.name

    @property
    def full_name(self):
        if self.letter:
            return f"{self.grade}{self.letter}"
        return self.name

    def update_student_count(self):
        self.student_count = self.students.count()
        self.save(update_fields=['student_count'])


class AuditLog(TenantAwareModel):
    """Лог аудита."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='audit_logs',
        verbose_name=_('Пользователь')
    )
    action = models.CharField(_('Действие'), max_length=100)
    details = models.JSONField(_('Детали'), default=dict, blank=True)
    created_at = models.DateTimeField(_('Дата'), auto_now_add=True)

    class Meta:
        verbose_name = _('Запись аудита')
        verbose_name_plural = _('Записи аудита')
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.action} by {self.user} at {self.created_at}"
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/stubs/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/stubs/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.stubs.models import Student, ClassGroup, AuditLog


@admin.register(Student)
class StudentAdmin(admin.ModelAdmin):
    list_display = ['last_name', 'first_name', 'class_group', 'tenant', 'created_at']
    list_filter = ['tenant', 'class_group']
    search_fields = ['last_name', 'first_name', 'enrollment_number']


@admin.register(ClassGroup)
class ClassGroupAdmin(admin.ModelAdmin):
    list_display = ['name', 'grade', 'letter', 'academic_year', 'student_count']
    list_filter = ['tenant', 'grade']
    search_fields = ['name']


@admin.register(AuditLog)
class AuditLogAdmin(admin.ModelAdmin):
    list_display = ['action', 'user', 'tenant', 'created_at']
    list_filter = ['action', 'tenant', 'created_at']
    search_fields = ['action', 'user__email']
    readonly_fields = ['id', 'user', 'action', 'details', 'created_at']
FILE_EOF

    log_success "apps/stubs записано"
}

# =============================================================================
# ШАГ 10: Приложение apps/management
# =============================================================================

write_management_app() {
    log_step "Шаг 10/9: Приложение apps/management"

    # -------------------------------------------------------------------------
    # apps/management/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/management/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class ManagementConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.management'
    verbose_name = 'Управление'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/management/views.py
    # -------------------------------------------------------------------------
    write_file "apps/management/views.py" << 'FILE_EOF'
"""
Представления раздела «Управление»
"""
from django.shortcuts import render, redirect, get_object_or_404
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.db.models import Count
from apps.users.permissions import admin_required
from apps.users.models import User
from apps.stubs.models import AuditLog


@login_required
@admin_required
def management_dashboard_view(request):
    """Главная страница раздела «Управление»."""
    tenant = request.tenant

    stats = {
        'total_users': User.objects.filter(tenant=tenant).count(),
        'active_users': User.objects.filter(tenant=tenant, is_active=True).count(),
    }

    recent_actions = AuditLog.objects.filter(
        tenant=tenant
    ).order_by('-created_at')[:10]

    context = {
        'stats': stats,
        'recent_actions': recent_actions,
    }

    return render(request, 'management/dashboard.html', context)


@login_required
@admin_required
def users_list_view(request):
    """Список пользователей школы."""
    users = User.objects.filter(tenant=request.tenant)

    # Фильтры
    role = request.GET.get('role', '')
    search = request.GET.get('search', '')

    if role:
        users = users.filter(role=role)

    if search:
        from django.db.models import Q
        users = users.filter(
            Q(email__icontains=search) |
            Q(first_name__icontains=search) |
            Q(last_name__icontains=search)
        )

    users = users.order_by('last_name', 'first_name')

    context = {
        'users': users,
        'role_filter': role,
        'search_query': search,
        'roles': User.Role.choices,
    }

    return render(request, 'management/users_list.html', context)
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/management/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/management/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.management import views

app_name = 'management'

urlpatterns = [
    path('', views.management_dashboard_view, name='dashboard'),
    path('users/', views.users_list_view, name='users'),
]
FILE_EOF

    log_success "apps/management записано"
}

# =============================================================================
# ШАГ 11: Приложение apps/references
# =============================================================================

write_references_app() {
    log_step "Шаг 11/9: Приложение apps/references"

    # -------------------------------------------------------------------------
    # apps/references/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/references/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class ReferencesConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.references'
    verbose_name = 'Справочники'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/references/models.py
    # -------------------------------------------------------------------------
    write_file "apps/references/models.py" << 'FILE_EOF'
"""
Модели справочников
"""
import uuid
from django.db import models
from django.core.exceptions import ValidationError
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class Subject(TenantAwareModel):
    """Предмет."""

    class Status(models.TextChoices):
        ACTIVE = 'ACTIVE', _('Активный')
        ARCHIVED = 'ARCHIVED', _('Архивный')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название предмета'), max_length=255)
    code = models.CharField(_('Код'), max_length=50, blank=True)
    description = models.TextField(_('Описание'), blank=True)
    color = models.CharField(_('Цвет'), max_length=7, default='#3B82F6')
    hours_per_week = models.PositiveIntegerField(_('Часов в неделю'), default=0)
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.ACTIVE
    )
    sort_order = models.PositiveIntegerField(_('Порядок'), default=0)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Предмет')
        verbose_name_plural = _('Предметы')
        unique_together = ['tenant', 'name']
        ordering = ['sort_order', 'name']

    def __str__(self):
        return self.name


class Classroom(TenantAwareModel):
    """Кабинет."""

    class Type(models.TextChoices):
        REGULAR = 'REGULAR', _('Обычный кабинет')
        LAB = 'LAB', _('Лаборатория')
        GYM = 'GYM', _('Спортзал')
        ASSEMBLY = 'ASSEMBLY', _('Актовый зал')
        LIBRARY = 'LIBRARY', _('Библиотека')
        CAFETERIA = 'CAFETERIA', _('Столовая')
        OTHER = 'OTHER', _('Другое')

    class Status(models.TextChoices):
        AVAILABLE = 'AVAILABLE', _('Доступен')
        MAINTENANCE = 'MAINTENANCE', _('На ремонте')
        UNAVAILABLE = 'UNAVAILABLE', _('Недоступен')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название'), max_length=100)
    number = models.CharField(_('Номер'), max_length=20, blank=True)
    floor = models.PositiveIntegerField(_('Этаж'), null=True, blank=True)
    building = models.CharField(_('Корпус'), max_length=100, blank=True)
    type = models.CharField(
        _('Тип'),
        max_length=20,
        choices=Type.choices,
        default=Type.REGULAR
    )
    capacity = models.PositiveIntegerField(_('Вместимость'), null=True, blank=True)
    equipment = models.TextField(_('Оборудование'), blank=True)
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.AVAILABLE
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Кабинет')
        verbose_name_plural = _('Кабинеты')
        unique_together = ['tenant', 'name']
        ordering = ['name']

    def __str__(self):
        return f"{self.name} ({self.number})" if self.number else self.name


class LessonType(TenantAwareModel):
    """Тип урока."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название'), max_length=100)
    code = models.CharField(_('Код'), max_length=50, blank=True)
    description = models.TextField(_('Описание'), blank=True)
    color = models.CharField(_('Цвет'), max_length=7, default='#3B82F6')
    is_assessment = models.BooleanField(_('Оценочный'), default=False)
    sort_order = models.PositiveIntegerField(_('Порядок'), default=0)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)

    class Meta:
        verbose_name = _('Тип урока')
        verbose_name_plural = _('Типы уроков')
        unique_together = ['tenant', 'name']
        ordering = ['sort_order', 'name']

    def __str__(self):
        return self.name


class AbsenceReason(TenantAwareModel):
    """Причина отсутствия."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название'), max_length=255)
    code = models.CharField(_('Код'), max_length=10)
    is_excused = models.BooleanField(_('Уважительная'), default=False)
    requires_document = models.BooleanField(_('Нужен документ'), default=False)
    description = models.TextField(_('Описание'), blank=True)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)

    class Meta:
        verbose_name = _('Причина отсутствия')
        verbose_name_plural = _('Причины отсутствия')
        unique_together = ['tenant', 'code']
        ordering = ['code']

    def __str__(self):
        return f"{self.code} - {self.name}"


class GradeType(TenantAwareModel):
    """Тип оценки."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название'), max_length=100)
    code = models.CharField(_('Код'), max_length=50, blank=True)
    weight = models.DecimalField(
        _('Вес'),
        max_digits=3,
        decimal_places=2,
        default=1.00
    )
    is_final = models.BooleanField(_('Итоговая'), default=False)
    description = models.TextField(_('Описание'), blank=True)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)

    class Meta:
        verbose_name = _('Тип оценки')
        verbose_name_plural = _('Типы оценок')
        unique_together = ['tenant', 'name']
        ordering = ['name']

    def __str__(self):
        return self.name


class AcademicYear(TenantAwareModel):
    """Учебный год."""

    class Status(models.TextChoices):
        PLANNED = 'PLANNED', _('Запланирован')
        ACTIVE = 'ACTIVE', _('Активный')
        COMPLETED = 'COMPLETED', _('Завершён')
        ARCHIVED = 'ARCHIVED', _('Архивный')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название'), max_length=20)
    start_date = models.DateField(_('Дата начала'))
    end_date = models.DateField(_('Дата окончания'))
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.PLANNED
    )
    is_current = models.BooleanField(_('Текущий'), default=False)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)

    class Meta:
        verbose_name = _('Учебный год')
        verbose_name_plural = _('Учебные годы')
        unique_together = ['tenant', 'name']
        ordering = ['-start_date']

    def __str__(self):
        return self.name

    def clean(self):
        super().clean()
        if self.start_date and self.end_date:
            if self.end_date <= self.start_date:
                raise ValidationError({
                    'end_date': 'Дата окончания должна быть позже даты начала.'
                })

    def save(self, *args, **kwargs):
        self.full_clean()
        if self.is_current:
            AcademicYear.objects.filter(
                tenant=self.tenant, is_current=True
            ).exclude(id=self.id).update(is_current=False)
        super().save(*args, **kwargs)
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/references/views.py
    # -------------------------------------------------------------------------
    write_file "apps/references/views.py" << 'FILE_EOF'
"""
Представления раздела «Справочники»
"""
from django.shortcuts import render, redirect, get_object_or_404
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from apps.users.permissions import admin_required
from apps.references.models import (
    Subject, Classroom, LessonType, AbsenceReason, GradeType, AcademicYear
)


@login_required
@admin_required
def references_dashboard_view(request):
    """Главная страница раздела «Справочники»."""
    tenant = request.tenant

    stats = {
        'subjects': Subject.objects.filter(tenant=tenant, status='ACTIVE').count(),
        'classrooms': Classroom.objects.filter(tenant=tenant, status='AVAILABLE').count(),
        'lesson_types': LessonType.objects.filter(tenant=tenant).count(),
        'absence_reasons': AbsenceReason.objects.filter(tenant=tenant).count(),
        'grade_types': GradeType.objects.filter(tenant=tenant).count(),
        'academic_years': AcademicYear.objects.filter(tenant=tenant).count(),
    }

    return render(request, 'references/dashboard.html', {'stats': stats})


@login_required
@admin_required
def subjects_list_view(request):
    """Список предметов."""
    subjects = Subject.objects.filter(tenant=request.tenant)

    status = request.GET.get('status', 'ACTIVE')
    if status != 'all':
        subjects = subjects.filter(status=status)

    subjects = subjects.order_by('sort_order', 'name')

    return render(request, 'references/subjects_list.html', {
        'subjects': subjects,
        'status_filter': status,
    })
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/references/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/references/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.references import views

app_name = 'references'

urlpatterns = [
    path('', views.references_dashboard_view, name='dashboard'),
    path('subjects/', views.subjects_list_view, name='subjects'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/references/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/references/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.references.models import (
    Subject, Classroom, LessonType, AbsenceReason, GradeType, AcademicYear
)


@admin.register(Subject)
class SubjectAdmin(admin.ModelAdmin):
    list_display = ['name', 'code', 'color', 'status', 'sort_order']
    list_filter = ['status', 'tenant']
    search_fields = ['name', 'code']


@admin.register(Classroom)
class ClassroomAdmin(admin.ModelAdmin):
    list_display = ['name', 'number', 'type', 'capacity', 'status']
    list_filter = ['type', 'status', 'tenant']
    search_fields = ['name', 'number']


@admin.register(LessonType)
class LessonTypeAdmin(admin.ModelAdmin):
    list_display = ['name', 'code', 'is_assessment', 'sort_order']
    list_filter = ['is_assessment', 'tenant']


@admin.register(AbsenceReason)
class AbsenceReasonAdmin(admin.ModelAdmin):
    list_display = ['name', 'code', 'is_excused', 'requires_document']
    list_filter = ['is_excused', 'tenant']


@admin.register(GradeType)
class GradeTypeAdmin(admin.ModelAdmin):
    list_display = ['name', 'code', 'weight', 'is_final']
    list_filter = ['is_final', 'tenant']


@admin.register(AcademicYear)
class AcademicYearAdmin(admin.ModelAdmin):
    list_display = ['name', 'start_date', 'end_date', 'status', 'is_current']
    list_filter = ['status', 'is_current', 'tenant']
FILE_EOF

    log_success "apps/references записано"
}

# =============================================================================
# СТРАНИЦА 4 ЗАВЕРШЕНА
# =============================================================================
#!/bin/bash
# =============================================================================
# СТРАНИЦА 5 / СТРАНИЦА 11
# =============================================================================
# Содержимое этой страницы:
#   Шаг 12: Приложение apps/schedule (расписание)
#   Шаг 13: Приложение apps/grades (журнал, оценки)
#   Шаг 14: Приложение apps/lessons (темплан)
# =============================================================================

# =============================================================================
# ШАГ 12: Приложение apps/schedule
# =============================================================================

write_schedule_app() {
    log_step "Шаг 12/9: Приложение apps/schedule"

    # -------------------------------------------------------------------------
    # apps/schedule/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/schedule/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class ScheduleConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.schedule'
    verbose_name = 'Расписание'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/schedule/models.py
    # -------------------------------------------------------------------------
    write_file "apps/schedule/models.py" << 'FILE_EOF'
"""
Модели расписания
"""
import uuid
from django.db import models
from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator, MaxValueValidator
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class TimeSlot(TenantAwareModel):
    """Временной слот."""

    class Type(models.TextChoices):
        LESSON = 'LESSON', _('Урок')
        BREAK = 'BREAK', _('Перемена')
        LUNCH = 'LUNCH', _('Обед')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название'), max_length=100)
    slot_type = models.CharField(
        _('Тип'),
        max_length=20,
        choices=Type.choices,
        default=Type.LESSON
    )
    start_time = models.TimeField(_('Время начала'))
    end_time = models.TimeField(_('Время окончания'))
    slot_number = models.PositiveIntegerField(
        _('Номер слота'),
        default=1,
        validators=[MinValueValidator(1)]
    )
    is_active = models.BooleanField(_('Активен'), default=True)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)

    class Meta:
        verbose_name = _('Временной слот')
        verbose_name_plural = _('Временные слоты')
        unique_together = ['tenant', 'slot_number', 'slot_type']
        ordering = ['slot_number']

    def __str__(self):
        return f"{self.name} ({self.start_time.strftime('%H:%M')}-{self.end_time.strftime('%H:%M')})"

    def clean(self):
        super().clean()
        if self.start_time and self.end_time:
            if self.end_time <= self.start_time:
                raise ValidationError({
                    'end_time': 'Время окончания должно быть позже времени начала.'
                })

    def save(self, *args, **kwargs):
        self.full_clean()
        super().save(*args, **kwargs)

    @property
    def is_lesson(self):
        return self.slot_type == self.Type.LESSON


class Schedule(TenantAwareModel):
    """Расписание на период."""

    class Status(models.TextChoices):
        DRAFT = 'DRAFT', _('Черновик')
        ACTIVE = 'ACTIVE', _('Активно')
        ARCHIVED = 'ARCHIVED', _('Архив')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название'), max_length=255)
    description = models.TextField(_('Описание'), blank=True)
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.DRAFT
    )
    valid_from = models.DateField(_('Дата начала'))
    valid_to = models.DateField(_('Дата окончания'))
    academic_year = models.ForeignKey(
        'references.AcademicYear',
        on_delete=models.PROTECT,
        related_name='schedules',
        verbose_name=_('Учебный год')
    )
    created_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='created_schedules',
        verbose_name=_('Создано')
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Расписание')
        verbose_name_plural = _('Расписания')
        ordering = ['-valid_from']

    def __str__(self):
        return self.name

    @property
    def item_count(self):
        return self.items.count()

    @property
    def is_current(self):
        from django.utils import timezone
        today = timezone.now().date()
        return self.valid_from <= today <= self.valid_to

    def activate(self):
        """Активировать расписание."""
        if self.items.count() == 0:
            raise ValidationError('Нельзя активировать пустое расписание.')

        from django.utils import timezone
        today = timezone.now().date()
        if self.valid_to < today:
            raise ValidationError('Нельзя активировать расписание с прошедшими датами.')

        Schedule.objects.filter(
            tenant=self.tenant,
            status=Schedule.Status.ACTIVE
        ).exclude(id=self.id).update(status=Schedule.Status.ARCHIVED)

        self.status = Schedule.Status.ACTIVE
        self.save()
        return True


class ScheduleItem(TenantAwareModel):
    """Элемент расписания (конкретный урок)."""

    class DayOfWeek(models.IntegerChoices):
        MONDAY = 1, _('Понедельник')
        TUESDAY = 2, _('Вторник')
        WEDNESDAY = 3, _('Среда')
        THURSDAY = 4, _('Четверг')
        FRIDAY = 5, _('Пятница')
        SATURDAY = 6, _('Суббота')
        SUNDAY = 7, _('Воскресенье')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)

    schedule = models.ForeignKey(
        Schedule,
        on_delete=models.CASCADE,
        related_name='items',
        verbose_name=_('Расписание')
    )
    day_of_week = models.PositiveSmallIntegerField(
        _('День недели'),
        choices=DayOfWeek.choices,
        validators=[MinValueValidator(1), MaxValueValidator(7)]
    )
    time_slot = models.ForeignKey(
        TimeSlot,
        on_delete=models.PROTECT,
        related_name='schedule_items',
        verbose_name=_('Временной слот')
    )
    subject = models.ForeignKey(
        'references.Subject',
        on_delete=models.PROTECT,
        related_name='schedule_items',
        verbose_name=_('Предмет')
    )
    teacher = models.ForeignKey(
        'users.User',
        on_delete=models.PROTECT,
        related_name='teaching_schedule_items',
        verbose_name=_('Учитель')
    )
    student_group = models.ForeignKey(
        'stubs.ClassGroup',
        on_delete=models.PROTECT,
        related_name='schedule_items',
        verbose_name=_('Класс')
    )
    class_room = models.ForeignKey(
        'references.Classroom',
        on_delete=models.PROTECT,
        null=True,
        blank=True,
        related_name='schedule_items',
        verbose_name=_('Кабинет')
    )
    lesson_type = models.ForeignKey(
        'references.LessonType',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='schedule_items',
        verbose_name=_('Тип урока')
    )
    notes = models.TextField(_('Примечания'), blank=True)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Элемент расписания')
        verbose_name_plural = _('Элементы расписания')
        unique_together = ['schedule', 'day_of_week', 'time_slot', 'student_group']
        ordering = ['day_of_week', 'time_slot']
        indexes = [
            models.Index(fields=['schedule', 'day_of_week', 'time_slot']),
            models.Index(fields=['tenant', 'teacher']),
        ]

    def __str__(self):
        return f"{self.get_day_of_week_display()}: {self.subject.name}"
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/schedule/services/conflict_checker.py
    # -------------------------------------------------------------------------
    write_file "apps/schedule/services/conflict_checker.py" << 'FILE_EOF'
"""
Сервис проверки конфликтов в расписании
"""
import logging

logger = logging.getLogger(__name__)


class ScheduleConflictError(Exception):
    """Исключение при конфликте в расписании."""

    def __init__(self, message, conflict_type, details=None):
        super().__init__(message)
        self.conflict_type = conflict_type
        self.details = details or {}


class ScheduleConflictChecker:
    """Проверка конфликтов: учитель, класс, кабинет."""

    def __init__(self, tenant):
        self.tenant = tenant

    def check_item_conflicts(self, schedule_id, day_of_week, time_slot_id,
                            teacher_id=None, student_group_id=None,
                            class_room_id=None, exclude_item_id=None):
        """Проверить конфликты для элемента расписания."""
        from apps.schedule.models import ScheduleItem

        conflicts = []

        base_query = ScheduleItem.objects.filter(
            tenant=self.tenant,
            schedule_id=schedule_id,
            day_of_week=day_of_week,
            time_slot_id=time_slot_id
        )

        if exclude_item_id:
            base_query = base_query.exclude(id=exclude_item_id)

        # Конфликт учителя
        if teacher_id:
            conflict = base_query.filter(teacher_id=teacher_id).first()
            if conflict:
                conflicts.append({
                    'type': 'TEACHER_CONFLICT',
                    'message': 'Учитель уже занят в это время',
                    'conflicting_item': str(conflict.id),
                })

        # Конфликт класса
        if student_group_id:
            conflict = base_query.filter(student_group_id=student_group_id).first()
            if conflict:
                conflicts.append({
                    'type': 'GROUP_CONFLICT',
                    'message': 'Класс уже занят в это время',
                    'conflicting_item': str(conflict.id),
                })

        # Конфликт кабинета
        if class_room_id:
            conflict = base_query.filter(class_room_id=class_room_id).first()
            if conflict:
                conflicts.append({
                    'type': 'ROOM_CONFLICT',
                    'message': 'Кабинет уже занят',
                    'conflicting_item': str(conflict.id),
                })

        return conflicts

    def check_item_before_save(self, item_data):
        """Полная проверка перед сохранением."""
        conflicts = self.check_item_conflicts(
            schedule_id=item_data.get('schedule_id'),
            day_of_week=item_data.get('day_of_week'),
            time_slot_id=item_data.get('time_slot_id'),
            teacher_id=item_data.get('teacher_id'),
            student_group_id=item_data.get('student_group_id'),
            class_room_id=item_data.get('class_room_id'),
            exclude_item_id=item_data.get('exclude_item_id'),
        )

        critical = [c for c in conflicts if c['type'] in [
            'TEACHER_CONFLICT', 'GROUP_CONFLICT', 'ROOM_CONFLICT'
        ]]

        if critical:
            raise ScheduleConflictError(
                message=f"Найдено конфликтов: {len(critical)}",
                conflict_type='MULTIPLE',
                details={'conflicts': conflicts}
            )

        return conflicts
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/schedule/services/builder.py
    # -------------------------------------------------------------------------
    write_file "apps/schedule/services/builder.py" << 'FILE_EOF'
"""
Сервис построения расписания
"""
from django.db import transaction
from apps.schedule.services.conflict_checker import ScheduleConflictChecker
import logging

logger = logging.getLogger(__name__)


class ScheduleBuilderService:
    """Сервис для создания и управления расписанием."""

    def __init__(self, tenant, user):
        self.tenant = tenant
        self.user = user
        self.conflict_checker = ScheduleConflictChecker(tenant)

    @transaction.atomic
    def create_schedule(self, name, description, valid_from, valid_to, academic_year_id):
        """Создать новое расписание."""
        from apps.schedule.models import Schedule
        from apps.references.models import AcademicYear

        academic_year = AcademicYear.objects.get(id=academic_year_id)

        schedule = Schedule.objects.create(
            tenant=self.tenant,
            name=name,
            description=description,
            valid_from=valid_from,
            valid_to=valid_to,
            academic_year=academic_year,
            created_by=self.user,
            status=Schedule.Status.DRAFT
        )

        return schedule

    @transaction.atomic
    def add_item(self, schedule_id, day_of_week, time_slot_id,
                subject_id, teacher_id, student_group_id=None,
                class_room_id=None, lesson_type_id=None, notes=''):
        """Добавить элемент в расписание с проверкой конфликтов."""
        from apps.schedule.models import ScheduleItem

        item_data = {
            'schedule_id': schedule_id,
            'day_of_week': day_of_week,
            'time_slot_id': time_slot_id,
            'teacher_id': teacher_id,
            'student_group_id': student_group_id,
            'class_room_id': class_room_id,
        }

        # Проверка выбросит исключение при конфликтах
        self.conflict_checker.check_item_before_save(item_data)

        item = ScheduleItem.objects.create(
            tenant=self.tenant,
            schedule_id=schedule_id,
            day_of_week=day_of_week,
            time_slot_id=time_slot_id,
            subject_id=subject_id,
            teacher_id=teacher_id,
            student_group_id=student_group_id,
            class_room_id=class_room_id,
            lesson_type_id=lesson_type_id,
            notes=notes,
        )

        return item

    @transaction.atomic
    def delete_item(self, item_id):
        """Удалить элемент расписания."""
        from apps.schedule.models import ScheduleItem

        item = ScheduleItem.objects.get(id=item_id, tenant=self.tenant)
        item.delete()
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/schedule/views.py
    # -------------------------------------------------------------------------
    write_file "apps/schedule/views.py" << 'FILE_EOF'
"""
Представления раздела «Расписание»
"""
from django.shortcuts import render, redirect, get_object_or_404
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from apps.users.permissions import role_or_higher
from apps.schedule.models import Schedule, ScheduleItem, TimeSlot


@login_required
@role_or_higher('DEPUTY')
def schedules_list_view(request):
    """Список расписаний школы."""
    schedules = Schedule.objects.filter(tenant=request.tenant)

    status = request.GET.get('status', '')
    if status:
        schedules = schedules.filter(status=status)

    schedules = schedules.order_by('-valid_from')

    return render(request, 'schedule/schedules_list.html', {
        'schedules': schedules,
        'status_filter': status,
    })


@login_required
@role_or_higher('DEPUTY')
def schedule_builder_view(request, schedule_id):
    """Конструктор расписания."""
    schedule = get_object_or_404(Schedule, id=schedule_id, tenant=request.tenant)

    time_slots = TimeSlot.objects.filter(
        tenant=request.tenant,
        is_active=True,
        slot_type=TimeSlot.Type.LESSON
    ).order_by('slot_number')

    items = ScheduleItem.objects.filter(
        schedule=schedule
    ).select_related('subject', 'teacher', 'class_room', 'student_group', 'time_slot')

    from apps.references.models import Subject, Classroom
    from apps.stubs.models import ClassGroup
    from apps.users.models import User

    subjects = Subject.objects.filter(tenant=request.tenant, status='ACTIVE')
    teachers = User.objects.filter(
        tenant=request.tenant,
        role__in=[User.Role.TEACHER, User.Role.CLASS_TEACHER],
        is_active=True
    )
    classrooms = Classroom.objects.filter(tenant=request.tenant, status='AVAILABLE')
    student_groups = ClassGroup.objects.filter(tenant=request.tenant)

    return render(request, 'schedule/builder.html', {
        'schedule': schedule,
        'time_slots': time_slots,
        'items': items,
        'subjects': subjects,
        'teachers': teachers,
        'classrooms': classrooms,
        'student_groups': student_groups,
    })


@login_required
def schedule_view(request, schedule_id):
    """Просмотр расписания (для всех ролей)."""
    schedule = get_object_or_404(Schedule, id=schedule_id, tenant=request.tenant)

    time_slots = TimeSlot.objects.filter(
        tenant=request.tenant,
        is_active=True,
        slot_type=TimeSlot.Type.LESSON
    ).order_by('slot_number')

    items = ScheduleItem.objects.filter(schedule=schedule)

    return render(request, 'schedule/view.html', {
        'schedule': schedule,
        'time_slots': time_slots,
        'items': items,
    })
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/schedule/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/schedule/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.schedule import views

app_name = 'schedule'

urlpatterns = [
    path('', views.schedules_list_view, name='list'),
    path('<uuid:schedule_id>/builder/', views.schedule_builder_view, name='builder'),
    path('<uuid:schedule_id>/view/', views.schedule_view, name='view'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/schedule/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/schedule/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.schedule.models import Schedule, ScheduleItem, TimeSlot


@admin.register(TimeSlot)
class TimeSlotAdmin(admin.ModelAdmin):
    list_display = ['name', 'slot_number', 'start_time', 'end_time', 'slot_type', 'is_active']
    list_filter = ['slot_type', 'is_active', 'tenant']


@admin.register(Schedule)
class ScheduleAdmin(admin.ModelAdmin):
    list_display = ['name', 'status', 'valid_from', 'valid_to', 'academic_year']
    list_filter = ['status', 'tenant']
    search_fields = ['name']


@admin.register(ScheduleItem)
class ScheduleItemAdmin(admin.ModelAdmin):
    list_display = ['day_of_week', 'time_slot', 'subject', 'teacher', 'student_group']
    list_filter = ['day_of_week', 'tenant']
FILE_EOF

    log_success "apps/schedule записано"
}

# =============================================================================
# ШАГ 13: Приложение apps/grades
# =============================================================================

write_grades_app() {
    log_step "Шаг 13/9: Приложение apps/grades"

    # -------------------------------------------------------------------------
    # apps/grades/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/grades/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class GradesConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.grades'
    verbose_name = 'Электронный журнал'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/grades/models.py
    # -------------------------------------------------------------------------
    write_file "apps/grades/models.py" << 'FILE_EOF'
"""
Модели электронного журнала
"""
import uuid
from django.db import models
from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator, MaxValueValidator
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class Lesson(TenantAwareModel):
    """Конкретный урок."""

    class Status(models.TextChoices):
        PLANNED = 'PLANNED', _('Запланирован')
        COMPLETED = 'COMPLETED', _('Проведён')
        CANCELLED = 'CANCELLED', _('Отменён')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)

    schedule_item = models.ForeignKey(
        'schedule.ScheduleItem',
        on_delete=models.CASCADE,
        related_name='lessons',
        verbose_name=_('Элемент расписания'),
        null=True,
        blank=True
    )
    lesson_date = models.DateField(_('Дата урока'))
    lesson_number = models.PositiveSmallIntegerField(_('Номер урока'), default=1)
    topic = models.CharField(_('Тема урока'), max_length=500, blank=True)
    homework = models.TextField(_('Домашнее задание'), blank=True)
    homework_deadline = models.DateField(_('Срок сдачи ДЗ'), null=True, blank=True)
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.PLANNED
    )
    teacher_notes = models.TextField(_('Примечания учителя'), blank=True)
    created_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='created_lessons',
        verbose_name=_('Создано')
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Урок')
        verbose_name_plural = _('Уроки')
        ordering = ['-lesson_date', 'lesson_number']
        indexes = [
            models.Index(fields=['tenant', 'lesson_date']),
        ]

    def __str__(self):
        return f"{self.subject_name} от {self.lesson_date}"

    @property
    def subject(self):
        if self.schedule_item and self.schedule_item.subject:
            return self.schedule_item.subject
        return None

    @property
    def subject_name(self):
        subject = self.subject
        return subject.name if subject else 'Урок'

    @property
    def teacher(self):
        if self.schedule_item and self.schedule_item.teacher:
            return self.schedule_item.teacher
        return None

    @property
    def class_group(self):
        if self.schedule_item and self.schedule_item.student_group:
            return self.schedule_item.student_group
        return None

    def mark_completed(self):
        self.status = self.Status.COMPLETED
        self.save()


class Grade(TenantAwareModel):
    """Оценка ученика."""

    class GradeType(models.TextChoices):
        REGULAR = 'REGULAR', _('Текущая')
        HOMEWORK = 'HOMEWORK', _('Домашняя работа')
        TEST = 'TEST', _('Контрольная работа')
        EXAM = 'EXAM', _('Экзамен')
        FINAL = 'FINAL', _('Итоговая')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)

    student = models.ForeignKey(
        'stubs.Student',
        on_delete=models.CASCADE,
        related_name='grades',
        verbose_name=_('Ученик')
    )
    lesson = models.ForeignKey(
        Lesson,
        on_delete=models.CASCADE,
        related_name='grades',
        verbose_name=_('Урок')
    )
    value = models.PositiveSmallIntegerField(
        _('Значение оценки'),
        validators=[MinValueValidator(2), MaxValueValidator(5)]
    )
    grade_type = models.CharField(
        _('Тип оценки'),
        max_length=20,
        choices=GradeType.choices,
        default=GradeType.REGULAR
    )
    weight = models.DecimalField(
        _('Вес оценки'),
        max_digits=3,
        decimal_places=2,
        default=1.00
    )
    comment = models.TextField(_('Комментарий'), blank=True)
    teacher = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='given_grades',
        verbose_name=_('Учитель')
    )
    is_visible_to_student = models.BooleanField(_('Видна ученику'), default=True)
    is_visible_to_parent = models.BooleanField(_('Видна родителю'), default=True)
    created_at = models.DateTimeField(_('Дата выставления'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Оценка')
        verbose_name_plural = _('Оценки')
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['tenant', 'student', 'lesson']),
        ]

    def __str__(self):
        return f"{self.value} ({self.get_grade_type_display()})"

    def clean(self):
        super().clean()
        if self.value is not None and (self.value < 2 or self.value > 5):
            raise ValidationError({
                'value': 'Оценка должна быть в диапазоне от 2 до 5.'
            })

    def save(self, *args, **kwargs):
        self.full_clean()
        super().save(*args, **kwargs)


class Attendance(TenantAwareModel):
    """Посещаемость урока."""

    class Status(models.TextChoices):
        PRESENT = 'PRESENT', _('Присутствовал')
        ABSENT = 'ABSENT', _('Отсутствовал')
        LATE = 'LATE', _('Опоздал')
        EXCUSED = 'EXCUSED', _('Уважительная причина')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)

    student = models.ForeignKey(
        'stubs.Student',
        on_delete=models.CASCADE,
        related_name='attendance_records',
        verbose_name=_('Ученик')
    )
    lesson = models.ForeignKey(
        Lesson,
        on_delete=models.CASCADE,
        related_name='attendance_records',
        verbose_name=_('Урок')
    )
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.PRESENT
    )
    reason = models.ForeignKey(
        'references.AbsenceReason',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='attendance_records',
        verbose_name=_('Причина')
    )
    comment = models.TextField(_('Комментарий'), blank=True)
    marked_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='marked_attendance',
        verbose_name=_('Отметил')
    )
    created_at = models.DateTimeField(_('Дата отметки'), auto_now_add=True)

    class Meta:
        verbose_name = _('Посещаемость')
        verbose_name_plural = _('Посещаемость')
        unique_together = ['student', 'lesson']
        indexes = [
            models.Index(fields=['tenant', 'student']),
            models.Index(fields=['tenant', 'lesson']),
        ]

    def __str__(self):
        return f"{self.student} - {self.get_status_display()}"
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/grades/services.py
    # -------------------------------------------------------------------------
    write_file "apps/grades/services.py" << 'FILE_EOF'
"""
Сервисы журнала
"""
from django.db import transaction
import logging

logger = logging.getLogger(__name__)


class GradeService:
    """Сервис для работы с оценками."""

    def __init__(self, tenant):
        self.tenant = tenant

    @transaction.atomic
    def create_grade(self, student_id, lesson_id, value, grade_type='REGULAR',
                    weight=1.00, comment='', teacher_id=None):
        """Выставить оценку ученику."""
        from apps.grades.models import Grade, Lesson
        from apps.stubs.models import Student

        if value < 2 or value > 5:
            raise ValueError('Оценка должна быть в диапазоне от 2 до 5')

        try:
            lesson = Lesson.objects.get(id=lesson_id, tenant=self.tenant)
        except Lesson.DoesNotExist:
            raise ValueError('Урок не найден')

        try:
            student = Student.objects.get(id=student_id, tenant=self.tenant)
        except Student.DoesNotExist:
            raise ValueError('Ученик не найден')

        if Grade.objects.filter(
            tenant=self.tenant,
            student=student,
            lesson=lesson
        ).exists():
            raise ValueError('Оценка уже выставлена')

        grade = Grade.objects.create(
            tenant=self.tenant,
            student=student,
            lesson=lesson,
            value=value,
            grade_type=grade_type,
            weight=weight,
            comment=comment,
            teacher_id=teacher_id,
        )

        return grade

    def get_student_average(self, student_id, subject_id=None):
        """Рассчитать средний балл ученика."""
        from apps.grades.models import Grade

        grades = Grade.objects.filter(
            tenant=self.tenant,
            student_id=student_id,
            is_visible_to_student=True
        )

        if subject_id:
            grades = grades.filter(lesson__schedule_item__subject_id=subject_id)

        grades_data = list(grades.values('value', 'weight'))

        if not grades_data:
            return 0

        total_weighted = 0
        total_weight = 0

        for g in grades_data:
            try:
                value = float(g['value'])
                weight = float(g['weight'])
                total_weighted += value * weight
                total_weight += weight
            except (TypeError, ValueError):
                continue

        if total_weight == 0:
            return 0

        return round(total_weighted / total_weight, 2)


class AttendanceService:
    """Сервис для работы с посещаемостью."""

    def __init__(self, tenant):
        self.tenant = tenant

    @transaction.atomic
    def mark_attendance(self, lesson_id, student_id, status,
                       reason_id=None, comment='', marked_by_id=None):
        """Отметить посещаемость ученика."""
        from apps.grades.models import Attendance, Lesson
        from apps.stubs.models import Student

        try:
            lesson = Lesson.objects.get(id=lesson_id, tenant=self.tenant)
        except Lesson.DoesNotExist:
            raise ValueError('Урок не найден')

        try:
            student = Student.objects.get(id=student_id, tenant=self.tenant)
        except Student.DoesNotExist:
            raise ValueError('Ученик не найден')

        attendance, created = Attendance.objects.update_or_create(
            tenant=self.tenant,
            lesson=lesson,
            student=student,
            defaults={
                'status': status,
                'reason_id': reason_id,
                'comment': comment,
                'marked_by_id': marked_by_id,
            }
        )

        return attendance
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/grades/views.py
    # -------------------------------------------------------------------------
    write_file "apps/grades/views.py" << 'FILE_EOF'
"""
Представления раздела «Электронный журнал»
"""
from django.shortcuts import render, redirect
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.http import JsonResponse
from django.views.decorators.http import require_http_methods
import json
from apps.users.permissions import teacher_required
from apps.grades.models import Lesson, Grade, Attendance
from apps.grades.services import GradeService, AttendanceService


@login_required
@teacher_required
def journal_view(request):
    """Главная страница журнала."""
    return render(request, 'grades/journal.html')


@login_required
def diary_view(request):
    """Дневник ученика."""
    user = request.user

    from apps.stubs.models import Student

    if user.role == 'STUDENT':
        student = Student.objects.filter(
            tenant=request.tenant,
            user=user
        ).first()
    elif user.role == 'PARENT':
        student = Student.objects.filter(
            tenant=request.tenant,
            parents=user
        ).first()
    else:
        messages.error(request, 'Доступ только для учеников и родителей.')
        return redirect('dashboard')

    if not student:
        messages.error(request, 'Профиль ученика не найден.')
        return redirect('dashboard')

    recent_grades = Grade.objects.filter(
        tenant=request.tenant,
        student=student,
        is_visible_to_student=True
    ).select_related('lesson__schedule_item__subject').order_by('-created_at')[:10]

    return render(request, 'grades/diary.html', {
        'student': student,
        'recent_grades': recent_grades,
    })


@login_required
@teacher_required
@require_http_methods(["POST"])
def api_add_grade(request):
    """API для выставления оценки."""
    try:
        data = json.loads(request.body)

        service = GradeService(request.tenant)

        grade = service.create_grade(
            student_id=data['student_id'],
            lesson_id=data['lesson_id'],
            value=data['value'],
            grade_type=data.get('grade_type', 'REGULAR'),
            comment=data.get('comment', ''),
            teacher_id=request.user.id,
        )

        return JsonResponse({
            'success': True,
            'grade_id': str(grade.id),
            'message': f'Оценка {grade.value} выставлена'
        })

    except ValueError as e:
        return JsonResponse({'success': False, 'error': str(e)}, status=400)

    except Exception as e:
        return JsonResponse({'success': False, 'error': str(e)}, status=500)
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/grades/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/grades/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.grades import views

app_name = 'grades'

urlpatterns = [
    path('', views.journal_view, name='journal'),
    path('diary/', views.diary_view, name='diary'),
    path('api/add-grade/', views.api_add_grade, name='api_add_grade'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/grades/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/grades/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.grades.models import Lesson, Grade, Attendance


@admin.register(Lesson)
class LessonAdmin(admin.ModelAdmin):
    list_display = ['lesson_date', 'lesson_number', 'topic', 'status', 'created_by']
    list_filter = ['status', 'lesson_date', 'tenant']
    search_fields = ['topic']


@admin.register(Grade)
class GradeAdmin(admin.ModelAdmin):
    list_display = ['student', 'lesson', 'value', 'grade_type', 'teacher', 'created_at']
    list_filter = ['value', 'grade_type', 'tenant']
    search_fields = ['student__last_name', 'student__first_name']


@admin.register(Attendance)
class AttendanceAdmin(admin.ModelAdmin):
    list_display = ['student', 'lesson', 'status', 'marked_by', 'created_at']
    list_filter = ['status', 'tenant']
FILE_EOF

    log_success "apps/grades записано"
}

# =============================================================================
# ШАГ 14: Приложение apps/lessons
# =============================================================================

write_lessons_app() {
    log_step "Шаг 14/9: Приложение apps/lessons"

    # -------------------------------------------------------------------------
    # apps/lessons/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/lessons/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class LessonsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.lessons'
    verbose_name = 'Тематическое планирование'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/lessons/models.py
    # -------------------------------------------------------------------------
    write_file "apps/lessons/models.py" << 'FILE_EOF'
"""
Модели тематического планирования
"""
import uuid
from django.db import models
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class LessonPlan(TenantAwareModel):
    """Тематический план."""

    class Status(models.TextChoices):
        DRAFT = 'DRAFT', _('Черновик')
        ACTIVE = 'ACTIVE', _('Активный')
        ARCHIVED = 'ARCHIVED', _('Архив')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название плана'), max_length=255)
    subject = models.ForeignKey(
        'references.Subject',
        on_delete=models.PROTECT,
        related_name='lesson_plans',
        verbose_name=_('Предмет')
    )
    class_group = models.ForeignKey(
        'stubs.ClassGroup',
        on_delete=models.PROTECT,
        related_name='lesson_plans',
        verbose_name=_('Класс')
    )
    academic_year = models.ForeignKey(
        'references.AcademicYear',
        on_delete=models.PROTECT,
        related_name='lesson_plans',
        verbose_name=_('Учебный год')
    )
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.DRAFT
    )
    total_hours = models.PositiveIntegerField(_('Всего часов'), default=0)
    description = models.TextField(_('Описание'), blank=True)
    created_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='created_lesson_plans',
        verbose_name=_('Создано')
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Тематический план')
        verbose_name_plural = _('Тематические планы')
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.name} ({self.subject.name})"

    @property
    def item_count(self):
        return self.items.count()


class LessonPlanItem(TenantAwareModel):
    """Элемент тематического плана."""

    class LessonType(models.TextChoices):
        THEORY = 'THEORY', _('Теория')
        PRACTICE = 'PRACTICE', _('Практика')
        CONTROL = 'CONTROL', _('Контрольная работа')
        LAB = 'LAB', _('Лабораторная работа')
        REVIEW = 'REVIEW', _('Повторение')
        EXAM = 'EXAM', _('Экзамен')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)

    lesson_plan = models.ForeignKey(
        LessonPlan,
        on_delete=models.CASCADE,
        related_name='items',
        verbose_name=_('Тематический план')
    )
    order_number = models.PositiveIntegerField(_('Порядковый номер'), default=1)
    topic = models.CharField(_('Тема урока'), max_length=500)
    lesson_type = models.CharField(
        _('Тип урока'),
        max_length=20,
        choices=LessonType.choices,
        default=LessonType.THEORY
    )
    hours = models.PositiveSmallIntegerField(_('Количество часов'), default=1)
    planned_date = models.DateField(_('Планируемая дата'), null=True, blank=True)
    homework = models.TextField(_('Домашнее задание'), blank=True)
    notes = models.TextField(_('Примечания'), blank=True)
    actual_lesson = models.ForeignKey(
        'grades.Lesson',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='plan_items',
        verbose_name=_('Фактический урок')
    )
    is_completed = models.BooleanField(_('Выполнено'), default=False)

    class Meta:
        verbose_name = _('Элемент темплана')
        verbose_name_plural = _('Элементы темпланов')
        unique_together = ['lesson_plan', 'order_number']
        ordering = ['order_number']

    def __str__(self):
        return f"{self.order_number}. {self.topic}"

    def mark_completed(self):
        self.is_completed = True
        self.save()
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/lessons/views.py
    # -------------------------------------------------------------------------
    write_file "apps/lessons/views.py" << 'FILE_EOF'
"""
Представления тематического планирования
"""
from django.shortcuts import render
from django.contrib.auth.decorators import login_required
from apps.users.permissions import teacher_required
from apps.lessons.models import LessonPlan


@login_required
@teacher_required
def lesson_plans_view(request):
    """Список тематических планов."""
    plans = LessonPlan.objects.filter(tenant=request.tenant)

    return render(request, 'lessons/plans.html', {'plans': plans})
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/lessons/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/lessons/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.lessons import views

app_name = 'lessons'

urlpatterns = [
    path('plans/', views.lesson_plans_view, name='plans'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/lessons/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/lessons/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.lessons.models import LessonPlan, LessonPlanItem


@admin.register(LessonPlan)
class LessonPlanAdmin(admin.ModelAdmin):
    list_display = ['name', 'subject', 'class_group', 'academic_year', 'status']
    list_filter = ['status', 'tenant']
    search_fields = ['name']


@admin.register(LessonPlanItem)
class LessonPlanItemAdmin(admin.ModelAdmin):
    list_display = ['order_number', 'topic', 'lesson_type', 'hours', 'is_completed']
    list_filter = ['lesson_type', 'is_completed', 'tenant']
FILE_EOF

    log_success "apps/lessons записано"
}

# =============================================================================
# СТРАНИЦА 5 ЗАВЕРШЕНА
# =============================================================================
#!/bin/bash
# =============================================================================
# СТРАНИЦА 6 / СТРАНИЦА 11
# =============================================================================
# Содержимое этой страницы:
#   Шаг 15: Приложение apps/groups (группы, кружки)
#   Шаг 16: Приложение apps/exams (экзамены, аттестаты)
#   Шаг 17: Приложение apps/calendar_app (календарь)
#   Шаг 18: Приложение apps/news (новости)
#   Шаг 19: Приложение apps/nutrition (питание)
# =============================================================================

# =============================================================================
# ШАГ 15: Приложение apps/groups
# =============================================================================

write_groups_app() {
    log_step "Шаг 15/9: Приложение apps/groups"

    # -------------------------------------------------------------------------
    # apps/groups/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/groups/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class GroupsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.groups'
    verbose_name = 'Группы'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/groups/models.py
    # -------------------------------------------------------------------------
    write_file "apps/groups/models.py" << 'FILE_EOF'
"""
Модели учебных групп
"""
import uuid
from django.db import models
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class Group(TenantAwareModel):
    """Учебная группа (факультатив, кружок, секция)."""

    class Type(models.TextChoices):
        ELECTIVE = 'ELECTIVE', _('Элективный курс')
        CLUB = 'CLUB', _('Кружок')
        SPORT = 'SPORT', _('Спортивная секция')
        TUTORIAL = 'TUTORIAL', _('Факультатив')
        SUBGROUP = 'SUBGROUP', _('Подгруппа')
        OTHER = 'OTHER', _('Другое')

    class Status(models.TextChoices):
        ACTIVE = 'ACTIVE', _('Активная')
        ARCHIVED = 'ARCHIVED', _('Архивная')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название группы'), max_length=255)
    group_type = models.CharField(
        _('Тип группы'),
        max_length=20,
        choices=Type.choices,
        default=Type.ELECTIVE
    )
    description = models.TextField(_('Описание'), blank=True)
    leader = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='led_groups',
        verbose_name=_('Руководитель')
    )
    subject = models.ForeignKey(
        'references.Subject',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='groups',
        verbose_name=_('Предмет')
    )
    academic_year = models.ForeignKey(
        'references.AcademicYear',
        on_delete=models.PROTECT,
        related_name='groups',
        verbose_name=_('Учебный год')
    )
    max_members = models.PositiveIntegerField(_('Максимум участников'), default=30)
    schedule = models.TextField(_('Расписание занятий'), blank=True)
    classroom = models.ForeignKey(
        'references.Classroom',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='groups',
        verbose_name=_('Кабинет')
    )
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.ACTIVE
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Группа')
        verbose_name_plural = _('Группы')
        ordering = ['name']

    def __str__(self):
        return self.name

    @property
    def member_count(self):
        return self.members.filter(status=GroupMember.Status.ACTIVE).count()

    @property
    def is_full(self):
        return self.member_count >= self.max_members

    def can_add_member(self):
        return not self.is_full


class GroupMember(TenantAwareModel):
    """Участник группы."""

    class Role(models.TextChoices):
        MEMBER = 'MEMBER', _('Участник')
        LEADER = 'LEADER', _('Староста')
        ASSISTANT = 'ASSISTANT', _('Помощник')

    class Status(models.TextChoices):
        ACTIVE = 'ACTIVE', _('Активен')
        LEFT = 'LEFT', _('Покинул группу')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    group = models.ForeignKey(
        Group,
        on_delete=models.CASCADE,
        related_name='members',
        verbose_name=_('Группа')
    )
    student = models.ForeignKey(
        'stubs.Student',
        on_delete=models.CASCADE,
        related_name='group_memberships',
        verbose_name=_('Ученик')
    )
    role = models.CharField(
        _('Роль в группе'),
        max_length=20,
        choices=Role.choices,
        default=Role.MEMBER
    )
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.ACTIVE
    )
    joined_at = models.DateTimeField(_('Дата вступления'), auto_now_add=True)
    left_at = models.DateTimeField(_('Дата выхода'), null=True, blank=True)

    class Meta:
        verbose_name = _('Участник группы')
        verbose_name_plural = _('Участники групп')
        unique_together = ['group', 'student']

    def __str__(self):
        return f"{self.student} в {self.group.name}"

    def leave_group(self):
        """Ученик покидает группу."""
        if self.status == self.Status.LEFT:
            return False

        self.status = self.Status.LEFT
        self.left_at = timezone.now()
        self.save(update_fields=['status', 'left_at'])
        return True
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/groups/views.py
    # -------------------------------------------------------------------------
    write_file "apps/groups/views.py" << 'FILE_EOF'
"""
Представления раздела «Группы»
"""
from django.shortcuts import render
from django.contrib.auth.decorators import login_required
from apps.users.permissions import teacher_required
from apps.groups.models import Group


@login_required
@teacher_required
def groups_list_view(request):
    """Список групп школы."""
    groups = Group.objects.filter(tenant=request.tenant)

    group_type = request.GET.get('type', '')
    if group_type:
        groups = groups.filter(group_type=group_type)

    groups = groups.order_by('name')

    return render(request, 'groups/list.html', {
        'groups': groups,
        'type_filter': group_type,
        'types': Group.Type.choices,
    })
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/groups/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/groups/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.groups import views

app_name = 'groups'

urlpatterns = [
    path('', views.groups_list_view, name='list'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/groups/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/groups/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.groups.models import Group, GroupMember


@admin.register(Group)
class GroupAdmin(admin.ModelAdmin):
    list_display = ['name', 'group_type', 'leader', 'member_count', 'max_members', 'status']
    list_filter = ['group_type', 'status', 'tenant']
    search_fields = ['name']


@admin.register(GroupMember)
class GroupMemberAdmin(admin.ModelAdmin):
    list_display = ['student', 'group', 'role', 'status', 'joined_at']
    list_filter = ['role', 'status', 'tenant']
FILE_EOF

    log_success "apps/groups записано"
}

# =============================================================================
# ШАГ 16: Приложение apps/exams
# =============================================================================

write_exams_app() {
    log_step "Шаг 16/9: Приложение apps/exams"

    # -------------------------------------------------------------------------
    # apps/exams/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/exams/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class ExamsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.exams'
    verbose_name = 'Экзамены и аттестаты'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/exams/models.py
    # -------------------------------------------------------------------------
    write_file "apps/exams/models.py" << 'FILE_EOF'
"""
Модели экзаменов и аттестатов
"""
import uuid
from django.db import models
from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator, MaxValueValidator
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class Exam(TenantAwareModel):
    """Экзамен."""

    class ExamType(models.TextChoices):
        INTERIM = 'INTERIM', _('Промежуточная аттестация')
        FINAL = 'FINAL', _('Итоговая аттестация')
        MOCK_OGE = 'MOCK_OGE', _('Пробный ОГЭ')
        MOCK_EGE = 'MOCK_EGE', _('Пробный ЕГЭ')
        CONTROL = 'CONTROL', _('Контрольная работа')
        OTHER = 'OTHER', _('Другое')

    class Status(models.TextChoices):
        SCHEDULED = 'SCHEDULED', _('Запланирован')
        IN_PROGRESS = 'IN_PROGRESS', _('Идёт')
        COMPLETED = 'COMPLETED', _('Завершён')
        CANCELLED = 'CANCELLED', _('Отменён')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название экзамена'), max_length=255)
    exam_type = models.CharField(
        _('Тип экзамена'),
        max_length=20,
        choices=ExamType.choices,
        default=ExamType.INTERIM
    )
    subject = models.ForeignKey(
        'references.Subject',
        on_delete=models.PROTECT,
        related_name='exams',
        verbose_name=_('Предмет')
    )
    class_group = models.ForeignKey(
        'stubs.ClassGroup',
        on_delete=models.PROTECT,
        related_name='exams',
        verbose_name=_('Класс')
    )
    exam_date = models.DateField(_('Дата экзамена'))
    start_time = models.TimeField(_('Время начала'))
    end_time = models.TimeField(_('Время окончания'))
    classroom = models.ForeignKey(
        'references.Classroom',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='exams',
        verbose_name=_('Кабинет')
    )
    organizer = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='organized_exams',
        verbose_name=_('Организатор')
    )
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.SCHEDULED
    )
    max_score = models.PositiveIntegerField(_('Максимальный балл'), default=100)
    passing_score = models.PositiveIntegerField(_('Проходной балл'), default=50)
    description = models.TextField(_('Описание'), blank=True)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Экзамен')
        verbose_name_plural = _('Экзамены')
        ordering = ['-exam_date']

    def __str__(self):
        return f"{self.name} ({self.subject.name})"

    def clean(self):
        super().clean()
        if self.start_time and self.end_time:
            if self.end_time <= self.start_time:
                raise ValidationError({
                    'end_time': 'Время окончания должно быть позже времени начала.'
                })
        if self.passing_score is not None and self.max_score is not None:
            if self.passing_score > self.max_score:
                raise ValidationError({
                    'passing_score': 'Проходной балл не может превышать максимальный.'
                })

    def save(self, *args, **kwargs):
        self.full_clean()
        super().save(*args, **kwargs)

    @property
    def average_score(self):
        results = self.results.filter(score__isnull=False)
        if not results.exists():
            return 0
        total = sum(r.score for r in results)
        return round(total / results.count(), 2)


class ExamResult(TenantAwareModel):
    """Результат экзамена ученика."""

    class Status(models.TextChoices):
        REGISTERED = 'REGISTERED', _('Зарегистрирован')
        ATTENDED = 'ATTENDED', _('Присутствовал')
        ABSENT = 'ABSENT', _('Отсутствовал')
        PASSED = 'PASSED', _('Сдал')
        FAILED = 'FAILED', _('Не сдал')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    exam = models.ForeignKey(
        Exam,
        on_delete=models.CASCADE,
        related_name='results',
        verbose_name=_('Экзамен')
    )
    student = models.ForeignKey(
        'stubs.Student',
        on_delete=models.CASCADE,
        related_name='exam_results',
        verbose_name=_('Ученик')
    )
    score = models.PositiveIntegerField(
        _('Балл'),
        null=True,
        blank=True,
        validators=[MinValueValidator(0)]
    )
    grade = models.PositiveSmallIntegerField(
        _('Оценка'),
        null=True,
        blank=True,
        validators=[MinValueValidator(2), MaxValueValidator(5)]
    )
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.REGISTERED
    )
    comment = models.TextField(_('Комментарий'), blank=True)
    graded_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='graded_exam_results',
        verbose_name=_('Оценил')
    )
    graded_at = models.DateTimeField(_('Дата оценивания'), null=True, blank=True)

    class Meta:
        verbose_name = _('Результат экзамена')
        verbose_name_plural = _('Результаты экзаменов')
        unique_together = ['exam', 'student']

    def __str__(self):
        return f"{self.student} - {self.exam.name}"

    @property
    def is_passed(self):
        if self.score is None:
            return False
        return self.score >= self.exam.passing_score

    def calculate_grade(self):
        if self.score is None:
            return None

        max_score = self.exam.max_score
        percentage = (self.score / max_score) * 100

        if percentage >= 90:
            return 5
        elif percentage >= 70:
            return 4
        elif percentage >= 50:
            return 3
        else:
            return 2


class Certificate(TenantAwareModel):
    """Аттестат об образовании."""

    class Type(models.TextChoices):
        BASIC = 'BASIC', _('Аттестат об основном общем образовании')
        SECONDARY = 'SECONDARY', _('Аттестат о среднем общем образовании')
        HONORS = 'HONORS', _('Аттестат с отличием')

    class Status(models.TextChoices):
        DRAFT = 'DRAFT', _('Черновик')
        APPROVED = 'APPROVED', _('Утверждён')
        ISSUED = 'ISSUED', _('Выдан')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    student = models.ForeignKey(
        'stubs.Student',
        on_delete=models.CASCADE,
        related_name='certificates',
        verbose_name=_('Ученик')
    )
    certificate_type = models.CharField(
        _('Тип аттестата'),
        max_length=20,
        choices=Type.choices,
        default=Type.BASIC
    )
    blank_number = models.CharField(_('Номер бланка'), max_length=50, blank=True)
    issue_date = models.DateField(_('Дата выдачи'), null=True, blank=True)
    graduation_year = models.PositiveIntegerField(_('Год выпуска'))
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.DRAFT
    )
    average_grade = models.DecimalField(
        _('Средний балл'),
        max_digits=3,
        decimal_places=2,
        null=True,
        blank=True
    )
    has_honors = models.BooleanField(_('С отличием'), default=False)
    created_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='created_certificates',
        verbose_name=_('Создано')
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Аттестат')
        verbose_name_plural = _('Аттестаты')
        ordering = ['-graduation_year']

    def __str__(self):
        return f"Аттестат {self.student} ({self.graduation_year})"

    def calculate_average(self):
        subjects = self.subjects.all()
        if not subjects.exists():
            return None

        total = 0
        count = 0
        for subject in subjects:
            if subject.final_grade is not None:
                total += subject.final_grade
                count += 1

        if count == 0:
            return None

        return round(total / count, 2)

    def check_honors(self):
        subjects = self.subjects.all()
        if not subjects.exists():
            return False
        if subjects.count() < 5:
            return False

        for subject in subjects:
            if subject.final_grade is None or subject.final_grade < 4:
                return False

        excellent_count = subjects.filter(final_grade=5).count()
        return (excellent_count / subjects.count()) >= 0.5


class CertificateSubject(TenantAwareModel):
    """Предмет в аттестате."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    certificate = models.ForeignKey(
        Certificate,
        on_delete=models.CASCADE,
        related_name='subjects',
        verbose_name=_('Аттестат')
    )
    subject = models.ForeignKey(
        'references.Subject',
        on_delete=models.PROTECT,
        related_name='certificate_entries',
        verbose_name=_('Предмет')
    )
    final_grade = models.PositiveSmallIntegerField(
        _('Итоговая оценка'),
        validators=[MinValueValidator(2), MaxValueValidator(5)]
    )

    class Meta:
        verbose_name = _('Предмет в аттестате')
        verbose_name_plural = _('Предметы в аттестатах')
        unique_together = ['certificate', 'subject']
        ordering = ['subject__name']

    def __str__(self):
        return f"{self.subject.name}: {self.final_grade}"
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/exams/views.py
    # -------------------------------------------------------------------------
    write_file "apps/exams/views.py" << 'FILE_EOF'
"""
Представления раздела «Экзамены»
"""
from django.shortcuts import render
from django.contrib.auth.decorators import login_required
from apps.users.permissions import teacher_required, admin_required
from apps.exams.models import Exam, Certificate


@login_required
@teacher_required
def exams_list_view(request):
    """Список экзаменов."""
    exams = Exam.objects.filter(tenant=request.tenant)

    status = request.GET.get('status', '')
    if status:
        exams = exams.filter(status=status)

    exams = exams.order_by('-exam_date')

    return render(request, 'exams/list.html', {
        'exams': exams,
        'status_filter': status,
        'statuses': Exam.Status.choices,
    })


@login_required
@admin_required
def certificates_list_view(request):
    """Список аттестатов."""
    certificates = Certificate.objects.filter(tenant=request.tenant)
    certificates = certificates.order_by('-graduation_year')

    return render(request, 'exams/certificates.html', {
        'certificates': certificates,
    })
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/exams/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/exams/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.exams import views

app_name = 'exams'

urlpatterns = [
    path('', views.exams_list_view, name='list'),
    path('certificates/', views.certificates_list_view, name='certificates'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/exams/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/exams/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.exams.models import Exam, ExamResult, Certificate, CertificateSubject


@admin.register(Exam)
class ExamAdmin(admin.ModelAdmin):
    list_display = ['name', 'exam_type', 'subject', 'class_group', 'exam_date', 'status']
    list_filter = ['exam_type', 'status', 'tenant']
    search_fields = ['name']


@admin.register(ExamResult)
class ExamResultAdmin(admin.ModelAdmin):
    list_display = ['student', 'exam', 'score', 'grade', 'status']
    list_filter = ['status', 'tenant']


@admin.register(Certificate)
class CertificateAdmin(admin.ModelAdmin):
    list_display = ['student', 'certificate_type', 'graduation_year', 'status', 'average_grade']
    list_filter = ['certificate_type', 'status', 'tenant']


@admin.register(CertificateSubject)
class CertificateSubjectAdmin(admin.ModelAdmin):
    list_display = ['certificate', 'subject', 'final_grade']
FILE_EOF

    log_success "apps/exams записано"
}

# =============================================================================
# ШАГ 17: Приложение apps/calendar_app
# =============================================================================

write_calendar_app() {
    log_step "Шаг 17/9: Приложение apps/calendar_app"

    # -------------------------------------------------------------------------
    # apps/calendar_app/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/calendar_app/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class CalendarAppConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.calendar_app'
    verbose_name = 'Календарь'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/calendar_app/models.py
    # -------------------------------------------------------------------------
    write_file "apps/calendar_app/models.py" << 'FILE_EOF'
"""
Модели календаря событий
"""
import uuid
from django.db import models
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class CalendarEvent(TenantAwareModel):
    """Событие календаря школы."""

    class EventType(models.TextChoices):
        SCHOOL = 'SCHOOL', _('Школьное мероприятие')
        CLASS = 'CLASS', _('Классное мероприятие')
        MEETING = 'MEETING', _('Собрание')
        EXCURSION = 'EXCURSION', _('Экскурсия')
        SPORT = 'SPORT', _('Спортивное мероприятие')
        HOLIDAY = 'HOLIDAY', _('Праздник')
        EXAM = 'EXAM', _('Экзамен')
        OTHER = 'OTHER', _('Другое')

    class Priority(models.TextChoices):
        LOW = 'LOW', _('Низкий')
        MEDIUM = 'MEDIUM', _('Средний')
        HIGH = 'HIGH', _('Высокий')
        CRITICAL = 'CRITICAL', _('Критический')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    title = models.CharField(_('Название события'), max_length=255)
    description = models.TextField(_('Описание'), blank=True)
    event_type = models.CharField(
        _('Тип события'),
        max_length=20,
        choices=EventType.choices,
        default=EventType.SCHOOL
    )
    start_date = models.DateField(_('Дата начала'))
    end_date = models.DateField(_('Дата окончания'), null=True, blank=True)
    start_time = models.TimeField(_('Время начала'), null=True, blank=True)
    end_time = models.TimeField(_('Время окончания'), null=True, blank=True)
    location = models.CharField(_('Место проведения'), max_length=255, blank=True)
    priority = models.CharField(
        _('Приоритет'),
        max_length=20,
        choices=Priority.choices,
        default=Priority.MEDIUM
    )
    class_group = models.ForeignKey(
        'stubs.ClassGroup',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='events',
        verbose_name=_('Класс')
    )
    organizer = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='organized_events',
        verbose_name=_('Организатор')
    )
    is_all_day = models.BooleanField(_('Весь день'), default=False)
    is_published = models.BooleanField(_('Опубликовано'), default=True)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Событие календаря')
        verbose_name_plural = _('События календаря')
        ordering = ['-start_date']
        indexes = [
            models.Index(fields=['tenant', 'start_date']),
        ]

    def __str__(self):
        return self.title

    @property
    def is_multi_day(self):
        return self.end_date and self.end_date != self.start_date


class Holiday(TenantAwareModel):
    """Праздник или каникулы."""

    class Type(models.TextChoices):
        NATIONAL = 'NATIONAL', _('Государственный праздник')
        SCHOOL = 'SCHOOL', _('Школьный праздник')
        VACATION = 'VACATION', _('Каникулы')
        WEEKEND = 'WEEKEND', _('Выходной')
        OTHER = 'OTHER', _('Другое')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название'), max_length=255)
    holiday_type = models.CharField(
        _('Тип'),
        max_length=20,
        choices=Type.choices,
        default=Type.NATIONAL
    )
    start_date = models.DateField(_('Дата начала'))
    end_date = models.DateField(_('Дата окончания'), null=True, blank=True)
    description = models.TextField(_('Описание'), blank=True)
    is_school_day = models.BooleanField(_('Учебный день'), default=False)

    class Meta:
        verbose_name = _('Праздник/Каникулы')
        verbose_name_plural = _('Праздники и каникулы')
        ordering = ['-start_date']

    def __str__(self):
        return self.name
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/calendar_app/views.py
    # -------------------------------------------------------------------------
    write_file "apps/calendar_app/views.py" << 'FILE_EOF'
"""
Представления календаря
"""
from django.shortcuts import render
from django.contrib.auth.decorators import login_required
from apps.calendar_app.models import CalendarEvent, Holiday


@login_required
def calendar_view(request):
    """Календарь событий школы."""
    events = CalendarEvent.objects.filter(
        tenant=request.tenant,
        is_published=True
    ).order_by('-start_date')[:50]

    holidays = Holiday.objects.filter(tenant=request.tenant)

    return render(request, 'calendar/calendar.html', {
        'events': events,
        'holidays': holidays,
    })
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/calendar_app/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/calendar_app/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.calendar_app import views

app_name = 'calendar_app'

urlpatterns = [
    path('', views.calendar_view, name='calendar'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/calendar_app/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/calendar_app/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.calendar_app.models import CalendarEvent, Holiday


@admin.register(CalendarEvent)
class CalendarEventAdmin(admin.ModelAdmin):
    list_display = ['title', 'event_type', 'start_date', 'priority', 'is_published']
    list_filter = ['event_type', 'priority', 'is_published', 'tenant']
    search_fields = ['title']


@admin.register(Holiday)
class HolidayAdmin(admin.ModelAdmin):
    list_display = ['name', 'holiday_type', 'start_date', 'end_date', 'is_school_day']
    list_filter = ['holiday_type', 'tenant']
FILE_EOF

    log_success "apps/calendar_app записано"
}

# =============================================================================
# ШАГ 18: Приложение apps/news
# =============================================================================

write_news_app() {
    log_step "Шаг 18/9: Приложение apps/news"

    # -------------------------------------------------------------------------
    # apps/news/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/news/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class NewsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.news'
    verbose_name = 'Новости'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/news/models.py
    # -------------------------------------------------------------------------
    write_file "apps/news/models.py" << 'FILE_EOF'
"""
Модели новостей
"""
import uuid
from django.db import models
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class NewsCategory(TenantAwareModel):
    """Категория новостей."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название категории'), max_length=100)
    color = models.CharField(_('Цвет'), max_length=7, default='#3B82F6')
    sort_order = models.PositiveIntegerField(_('Порядок'), default=0)

    class Meta:
        verbose_name = _('Категория новостей')
        verbose_name_plural = _('Категории новостей')
        ordering = ['sort_order', 'name']

    def __str__(self):
        return self.name


class News(TenantAwareModel):
    """Новость школы."""

    class Status(models.TextChoices):
        DRAFT = 'DRAFT', _('Черновик')
        PUBLISHED = 'PUBLISHED', _('Опубликовано')
        ARCHIVED = 'ARCHIVED', _('Архив')

    class Audience(models.TextChoices):
        ALL = 'ALL', _('Все')
        STUDENTS = 'STUDENTS', _('Ученики')
        PARENTS = 'PARENTS', _('Родители')
        TEACHERS = 'TEACHERS', _('Учителя')
        STAFF = 'STAFF', _('Персонал')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    title = models.CharField(_('Заголовок'), max_length=500)
    slug = models.SlugField(_('URL-слаг'), max_length=500, blank=True)
    excerpt = models.TextField(_('Анонс'), max_length=1000, blank=True)
    content = models.TextField(_('Содержание'))
    category = models.ForeignKey(
        NewsCategory,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='news',
        verbose_name=_('Категория')
    )
    audience = models.CharField(
        _('Аудитория'),
        max_length=20,
        choices=Audience.choices,
        default=Audience.ALL
    )
    image = models.ImageField(_('Изображение'), upload_to='news/', null=True, blank=True)
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.DRAFT
    )
    published_at = models.DateTimeField(_('Дата публикации'), null=True, blank=True)
    is_pinned = models.BooleanField(_('Закреплена'), default=False)
    allow_comments = models.BooleanField(_('Разрешить комментарии'), default=False)
    author = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='written_news',
        verbose_name=_('Автор')
    )
    views_count = models.PositiveIntegerField(_('Просмотры'), default=0)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Новость')
        verbose_name_plural = _('Новости')
        ordering = ['-is_pinned', '-published_at']
        unique_together = ['tenant', 'slug']
        indexes = [
            models.Index(fields=['tenant', 'status']),
        ]

    def __str__(self):
        return self.title

    def save(self, *args, **kwargs):
        if not self.slug:
            from django.utils.text import slugify
            base_slug = slugify(self.title, allow_unicode=True)
            slug = base_slug

            counter = 1
            while News.objects.filter(
                tenant=self.tenant,
                slug=slug
            ).exclude(id=self.id).exists():
                slug = f"{base_slug}-{counter}"
                counter += 1

            self.slug = slug

        if self.status == self.Status.PUBLISHED and not self.published_at:
            self.published_at = timezone.now()

        super().save(*args, **kwargs)

    def publish(self):
        self.status = self.Status.PUBLISHED
        self.published_at = timezone.now()
        self.save()

    def increment_views(self):
        self.views_count += 1
        self.save(update_fields=['views_count'])
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/news/views.py
    # -------------------------------------------------------------------------
    write_file "apps/news/views.py" << 'FILE_EOF'
"""
Представления новостей
"""
from django.shortcuts import render, get_object_or_404
from django.contrib.auth.decorators import login_required
from apps.news.models import News, NewsCategory


@login_required
def news_list_view(request):
    """Список новостей школы."""
    news = News.objects.filter(
        tenant=request.tenant,
        status=News.Status.PUBLISHED
    ).select_related('category', 'author')

    category_id = request.GET.get('category')
    if category_id:
        news = news.filter(category_id=category_id)

    news = news.order_by('-is_pinned', '-published_at')

    categories = NewsCategory.objects.filter(tenant=request.tenant)

    return render(request, 'news/list.html', {
        'news': news,
        'categories': categories,
        'category_filter': category_id,
    })


@login_required
def news_detail_view(request, slug):
    """Детальная страница новости."""
    news = get_object_or_404(
        News,
        tenant=request.tenant,
        slug=slug,
        status=News.Status.PUBLISHED
    )

    news.increment_views()

    return render(request, 'news/detail.html', {'news': news})
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/news/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/news/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.news import views

app_name = 'news'

urlpatterns = [
    path('', views.news_list_view, name='list'),
    path('<slug:slug>/', views.news_detail_view, name='detail'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/news/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/news/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.news.models import News, NewsCategory


@admin.register(NewsCategory)
class NewsCategoryAdmin(admin.ModelAdmin):
    list_display = ['name', 'color', 'sort_order']
    list_filter = ['tenant']


@admin.register(News)
class NewsAdmin(admin.ModelAdmin):
    list_display = ['title', 'category', 'status', 'audience', 'published_at', 'views_count']
    list_filter = ['status', 'audience', 'category', 'tenant']
    search_fields = ['title', 'content']
FILE_EOF

    log_success "apps/news записано"
}

# =============================================================================
# ШАГ 19: Приложение apps/nutrition
# =============================================================================

write_nutrition_app() {
    log_step "Шаг 19/9: Приложение apps/nutrition"

    # -------------------------------------------------------------------------
    # apps/nutrition/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/nutrition/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class NutritionConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.nutrition'
    verbose_name = 'Питание'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/nutrition/models.py
    # -------------------------------------------------------------------------
    write_file "apps/nutrition/models.py" << 'FILE_EOF'
"""
Модели питания
"""
import uuid
from django.db import models
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class Meal(TenantAwareModel):
    """Блюдо."""

    class MealType(models.TextChoices):
        BREAKFAST = 'BREAKFAST', _('Завтрак')
        LUNCH = 'LUNCH', _('Обед')
        DINNER = 'DINNER', _('Ужин')
        SNACK = 'SNACK', _('Полдник')

    class Category(models.TextChoices):
        SOUP = 'SOUP', _('Первое блюдо')
        MAIN = 'MAIN', _('Второе блюдо')
        SALAD = 'SALAD', _('Салат')
        SIDE = 'SIDE', _('Гарнир')
        DRINK = 'DRINK', _('Напиток')
        DESSERT = 'DESSERT', _('Десерт')
        BAKERY = 'BAKERY', _('Выпечка')
        OTHER = 'OTHER', _('Другое')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название блюда'), max_length=255)
    meal_type = models.CharField(
        _('Тип приёма пищи'),
        max_length=20,
        choices=MealType.choices,
        default=MealType.LUNCH
    )
    category = models.CharField(
        _('Категория'),
        max_length=20,
        choices=Category.choices,
        default=Category.MAIN
    )
    description = models.TextField(_('Описание'), blank=True)
    calories = models.PositiveIntegerField(_('Калории (ккал)'), null=True, blank=True)
    protein = models.DecimalField(
        _('Белки (г)'),
        max_digits=5,
        decimal_places=1,
        null=True,
        blank=True
    )
    fat = models.DecimalField(
        _('Жиры (г)'),
        max_digits=5,
        decimal_places=1,
        null=True,
        blank=True
    )
    carbohydrates = models.DecimalField(
        _('Углеводы (г)'),
        max_digits=5,
        decimal_places=1,
        null=True,
        blank=True
    )
    allergens = models.TextField(_('Аллергены'), blank=True)
    price = models.DecimalField(
        _('Цена (руб.)'),
        max_digits=10,
        decimal_places=2,
        null=True,
        blank=True
    )
    is_active = models.BooleanField(_('Активно'), default=True)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)

    class Meta:
        verbose_name = _('Блюдо')
        verbose_name_plural = _('Блюда')
        ordering = ['name']

    def __str__(self):
        return self.name


class Menu(TenantAwareModel):
    """Меню на день."""

    class MenuType(models.TextChoices):
        REGULAR = 'REGULAR', _('Обычное меню')
        VEGETARIAN = 'VEGETARIAN', _('Вегетарианское')
        MEDICAL = 'MEDICAL', _('Диетическое')
        SPECIAL = 'SPECIAL', _('Особое')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    menu_date = models.DateField(_('Дата меню'))
    menu_type = models.CharField(
        _('Тип меню'),
        max_length=20,
        choices=MenuType.choices,
        default=MenuType.REGULAR
    )
    description = models.TextField(_('Описание'), blank=True)
    class_group = models.ForeignKey(
        'stubs.ClassGroup',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='menus',
        verbose_name=_('Класс')
    )
    is_active = models.BooleanField(_('Активно'), default=True)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Меню')
        verbose_name_plural = _('Меню')
        unique_together = ['tenant', 'menu_date', 'menu_type']
        ordering = ['-menu_date']

    def __str__(self):
        return f"Меню на {self.menu_date} ({self.get_menu_type_display()})"

    @property
    def total_calories(self):
        items = self.items.select_related('meal')
        total = 0
        for item in items:
            if item.meal.calories is not None:
                total += item.meal.calories
        return total


class MenuItem(TenantAwareModel):
    """Позиция в меню."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    menu = models.ForeignKey(
        Menu,
        on_delete=models.CASCADE,
        related_name='items',
        verbose_name=_('Меню')
    )
    meal = models.ForeignKey(
        Meal,
        on_delete=models.PROTECT,
        related_name='menu_items',
        verbose_name=_('Блюдо')
    )
    order_number = models.PositiveSmallIntegerField(_('Порядок подачи'), default=1)
    portion = models.CharField(_('Порция'), max_length=100, blank=True)

    class Meta:
        verbose_name = _('Позиция меню')
        verbose_name_plural = _('Позиции меню')
        unique_together = ['menu', 'meal', 'order_number']
        ordering = ['order_number']

    def __str__(self):
        return f"{self.menu} - {self.meal.name}"
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/nutrition/views.py
    # -------------------------------------------------------------------------
    write_file "apps/nutrition/views.py" << 'FILE_EOF'
"""
Представления раздела «Питание»
"""
from django.shortcuts import render
from django.contrib.auth.decorators import login_required
from apps.nutrition.models import Menu, Meal


@login_required
def menu_view(request):
    """Меню столовой."""
    menus = Menu.objects.filter(
        tenant=request.tenant,
        is_active=True
    ).order_by('-menu_date')[:7]

    meals = Meal.objects.filter(
        tenant=request.tenant,
        is_active=True
    )

    return render(request, 'nutrition/menu.html', {
        'menus': menus,
        'meals': meals,
    })
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/nutrition/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/nutrition/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.nutrition import views

app_name = 'nutrition'

urlpatterns = [
    path('', views.menu_view, name='menu'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/nutrition/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/nutrition/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.nutrition.models import Meal, Menu, MenuItem


@admin.register(Meal)
class MealAdmin(admin.ModelAdmin):
    list_display = ['name', 'meal_type', 'category', 'calories', 'price', 'is_active']
    list_filter = ['meal_type', 'category', 'is_active', 'tenant']
    search_fields = ['name']


@admin.register(Menu)
class MenuAdmin(admin.ModelAdmin):
    list_display = ['menu_date', 'menu_type', 'is_active', 'total_calories']
    list_filter = ['menu_type', 'is_active', 'tenant']


@admin.register(MenuItem)
class MenuItemAdmin(admin.ModelAdmin):
    list_display = ['menu', 'meal', 'order_number', 'portion']
FILE_EOF

    log_success "apps/nutrition записано"
}

# =============================================================================
# СТРАНИЦА 6 ЗАВЕРШЕНА
# =============================================================================
#!/bin/bash
# =============================================================================
# СТРАНИЦА 7 / СТРАНИЦА 11
# =============================================================================
# Содержимое этой страницы:
#   Шаг 20: Приложение apps/chats (мессенджер + WebSocket)
#   Шаг 21: Приложение apps/notifications (уведомления + WebSocket)
#   Шаг 22: Приложение apps/video (видеоконференции Jitsi)
# =============================================================================

# =============================================================================
# ШАГ 20: Приложение apps/chats
# =============================================================================

write_chats_app() {
    log_step "Шаг 20/9: Приложение apps/chats"

    # -------------------------------------------------------------------------
    # apps/chats/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/chats/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class ChatsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.chats'
    verbose_name = 'Мессенджер'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/chats/models.py
    # -------------------------------------------------------------------------
    write_file "apps/chats/models.py" << 'FILE_EOF'
"""
Модели мессенджера
"""
import uuid
from django.db import models
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class Chat(TenantAwareModel):
    """Чат (личный или групповой)."""

    class ChatType(models.TextChoices):
        PERSONAL = 'PERSONAL', _('Личный')
        GROUP = 'GROUP', _('Групповой')
        CLASS = 'CLASS', _('Классный')
        SYSTEM = 'SYSTEM', _('Системный')

    class Status(models.TextChoices):
        ACTIVE = 'ACTIVE', _('Активный')
        ARCHIVED = 'ARCHIVED', _('Архивный')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    chat_type = models.CharField(
        _('Тип чата'),
        max_length=20,
        choices=ChatType.choices,
        default=ChatType.PERSONAL
    )
    name = models.CharField(_('Название'), max_length=255, blank=True)
    avatar = models.ImageField(_('Аватар'), upload_to='chat_avatars/', null=True, blank=True)
    description = models.TextField(_('Описание'), blank=True)
    class_group = models.ForeignKey(
        'stubs.ClassGroup',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='chats',
        verbose_name=_('Класс')
    )
    creator = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='created_chats',
        verbose_name=_('Создатель')
    )
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.ACTIVE
    )
    is_muted = models.BooleanField(_('Беззвучный режим'), default=False)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)
    last_message_at = models.DateTimeField(
        _('Время последнего сообщения'),
        null=True,
        blank=True
    )

    class Meta:
        verbose_name = _('Чат')
        verbose_name_plural = _('Чаты')
        ordering = ['-last_message_at']
        indexes = [
            models.Index(fields=['tenant', 'last_message_at']),
        ]

    def __str__(self):
        return self.name or f"Чат {self.id}"

    @property
    def member_count(self):
        return self.members.filter(status=ChatMember.Status.ACTIVE).count()

    @property
    def last_message(self):
        return self.messages.order_by('-created_at').first()

    def get_display_name(self, current_user):
        if self.chat_type == self.ChatType.PERSONAL:
            other_member = self.members.filter(
                status=ChatMember.Status.ACTIVE
            ).exclude(
                user_id=current_user.id
            ).select_related('user').first()

            if other_member:
                return other_member.user.get_display_name()

            return "Личный чат"

        return self.name or "Групповой чат"

    def update_last_message_time(self):
        self.last_message_at = timezone.now()
        self.save(update_fields=['last_message_at'])


class ChatMember(TenantAwareModel):
    """Участник чата."""

    class Role(models.TextChoices):
        OWNER = 'OWNER', _('Владелец')
        ADMIN = 'ADMIN', _('Администратор')
        MEMBER = 'MEMBER', _('Участник')

    class Status(models.TextChoices):
        ACTIVE = 'ACTIVE', _('Активен')
        LEFT = 'LEFT', _('Покинул')
        BANNED = 'BANNED', _('Заблокирован')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    chat = models.ForeignKey(
        Chat,
        on_delete=models.CASCADE,
        related_name='members',
        verbose_name=_('Чат')
    )
    user = models.ForeignKey(
        'users.User',
        on_delete=models.CASCADE,
        related_name='chat_memberships',
        verbose_name=_('Пользователь')
    )
    role = models.CharField(
        _('Роль'),
        max_length=20,
        choices=Role.choices,
        default=Role.MEMBER
    )
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.ACTIVE
    )
    is_muted = models.BooleanField(_('Беззвучный режим'), default=False)
    last_read_at = models.DateTimeField(
        _('Последнее прочтение'),
        null=True,
        blank=True
    )
    joined_at = models.DateTimeField(_('Дата вступления'), auto_now_add=True)
    left_at = models.DateTimeField(_('Дата выхода'), null=True, blank=True)

    class Meta:
        verbose_name = _('Участник чата')
        verbose_name_plural = _('Участники чатов')
        unique_together = ['chat', 'user']
        indexes = [
            models.Index(fields=['tenant', 'user']),
        ]

    def __str__(self):
        return f"{self.user.get_display_name()} в {self.chat}"

    @property
    def unread_count(self):
        if not self.last_read_at:
            return self.chat.messages.count()

        return self.chat.messages.filter(
            created_at__gt=self.last_read_at
        ).exclude(sender=self.user).count()

    def mark_read(self):
        self.last_read_at = timezone.now()
        self.save(update_fields=['last_read_at'])

    def is_admin_or_owner(self):
        return self.role in [self.Role.OWNER, self.Role.ADMIN]


class Message(TenantAwareModel):
    """Сообщение в чате."""

    class MessageType(models.TextChoices):
        TEXT = 'TEXT', _('Текст')
        IMAGE = 'IMAGE', _('Изображение')
        FILE = 'FILE', _('Файл')
        SYSTEM = 'SYSTEM', _('Системное')
        VIDEO_CALL = 'VIDEO_CALL', _('Видеозвонок')
        VOICE = 'VOICE', _('Голосовое сообщение')

    class Status(models.TextChoices):
        SENT = 'SENT', _('Отправлено')
        DELIVERED = 'DELIVERED', _('Доставлено')
        READ = 'READ', _('Прочитано')
        DELETED = 'DELETED', _('Удалено')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    chat = models.ForeignKey(
        Chat,
        on_delete=models.CASCADE,
        related_name='messages',
        verbose_name=_('Чат')
    )
    sender = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='sent_messages',
        verbose_name=_('Отправитель')
    )
    message_type = models.CharField(
        _('Тип сообщения'),
        max_length=20,
        choices=MessageType.choices,
        default=MessageType.TEXT
    )
    text = models.TextField(_('Текст'), blank=True)
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.SENT
    )
    reply_to = models.ForeignKey(
        'self',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='replies',
        verbose_name=_('Ответ на')
    )
    is_edited = models.BooleanField(_('Отредактировано'), default=False)
    edited_at = models.DateTimeField(_('Дата редактирования'), null=True, blank=True)
    created_at = models.DateTimeField(_('Дата отправки'), auto_now_add=True)

    class Meta:
        verbose_name = _('Сообщение')
        verbose_name_plural = _('Сообщения')
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['tenant', 'chat', 'created_at']),
        ]

    def __str__(self):
        return f"{self.sender}: {self.text[:50]}..." if self.sender else self.text[:50]

    def edit(self, new_text):
        self.text = new_text
        self.is_edited = True
        self.edited_at = timezone.now()
        self.save()

    def soft_delete(self):
        """Мягкое удаление с очисткой вложений."""
        self.status = self.Status.DELETED
        self.text = "Сообщение удалено"

        # Удаляем вложения
        self.attachments.all().delete()

        self.save()
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/chats/consumers.py
    # -------------------------------------------------------------------------
    write_file "apps/chats/consumers.py" << 'FILE_EOF'
"""
WebSocket consumer для мессенджера
"""
import json
from channels.generic.websocket import AsyncWebsocketConsumer
from channels.db import database_sync_to_async
from django.utils import timezone
import logging

logger = logging.getLogger(__name__)


class ChatConsumer(AsyncWebsocketConsumer):
    """
    WebSocket consumer для чата.

    Подключение: /ws/chat/{chat_id}/
    """

    async def connect(self):
        """Обработка подключения."""
        self.chat_id = self.scope['url_route']['kwargs']['chat_id']
        self.chat_group_name = f'chat_{self.chat_id}'
        self.user = self.scope.get('user')

        if not self.user or not self.user.is_authenticated:
            await self.close()
            return

        has_access = await self.check_chat_access()
        if not has_access:
            await self.close()
            return

        await self.channel_layer.group_add(
            self.chat_group_name,
            self.channel_name
        )

        await self.accept()

        await self.channel_layer.group_send(
            self.chat_group_name,
            {
                'type': 'user_joined',
                'user_id': str(self.user.id),
                'user_name': self.user.get_display_name(),
            }
        )

    async def disconnect(self, close_code):
        """Обработка отключения."""
        await self.channel_layer.group_send(
            self.chat_group_name,
            {
                'type': 'user_left',
                'user_id': str(self.user.id),
            }
        )

        await self.channel_layer.group_discard(
            self.chat_group_name,
            self.channel_name
        )

    async def receive(self, text_data):
        """Обработка входящего сообщения."""
        try:
            data = json.loads(text_data)
            message_type = data.get('type')

            if message_type == 'chat_message':
                await self.handle_chat_message(data)
            elif message_type == 'typing_start':
                await self.handle_typing_start()
            elif message_type == 'typing_stop':
                await self.handle_typing_stop()
            elif message_type == 'mark_read':
                await self.handle_mark_read()

        except json.JSONDecodeError:
            logger.warning(f"Invalid JSON from user {self.user.id}")

    async def handle_chat_message(self, data):
        """Обработка сообщения чата."""
        message_text = data.get('message', '').strip()

        if not message_text:
            return

        message = await self.save_message(message_text)

        if message:
            await self.channel_layer.group_send(
                self.chat_group_name,
                {
                    'type': 'chat_message',
                    'message': message_text,
                    'message_id': str(message['id']),
                    'sender_id': str(self.user.id),
                    'sender_name': self.user.get_display_name(),
                    'created_at': message['created_at'],
                }
            )

    async def handle_typing_start(self):
        """Начало печати."""
        await self.channel_layer.group_send(
            self.chat_group_name,
            {
                'type': 'typing_indicator',
                'user_id': str(self.user.id),
                'user_name': self.user.get_display_name(),
                'is_typing': True,
            }
        )

    async def handle_typing_stop(self):
        """Окончание печати."""
        await self.channel_layer.group_send(
            self.chat_group_name,
            {
                'type': 'typing_indicator',
                'user_id': str(self.user.id),
                'user_name': self.user.get_display_name(),
                'is_typing': False,
            }
        )

    async def handle_mark_read(self):
        """Отметка прочтения."""
        await self.mark_messages_read()

    async def chat_message(self, event):
        """Отправка сообщения в WebSocket."""
        if event['sender_id'] == str(self.user.id):
            return

        await self.send(text_data=json.dumps({
            'type': 'chat_message',
            'message': event['message'],
            'message_id': event['message_id'],
            'sender_id': event['sender_id'],
            'sender_name': event['sender_name'],
            'created_at': event['created_at'],
        }))

    async def typing_indicator(self, event):
        """Индикатор печати."""
        if event['user_id'] == str(self.user.id):
            return

        await self.send(text_data=json.dumps({
            'type': 'typing_indicator',
            'user_id': event['user_id'],
            'user_name': event['user_name'],
            'is_typing': event['is_typing'],
        }))

    async def user_joined(self, event):
        """Уведомление о подключении."""
        if event['user_id'] == str(self.user.id):
            return

        await self.send(text_data=json.dumps({
            'type': 'user_joined',
            'user_id': event['user_id'],
            'user_name': event['user_name'],
        }))

    async def user_left(self, event):
        """Уведомление об отключении."""
        if event['user_id'] == str(self.user.id):
            return

        await self.send(text_data=json.dumps({
            'type': 'user_left',
            'user_id': event['user_id'],
        }))

    @database_sync_to_async
    def check_chat_access(self):
        """Проверка доступа к чату."""
        from apps.chats.models import ChatMember

        return ChatMember.objects.filter(
            chat_id=self.chat_id,
            user=self.user,
            status='ACTIVE'
        ).exists()

    @database_sync_to_async
    def save_message(self, text):
        """Сохранение сообщения в БД."""
        from apps.chats.models import Message, Chat

        try:
            chat = Chat.objects.get(id=self.chat_id)

            message = Message.objects.create(
                tenant=chat.tenant,
                chat=chat,
                sender=self.user,
                text=text,
                message_type='TEXT',
                status='SENT',
            )

            chat.update_last_message_time()

            return {
                'id': message.id,
                'created_at': message.created_at.isoformat(),
            }

        except Exception as e:
            logger.error(f"Error saving message: {str(e)}")
            return None

    @database_sync_to_async
    def mark_messages_read(self):
        """Отметка сообщений как прочитанных."""
        from apps.chats.models import ChatMember, Message

        try:
            ChatMember.objects.filter(
                chat_id=self.chat_id,
                user=self.user
            ).update(last_read_at=timezone.now())

            Message.objects.filter(
                chat_id=self.chat_id,
                status__in=['SENT', 'DELIVERED']
            ).exclude(sender=self.user).update(status='READ')

        except Exception as e:
            logger.error(f"Error marking messages read: {str(e)}")
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/chats/routing.py
    # -------------------------------------------------------------------------
    write_file "apps/chats/routing.py" << 'FILE_EOF'
"""
WebSocket маршруты для мессенджера
"""
from django.urls import re_path
from apps.chats import consumers

websocket_urlpatterns = [
    re_path(
        r'ws/chat/(?P<chat_id>\w+)/$',
        consumers.ChatConsumer.as_asgi()
    ),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/chats/views.py
    # -------------------------------------------------------------------------
    write_file "apps/chats/views.py" << 'FILE_EOF'
"""
Представления мессенджера
"""
from django.shortcuts import render, get_object_or_404
from django.contrib.auth.decorators import login_required
from apps.chats.models import Chat, ChatMember


@login_required
def messenger_view(request):
    """Главная страница мессенджера."""
    memberships = ChatMember.objects.filter(
        tenant=request.tenant,
        user=request.user,
        status=ChatMember.Status.ACTIVE
    ).select_related('chat')

    chats = [m.chat for m in memberships]

    return render(request, 'chats/messenger.html', {
        'chats': chats,
    })


@login_required
def chat_view(request, chat_id):
    """Окно конкретного чата."""
    chat = get_object_or_404(Chat, id=chat_id, tenant=request.tenant)

    # Проверяем, что пользователь участник чата
    membership = ChatMember.objects.filter(
        chat=chat,
        user=request.user,
        status=ChatMember.Status.ACTIVE
    ).exists()

    if not membership:
        from django.http import HttpResponseForbidden
        return HttpResponseForbidden('Нет доступа к этому чату.')

    messages = chat.messages.select_related('sender').order_by('created_at')[-100:]

    return render(request, 'chats/chat_window.html', {
        'chat': chat,
        'messages': messages,
    })
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/chats/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/chats/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.chats import views

app_name = 'chats'

urlpatterns = [
    path('', views.messenger_view, name='messenger'),
    path('<uuid:chat_id>/', views.chat_view, name='chat'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/chats/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/chats/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.chats.models import Chat, ChatMember, Message


@admin.register(Chat)
class ChatAdmin(admin.ModelAdmin):
    list_display = ['name', 'chat_type', 'status', 'member_count', 'last_message_at']
    list_filter = ['chat_type', 'status', 'tenant']
    search_fields = ['name']


@admin.register(ChatMember)
class ChatMemberAdmin(admin.ModelAdmin):
    list_display = ['user', 'chat', 'role', 'status', 'joined_at']
    list_filter = ['role', 'status', 'tenant']


@admin.register(Message)
class MessageAdmin(admin.ModelAdmin):
    list_display = ['sender', 'chat', 'message_type', 'status', 'created_at']
    list_filter = ['message_type', 'status', 'tenant']
FILE_EOF

    log_success "apps/chats записано"
}

# =============================================================================
# ШАГ 21: Приложение apps/notifications
# =============================================================================

write_notifications_app() {
    log_step "Шаг 21/9: Приложение apps/notifications"

    # -------------------------------------------------------------------------
    # apps/notifications/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/notifications/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class NotificationsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.notifications'
    verbose_name = 'Уведомления'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/notifications/models.py
    # -------------------------------------------------------------------------
    write_file "apps/notifications/models.py" << 'FILE_EOF'
"""
Модели уведомлений
"""
import uuid
from django.db import models
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class Notification(TenantAwareModel):
    """Уведомление для пользователя."""

    class NotificationType(models.TextChoices):
        GRADE = 'GRADE', _('Новая оценка')
        MESSAGE = 'MESSAGE', _('Новое сообщение')
        HOMEWORK = 'HOMEWORK', _('Домашнее задание')
        SCHEDULE = 'SCHEDULE', _('Изменение расписания')
        EVENT = 'EVENT', _('Событие')
        NEWS = 'NEWS', _('Новость')
        EXAM = 'EXAM', _('Экзамен')
        SYSTEM = 'SYSTEM', _('Системное')
        MENTION = 'MENTION', _('Упоминание')
        OTHER = 'OTHER', _('Другое')

    class Priority(models.TextChoices):
        LOW = 'LOW', _('Низкий')
        MEDIUM = 'MEDIUM', _('Средний')
        HIGH = 'HIGH', _('Высокий')
        URGENT = 'URGENT', _('Срочный')

    class Status(models.TextChoices):
        UNREAD = 'UNREAD', _('Непрочитано')
        READ = 'READ', _('Прочитано')
        ARCHIVED = 'ARCHIVED', _('Архивировано')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    recipient = models.ForeignKey(
        'users.User',
        on_delete=models.CASCADE,
        related_name='notifications',
        verbose_name=_('Получатель')
    )
    notification_type = models.CharField(
        _('Тип'),
        max_length=20,
        choices=NotificationType.choices,
        default=NotificationType.OTHER
    )
    priority = models.CharField(
        _('Приоритет'),
        max_length=20,
        choices=Priority.choices,
        default=Priority.MEDIUM
    )
    title = models.CharField(_('Заголовок'), max_length=255)
    message = models.TextField(_('Сообщение'))
    link = models.URLField(_('Ссылка'), blank=True)
    sender = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='sent_notifications',
        verbose_name=_('Отправитель')
    )
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.UNREAD
    )
    read_at = models.DateTimeField(_('Дата прочтения'), null=True, blank=True)
    data = models.JSONField(_('Дополнительные данные'), default=dict, blank=True)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)

    class Meta:
        verbose_name = _('Уведомление')
        verbose_name_plural = _('Уведомления')
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['tenant', 'recipient', 'status']),
        ]

    def __str__(self):
        return f"{self.title} → {self.recipient.get_display_name()}"

    def mark_read(self):
        self.status = self.Status.READ
        self.read_at = timezone.now()
        self.save(update_fields=['status', 'read_at'])

    def archive(self):
        self.status = self.Status.ARCHIVED
        self.save(update_fields=['status'])

    @property
    def is_urgent(self):
        return self.priority == self.Priority.URGENT


class NotificationPreference(TenantAwareModel):
    """Настройки уведомлений."""

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.OneToOneField(
        'users.User',
        on_delete=models.CASCADE,
        related_name='notification_preferences',
        verbose_name=_('Пользователь')
    )
    channel_in_app = models.BooleanField(_('В приложении'), default=True)
    channel_email = models.BooleanField(_('Email'), default=True)
    channel_push = models.BooleanField(_('Push'), default=False)

    notify_grades = models.BooleanField(_('Оценки'), default=True)
    notify_messages = models.BooleanField(_('Сообщения'), default=True)
    notify_homework = models.BooleanField(_('Домашние задания'), default=True)
    notify_schedule = models.BooleanField(_('Изменения расписания'), default=True)
    notify_events = models.BooleanField(_('События'), default=True)
    notify_news = models.BooleanField(_('Новости'), default=True)
    notify_exams = models.BooleanField(_('Экзамены'), default=True)
    notify_system = models.BooleanField(_('Системные'), default=True)

    do_not_disturb_start = models.TimeField(
        _('Начало режима тишины'),
        null=True,
        blank=True
    )
    do_not_disturb_end = models.TimeField(
        _('Окончание режима тишины'),
        null=True,
        blank=True
    )

    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Настройки уведомлений')
        verbose_name_plural = _('Настройки уведомлений')

    def __str__(self):
        return f"Настройки уведомлений {self.user.get_display_name()}"

    def is_in_quiet_hours(self):
        """Проверка режима тишины (с обработкой через полночь)."""
        if not self.do_not_disturb_start or not self.do_not_disturb_end:
            return False

        now = timezone.now().time()
        start = self.do_not_disturb_start
        end = self.do_not_disturb_end

        if start <= end:
            return start <= now <= end
        else:
            return now >= start or now <= end

    def should_notify(self, notification_type):
        """Проверить, нужно ли отправлять уведомление."""
        type_mapping = {
            'GRADE': self.notify_grades,
            'MESSAGE': self.notify_messages,
            'HOMEWORK': self.notify_homework,
            'SCHEDULE': self.notify_schedule,
            'EVENT': self.notify_events,
            'NEWS': self.notify_news,
            'EXAM': self.notify_exams,
            'SYSTEM': self.notify_system,
        }

        return type_mapping.get(notification_type, True)
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/notifications/consumers.py
    # -------------------------------------------------------------------------
    write_file "apps/notifications/consumers.py" << 'FILE_EOF'
"""
WebSocket consumer для уведомлений
"""
import json
from channels.generic.websocket import AsyncWebsocketConsumer
from channels.db import database_sync_to_async
import logging

logger = logging.getLogger(__name__)


class NotificationConsumer(AsyncWebsocketConsumer):
    """
    WebSocket consumer для уведомлений.

    Подключение: /ws/notifications/
    """

    async def connect(self):
        """Обработка подключения."""
        self.user = self.scope.get('user')

        if not self.user or not self.user.is_authenticated:
            await self.close()
            return

        self.notification_group_name = f'notifications_{self.user.id}'

        await self.channel_layer.group_add(
            self.notification_group_name,
            self.channel_name
        )

        await self.accept()

        unread_count = await self.get_unread_count()
        await self.send(text_data=json.dumps({
            'type': 'initial_state',
            'unread_count': unread_count,
        }))

    async def disconnect(self, close_code):
        """Обработка отключения."""
        await self.channel_layer.group_discard(
            self.notification_group_name,
            self.channel_name
        )

    async def receive(self, text_data):
        """Обработка входящего сообщения."""
        try:
            data = json.loads(text_data)
            message_type = data.get('type')

            if message_type == 'mark_read':
                notification_id = data.get('notification_id')
                await self.mark_notification_read(notification_id)

            elif message_type == 'mark_all_read':
                await self.mark_all_read()

        except json.JSONDecodeError:
            pass

    async def notification_received(self, event):
        """Отправка нового уведомления."""
        await self.send(text_data=json.dumps({
            'type': 'notification',
            'notification_id': event['notification_id'],
            'title': event['title'],
            'message': event['message'],
            'notification_type': event['notification_type'],
            'priority': event['priority'],
            'link': event['link'],
            'created_at': event['created_at'],
        }))

    @database_sync_to_async
    def get_unread_count(self):
        """Получить количество непрочитанных уведомлений."""
        from apps.notifications.models import Notification

        return Notification.objects.filter(
            recipient=self.user,
            status='UNREAD'
        ).count()

    @database_sync_to_async
    def mark_notification_read(self, notification_id):
        """Отметить уведомление как прочитанное."""
        from apps.notifications.models import Notification

        try:
            notification = Notification.objects.get(
                id=notification_id,
                recipient=self.user
            )
            notification.mark_read()
        except Notification.DoesNotExist:
            pass

    @database_sync_to_async
    def mark_all_read(self):
        """Отметить все уведомления как прочитанные."""
        from apps.notifications.models import Notification
        from django.utils import timezone

        Notification.objects.filter(
            recipient=self.user,
            status='UNREAD'
        ).update(status='READ', read_at=timezone.now())
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/notifications/routing.py
    # -------------------------------------------------------------------------
    write_file "apps/notifications/routing.py" << 'FILE_EOF'
"""
WebSocket маршруты для уведомлений
"""
from django.urls import re_path
from apps.notifications import consumers

websocket_urlpatterns = [
    re_path(
        r'ws/notifications/$',
        consumers.NotificationConsumer.as_asgi()
    ),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/notifications/services.py
    # -------------------------------------------------------------------------
    write_file "apps/notifications/services.py" << 'FILE_EOF'
"""
Сервис для работы с уведомлениями
"""
from django.db import transaction
from channels.layers import get_channel_layer
from asgiref.sync import async_to_sync
import logging

logger = logging.getLogger(__name__)


class NotificationService:
    """Сервис для отправки уведомлений."""

    def __init__(self, tenant):
        self.tenant = tenant

    @transaction.atomic
    def send_notification(self, recipient, notification_type, title, message,
                         priority='MEDIUM', link='', sender=None, data=None):
        """Отправить уведомление пользователю."""
        from apps.notifications.models import Notification, NotificationPreference

        # Проверяем настройки получателя
        try:
            prefs = recipient.notification_preferences

            if not prefs.should_notify(notification_type):
                logger.info(f"User {recipient.id} disabled {notification_type}")
                return None

            if prefs.is_in_quiet_hours():
                logger.info(f"User {recipient.id} in quiet hours")
                return None

        except NotificationPreference.DoesNotExist:
            pass

        # Создаём уведомление
        notification = Notification.objects.create(
            tenant=self.tenant,
            recipient=recipient,
            notification_type=notification_type,
            priority=priority,
            title=title,
            message=message,
            link=link,
            sender=sender,
            data=data or {},
        )

        # Отправляем через WebSocket
        self.send_websocket_notification(recipient, notification)

        logger.info(f"Sent notification {notification.id} to user {recipient.id}")

        return notification

    def send_websocket_notification(self, recipient, notification):
        """Отправить уведомление через WebSocket."""
        channel_layer = get_channel_layer()

        if channel_layer:
            async_to_sync(channel_layer.group_send)(
                f'notifications_{recipient.id}',
                {
                    'type': 'notification_received',
                    'notification_id': str(notification.id),
                    'title': notification.title,
                    'message': notification.message,
                    'notification_type': notification.notification_type,
                    'priority': notification.priority,
                    'link': notification.link,
                    'created_at': notification.created_at.isoformat(),
                }
            )

    def get_unread_count(self, user):
        """Получить количество непрочитанных уведомлений."""
        from apps.notifications.models import Notification

        return Notification.objects.filter(
            tenant=self.tenant,
            recipient=user,
            status='UNREAD'
        ).count()
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/notifications/views.py
    # -------------------------------------------------------------------------
    write_file "apps/notifications/views.py" << 'FILE_EOF'
"""
Представления уведомлений
"""
from django.shortcuts import render
from django.contrib.auth.decorators import login_required
from apps.notifications.models import Notification


@login_required
def notifications_list_view(request):
    """Список уведомлений пользователя."""
    notifications = Notification.objects.filter(
        tenant=request.tenant,
        recipient=request.user
    ).order_by('-created_at')[:50]

    unread_count = Notification.objects.filter(
        tenant=request.tenant,
        recipient=request.user,
        status='UNREAD'
    ).count()

    return render(request, 'notifications/list.html', {
        'notifications': notifications,
        'unread_count': unread_count,
    })
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/notifications/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/notifications/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.notifications import views

app_name = 'notifications'

urlpatterns = [
    path('', views.notifications_list_view, name='list'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/notifications/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/notifications/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.notifications.models import Notification, NotificationPreference


@admin.register(Notification)
class NotificationAdmin(admin.ModelAdmin):
    list_display = ['title', 'recipient', 'notification_type', 'priority', 'status', 'created_at']
    list_filter = ['notification_type', 'priority', 'status', 'tenant']
    search_fields = ['title', 'message']


@admin.register(NotificationPreference)
class NotificationPreferenceAdmin(admin.ModelAdmin):
    list_display = ['user', 'channel_in_app', 'channel_email', 'channel_push']
FILE_EOF

    log_success "apps/notifications записано"
}

# =============================================================================
# ШАГ 22: Приложение apps/video
# =============================================================================

write_video_app() {
    log_step "Шаг 22/9: Приложение apps/video"

    # -------------------------------------------------------------------------
    # apps/video/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/video/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class VideoConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.video'
    verbose_name = 'Видеоконференции'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/video/models.py
    # -------------------------------------------------------------------------
    write_file "apps/video/models.py" << 'FILE_EOF'
"""
Модели видеоконференций (интеграция с Jitsi)
"""
import uuid
import secrets
from django.db import models
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class VideoRoom(TenantAwareModel):
    """Комната для видеоконференций."""

    class RoomType(models.TextChoices):
        LESSON = 'LESSON', _('Урок')
        MEETING = 'MEETING', _('Собрание')
        CONSULTATION = 'CONSULTATION', _('Консультация')
        PARENT_MEETING = 'PARENT_MEETING', _('Родительское собрание')
        OTHER = 'OTHER', _('Другое')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название'), max_length=255)
    room_type = models.CharField(
        _('Тип комнаты'),
        max_length=20,
        choices=RoomType.choices,
        default=RoomType.MEETING
    )
    jitsi_room_id = models.CharField(
        _('Jitsi Room ID'),
        max_length=100,
        unique=True
    )
    description = models.TextField(_('Описание'), blank=True)
    creator = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='created_video_rooms',
        verbose_name=_('Создатель')
    )
    lesson = models.ForeignKey(
        'grades.Lesson',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='video_rooms',
        verbose_name=_('Урок')
    )
    chat = models.ForeignKey(
        'chats.Chat',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='video_rooms',
        verbose_name=_('Чат')
    )
    is_active = models.BooleanField(_('Активна'), default=True)
    is_public = models.BooleanField(_('Публичная'), default=False)
    scheduled_start = models.DateTimeField(
        _('Планируемое начало'),
        null=True,
        blank=True
    )
    scheduled_end = models.DateTimeField(
        _('Планируемое окончание'),
        null=True,
        blank=True
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)

    class Meta:
        verbose_name = _('Видеокомната')
        verbose_name_plural = _('Видеокомнаты')
        ordering = ['-created_at']

    def __str__(self):
        return self.name

    def save(self, *args, **kwargs):
        """Генерация уникального Jitsi Room ID с проверкой коллизий."""
        if not self.jitsi_room_id:
            max_attempts = 10
            for _ in range(max_attempts):
                candidate = f"{self.tenant.subdomain}-{secrets.token_hex(8)}"

                if not VideoRoom.objects.filter(jitsi_room_id=candidate).exists():
                    self.jitsi_room_id = candidate
                    break
            else:
                self.jitsi_room_id = f"{self.tenant.subdomain}-{uuid.uuid4().hex[:16]}"

        super().save(*args, **kwargs)

    @property
    def jitsi_url(self):
        """Получить URL комнаты в Jitsi."""
        from django.conf import settings
        jitsi_domain = getattr(settings, 'JITSI_DOMAIN', 'meet.jit.si')
        return f"https://{jitsi_domain}/{self.jitsi_room_id}"


class VideoSession(TenantAwareModel):
    """Сессия видеозвонка."""

    class Status(models.TextChoices):
        ACTIVE = 'ACTIVE', _('Активна')
        ENDED = 'ENDED', _('Завершена')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    room = models.ForeignKey(
        VideoRoom,
        on_delete=models.CASCADE,
        related_name='sessions',
        verbose_name=_('Комната')
    )
    user = models.ForeignKey(
        'users.User',
        on_delete=models.CASCADE,
        related_name='video_sessions',
        verbose_name=_('Пользователь')
    )
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.ACTIVE
    )
    joined_at = models.DateTimeField(_('Время подключения'), auto_now_add=True)
    left_at = models.DateTimeField(_('Время отключения'), null=True, blank=True)
    duration_seconds = models.PositiveIntegerField(
        _('Длительность (секунды)'),
        null=True,
        blank=True
    )

    class Meta:
        verbose_name = _('Сессия видеозвонка')
        verbose_name_plural = _('Сессии видеозвонков')
        ordering = ['-joined_at']

    def __str__(self):
        return f"{self.user.get_display_name()} в {self.room.name}"

    def end_session(self):
        """Завершить сессию."""
        self.status = self.Status.ENDED
        self.left_at = timezone.now()

        if self.joined_at and self.left_at:
            delta = self.left_at - self.joined_at
            self.duration_seconds = int(delta.total_seconds())

        self.save()
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/video/services.py
    # -------------------------------------------------------------------------
    write_file "apps/video/services.py" << 'FILE_EOF'
"""
Сервис для работы с Jitsi видеоконференциями
"""
from django.db import transaction
import logging

logger = logging.getLogger(__name__)


class JitsiService:
    """Сервис для управления видеоконференциями."""

    def __init__(self, tenant):
        self.tenant = tenant

    @transaction.atomic
    def create_room(self, name, room_type='MEETING', creator=None,
                   lesson=None, chat=None, description='',
                   scheduled_start=None, scheduled_end=None):
        """Создать комнату для видеоконференции."""
        from apps.video.models import VideoRoom

        room = VideoRoom.objects.create(
            tenant=self.tenant,
            name=name,
            room_type=room_type,
            description=description,
            creator=creator,
            lesson=lesson,
            chat=chat,
            scheduled_start=scheduled_start,
            scheduled_end=scheduled_end,
        )

        logger.info(f"Created video room {room.id}")

        return room

    @transaction.atomic
    def join_room(self, room_id, user):
        """Пользователь подключается к комнате."""
        from apps.video.models import VideoRoom, VideoSession

        try:
            room = VideoRoom.objects.get(id=room_id, tenant=self.tenant)
        except VideoRoom.DoesNotExist:
            raise ValueError('Комната не найдена')

        existing_session = VideoSession.objects.filter(
            tenant=self.tenant,
            room=room,
            user=user,
            status=VideoSession.Status.ACTIVE
        ).first()

        if existing_session:
            return existing_session

        session = VideoSession.objects.create(
            tenant=self.tenant,
            room=room,
            user=user,
            status=VideoSession.Status.ACTIVE,
        )

        return session

    @transaction.atomic
    def leave_room(self, session_id):
        """Пользователь покидает комнату."""
        from apps.video.models import VideoSession

        try:
            session = VideoSession.objects.get(id=session_id, tenant=self.tenant)
        except VideoSession.DoesNotExist:
            raise ValueError('Сессия не найдена')

        session.end_session()

        return session

    def get_room_url(self, room):
        """Получить URL комнаты в Jitsi."""
        return room.jitsi_url
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/video/views.py
    # -------------------------------------------------------------------------
    write_file "apps/video/views.py" << 'FILE_EOF'
"""
Представления видеоконференций
"""
from django.shortcuts import render, redirect, get_object_or_404
from django.contrib import messages
from django.contrib.auth.decorators import login_required
from apps.video.models import VideoRoom
from apps.video.services import JitsiService


@login_required
def video_rooms_view(request):
    """Список видеокомнат."""
    rooms = VideoRoom.objects.filter(
        tenant=request.tenant,
        is_active=True
    ).order_by('-created_at')

    return render(request, 'video/rooms.html', {'rooms': rooms})


@login_required
def video_room_view(request, room_id):
    """Комната видеоконференции."""
    room = get_object_or_404(VideoRoom, id=room_id, tenant=request.tenant)

    service = JitsiService(request.tenant)
    service.join_room(room_id, request.user)

    return render(request, 'video/room.html', {
        'room': room,
        'jitsi_url': room.jitsi_url,
    })
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/video/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/video/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.video import views

app_name = 'video'

urlpatterns = [
    path('', views.video_rooms_view, name='rooms'),
    path('<uuid:room_id>/', views.video_room_view, name='room'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/video/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/video/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.video.models import VideoRoom, VideoSession


@admin.register(VideoRoom)
class VideoRoomAdmin(admin.ModelAdmin):
    list_display = ['name', 'room_type', 'jitsi_room_id', 'is_active', 'created_at']
    list_filter = ['room_type', 'is_active', 'tenant']
    search_fields = ['name']


@admin.register(VideoSession)
class VideoSessionAdmin(admin.ModelAdmin):
    list_display = ['user', 'room', 'status', 'joined_at', 'left_at', 'duration_seconds']
    list_filter = ['status', 'tenant']
FILE_EOF

    log_success "apps/video записано"
}

# =============================================================================
# СТРАНИЦА 7 ЗАВЕРШЕНА
# =============================================================================
#!/bin/bash
# =============================================================================
# СТРАНИЦА 8 / СТРАНИЦА 11
# =============================================================================
# Содержимое этой страницы:
#   Шаг 23: Приложение apps/analytics (аналитика)
#   Шаг 24: Приложение apps/reports (отчёты)
#   Шаг 25: Приложение apps/api_external (внешний API)
#   Шаг 26: Приложение apps/webhooks (вебхуки)
#   Шаг 27: Приложение apps/integrations (интеграции)
# =============================================================================

# =============================================================================
# ШАГ 23: Приложение apps/analytics
# =============================================================================

write_analytics_app() {
    log_step "Шаг 23/9: Приложение apps/analytics"

    # -------------------------------------------------------------------------
    # apps/analytics/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/analytics/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class AnalyticsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.analytics'
    verbose_name = 'Аналитика'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/analytics/models.py
    # -------------------------------------------------------------------------
    write_file "apps/analytics/models.py" << 'FILE_EOF'
"""
Модели аналитики и отчётов
"""
import uuid
from django.db import models
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class Report(TenantAwareModel):
    """Сгенерированный отчёт."""

    class ReportType(models.TextChoices):
        ACADEMIC_PERFORMANCE = 'ACADEMIC_PERFORMANCE', _('Успеваемость')
        ATTENDANCE = 'ATTENDANCE', _('Посещаемость')
        CLASS_PROGRESS = 'CLASS_PROGRESS', _('Прогресс класса')
        TEACHER_LOAD = 'TEACHER_LOAD', _('Нагрузка учителей')
        STUDENT_PROGRESS = 'STUDENT_PROGRESS', _('Прогресс ученика')
        EXAM_RESULTS = 'EXAM_RESULTS', _('Результаты экзаменов')
        CUSTOM = 'CUSTOM', _('Пользовательский')

    class Format(models.TextChoices):
        PDF = 'PDF', _('PDF')
        EXCEL = 'EXCEL', _('Excel')
        CSV = 'CSV', _('CSV')

    class Status(models.TextChoices):
        PENDING = 'PENDING', _('В обработке')
        COMPLETED = 'COMPLETED', _('Готов')
        FAILED = 'FAILED', _('Ошибка')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    report_type = models.CharField(
        _('Тип отчёта'),
        max_length=30,
        choices=ReportType.choices,
        default=ReportType.CUSTOM
    )
    name = models.CharField(_('Название'), max_length=255)
    description = models.TextField(_('Описание'), blank=True)
    format = models.CharField(
        _('Формат'),
        max_length=20,
        choices=Format.choices,
        default=Format.PDF
    )
    file = models.FileField(_('Файл отчёта'), upload_to='reports/', null=True, blank=True)
    parameters = models.JSONField(_('Параметры'), default=dict, blank=True)
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.PENDING
    )
    error_message = models.TextField(_('Сообщение об ошибке'), blank=True)
    requested_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='requested_reports',
        verbose_name=_('Запрошен')
    )
    period_start = models.DateField(_('Начало периода'), null=True, blank=True)
    period_end = models.DateField(_('Окончание периода'), null=True, blank=True)
    generated_at = models.DateTimeField(_('Дата генерации'), null=True, blank=True)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)

    class Meta:
        verbose_name = _('Отчёт')
        verbose_name_plural = _('Отчёты')
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['tenant', 'status']),
        ]

    def __str__(self):
        return self.name

    @property
    def is_ready(self):
        return self.status == self.Status.COMPLETED


class DashboardConfig(TenantAwareModel):
    """Конфигурация дашборда."""

    class DashboardType(models.TextChoices):
        ADMIN = 'ADMIN', _('Администратор')
        TEACHER = 'TEACHER', _('Учитель')
        STUDENT = 'STUDENT', _('Ученик')
        PARENT = 'PARENT', _('Родитель')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    user = models.OneToOneField(
        'users.User',
        on_delete=models.CASCADE,
        related_name='dashboard_config',
        verbose_name=_('Пользователь')
    )
    dashboard_type = models.CharField(
        _('Тип дашборда'),
        max_length=20,
        choices=DashboardType.choices,
        default=DashboardType.STUDENT
    )
    widgets = models.JSONField(_('Виджеты'), default=list, blank=True)
    theme = models.CharField(_('Тема'), max_length=50, default='default')
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Конфигурация дашборда')
        verbose_name_plural = _('Конфигурации дашбордов')

    def __str__(self):
        return f"Дашборд {self.user.get_display_name()}"
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/analytics/services/academic.py
    # -------------------------------------------------------------------------
    write_file "apps/analytics/services/academic.py" << 'FILE_EOF'
"""
Сервисы аналитики успеваемости
"""
import logging

logger = logging.getLogger(__name__)


class AcademicAnalyticsService:
    """Сервис аналитики успеваемости."""

    def __init__(self, tenant):
        self.tenant = tenant

    def get_school_average(self, period_start=None, period_end=None):
        """Получить средний балл по школе."""
        from apps.grades.models import Grade

        grades = Grade.objects.filter(
            tenant=self.tenant,
            is_visible_to_student=True
        )

        if period_start:
            grades = grades.filter(lesson__lesson_date__gte=period_start)
        if period_end:
            grades = grades.filter(lesson__lesson_date__lte=period_end)

        grades_data = list(grades.values('value', 'weight'))

        if not grades_data:
            return {'average': 0, 'count': 0}

        total_weighted = 0
        total_weight = 0

        for g in grades_data:
            try:
                value = float(g['value'])
                weight = float(g['weight'])
                total_weighted += value * weight
                total_weight += weight
            except (TypeError, ValueError):
                continue

        average = round(total_weighted / total_weight, 2) if total_weight > 0 else 0

        return {'average': average, 'count': len(grades_data)}

    def get_grade_distribution(self, period_start=None, period_end=None):
        """Получить распределение оценок."""
        from apps.grades.models import Grade

        grades = Grade.objects.filter(
            tenant=self.tenant,
            is_visible_to_student=True
        )

        if period_start:
            grades = grades.filter(lesson__lesson_date__gte=period_start)
        if period_end:
            grades = grades.filter(lesson__lesson_date__lte=period_end)

        distribution = {2: 0, 3: 0, 4: 0, 5: 0}

        for grade in grades:
            if grade.value in distribution:
                distribution[grade.value] += 1

        total = sum(distribution.values())

        percentages = {}
        for value, count in distribution.items():
            percentages[value] = round((count / total * 100), 1) if total > 0 else 0

        return {
            'counts': distribution,
            'percentages': percentages,
            'total': total,
        }

    def get_top_students(self, limit=10, period_start=None, period_end=None):
        """Получить лучших учеников."""
        from apps.stubs.models import Student
        from apps.grades.models import Grade

        students = Student.objects.filter(tenant=self.tenant)

        student_averages = []
        for student in students:
            grades = Grade.objects.filter(
                tenant=self.tenant,
                student=student,
                is_visible_to_student=True
            )

            if period_start:
                grades = grades.filter(lesson__lesson_date__gte=period_start)
            if period_end:
                grades = grades.filter(lesson__lesson_date__lte=period_end)

            grades_data = list(grades.values('value', 'weight'))

            if grades_data:
                total_weighted = sum(
                    float(g['value']) * float(g['weight']) for g in grades_data
                )
                total_weight = sum(float(g['weight']) for g in grades_data)
                average = round(total_weighted / total_weight, 2) if total_weight > 0 else 0

                student_averages.append({
                    'student': student,
                    'average': average,
                })

        student_averages.sort(key=lambda x: x['average'], reverse=True)

        return student_averages[:limit]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/analytics/views.py
    # -------------------------------------------------------------------------
    write_file "apps/analytics/views.py" << 'FILE_EOF'
"""
Представления раздела «Аналитика»
"""
from django.shortcuts import render
from django.contrib.auth.decorators import login_required
from django.utils import timezone
from apps.users.permissions import admin_required
from apps.analytics.services.academic import AcademicAnalyticsService
from apps.analytics.models import Report


@login_required
@admin_required
def admin_dashboard_view(request):
    """Дашборд администратора."""
    academic_service = AcademicAnalyticsService(request.tenant)

    end_date = timezone.now().date()
    start_date = end_date.replace(day=1)

    school_average = academic_service.get_school_average(start_date, end_date)
    grade_distribution = academic_service.get_grade_distribution(start_date, end_date)
    top_students = academic_service.get_top_students(
        limit=10,
        period_start=start_date,
        period_end=end_date
    )

    return render(request, 'analytics/admin_dashboard.html', {
        'school_average': school_average,
        'grade_distribution': grade_distribution,
        'top_students': top_students,
        'period_start': start_date,
        'period_end': end_date,
    })


@login_required
@admin_required
def reports_list_view(request):
    """Список отчётов."""
    reports = Report.objects.filter(tenant=request.tenant).order_by('-created_at')

    return render(request, 'analytics/reports_list.html', {'reports': reports})
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/analytics/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/analytics/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.analytics import views

app_name = 'analytics'

urlpatterns = [
    path('', views.admin_dashboard_view, name='dashboard'),
    path('reports/', views.reports_list_view, name='reports'),
]
FILE_EOF

    log_success "apps/analytics записано"
}

# =============================================================================
# ШАГ 24: Приложение apps/reports
# =============================================================================

write_reports_app() {
    log_step "Шаг 24/9: Приложение apps/reports"

    # -------------------------------------------------------------------------
    # apps/reports/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/reports/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class ReportsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.reports'
    verbose_name = 'Отчёты'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/reports/services.py
    # -------------------------------------------------------------------------
    write_file "apps/reports/services.py" << 'FILE_EOF'
"""
Сервис генерации отчётов
"""
from django.db import transaction
import io
import logging

logger = logging.getLogger(__name__)


class ReportGeneratorService:
    """Сервис генерации отчётов."""

    def __init__(self, tenant, user):
        self.tenant = tenant
        self.user = user

    @transaction.atomic
    def create_report(self, report_type, name, format='PDF',
                     period_start=None, period_end=None, parameters=None):
        """Создать отчёт и запустить генерацию."""
        from apps.analytics.models import Report

        report = Report.objects.create(
            tenant=self.tenant,
            report_type=report_type,
            name=name,
            format=format,
            period_start=period_start,
            period_end=period_end,
            parameters=parameters or {},
            requested_by=self.user,
            status=Report.Status.PENDING,
        )

        from apps.reports.tasks import generate_report_task
        generate_report_task.delay(str(report.id))

        return report

    def generate_academic_report(self, report):
        """Сгенерировать отчёт об успеваемости."""
        from apps.analytics.services.academic import AcademicAnalyticsService

        academic_service = AcademicAnalyticsService(self.tenant)

        school_average = academic_service.get_school_average(
            report.period_start,
            report.period_end
        )

        grade_distribution = academic_service.get_grade_distribution(
            report.period_start,
            report.period_end
        )

        if report.format == 'EXCEL':
            return self._generate_excel_report(school_average, grade_distribution)
        elif report.format == 'CSV':
            return self._generate_csv_report(school_average, grade_distribution)
        else:
            return self._generate_pdf_report(school_average, grade_distribution)

    def _generate_excel_report(self, school_average, grade_distribution):
        """Генерация Excel отчёта."""
        from openpyxl import Workbook

        workbook = Workbook()
        sheet = workbook.active
        sheet.title = 'Успеваемость'

        sheet.append(['Показатель', 'Значение'])
        sheet.append(['Средний балл', school_average['average']])
        sheet.append(['Всего оценок', school_average['count']])
        sheet.append([])
        sheet.append(['Распределение оценок'])

        for value, count in grade_distribution['counts'].items():
            sheet.append([f'Оценка {value}', count])

        output = io.BytesIO()
        workbook.save(output)
        output.seek(0)

        return output

    def _generate_csv_report(self, school_average, grade_distribution):
        """Генерация CSV отчёта."""
        import csv

        output = io.StringIO()
        writer = csv.writer(output)

        writer.writerow(['Показатель', 'Значение'])
        writer.writerow(['Средний балл', school_average['average']])
        writer.writerow(['Всего оценок', school_average['count']])
        writer.writerow([])
        writer.writerow(['Распределение оценок'])

        for value, count in grade_distribution['counts'].items():
            writer.writerow([f'Оценка {value}', count])

        csv_bytes = io.BytesIO(output.getvalue().encode('utf-8'))
        csv_bytes.seek(0)

        return csv_bytes

    def _generate_pdf_report(self, school_average, grade_distribution):
        """Генерация PDF отчёта (заглушка)."""
        # В продакшене использовать WeasyPrint
        logger.info("PDF generation not yet implemented")
        return None
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/reports/tasks.py
    # -------------------------------------------------------------------------
    write_file "apps/reports/tasks.py" << 'FILE_EOF'
"""
Celery задачи для генерации отчётов
"""
from celery import shared_task
from django.utils import timezone
import logging

logger = logging.getLogger(__name__)


@shared_task(bind=True, max_retries=3)
def generate_report_task(self, report_id):
    """Асинхронная задача генерации отчёта."""
    try:
        from apps.analytics.models import Report

        report = Report.objects.get(id=report_id)

        logger.info(f"Starting report generation: {report_id}")

        from apps.reports.services import ReportGeneratorService

        service = ReportGeneratorService(report.tenant, report.requested_by)
        file_content = service.generate_academic_report(report)

        if file_content:
            from django.core.files.base import ContentFile

            extensions = {
                'PDF': 'pdf',
                'EXCEL': 'xlsx',
                'CSV': 'csv',
            }
            extension = extensions.get(report.format, 'pdf')
            file_name = f"{report.report_type}_{report.id}.{extension}"

            report.file.save(file_name, ContentFile(file_content.read()), save=False)
            report.status = Report.Status.COMPLETED
            report.generated_at = timezone.now()
        else:
            report.status = Report.Status.FAILED
            report.error_message = 'Не удалось сгенерировать файл'

        report.save()

        logger.info(f"Report {report_id} generated successfully")

    except Exception as e:
        logger.error(f"Error generating report {report_id}: {str(e)}", exc_info=True)
        raise self.retry(exc=e, countdown=60)
FILE_EOF

    log_success "apps/reports записано"
}

# =============================================================================
# ШАГ 25: Приложение apps/api_external
# =============================================================================

write_api_external_app() {
    log_step "Шаг 25/9: Приложение apps/api_external"

    # -------------------------------------------------------------------------
    # apps/api_external/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/api_external/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class ApiExternalConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.api_external'
    verbose_name = 'Внешний API'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/api_external/models.py
    # -------------------------------------------------------------------------
    write_file "apps/api_external/models.py" << 'FILE_EOF'
"""
Модели внешнего API
"""
import uuid
import secrets
import hashlib
from django.db import models
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class ApiApplication(TenantAwareModel):
    """Приложение (клиент) для доступа к внешнему API."""

    class Status(models.TextChoices):
        ACTIVE = 'ACTIVE', _('Активно')
        SUSPENDED = 'SUSPENDED', _('Приостановлено')
        REVOKED = 'REVOKED', _('Отозвано')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название'), max_length=255)
    description = models.TextField(_('Описание'), blank=True)
    client_id = models.CharField(_('Client ID'), max_length=100, unique=True)
    client_secret_hash = models.CharField(_('Client Secret (hash)'), max_length=255)
    allowed_scopes = models.JSONField(_('Разрешённые scopes'), default=list)
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.ACTIVE
    )
    requests_per_minute = models.PositiveIntegerField(_('Запросов в минуту'), default=60)
    requests_per_day = models.PositiveIntegerField(_('Запросов в день'), default=10000)
    created_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='created_api_applications',
        verbose_name=_('Создано')
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)
    last_used_at = models.DateTimeField(_('Последнее использование'), null=True, blank=True)

    class Meta:
        verbose_name = _('Приложение внешнего API')
        verbose_name_plural = _('Приложения внешнего API')
        ordering = ['-created_at']

    def __str__(self):
        return self.name

    def save(self, *args, **kwargs):
        if not self.client_id:
            self.client_id = secrets.token_urlsafe(32)

        if not self.client_secret_hash:
            secret = secrets.token_urlsafe(32)
            self.set_client_secret(secret)
            self._generated_secret = secret

        super().save(*args, **kwargs)

    def set_client_secret(self, secret):
        """Установить и хэшировать client secret."""
        self.client_secret_hash = hashlib.sha256(secret.encode()).hexdigest()

    def verify_client_secret(self, secret):
        """Проверить client secret."""
        secret_hash = hashlib.sha256(secret.encode()).hexdigest()
        return secrets.compare_digest(secret_hash, self.client_secret_hash)

    def is_active(self):
        """Проверка активности приложения."""
        return self.status == self.Status.ACTIVE

    def has_scope(self, scope):
        """Проверить наличие scope."""
        return scope in self.allowed_scopes


class ApiKey(TenantAwareModel):
    """API ключ для аутентификации."""

    class Status(models.TextChoices):
        ACTIVE = 'ACTIVE', _('Активен')
        REVOKED = 'REVOKED', _('Отозван')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название'), max_length=255)
    key_hash = models.CharField(_('Ключ (hash)'), max_length=255, unique=True)
    key_prefix = models.CharField(_('Префикс ключа'), max_length=10)
    application = models.ForeignKey(
        ApiApplication,
        on_delete=models.CASCADE,
        related_name='api_keys',
        verbose_name=_('Приложение')
    )
    allowed_scopes = models.JSONField(_('Разрешённые scopes'), default=list, blank=True)
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.ACTIVE
    )
    expires_at = models.DateTimeField(_('Действует до'), null=True, blank=True)
    created_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='created_api_keys',
        verbose_name=_('Создано')
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    last_used_at = models.DateTimeField(_('Последнее использование'), null=True, blank=True)

    class Meta:
        verbose_name = _('API ключ')
        verbose_name_plural = _('API ключи')
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.name} ({self.key_prefix}...)"

    @classmethod
    def generate_key(cls):
        """Сгенерировать новый API ключ."""
        return f"sk_live_{secrets.token_urlsafe(48)}"

    def set_key(self, key):
        """Установить и хэшировать ключ."""
        self.key_prefix = key[:10]
        self.key_hash = hashlib.sha256(key.encode()).hexdigest()

    def verify_key(self, key):
        """Проверить ключ."""
        key_hash = hashlib.sha256(key.encode()).hexdigest()
        return secrets.compare_digest(key_hash, self.key_hash)

    def is_active(self):
        """Проверка активности ключа."""
        if self.status != self.Status.ACTIVE:
            return False

        if self.expires_at and self.expires_at < timezone.now():
            return False

        return True

    def get_scopes(self):
        """Получить разрешённые scopes."""
        if self.allowed_scopes:
            return self.allowed_scopes
        return self.application.allowed_scopes


class ApiToken(TenantAwareModel):
    """Токен доступа для OAuth2."""

    class TokenType(models.TextChoices):
        ACCESS = 'ACCESS', _('Access token')
        REFRESH = 'REFRESH', _('Refresh token')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    token_hash = models.CharField(_('Токен (hash)'), max_length=255, unique=True)
    token_type = models.CharField(
        _('Тип токена'),
        max_length=20,
        choices=TokenType.choices,
        default=TokenType.ACCESS
    )
    application = models.ForeignKey(
        ApiApplication,
        on_delete=models.CASCADE,
        related_name='tokens',
        verbose_name=_('Приложение')
    )
    scopes = models.JSONField(_('Scopes'), default=list)
    expires_at = models.DateTimeField(_('Действует до'))
    is_revoked = models.BooleanField(_('Отозван'), default=False)
    revoked_at = models.DateTimeField(_('Дата отзыва'), null=True, blank=True)
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    last_used_at = models.DateTimeField(_('Последнее использование'), null=True, blank=True)

    class Meta:
        verbose_name = _('Токен доступа')
        verbose_name_plural = _('Токены доступа')
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.token_type} для {self.application.name}"

    @classmethod
    def generate_token(cls):
        """Сгенерировать новый токен."""
        return secrets.token_urlsafe(64)

    def set_token(self, token):
        """Установить и хэшировать токен."""
        self.token_hash = hashlib.sha256(token.encode()).hexdigest()

    def verify_token(self, token):
        """Проверить токен."""
        token_hash = hashlib.sha256(token.encode()).hexdigest()
        return secrets.compare_digest(token_hash, self.token_hash)

    def is_valid(self):
        """Проверка валидности токена."""
        if self.is_revoked:
            return False

        if self.expires_at < timezone.now():
            return False

        return True

    def has_scope(self, scope):
        """Проверить наличие scope."""
        return scope in self.scopes

    def revoke(self):
        """Отозвать токен."""
        self.is_revoked = True
        self.revoked_at = timezone.now()
        self.save(update_fields=['is_revoked', 'revoked_at'])

    def refresh(self, additional_seconds=3600):
        """Продлить токен."""
        from datetime import timedelta

        if self.is_revoked:
            return False

        if self.expires_at < timezone.now():
            return False

        self.expires_at = self.expires_at + timedelta(seconds=additional_seconds)
        self.save(update_fields=['expires_at'])

        return True
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/api_external/authentication.py
    # -------------------------------------------------------------------------
    write_file "apps/api_external/authentication.py" << 'FILE_EOF'
"""
Аутентификация для внешнего API
"""
from rest_framework.authentication import BaseAuthentication
from rest_framework.exceptions import AuthenticationFailed
import hashlib


class ApiKeyAuthentication(BaseAuthentication):
    """Аутентификация по API-ключу."""

    keyword = 'Bearer'

    def authenticate(self, request):
        auth_header = request.META.get('HTTP_AUTHORIZATION', '')

        if not auth_header:
            return None

        parts = auth_header.split()

        if len(parts) != 2:
            return None

        keyword, key = parts

        if keyword.lower() != self.keyword.lower():
            return None

        if not key.startswith('sk_'):
            return None

        from apps.api_external.models import ApiKey

        key_hash = hashlib.sha256(key.encode()).hexdigest()

        try:
            api_key = ApiKey.objects.select_related(
                'application', 'tenant'
            ).get(key_hash=key_hash)
        except ApiKey.DoesNotExist:
            raise AuthenticationFailed('Неверный API ключ.')

        if not api_key.is_active():
            raise AuthenticationFailed('API ключ неактивен или истёк.')

        if not api_key.application.is_active():
            raise AuthenticationFailed('Приложение неактивно.')

        request.tenant = api_key.tenant

        return (api_key.application, api_key)

    def authenticate_header(self, request):
        return self.keyword


class OAuth2TokenAuthentication(BaseAuthentication):
    """Аутентификация по OAuth2 токену."""

    keyword = 'Bearer'

    def authenticate(self, request):
        auth_header = request.META.get('HTTP_AUTHORIZATION', '')

        if not auth_header:
            return None

        parts = auth_header.split()

        if len(parts) != 2:
            return None

        keyword, token = parts

        if keyword.lower() != self.keyword.lower():
            return None

        if token.startswith('sk_'):
            return None

        from apps.api_external.models import ApiToken

        token_hash = hashlib.sha256(token.encode()).hexdigest()

        try:
            api_token = ApiToken.objects.select_related(
                'application', 'tenant'
            ).get(token_hash=token_hash)
        except ApiToken.DoesNotExist:
            raise AuthenticationFailed('Неверный токен.')

        if not api_token.is_valid():
            raise AuthenticationFailed('Токен истёк или отозван.')

        if not api_token.application.is_active():
            raise AuthenticationFailed('Приложение неактивно.')

        request.tenant = api_token.tenant

        return (api_token.application, api_token)

    def authenticate_header(self, request):
        return self.keyword


def get_client_credentials(request):
    """Получить client credentials из запроса."""
    import base64

    auth_header = request.META.get('HTTP_AUTHORIZATION', '')

    if auth_header.startswith('Basic '):
        try:
            decoded = base64.b64decode(auth_header[6:]).decode('utf-8')
            client_id, client_secret = decoded.split(':', 1)
            return client_id, client_secret
        except Exception:
            pass

    client_id = request.data.get('client_id')
    client_secret = request.data.get('client_secret')

    if client_id and client_secret:
        return client_id, client_secret

    return None, None
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/api_external/views.py
    # -------------------------------------------------------------------------
    write_file "apps/api_external/views.py" << 'FILE_EOF'
"""
Представления внешнего API
"""
from rest_framework import viewsets, status
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated
from rest_framework.views import APIView
from django.utils import timezone
from datetime import timedelta
import logging

from apps.api_external.authentication import ApiKeyAuthentication, OAuth2TokenAuthentication
from apps.api_external.serializers import StudentSerializer, GradeSerializer
from apps.stubs.models import Student
from apps.grades.models import Grade

logger = logging.getLogger(__name__)


class ExternalApiViewSet(viewsets.ModelViewSet):
    """Базовый ViewSet для внешнего API."""

    authentication_classes = [ApiKeyAuthentication, OAuth2TokenAuthentication]
    permission_classes = [IsAuthenticated]

    required_scope = None

    def get_queryset(self):
        if not hasattr(self.request, 'tenant'):
            return self.queryset.none()

        return self.queryset.filter(tenant=self.request.tenant)

    def check_permissions(self, request):
        super().check_permissions(request)

        if self.required_scope:
            if not self.has_scope(request, self.required_scope):
                self.permission_denied(
                    request,
                    message=f'Требуется право доступа: {self.required_scope}'
                )

    def has_scope(self, request, scope):
        if not hasattr(request, 'auth') or request.auth is None:
            return False

        from apps.api_external.models import ApiKey, ApiToken

        try:
            if isinstance(request.auth, ApiKey):
                return scope in request.auth.get_scopes()
            elif isinstance(request.auth, ApiToken):
                return request.auth.has_scope(scope)
        except Exception as e:
            logger.warning(f"Error checking scope: {str(e)}")
            return False

        return False


class StudentViewSet(ExternalApiViewSet):
    """API для управления учениками."""

    queryset = Student.objects.all()
    serializer_class = StudentSerializer
    required_scope = 'students:read'

    http_method_names = ['get']


class GradeViewSet(ExternalApiViewSet):
    """API для управления оценками."""

    queryset = Grade.objects.all()
    serializer_class = GradeSerializer
    required_scope = 'grades:read'

    http_method_names = ['get']

    def get_queryset(self):
        queryset = super().get_queryset()

        student_id = self.request.query_params.get('student_id')
        if student_id:
            queryset = queryset.filter(student_id=student_id)

        return queryset


class OAuth2TokenView(APIView):
    """Эндпоинт для получения токена доступа."""

    authentication_classes = []
    permission_classes = []

    def post(self, request):
        from apps.api_external.authentication import get_client_credentials
        from apps.api_external.models import ApiApplication, ApiToken

        grant_type = request.data.get('grant_type')

        if grant_type != 'client_credentials':
            return Response({
                'error': 'unsupported_grant_type',
                'error_description': 'Поддерживается только client_credentials',
            }, status=status.HTTP_400_BAD_REQUEST)

        client_id, client_secret = get_client_credentials(request)

        if not client_id or not client_secret:
            return Response({
                'error': 'invalid_client',
                'error_description': 'Не указаны клиентские данные',
            }, status=status.HTTP_401_UNAUTHORIZED)

        try:
            application = ApiApplication.objects.get(client_id=client_id)
        except ApiApplication.DoesNotExist:
            return Response({
                'error': 'invalid_client',
                'error_description': 'Неверные клиентские данные',
            }, status=status.HTTP_401_UNAUTHORIZED)

        if not application.verify_client_secret(client_secret):
            return Response({
                'error': 'invalid_client',
                'error_description': 'Неверный клиентский секрет',
            }, status=status.HTTP_401_UNAUTHORIZED)

        if not application.is_active():
            return Response({
                'error': 'invalid_client',
                'error_description': 'Приложение неактивно',
            }, status=status.HTTP_403_FORBIDDEN)

        if application.tenant.status not in ['ACTIVE', 'TRIAL']:
            return Response({
                'error': 'invalid_client',
                'error_description': 'Тенант приложения неактивен',
            }, status=status.HTTP_403_FORBIDDEN)

        requested_scopes = request.data.get('scope', '').split()

        if requested_scopes:
            for scope in requested_scopes:
                if not application.has_scope(scope):
                    return Response({
                        'error': 'invalid_scope',
                        'error_description': f'Недопустимый scope: {scope}',
                    }, status=status.HTTP_400_BAD_REQUEST)
        else:
            requested_scopes = application.allowed_scopes

        token_value = ApiToken.generate_token()

        expires_in = 3600
        expires_at = timezone.now() + timedelta(seconds=expires_in)

        token = ApiToken.objects.create(
            tenant=application.tenant,
            application=application,
            token_type=ApiToken.TokenType.ACCESS,
            scopes=requested_scopes,
            expires_at=expires_at,
        )
        token.set_token(token_value)
        token.save()

        logger.info(f"Issued OAuth2 token for application {application.id}")

        return Response({
            'access_token': token_value,
            'token_type': 'Bearer',
            'expires_in': expires_in,
            'scope': ' '.join(requested_scopes),
        })
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/api_external/serializers.py
    # -------------------------------------------------------------------------
    write_file "apps/api_external/serializers.py" << 'FILE_EOF'
"""
Сериализаторы для внешнего API
"""
from rest_framework import serializers
from apps.stubs.models import Student
from apps.grades.models import Grade


class StudentSerializer(serializers.ModelSerializer):
    """Сериализатор ученика."""

    class Meta:
        model = Student
        fields = [
            'id', 'first_name', 'last_name', 'middle_name',
            'date_of_birth', 'enrollment_number',
        ]


class GradeSerializer(serializers.ModelSerializer):
    """Сериализатор оценки."""

    student = StudentSerializer(read_only=True)
    lesson_date = serializers.SerializerMethodField()
    subject_name = serializers.SerializerMethodField()

    class Meta:
        model = Grade
        fields = [
            'id', 'student', 'value', 'grade_type',
            'weight', 'comment', 'lesson_date', 'subject_name',
            'created_at',
        ]

    def get_lesson_date(self, obj):
        if obj.lesson:
            return obj.lesson.lesson_date
        return None

    def get_subject_name(self, obj):
        if obj.lesson and obj.lesson.schedule_item and obj.lesson.schedule_item.subject:
            return obj.lesson.schedule_item.subject.name
        return None
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/api_external/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/api_external/urls.py" << 'FILE_EOF'
from django.urls import path, include
from rest_framework.routers import DefaultRouter
from apps.api_external import views

app_name = 'api_external'

router = DefaultRouter()
router.register(r'students', views.StudentViewSet, basename='students')
router.register(r'grades', views.GradeViewSet, basename='grades')

urlpatterns = [
    path('oauth/token/', views.OAuth2TokenView.as_view(), name='oauth_token'),
    path('', include(router.urls)),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/api_external/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/api_external/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.api_external.models import ApiApplication, ApiKey, ApiToken


@admin.register(ApiApplication)
class ApiApplicationAdmin(admin.ModelAdmin):
    list_display = ['name', 'client_id', 'status', 'requests_per_minute', 'created_at']
    list_filter = ['status', 'tenant']
    search_fields = ['name', 'client_id']


@admin.register(ApiKey)
class ApiKeyAdmin(admin.ModelAdmin):
    list_display = ['name', 'key_prefix', 'application', 'status', 'expires_at']
    list_filter = ['status', 'tenant']


@admin.register(ApiToken)
class ApiTokenAdmin(admin.ModelAdmin):
    list_display = ['application', 'token_type', 'expires_at', 'is_revoked']
    list_filter = ['token_type', 'is_revoked', 'tenant']
FILE_EOF

    log_success "apps/api_external записано"
}

# =============================================================================
# ШАГ 26: Приложение apps/webhooks
# =============================================================================

write_webhooks_app() {
    log_step "Шаг 26/9: Приложение apps/webhooks"

    # -------------------------------------------------------------------------
    # apps/webhooks/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/webhooks/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class WebhooksConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.webhooks'
    verbose_name = 'Вебхуки'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/webhooks/models.py
    # -------------------------------------------------------------------------
    write_file "apps/webhooks/models.py" << 'FILE_EOF'
"""
Модели вебхуков
"""
import uuid
import secrets
from django.db import models
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


class WebhookSubscription(TenantAwareModel):
    """Подписка на вебхуки."""

    class Status(models.TextChoices):
        ACTIVE = 'ACTIVE', _('Активна')
        SUSPENDED = 'SUSPENDED', _('Приостановлена')
        REVOKED = 'REVOKED', _('Отозвана')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    name = models.CharField(_('Название'), max_length=255)
    url = models.URLField(_('URL доставки'), max_length=2000)
    secret = models.CharField(_('Секрет для подписи'), max_length=100)
    events = models.JSONField(_('События'), default=list)
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.ACTIVE
    )
    description = models.TextField(_('Описание'), blank=True)
    created_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='created_webhook_subscriptions',
        verbose_name=_('Создано')
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)
    last_delivery_at = models.DateTimeField(_('Последняя доставка'), null=True, blank=True)

    class Meta:
        verbose_name = _('Подписка на вебхуки')
        verbose_name_plural = _('Подписки на вебхуки')
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.name} → {self.url}"

    def save(self, *args, **kwargs):
        if not self.secret:
            self.secret = secrets.token_urlsafe(32)

        self.full_clean()
        super().save(*args, **kwargs)

    def clean(self):
        super().clean()

        if self.url:
            from django.core.exceptions import ValidationError

            if not self.url.startswith('https://'):
                raise ValidationError({
                    'url': 'URL должен использовать HTTPS для безопасности.'
                })

    def is_active(self):
        """Проверка активности подписки."""
        return self.status == self.Status.ACTIVE

    def is_subscribed_to(self, event_type):
        """Проверить, подписаны ли на событие."""
        for event in self.events:
            if event == event_type:
                return True
            if event.endswith('.*') and event_type.startswith(event[:-1]):
                return True
        return False

    def update_last_delivery(self):
        self.last_delivery_at = timezone.now()
        self.save(update_fields=['last_delivery_at'])


class WebhookEvent(TenantAwareModel):
    """Событие вебхука."""

    class Status(models.TextChoices):
        PENDING = 'PENDING', _('Ожидает доставки')
        DELIVERED = 'DELIVERED', _('Доставлено')
        FAILED = 'FAILED', _('Ошибка доставки')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    event_type = models.CharField(_('Тип события'), max_length=100)
    payload = models.JSONField(_('Данные события'), default=dict)
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.PENDING
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)

    class Meta:
        verbose_name = _('Событие вебхука')
        verbose_name_plural = _('События вебхуков')
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['tenant', 'event_type', 'created_at']),
        ]

    def __str__(self):
        return f"{self.event_type} ({self.created_at})"

    def get_subscribed_subscriptions(self):
        """Получить подписки для этого события."""
        subscriptions = WebhookSubscription.objects.filter(
            tenant=self.tenant,
            status=WebhookSubscription.Status.ACTIVE
        )

        return [
            sub for sub in subscriptions
            if sub.is_subscribed_to(self.event_type)
        ]

    def mark_delivered(self):
        self.status = self.Status.DELIVERED
        self.save(update_fields=['status'])

    def mark_failed(self):
        self.status = self.Status.FAILED
        self.save(update_fields=['status'])


class WebhookDelivery(TenantAwareModel):
    """Доставка вебхука."""

    class Status(models.TextChoices):
        PENDING = 'PENDING', _('Ожидает')
        SUCCESS = 'SUCCESS', _('Успешно')
        FAILED = 'FAILED', _('Ошибка')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    event = models.ForeignKey(
        WebhookEvent,
        on_delete=models.CASCADE,
        related_name='deliveries',
        verbose_name=_('Событие')
    )
    subscription = models.ForeignKey(
        WebhookSubscription,
        on_delete=models.CASCADE,
        related_name='deliveries',
        verbose_name=_('Подписка')
    )
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.PENDING
    )
    attempt = models.PositiveSmallIntegerField(_('Попытка'), default=1)
    response_status_code = models.PositiveSmallIntegerField(
        _('Код ответа'),
        null=True,
        blank=True
    )
    response_body = models.TextField(_('Тело ответа'), blank=True)
    error_message = models.TextField(_('Сообщение об ошибке'), blank=True)
    response_time_ms = models.PositiveIntegerField(
        _('Время обработки (мс)'),
        null=True,
        blank=True
    )
    created_at = models.DateTimeField(_('Дата попытки'), auto_now_add=True)
    delivered_at = models.DateTimeField(_('Дата доставки'), null=True, blank=True)

    class Meta:
        verbose_name = _('Доставка вебхука')
        verbose_name_plural = _('Доставки вебхуков')
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['tenant', 'event']),
            models.Index(fields=['tenant', 'subscription']),
            models.Index(fields=['tenant', 'status']),
        ]

    def __str__(self):
        return f"{self.event.event_type} → {self.subscription.url}"

    def mark_success(self, status_code, response_time_ms):
        self.status = self.Status.SUCCESS
        self.response_status_code = status_code
        self.response_time_ms = response_time_ms
        self.delivered_at = timezone.now()
        self.save()

    def mark_failed(self, error_message, status_code=None):
        self.status = self.Status.FAILED
        self.error_message = error_message
        if status_code:
            self.response_status_code = status_code
        self.save()
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/webhooks/services.py
    # -------------------------------------------------------------------------
    write_file "apps/webhooks/services.py" << 'FILE_EOF'
"""
Сервис для работы с вебхуками
"""
from django.db import transaction
from django.utils import timezone
import hmac
import hashlib
import json
import time
import logging

logger = logging.getLogger(__name__)


class WebhookService:
    """Сервис для работы с вебхуками."""

    MAX_RETRIES = 5
    RETRY_DELAYS = [1, 2, 4, 8, 16]
    REQUEST_TIMEOUT = 10

    def __init__(self, tenant):
        self.tenant = tenant

    @transaction.atomic
    def create_event(self, event_type, payload):
        """Создать событие вебхука."""
        from apps.webhooks.models import WebhookEvent

        event = WebhookEvent.objects.create(
            tenant=self.tenant,
            event_type=event_type,
            payload=payload,
        )

        logger.info(f"Created webhook event {event.id}: {event_type}")

        from apps.webhooks.tasks import deliver_webhooks_task
        deliver_webhooks_task.delay(str(event.id))

        return event

    def deliver_event(self, event_id):
        """Доставить событие всем подписчикам."""
        from apps.webhooks.models import WebhookEvent

        try:
            event = WebhookEvent.objects.get(id=event_id, tenant=self.tenant)
        except WebhookEvent.DoesNotExist:
            logger.error(f"Webhook event {event_id} does not exist")
            return

        subscriptions = event.get_subscribed_subscriptions()

        if not subscriptions:
            event.mark_delivered()
            return

        for subscription in subscriptions:
            self.deliver_to_subscription(event, subscription)

        event.mark_delivered()

    def deliver_to_subscription(self, event, subscription):
        """Доставить событие конкретной подписке."""
        import requests
        from apps.webhooks.models import WebhookDelivery

        payload = self.build_payload(event)
        signature = self.generate_signature(payload, subscription.secret)

        headers = {
            'Content-Type': 'application/json',
            'User-Agent': 'SchoolCRM-Webhooks/1.0',
            'X-Webhook-Id': str(event.id),
            'X-Webhook-Event': event.event_type,
            'X-Webhook-Timestamp': str(int(timezone.now().timestamp())),
            'X-Webhook-Signature': signature,
            'X-Webhook-Signature-256': f"sha256={signature}",
        }

        for attempt in range(1, self.MAX_RETRIES + 1):
            delivery = WebhookDelivery.objects.create(
                tenant=self.tenant,
                event=event,
                subscription=subscription,
                attempt=attempt,
            )

            try:
                start_time = time.time()

                response = requests.post(
                    subscription.url,
                    json=payload,
                    headers=headers,
                    timeout=self.REQUEST_TIMEOUT,
                    allow_redirects=False,
                    verify=True,
                )

                response_time_ms = int((time.time() - start_time) * 1000)

                if 200 <= response.status_code < 300:
                    delivery.mark_success(response.status_code, response_time_ms)
                    subscription.update_last_delivery()

                    logger.info(
                        f"Webhook delivered: {event.event_type} → {subscription.url} "
                        f"(attempt {attempt})"
                    )
                    return True
                else:
                    response_text = response.text[:500] if response.text else ""
                    delivery.mark_failed(
                        f"HTTP {response.status_code}: {response_text}",
                        response.status_code
                    )

            except requests.exceptions.Timeout:
                delivery.mark_failed('Timeout')

            except requests.exceptions.RequestException as e:
                error_msg = str(e)[:200]
                delivery.mark_failed(f"Request error: {error_msg}")

            except Exception as e:
                error_msg = str(e)[:200]
                delivery.mark_failed(f"Unexpected error: {error_msg}")

            if attempt < self.MAX_RETRIES:
                delay = self.RETRY_DELAYS[attempt - 1]
                time.sleep(delay)

        logger.error(
            f"Webhook delivery failed after {self.MAX_RETRIES} attempts: "
            f"{event.event_type} → {subscription.url}"
        )
        return False

    def build_payload(self, event):
        """Построить данные для отправки."""
        return {
            'id': str(event.id),
            'type': event.event_type,
            'created_at': event.created_at.isoformat(),
            'tenant_id': str(self.tenant.id),
            'data': event.payload,
        }

    def generate_signature(self, payload, secret):
        """Сгенерировать подпись для вебхука."""
        try:
            payload_bytes = json.dumps(payload, sort_keys=True).encode('utf-8')
            secret_bytes = secret.encode('utf-8')

            signature = hmac.new(
                key=secret_bytes,
                msg=payload_bytes,
                digestmod=hashlib.sha256
            ).hexdigest()

            return signature

        except Exception as e:
            logger.error(f"Error generating signature: {str(e)}")
            return ""

    def verify_signature(self, payload, signature, secret):
        """Проверить подпись вебхука."""
        try:
            expected_signature = self.generate_signature(payload, secret)
            return hmac.compare_digest(signature, expected_signature)
        except Exception as e:
            logger.error(f"Error verifying signature: {str(e)}")
            return False


class WebhookEmitter:
    """Эмиттер событий вебхуков."""

    def __init__(self, tenant):
        self.tenant = tenant
        self.service = WebhookService(tenant)

    def emit_student_created(self, student):
        """Событие: ученик создан."""
        self.service.create_event(
            event_type='student.created',
            payload={
                'id': str(student.id),
                'first_name': student.first_name,
                'last_name': student.last_name,
            }
        )

    def emit_grade_created(self, grade):
        """Событие: оценка выставлена."""
        self.service.create_event(
            event_type='grade.created',
            payload={
                'id': str(grade.id),
                'student_id': str(grade.student_id),
                'value': grade.value,
            }
        )
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/webhooks/tasks.py
    # -------------------------------------------------------------------------
    write_file "apps/webhooks/tasks.py" << 'FILE_EOF'
"""
Celery задачи для доставки вебхуков
"""
from celery import shared_task
import logging

logger = logging.getLogger(__name__)


@shared_task(bind=True, max_retries=3)
def deliver_webhooks_task(self, event_id):
    """Асинхронная задача доставки вебхуков."""
    try:
        from apps.webhooks.models import WebhookEvent

        event = WebhookEvent.objects.get(id=event_id)

        logger.info(f"Starting webhook delivery for event {event_id}")

        from apps.webhooks.services import WebhookService

        service = WebhookService(event.tenant)
        service.deliver_event(event_id)

        logger.info(f"Webhook delivery completed for event {event_id}")

    except Exception as e:
        logger.error(f"Error delivering webhooks for event {event_id}: {str(e)}", exc_info=True)
        raise self.retry(exc=e, countdown=60)
FILE_EOF

    log_success "apps/webhooks записано"
}

# =============================================================================
# ШАГ 27: Приложение apps/integrations
# =============================================================================

write_integrations_app() {
    log_step "Шаг 27/9: Приложение apps/integrations"

    # -------------------------------------------------------------------------
    # apps/integrations/apps.py
    # -------------------------------------------------------------------------
    write_file "apps/integrations/apps.py" << 'FILE_EOF'
from django.apps import AppConfig


class IntegrationsConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.integrations'
    verbose_name = 'Интеграции'
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/integrations/models.py
    # -------------------------------------------------------------------------
    write_file "apps/integrations/models.py" << 'FILE_EOF'
"""
Модели интеграций с внешними системами
"""
import uuid
import base64
import hashlib
from django.db import models
from django.conf import settings
from django.core.exceptions import ValidationError
from django.utils import timezone
from django.utils.translation import gettext_lazy as _
from apps.tenants.managers import TenantAwareModel


def encrypt_secret(plain_text):
    """Зашифровать секретные данные."""
    if not plain_text:
        return ''

    key = hashlib.sha256(settings.SECRET_KEY.encode()).digest()

    encrypted_bytes = bytes(
        b ^ key[i % len(key)]
        for i, b in enumerate(plain_text.encode())
    )

    return base64.b64encode(encrypted_bytes).decode()


def decrypt_secret(encrypted_text):
    """Расшифровать секретные данные."""
    if not encrypted_text:
        return ''

    try:
        key = hashlib.sha256(settings.SECRET_KEY.encode()).digest()

        encrypted_bytes = base64.b64decode(encrypted_text.encode())

        decrypted_bytes = bytes(
            b ^ key[i % len(key)]
            for i, b in enumerate(encrypted_bytes)
        )

        return decrypted_bytes.decode()
    except Exception:
        return ''


class Integration(TenantAwareModel):
    """Настройка интеграции с внешней системой."""

    class IntegrationType(models.TextChoices):
        NETWORK_CITY = 'NETWORK_CITY', _('Сетевой Город')
        ELJUR = 'ELJUR', _('ЭлЖур')
        GIS = 'GIS', _('ГИС-системы')
        CUSTOM = 'CUSTOM', _('Пользовательская')

    class Status(models.TextChoices):
        NOT_CONFIGURED = 'NOT_CONFIGURED', _('Не настроена')
        CONFIGURED = 'CONFIGURED', _('Настроена')
        ACTIVE = 'ACTIVE', _('Активна')
        SUSPENDED = 'SUSPENDED', _('Приостановлена')
        ERROR = 'ERROR', _('Ошибка')

    class SyncDirection(models.TextChoices):
        IMPORT = 'IMPORT', _('Только импорт')
        EXPORT = 'EXPORT', _('Только экспорт')
        BIDIRECTIONAL = 'BIDIRECTIONAL', _('Двусторонняя')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    integration_type = models.CharField(
        _('Тип интеграции'),
        max_length=30,
        choices=IntegrationType.choices,
        default=IntegrationType.CUSTOM
    )
    name = models.CharField(_('Название'), max_length=255)
    description = models.TextField(_('Описание'), blank=True)
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.NOT_CONFIGURED
    )
    sync_direction = models.CharField(
        _('Направление синхронизации'),
        max_length=20,
        choices=SyncDirection.choices,
        default=SyncDirection.IMPORT
    )
    api_url = models.URLField(_('URL API'), max_length=500, blank=True)
    api_key_encrypted = models.TextField(
        _('API ключ (шифрованный)'),
        blank=True,
        help_text=_('Хранится в зашифрованном виде')
    )
    api_secret_encrypted = models.TextField(
        _('API секрет (шифрованный)'),
        blank=True,
        help_text=_('Хранится в зашифрованном виде')
    )
    username = models.CharField(_('Имя пользователя'), max_length=255, blank=True)
    password_encrypted = models.TextField(
        _('Пароль (шифрованный)'),
        blank=True,
        help_text=_('Хранится в зашифрованном виде')
    )
    config = models.JSONField(_('Дополнительные настройки'), default=dict, blank=True)
    auto_sync_enabled = models.BooleanField(_('Автоматическая синхронизация'), default=False)
    sync_cron = models.CharField(_('Cron-выражение'), max_length=100, blank=True)
    last_sync_at = models.DateTimeField(_('Последняя синхронизация'), null=True, blank=True)
    total_syncs = models.PositiveIntegerField(_('Всего синхронизаций'), default=0)
    failed_syncs = models.PositiveIntegerField(_('Неудачных синхронизаций'), default=0)
    created_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='created_integrations',
        verbose_name=_('Создано')
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)
    updated_at = models.DateTimeField(_('Дата обновления'), auto_now=True)

    class Meta:
        verbose_name = _('Интеграция')
        verbose_name_plural = _('Интеграции')
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['tenant', 'integration_type']),
            models.Index(fields=['tenant', 'status']),
        ]

    def __str__(self):
        return f"{self.name} ({self.get_integration_type_display()})"

    def set_api_key(self, plain_key):
        """Установить API ключ (шифрует при сохранении)."""
        self.api_key_encrypted = encrypt_secret(plain_key)

    def get_api_key(self):
        """Получить расшифрованный API ключ."""
        return decrypt_secret(self.api_key_encrypted)

    def set_api_secret(self, plain_secret):
        """Установить API секрет."""
        self.api_secret_encrypted = encrypt_secret(plain_secret)

    def get_api_secret(self):
        """Получить расшифрованный API секрет."""
        return decrypt_secret(self.api_secret_encrypted)

    def set_password(self, plain_password):
        """Установить пароль."""
        self.password_encrypted = encrypt_secret(plain_password)

    def get_password(self):
        """Получить расшифрованный пароль."""
        return decrypt_secret(self.password_encrypted)

    @property
    def is_active(self):
        return self.status == self.Status.ACTIVE

    @property
    def success_rate(self):
        if self.total_syncs == 0:
            return 0
        successful = self.total_syncs - self.failed_syncs
        return round((successful / self.total_syncs) * 100, 1)

    def update_last_sync(self):
        self.last_sync_at = timezone.now()
        self.total_syncs += 1
        self.save(update_fields=['last_sync_at', 'total_syncs'])

    def increment_failed_syncs(self):
        self.failed_syncs += 1
        self.save(update_fields=['failed_syncs'])


class IntegrationJob(TenantAwareModel):
    """Задача синхронизации."""

    class JobType(models.TextChoices):
        IMPORT_STUDENTS = 'IMPORT_STUDENTS', _('Импорт учеников')
        IMPORT_TEACHERS = 'IMPORT_TEACHERS', _('Импорт учителей')
        EXPORT_GRADES = 'EXPORT_GRADES', _('Экспорт оценок')
        EXPORT_ATTENDANCE = 'EXPORT_ATTENDANCE', _('Экспорт посещаемости')
        FULL_SYNC = 'FULL_SYNC', _('Полная синхронизация')

    class Status(models.TextChoices):
        PENDING = 'PENDING', _('В очереди')
        RUNNING = 'RUNNING', _('Выполняется')
        COMPLETED = 'COMPLETED', _('Завершено')
        FAILED = 'FAILED', _('Ошибка')
        CANCELLED = 'CANCELLED', _('Отменено')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    integration = models.ForeignKey(
        Integration,
        on_delete=models.CASCADE,
        related_name='jobs',
        verbose_name=_('Интеграция')
    )
    job_type = models.CharField(
        _('Тип задачи'),
        max_length=30,
        choices=JobType.choices,
        default=JobType.FULL_SYNC
    )
    status = models.CharField(
        _('Статус'),
        max_length=20,
        choices=Status.choices,
        default=Status.PENDING
    )
    parameters = models.JSONField(_('Параметры'), default=dict, blank=True)
    result = models.JSONField(_('Результат'), default=dict, blank=True)
    error_message = models.TextField(_('Сообщение об ошибке'), blank=True)
    started_at = models.DateTimeField(_('Время начала'), null=True, blank=True)
    finished_at = models.DateTimeField(_('Время окончания'), null=True, blank=True)
    started_by = models.ForeignKey(
        'users.User',
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name='started_integration_jobs',
        verbose_name=_('Запущено')
    )
    created_at = models.DateTimeField(_('Дата создания'), auto_now_add=True)

    class Meta:
        verbose_name = _('Задача синхронизации')
        verbose_name_plural = _('Задачи синхронизации')
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['tenant', 'integration', 'status']),
        ]

    def __str__(self):
        return f"{self.get_job_type_display()} - {self.get_status_display()}"

    @property
    def duration_seconds(self):
        if not self.started_at or not self.finished_at:
            return None
        return int((self.finished_at - self.started_at).total_seconds())

    def start(self):
        """Отметить задачу как запущенную."""
        self.status = self.Status.RUNNING
        self.started_at = timezone.now()
        self.save(update_fields=['status', 'started_at'])

    def complete(self, result=None):
        """Отметить задачу как завершённую."""
        self.status = self.Status.COMPLETED
        self.finished_at = timezone.now()
        if result:
            self.result = result
        self.save(update_fields=['status', 'finished_at', 'result'])

        self.integration.update_last_sync()

    def fail(self, error_message):
        """Отметить задачу как неудачную."""
        self.status = self.Status.FAILED
        self.finished_at = timezone.now()
        self.error_message = error_message
        self.save(update_fields=['status', 'finished_at', 'error_message'])

        self.integration.update_last_sync()
        self.integration.increment_failed_syncs()


class IntegrationLog(TenantAwareModel):
    """Лог операций синхронизации."""

    class LogLevel(models.TextChoices):
        DEBUG = 'DEBUG', _('Отладка')
        INFO = 'INFO', _('Информация')
        WARNING = 'WARNING', _('Предупреждение')
        ERROR = 'ERROR', _('Ошибка')

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    job = models.ForeignKey(
        IntegrationJob,
        on_delete=models.CASCADE,
        related_name='logs',
        verbose_name=_('Задача')
    )
    level = models.CharField(
        _('Уровень'),
        max_length=20,
        choices=LogLevel.choices,
        default=LogLevel.INFO
    )
    message = models.TextField(_('Сообщение'))
    data = models.JSONField(_('Данные'), default=dict, blank=True)
    created_at = models.DateTimeField(_('Дата записи'), auto_now_add=True)

    class Meta:
        verbose_name = _('Лог интеграции')
        verbose_name_plural = _('Логи интеграций')
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['tenant', 'job', 'level']),
        ]

    def __str__(self):
        return f"[{self.level}] {self.message[:100]}"
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/integrations/connectors/base.py
    # -------------------------------------------------------------------------
    write_file "apps/integrations/connectors/base.py" << 'FILE_EOF'
"""
Базовый коннектор для интеграций
"""
from abc import ABC, abstractmethod
import logging

logger = logging.getLogger(__name__)


class BaseConnector(ABC):
    """Абстрактный базовый коннектор."""

    CONNECTOR_NAME = 'base'
    SUPPORTED_OPERATIONS = []

    def __init__(self, integration, job=None):
        """Инициализация коннектора."""
        if integration is None:
            raise ValueError('Интеграция не может быть None')

        self.integration = integration
        self.job = job
        self.tenant = integration.tenant

    @abstractmethod
    def test_connection(self):
        """Проверить соединение с внешней системой."""
        pass

    @abstractmethod
    def import_data(self, data_type, parameters=None):
        """Импортировать данные из внешней системы."""
        pass

    @abstractmethod
    def export_data(self, data_type, parameters=None):
        """Экспортировать данные во внешнюю систему."""
        pass

    def log(self, level, message, data=None):
        """Записать сообщение в лог."""
        log_method = getattr(logger, level.lower(), logger.info)
        log_method(f"[{self.CONNECTOR_NAME}] {message}")

        if self.job:
            from apps.integrations.models import IntegrationLog

            IntegrationLog.objects.create(
                tenant=self.tenant,
                job=self.job,
                level=level,
                message=message,
                data=data or {},
            )

    def validate_credentials(self):
        """Проверить наличие учётных данных."""
        if not self.integration.api_url:
            return False

        has_api_key = bool(self.integration.get_api_key())
        has_credentials = bool(
            self.integration.username and self.integration.get_password()
        )

        return has_api_key or has_credentials


class ConnectorFactory:
    """Фабрика для создания коннекторов."""

    CONNECTORS = {}

    @classmethod
    def register(cls, integration_type, connector_class):
        """Зарегистрировать коннектор."""
        cls.CONNECTORS[integration_type] = connector_class

    @classmethod
    def get_connector(cls, integration, job=None):
        """Получить коннектор для интеграции."""
        if integration is None:
            raise ValueError('Интеграция не может быть None')

        connector_class = cls.CONNECTORS.get(integration.integration_type)

        if not connector_class:
            raise ValueError(
                f'Неподдерживаемый тип интеграции: {integration.integration_type}'
            )

        return connector_class(integration, job)

    @classmethod
    def get_available_connectors(cls):
        """Получить список доступных коннекторов."""
        return list(cls.CONNECTORS.keys())

    @classmethod
    def is_supported(cls, integration_type):
        """Проверить, поддерживается ли тип интеграции."""
        if integration_type is None:
            return False
        return integration_type in cls.CONNECTORS
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/integrations/views.py
    # -------------------------------------------------------------------------
    write_file "apps/integrations/views.py" << 'FILE_EOF'
"""
Представления раздела «Интеграции»
"""
from django.shortcuts import render, get_object_or_404
from django.contrib.auth.decorators import login_required
from apps.users.permissions import admin_required
from apps.integrations.models import Integration, IntegrationJob


@login_required
@admin_required
def integrations_list_view(request):
    """Список интеграций школы."""
    integrations = Integration.objects.filter(tenant=request.tenant)

    integration_type = request.GET.get('type', '')
    if integration_type:
        integrations = integrations.filter(integration_type=integration_type)

    status = request.GET.get('status', '')
    if status:
        integrations = integrations.filter(status=status)

    integrations = integrations.order_by('-created_at')

    return render(request, 'integrations/list.html', {
        'integrations': integrations,
        'type_filter': integration_type,
        'status_filter': status,
        'types': Integration.IntegrationType.choices,
        'statuses': Integration.Status.choices,
    })


@login_required
@admin_required
def integration_detail_view(request, integration_id):
    """Детальная информация об интеграции."""
    integration = get_object_or_404(Integration, id=integration_id, tenant=request.tenant)

    recent_jobs = IntegrationJob.objects.filter(
        tenant=request.tenant,
        integration=integration
    ).order_by('-created_at')[:10]

    return render(request, 'integrations/detail.html', {
        'integration': integration,
        'recent_jobs': recent_jobs,
    })
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/integrations/urls.py
    # -------------------------------------------------------------------------
    write_file "apps/integrations/urls.py" << 'FILE_EOF'
from django.urls import path
from apps.integrations import views

app_name = 'integrations'

urlpatterns = [
    path('', views.integrations_list_view, name='list'),
    path('<uuid:integration_id>/', views.integration_detail_view, name='detail'),
]
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/integrations/admin.py
    # -------------------------------------------------------------------------
    write_file "apps/integrations/admin.py" << 'FILE_EOF'
from django.contrib import admin
from apps.integrations.models import Integration, IntegrationJob, IntegrationLog


@admin.register(Integration)
class IntegrationAdmin(admin.ModelAdmin):
    list_display = ['name', 'integration_type', 'status', 'sync_direction', 'last_sync_at']
    list_filter = ['integration_type', 'status', 'tenant']
    search_fields = ['name']


@admin.register(IntegrationJob)
class IntegrationJobAdmin(admin.ModelAdmin):
    list_display = ['integration', 'job_type', 'status', 'started_at', 'finished_at']
    list_filter = ['job_type', 'status', 'tenant']


@admin.register(IntegrationLog)
class IntegrationLogAdmin(admin.ModelAdmin):
    list_display = ['job', 'level', 'message', 'created_at']
    list_filter = ['level', 'tenant']
FILE_EOF

    log_success "apps/integrations записано"
}

# =============================================================================
# СТРАНИЦА 8 ЗАВЕРШЕНА
# =============================================================================
#!/bin/bash
# =============================================================================
# СТРАНИЦА 9 / СТРАНИЦА 11
# =============================================================================
# Содержимое этой страницы:
#   Шаг 28: Базовые шаблоны
#   Шаг 29: Шаблоны ключевых страниц
#   Шаг 30: Статические файлы (CSS, JS)
# =============================================================================

# =============================================================================
# ШАГ 28: Базовые шаблоны
# =============================================================================

write_base_templates() {
    log_step "Шаг 28/9: Базовые шаблоны"

    # -------------------------------------------------------------------------
    # templates/base.html
    # -------------------------------------------------------------------------
    write_file "templates/base.html" << 'FILE_EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="School CRM - система управления школой">
    <title>{% block title %}School CRM{% endblock %}</title>
    
    {% load static %}
    <link rel="stylesheet" href="{% static 'css/main.css' %}">
    <link rel="stylesheet" href="{% static 'css/components.css' %}">
    
    {% block extra_css %}{% endblock %}
</head>
<body class="app-body">
    <!-- Шапка приложения -->
    <header class="app-header">
        <div class="header-container">
            <button class="menu-toggle" id="menuToggle" aria-label="Открыть меню">
                <span></span>
                <span></span>
                <span></span>
            </button>
            
            <div class="logo">
                <a href="{% url 'dashboard' %}" class="logo-link">
                    <span class="logo-icon">🏫</span>
                    <span class="logo-text">School CRM</span>
                </a>
            </div>
            
            {% if user.is_authenticated %}
            <div class="user-menu">
                <div class="user-info">
                    {% if user.avatar %}
                    <img src="{{ user.avatar.url }}" alt="{{ user.get_display_name }}" class="user-avatar">
                    {% else %}
                    <div class="user-avatar user-avatar-placeholder">
                        {{ user.first_name|first }}{{ user.last_name|first }}
                    </div>
                    {% endif %}
                    <span class="user-name">{{ user.get_display_name }}</span>
                </div>
                
                <div class="user-dropdown" id="userDropdown">
                    <button class="dropdown-toggle" aria-expanded="false">▼</button>
                    <ul class="dropdown-menu">
                        <li><a href="{% url 'users:profile' %}">👤 Профиль</a></li>
                        <li class="divider"></li>
                        <li><a href="{% url 'users:logout' %}">🚪 Выйти</a></li>
                    </ul>
                </div>
            </div>
            {% endif %}
        </div>
    </header>
    
    <div class="app-container">
        {% if user.is_authenticated %}
        <!-- Боковое меню -->
        <aside class="sidebar" id="sidebar">
            <nav class="sidebar-nav">
                <ul class="nav-list">
                    <li class="nav-item {% if request.resolver_match.url_name == 'dashboard' %}active{% endif %}">
                        <a href="{% url 'dashboard' %}" class="nav-link">
                            <span class="nav-icon">🏠</span>
                            <span class="nav-text">Главная</span>
                        </a>
                    </li>
                    
                    {% if user.is_teacher or user.is_local_admin %}
                    <li class="nav-item">
                        <a href="{% url 'grades:journal' %}" class="nav-link">
                            <span class="nav-icon">📖</span>
                            <span class="nav-text">Журнал</span>
                        </a>
                    </li>
                    {% endif %}
                    
                    {% if user.role == 'STUDENT' or user.role == 'PARENT' %}
                    <li class="nav-item">
                        <a href="{% url 'grades:diary' %}" class="nav-link">
                            <span class="nav-icon">📓</span>
                            <span class="nav-text">Дневник</span>
                        </a>
                    </li>
                    {% endif %}
                    
                    <li class="nav-item">
                        <a href="{% url 'schedule:list' %}" class="nav-link">
                            <span class="nav-icon">📅</span>
                            <span class="nav-text">Расписание</span>
                        </a>
                    </li>
                    
                    {% if user.is_local_admin %}
                    <li class="nav-item">
                        <a href="{% url 'management:dashboard' %}" class="nav-link">
                            <span class="nav-icon">⚙️</span>
                            <span class="nav-text">Управление</span>
                        </a>
                    </li>
                    
                    <li class="nav-item">
                        <a href="{% url 'references:dashboard' %}" class="nav-link">
                            <span class="nav-icon">📚</span>
                            <span class="nav-text">Справочники</span>
                        </a>
                    </li>
                    
                    <li class="nav-item">
                        <a href="{% url 'analytics:dashboard' %}" class="nav-link">
                            <span class="nav-icon">📊</span>
                            <span class="nav-text">Аналитика</span>
                        </a>
                    </li>
                    {% endif %}
                    
                    <li class="nav-item">
                        <a href="{% url 'calendar_app:calendar' %}" class="nav-link">
                            <span class="nav-icon">🗓️</span>
                            <span class="nav-text">Календарь</span>
                        </a>
                    </li>
                    
                    <li class="nav-item">
                        <a href="{% url 'news:list' %}" class="nav-link">
                            <span class="nav-icon">📰</span>
                            <span class="nav-text">Новости</span>
                        </a>
                    </li>
                    
                    <li class="nav-item">
                        <a href="{% url 'chats:messenger' %}" class="nav-link">
                            <span class="nav-icon">💬</span>
                            <span class="nav-text">Мессенджер</span>
                        </a>
                    </li>
                    
                    {% if user.is_local_admin %}
                    <li class="nav-item">
                        <a href="{% url 'integrations:list' %}" class="nav-link">
                            <span class="nav-icon">🔌</span>
                            <span class="nav-text">Интеграции</span>
                        </a>
                    </li>
                    {% endif %}
                </ul>
            </nav>
            
            {% if request.tenant %}
            <div class="sidebar-footer">
                <div class="tenant-info">
                    <span class="tenant-name">{{ request.tenant.name }}</span>
                    <span class="tenant-domain">{{ request.tenant.subdomain }}.rksh41.ru</span>
                </div>
            </div>
            {% endif %}
        </aside>
        {% endif %}
        
        <!-- Основной контент -->
        <main class="main-content">
            {% if messages %}
            <div class="messages" id="messages">
                {% for message in messages %}
                <div class="alert alert-{{ message.tags }} alert-dismissible">
                    <span class="alert-message">{{ message }}</span>
                    <button class="alert-close" aria-label="Закрыть">&times;</button>
                </div>
                {% endfor %}
            </div>
            {% endif %}
            
            {% block content %}{% endblock %}
        </main>
    </div>
    
    <footer class="app-footer">
        <div class="footer-container">
            <span class="footer-text">© 2025 School CRM. Все права защищены.</span>
        </div>
    </footer>
    
    <script src="{% static 'js/main.js' %}"></script>
    <script src="{% static 'js/components.js' %}"></script>
    
    {% block extra_js %}{% endblock %}
</body>
</html>
FILE_EOF

    # -------------------------------------------------------------------------
    # templates/core/placeholder.html
    # -------------------------------------------------------------------------
    write_file "templates/core/placeholder.html" << 'FILE_EOF'
{% extends "base.html" %}

{% block title %}{{ section_name }} - School CRM{% endblock %}

{% block content %}
<div class="placeholder-container">
    <div class="placeholder-icon">🚧</div>
    <h1>{{ section_name }}</h1>
    <p>Раздел находится в разработке и будет доступен в следующей версии.</p>
    <a href="{% url 'dashboard' %}" class="btn btn-primary">Вернуться на главную</a>
</div>

<style>
.placeholder-container {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 60vh;
    text-align: center;
}
.placeholder-icon {
    font-size: 4rem;
    margin-bottom: 1rem;
}
.placeholder-container h1 {
    font-size: 2rem;
    color: var(--color-gray-900);
    margin-bottom: 0.5rem;
}
.placeholder-container p {
    color: var(--color-gray-500);
    margin-bottom: 2rem;
}
</style>
{% endblock %}
FILE_EOF

    # -------------------------------------------------------------------------
    # templates/errors/403.html
    # -------------------------------------------------------------------------
    write_file "templates/errors/403.html" << 'FILE_EOF'
{% extends "base.html" %}

{% block title %}Доступ запрещён - School CRM{% endblock %}

{% block content %}
<div class="error-container">
    <div class="error-code">403</div>
    <h1>Доступ запрещён</h1>
    <p>У вас недостаточно прав для доступа к этой странице.</p>
    <a href="{% url 'dashboard' %}" class="btn btn-primary">Вернуться на главную</a>
</div>
{% endblock %}
FILE_EOF

    # -------------------------------------------------------------------------
    # templates/errors/404.html
    # -------------------------------------------------------------------------
    write_file "templates/errors/404.html" << 'FILE_EOF'
{% extends "base.html" %}

{% block title %}Страница не найдена - School CRM{% endblock %}

{% block content %}
<div class="error-container">
    <div class="error-code">404</div>
    <h1>Страница не найдена</h1>
    <p>Запрошенная страница не существует или была перемещена.</p>
    <a href="{% url 'dashboard' %}" class="btn btn-primary">Вернуться на главную</a>
</div>
{% endblock %}
FILE_EOF

    # -------------------------------------------------------------------------
    # templates/errors/500.html
    # -------------------------------------------------------------------------
    write_file "templates/errors/500.html" << 'FILE_EOF'
{% extends "base.html" %}

{% block title %}Ошибка сервера - School CRM{% endblock %}

{% block content %}
<div class="error-container">
    <div class="error-code">500</div>
    <h1>Внутренняя ошибка сервера</h1>
    <p>Произошла непредвиденная ошибка. Попробуйте обновить страницу позже.</p>
    <a href="{% url 'dashboard' %}" class="btn btn-primary">Вернуться на главную</a>
</div>
{% endblock %}
FILE_EOF

    log_success "Базовые шаблоны записаны"
}

# =============================================================================
# ШАГ 29: Шаблоны ключевых страниц
# =============================================================================

write_page_templates() {
    log_step "Шаг 29/9: Шаблоны ключевых страниц"

    # -------------------------------------------------------------------------
    # templates/users/login.html
    # -------------------------------------------------------------------------
    write_file "templates/users/login.html" << 'FILE_EOF'
{% extends "base.html" %}

{% block title %}Вход - School CRM{% endblock %}

{% block content %}
<div class="login-container">
    <div class="login-card">
        <div class="login-header">
            <div class="login-logo">🏫</div>
            <h1>School CRM</h1>
            <p>Войдите в свой аккаунт</p>
        </div>
        
        <form method="post" class="login-form">
            {% csrf_token %}
            
            {% if form.non_field_errors %}
            <div class="alert alert-error">
                {% for error in form.non_field_errors %}
                <span>{{ error }}</span>
                {% endfor %}
            </div>
            {% endif %}
            
            <div class="form-group">
                <label for="{{ form.email.id_for_label }}" class="form-label">
                    {{ form.email.label }}
                </label>
                {{ form.email }}
                {% if form.email.errors %}
                <div class="field-errors">
                    {% for error in form.email.errors %}
                    <span class="error">{{ error }}</span>
                    {% endfor %}
                </div>
                {% endif %}
            </div>
            
            <div class="form-group">
                <label for="{{ form.password.id_for_label }}" class="form-label">
                    {{ form.password.label }}
                </label>
                {{ form.password }}
                {% if form.password.errors %}
                <div class="field-errors">
                    {% for error in form.password.errors %}
                    <span class="error">{{ error }}</span>
                    {% endfor %}
                </div>
                {% endif %}
            </div>
            
            <div class="form-group form-checkbox-group">
                {{ form.remember_me }}
                <label for="{{ form.remember_me.id_for_label }}">
                    {{ form.remember_me.label }}
                </label>
            </div>
            
            <button type="submit" class="btn btn-primary btn-block">Войти</button>
        </form>
    </div>
</div>

<style>
.login-container {
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: calc(100vh - 200px);
    padding: var(--spacing-4);
}
.login-card {
    background: var(--color-white);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-lg);
    padding: var(--spacing-8);
    max-width: 400px;
    width: 100%;
}
.login-header {
    text-align: center;
    margin-bottom: var(--spacing-6);
}
.login-logo {
    font-size: 3rem;
    margin-bottom: var(--spacing-2);
}
.login-header h1 {
    font-size: 1.5rem;
    color: var(--color-gray-900);
    margin-bottom: var(--spacing-1);
}
.login-header p {
    color: var(--color-gray-500);
    font-size: var(--font-size-sm);
}
.login-form .form-group {
    margin-bottom: var(--spacing-4);
}
.form-checkbox-group {
    display: flex;
    align-items: center;
    gap: var(--spacing-2);
}
.btn-block {
    width: 100%;
}
</style>
{% endblock %}
FILE_EOF

    # -------------------------------------------------------------------------
    # templates/users/profile.html
    # -------------------------------------------------------------------------
    write_file "templates/users/profile.html" << 'FILE_EOF'
{% extends "base.html" %}

{% block title %}Профиль - School CRM{% endblock %}

{% block content %}
<div class="page-header">
    <h1>👤 Профиль</h1>
</div>

<div class="profile-card">
    <div class="profile-avatar">
        {% if user.avatar %}
        <img src="{{ user.avatar.url }}" alt="{{ user.get_display_name }}">
        {% else %}
        <div class="avatar-placeholder">
            {{ user.first_name|first }}{{ user.last_name|first }}
        </div>
        {% endif %}
    </div>
    
    <div class="profile-info">
        <h2>{{ user.get_display_name }}</h2>
        <p class="profile-email">{{ user.email }}</p>
        <p class="profile-role">{{ user.get_role_display }}</p>
        
        {% if user.phone %}
        <p class="profile-phone">📱 {{ user.phone }}</p>
        {% endif %}
        
        {% if user.tenant %}
        <p class="profile-tenant">🏫 {{ user.tenant.name }}</p>
        {% endif %}
    </div>
</div>

<style>
.profile-card {
    display: flex;
    gap: var(--spacing-6);
    background: var(--color-white);
    border-radius: var(--radius-lg);
    padding: var(--spacing-6);
    box-shadow: var(--shadow-sm);
    max-width: 600px;
}
.profile-avatar img,
.avatar-placeholder {
    width: 100px;
    height: 100px;
    border-radius: 50%;
    object-fit: cover;
}
.avatar-placeholder {
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--color-primary);
    color: white;
    font-size: 2rem;
    font-weight: 600;
}
.profile-info h2 {
    margin: 0 0 var(--spacing-2) 0;
}
.profile-email {
    color: var(--color-gray-500);
}
.profile-role {
    color: var(--color-primary);
    font-weight: 500;
}
</style>
{% endblock %}
FILE_EOF

    log_success "Шаблоны ключевых страниц записаны"
}

# =============================================================================
# ШАГ 30: Статические файлы
# =============================================================================

write_static_files() {
    log_step "Шаг 30/9: Статические файлы"

    # -------------------------------------------------------------------------
    # static/css/main.css
    # -------------------------------------------------------------------------
    write_file "static/css/main.css" << 'FILE_EOF'
/* ==========================================================================
   School CRM - Основные стили
   ========================================================================== */

/* Переменные */
:root {
    /* Цветовая палитра */
    --color-primary: #2563eb;
    --color-primary-dark: #1d4ed8;
    --color-primary-light: #dbeafe;
    
    --color-secondary: #64748b;
    --color-success: #10b981;
    --color-warning: #f59e0b;
    --color-danger: #ef4444;
    --color-info: #0ea5e9;
    
    /* Нейтральные цвета */
    --color-white: #ffffff;
    --color-gray-50: #f8fafc;
    --color-gray-100: #f1f5f9;
    --color-gray-200: #e2e8f0;
    --color-gray-300: #cbd5e1;
    --color-gray-400: #94a3b8;
    --color-gray-500: #64748b;
    --color-gray-600: #475569;
    --color-gray-700: #334155;
    --color-gray-800: #1e293b;
    --color-gray-900: #0f172a;
    
    /* Типографика */
    --font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    --font-size-xs: 0.75rem;
    --font-size-sm: 0.875rem;
    --font-size-base: 1rem;
    --font-size-lg: 1.125rem;
    --font-size-xl: 1.25rem;
    --font-size-2xl: 1.5rem;
    --font-size-3xl: 1.875rem;
    
    /* Отступы */
    --spacing-1: 0.25rem;
    --spacing-2: 0.5rem;
    --spacing-3: 0.75rem;
    --spacing-4: 1rem;
    --spacing-6: 1.5rem;
    --spacing-8: 2rem;
    
    /* Тени */
    --shadow-sm: 0 1px 2px 0 rgb(0 0 0 / 0.05);
    --shadow-md: 0 4px 6px -1px rgb(0 0 0 / 0.1);
    --shadow-lg: 0 10px 15px -3px rgb(0 0 0 / 0.1);
    
    /* Скругления */
    --radius-sm: 0.25rem;
    --radius-md: 0.375rem;
    --radius-lg: 0.5rem;
    --radius-full: 9999px;
    
    /* Размеры */
    --header-height: 64px;
    --sidebar-width: 260px;
}

/* Базовые стили */
* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

html {
    font-size: 16px;
    -webkit-text-size-adjust: 100%;
}

body {
    font-family: var(--font-family);
    font-size: var(--font-size-base);
    line-height: 1.5;
    color: var(--color-gray-900);
    background-color: var(--color-gray-50);
    min-height: 100vh;
}

/* Шапка приложения */
.app-header {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    height: var(--header-height);
    background: var(--color-white);
    border-bottom: 1px solid var(--color-gray-200);
    box-shadow: var(--shadow-sm);
    z-index: 1000;
}

.header-container {
    display: flex;
    align-items: center;
    justify-content: space-between;
    height: 100%;
    padding: 0 var(--spacing-4);
}

.logo {
    display: flex;
    align-items: center;
}

.logo-link {
    display: flex;
    align-items: center;
    gap: var(--spacing-2);
    text-decoration: none;
    color: var(--color-gray-900);
    font-weight: 600;
    font-size: var(--font-size-lg);
}

.logo-icon {
    font-size: var(--font-size-2xl);
}

.user-menu {
    display: flex;
    align-items: center;
    gap: var(--spacing-3);
}

.user-info {
    display: flex;
    align-items: center;
    gap: var(--spacing-2);
}

.user-avatar {
    width: 36px;
    height: 36px;
    border-radius: var(--radius-full);
    object-fit: cover;
}

.user-avatar-placeholder {
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--color-primary);
    color: var(--color-white);
    font-weight: 600;
    font-size: var(--font-size-sm);
}

.user-name {
    font-weight: 500;
    color: var(--color-gray-700);
}

.user-dropdown {
    position: relative;
}

.dropdown-toggle {
    background: none;
    border: none;
    cursor: pointer;
    padding: var(--spacing-2);
    color: var(--color-gray-500);
}

.dropdown-menu {
    position: absolute;
    top: 100%;
    right: 0;
    background: var(--color-white);
    border: 1px solid var(--color-gray-200);
    border-radius: var(--radius-md);
    box-shadow: var(--shadow-lg);
    min-width: 200px;
    display: none;
    z-index: 1001;
}

.dropdown-menu.show {
    display: block;
}

.dropdown-menu li {
    list-style: none;
}

.dropdown-menu a {
    display: block;
    padding: var(--spacing-3) var(--spacing-4);
    color: var(--color-gray-700);
    text-decoration: none;
    transition: background-color 0.2s;
}

.dropdown-menu a:hover {
    background: var(--color-gray-50);
}

.dropdown-menu .divider {
    height: 1px;
    background: var(--color-gray-200);
    margin: var(--spacing-1) 0;
}

/* Контейнер приложения */
.app-container {
    display: flex;
    min-height: 100vh;
    padding-top: var(--header-height);
}

/* Боковое меню */
.sidebar {
    width: var(--sidebar-width);
    background: var(--color-white);
    border-right: 1px solid var(--color-gray-200);
    display: flex;
    flex-direction: column;
    position: fixed;
    top: var(--header-height);
    left: 0;
    bottom: 0;
    overflow-y: auto;
}

.sidebar-nav {
    flex: 1;
    padding: var(--spacing-4) 0;
}

.nav-list {
    list-style: none;
}

.nav-item {
    margin-bottom: var(--spacing-1);
}

.nav-link {
    display: flex;
    align-items: center;
    gap: var(--spacing-3);
    padding: var(--spacing-3) var(--spacing-4);
    color: var(--color-gray-700);
    text-decoration: none;
    transition: all 0.2s;
    border-left: 3px solid transparent;
}

.nav-link:hover {
    background: var(--color-gray-50);
    color: var(--color-primary);
}

.nav-item.active .nav-link {
    background: var(--color-primary-light);
    color: var(--color-primary);
    border-left-color: var(--color-primary);
}

.nav-icon {
    font-size: var(--font-size-lg);
    width: 24px;
    text-align: center;
}

.nav-text {
    flex: 1;
}

.sidebar-footer {
    padding: var(--spacing-4);
    border-top: 1px solid var(--color-gray-200);
}

.tenant-info {
    display: flex;
    flex-direction: column;
    gap: var(--spacing-1);
}

.tenant-name {
    font-weight: 600;
    color: var(--color-gray-900);
}

.tenant-domain {
    font-size: var(--font-size-sm);
    color: var(--color-gray-500);
}

/* Основной контент */
.main-content {
    flex: 1;
    margin-left: var(--sidebar-width);
    padding: var(--spacing-6);
    background: var(--color-gray-50);
    min-height: calc(100vh - var(--header-height));
}

/* Сообщения (алерты) */
.messages {
    margin-bottom: var(--spacing-4);
}

.alert {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: var(--spacing-3) var(--spacing-4);
    border-radius: var(--radius-md);
    margin-bottom: var(--spacing-2);
}

.alert-success {
    background: #d1fae5;
    color: #065f46;
    border: 1px solid #6ee7b7;
}

.alert-error,
.alert-danger {
    background: #fee2e2;
    color: #991b1b;
    border: 1px solid #fca5a5;
}

.alert-warning {
    background: #fef3c7;
    color: #92400e;
    border: 1px solid #fcd34d;
}

.alert-info {
    background: #dbeafe;
    color: #1e40af;
    border: 1px solid #93c5fd;
}

.alert-close {
    background: none;
    border: none;
    font-size: var(--font-size-xl);
    cursor: pointer;
    opacity: 0.5;
}

.alert-close:hover {
    opacity: 1;
}

/* Заголовок страницы */
.page-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: var(--spacing-6);
}

.page-header h1 {
    font-size: var(--font-size-2xl);
    color: var(--color-gray-900);
}

/* Ошибки */
.error-container {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 60vh;
    text-align: center;
}

.error-code {
    font-size: 6rem;
    font-weight: 700;
    color: var(--color-gray-300);
}

.error-container h1 {
    font-size: 1.5rem;
    color: var(--color-gray-900);
    margin-bottom: var(--spacing-2);
}

.error-container p {
    color: var(--color-gray-500);
    margin-bottom: var(--spacing-6);
}

/* Футер */
.app-footer {
    background: var(--color-white);
    border-top: 1px solid var(--color-gray-200);
    padding: var(--spacing-4);
    text-align: center;
    color: var(--color-gray-500);
    font-size: var(--font-size-sm);
}

/* Адаптивность */
@media (max-width: 768px) {
    .sidebar {
        transform: translateX(-100%);
        transition: transform 0.3s ease;
    }
    
    .sidebar.open {
        transform: translateX(0);
    }
    
    .main-content {
        margin-left: 0;
    }
    
    .user-name {
        display: none;
    }
}
FILE_EOF

    # -------------------------------------------------------------------------
    # static/css/components.css
    # -------------------------------------------------------------------------
    write_file "static/css/components.css" << 'FILE_EOF'
/* ==========================================================================
   School CRM - Компоненты
   ========================================================================== */

/* Кнопки */
.btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: var(--spacing-2);
    padding: var(--spacing-3) var(--spacing-6);
    font-size: var(--font-size-base);
    font-weight: 500;
    border: none;
    border-radius: var(--radius-md);
    cursor: pointer;
    transition: all 0.2s;
    text-decoration: none;
}

.btn-primary {
    background: var(--color-primary);
    color: var(--color-white);
}

.btn-primary:hover {
    background: var(--color-primary-dark);
}

.btn-secondary {
    background: var(--color-gray-200);
    color: var(--color-gray-700);
}

.btn-secondary:hover {
    background: var(--color-gray-300);
}

.btn-danger {
    background: var(--color-danger);
    color: var(--color-white);
}

.btn-danger:hover {
    background: #dc2626;
}

.btn-sm {
    padding: var(--spacing-2) var(--spacing-3);
    font-size: var(--font-size-sm);
}

.btn-block {
    width: 100%;
}

/* Формы */
.form-group {
    margin-bottom: var(--spacing-4);
}

.form-label {
    display: block;
    margin-bottom: var(--spacing-2);
    font-weight: 500;
    color: var(--color-gray-700);
}

.form-input,
.form-select,
.form-textarea {
    width: 100%;
    padding: var(--spacing-3) var(--spacing-4);
    border: 1px solid var(--color-gray-300);
    border-radius: var(--radius-md);
    font-size: var(--font-size-base);
    transition: border-color 0.2s, box-shadow 0.2s;
}

.form-input:focus,
.form-select:focus,
.form-textarea:focus {
    outline: none;
    border-color: var(--color-primary);
    box-shadow: 0 0 0 3px rgba(37, 99, 235, 0.1);
}

.form-checkbox {
    width: 18px;
    height: 18px;
    cursor: pointer;
}

.field-errors {
    margin-top: var(--spacing-1);
}

.error {
    color: var(--color-danger);
    font-size: var(--font-size-sm);
}

.help-text {
    margin-top: var(--spacing-1);
    font-size: var(--font-size-sm);
    color: var(--color-gray-500);
}

/* Таблицы */
.data-table {
    width: 100%;
    border-collapse: collapse;
    background: var(--color-white);
    border-radius: var(--radius-lg);
    overflow: hidden;
}

.data-table th,
.data-table td {
    padding: var(--spacing-3);
    text-align: left;
    border-bottom: 1px solid var(--color-gray-200);
}

.data-table th {
    background: var(--color-gray-50);
    font-weight: 600;
}

.data-table tr:hover {
    background: var(--color-gray-50);
}

/* Карточки */
.card {
    background: var(--color-white);
    border-radius: var(--radius-lg);
    padding: var(--spacing-4);
    box-shadow: var(--shadow-sm);
}

.card-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
    gap: var(--spacing-4);
}

/* Статистика */
.stat-card {
    background: var(--color-white);
    border-radius: var(--radius-lg);
    padding: var(--spacing-4);
    box-shadow: var(--shadow-sm);
}

.stat-card .stat-icon {
    font-size: 2rem;
    margin-bottom: var(--spacing-2);
}

.stat-card .stat-value {
    font-size: 2rem;
    font-weight: 700;
    color: var(--color-gray-900);
}

.stat-card .stat-label {
    color: var(--color-gray-500);
    font-size: var(--font-size-sm);
}

/* Бейджи */
.badge {
    display: inline-block;
    padding: 2px 8px;
    border-radius: var(--radius-full);
    font-size: var(--font-size-xs);
    font-weight: 500;
}

.badge-success {
    background: #d1fae5;
    color: #065f46;
}

.badge-warning {
    background: #fef3c7;
    color: #92400e;
}

.badge-danger {
    background: #fee2e2;
    color: #991b1b;
}

.badge-info {
    background: #dbeafe;
    color: #1e40af;
}
FILE_EOF

    # -------------------------------------------------------------------------
    # static/js/main.js
    # -------------------------------------------------------------------------
    write_file "static/js/main.js" << 'FILE_EOF'
/**
 * School CRM - Основной JavaScript
 */

// Инициализация при загрузке страницы
document.addEventListener('DOMContentLoaded', function() {
    initSidebar();
    initUserDropdown();
    initAlerts();
});

// Боковое меню (мобильная версия)
function initSidebar() {
    const menuToggle = document.getElementById('menuToggle');
    const sidebar = document.getElementById('sidebar');
    
    if (menuToggle && sidebar) {
        menuToggle.addEventListener('click', function() {
            sidebar.classList.toggle('open');
            this.classList.toggle('active');
        });
        
        document.addEventListener('click', function(event) {
            if (!sidebar.contains(event.target) && !menuToggle.contains(event.target)) {
                sidebar.classList.remove('open');
                menuToggle.classList.remove('active');
            }
        });
    }
}

// Выпадающее меню пользователя
function initUserDropdown() {
    const dropdown = document.getElementById('userDropdown');
    
    if (dropdown) {
        const toggle = dropdown.querySelector('.dropdown-toggle');
        const menu = dropdown.querySelector('.dropdown-menu');
        
        toggle.addEventListener('click', function(e) {
            e.stopPropagation();
            menu.classList.toggle('show');
            this.setAttribute('aria-expanded', menu.classList.contains('show'));
        });
        
        document.addEventListener('click', function() {
            menu.classList.remove('show');
            toggle.setAttribute('aria-expanded', 'false');
        });
    }
}

// Сообщения (алерты)
function initAlerts() {
    const alerts = document.querySelectorAll('.alert-dismissible');
    
    alerts.forEach(function(alert) {
        const closeBtn = alert.querySelector('.alert-close');
        
        if (closeBtn) {
            closeBtn.addEventListener('click', function() {
                alert.style.animation = 'fadeOut 0.3s ease-out';
                setTimeout(function() {
                    alert.remove();
                }, 300);
            });
        }
        
        setTimeout(function() {
            alert.style.animation = 'fadeOut 0.3s ease-out';
            setTimeout(function() {
                alert.remove();
            }, 300);
        }, 5000);
    });
}

// Анимация исчезновения
const style = document.createElement('style');
style.textContent = `
    @keyframes fadeOut {
        from {
            opacity: 1;
            transform: translateY(0);
        }
        to {
            opacity: 0;
            transform: translateY(-10px);
        }
    }
`;
document.head.appendChild(style);

// Утилиты

/**
 * Получить CSRF токен из cookies
 */
function getCookie(name) {
    let cookieValue = null;
    if (document.cookie && document.cookie !== '') {
        const cookies = document.cookie.split(';');
        for (let i = 0; i < cookies.length; i++) {
            const cookie = cookies[i].trim();
            if (cookie.substring(0, name.length + 1) === (name + '=')) {
                cookieValue = decodeURIComponent(cookie.substring(name.length + 1));
                break;
            }
        }
    }
    return cookieValue;
}

/**
 * Показать уведомление пользователю
 */
function showNotification(message, type = 'info') {
    const notification = document.createElement('div');
    notification.className = `alert alert-${type}`;
    notification.innerHTML = `
        <span class="alert-message">${message}</span>
        <button class="alert-close" aria-label="Закрыть">&times;</button>
    `;
    
    const container = document.querySelector('.messages') || document.body;
    container.prepend(notification);
    
    setTimeout(function() {
        notification.style.animation = 'fadeOut 0.3s ease-out';
        setTimeout(() => notification.remove(), 300);
    }, 5000);
}

/**
 * Форматировать дату для отображения
 */
function formatDate(dateString) {
    const date = new Date(dateString);
    const options = { 
        year: 'numeric', 
        month: 'long', 
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit'
    };
    return date.toLocaleDateString('ru-RU', options);
}
FILE_EOF

    # -------------------------------------------------------------------------
    # static/js/components.js
    # -------------------------------------------------------------------------
    write_file "static/js/components.js" << 'FILE_EOF'
/**
 * School CRM - Компоненты JavaScript
 */

/**
 * Отправить GET запрос
 */
async function apiGet(url, params = {}) {
    try {
        const queryString = new URLSearchParams(params).toString();
        const fullUrl = queryString ? `${url}?${queryString}` : url;
        
        const response = await fetch(fullUrl, {
            method: 'GET',
            headers: {
                'Content-Type': 'application/json',
            },
        });
        
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        return await response.json();
    } catch (error) {
        console.error('API GET error:', error);
        throw error;
    }
}

/**
 * Отправить POST запрос
 */
async function apiPost(url, data) {
    try {
        const csrfToken = getCookie('csrftoken');
        
        const response = await fetch(url, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-CSRFToken': csrfToken,
            },
            body: JSON.stringify(data),
        });
        
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        return await response.json();
    } catch (error) {
        console.error('API POST error:', error);
        throw error;
    }
}

/**
 * Копировать текст в буфер обмена
 */
async function copyToClipboard(text) {
    try {
        await navigator.clipboard.writeText(text);
        showNotification('Скопировано в буфер обмена', 'success');
    } catch (err) {
        showNotification('Не удалось скопировать', 'error');
    }
}

/**
 * Валидация формы
 */
function validateForm(form) {
    let isValid = true;
    const requiredFields = form.querySelectorAll('[required]');
    
    requiredFields.forEach(function(field) {
        if (!field.value.trim()) {
            isValid = false;
            showFieldError(field, 'Это поле обязательно для заполнения');
        } else {
            clearFieldError(field);
        }
    });
    
    return isValid;
}

function showFieldError(field, message) {
    clearFieldError(field);
    
    field.classList.add('is-invalid');
    
    const error = document.createElement('div');
    error.className = 'field-errors';
    error.style.color = 'var(--color-danger)';
    error.style.fontSize = 'var(--font-size-sm)';
    error.style.marginTop = 'var(--spacing-1)';
    error.textContent = message;
    
    field.parentNode.appendChild(error);
}

function clearFieldError(field) {
    field.classList.remove('is-invalid');
    const error = field.parentNode.querySelector('.field-errors');
    if (error) {
        error.remove();
    }
}
FILE_EOF

    # -------------------------------------------------------------------------
    # static/img/favicon.ico (заглушка)
    # -------------------------------------------------------------------------
    write_file "static/img/favicon.ico" << 'FILE_EOF'
FILE_EOF
    # Создаём пустой файл для favicon
    touch "$INSTALL_DIR/static/img/favicon.ico"

    log_success "Статические файлы записаны"
}

# =============================================================================
# СТРАНИЦА 9 ЗАВЕРШЕНА
# =============================================================================
#!/bin/bash
# =============================================================================
# СТРАНИЦА 10 / СТРАНИЦА 11
# =============================================================================
# Содержимое этой страницы:
#   Шаг 31: Скрипты обслуживания
#   Шаг 32: Документация
#   Шаг 33: Команда заполнения тестовыми данными
# =============================================================================

# =============================================================================
# ШАГ 31: Скрипты обслуживания
# =============================================================================

write_maintenance_scripts() {
    log_step "Шаг 31/9: Скрипты обслуживания"

    # -------------------------------------------------------------------------
    # scripts/backup.sh
    # -------------------------------------------------------------------------
    write_file "scripts/backup.sh" << 'FILE_EOF'
#!/bin/bash
#
# Скрипт ежедневного бэкапа School CRM
#
# Использование:
#   ./backup.sh
#
# Автоматически вызывается из cron ежедневно в 02:00

set -e

# Конфигурация
APP_NAME="schoolcrm"
DB_NAME="schoolcrm"
BACKUP_DIR="/var/backups/schoolcrm"
MEDIA_DIR="/var/media"
APP_DIR="/opt/schoolcrm"
DATE=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=30

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo "[OK] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Создание директории бэкапов
mkdir -p "$BACKUP_DIR"

log_info "Начало бэкапа: $DATE"

# 1. Бэкап базы данных
log_info "Бэкап базы данных..."
sudo -u postgres pg_dump "$DB_NAME" | gzip > "$BACKUP_DIR/db_$DATE.sql.gz"
log_success "Бэкап БД создан: db_$DATE.sql.gz"

# 2. Бэкап медиа файлов
log_info "Бэкап медиа файлов..."
if [ -d "$MEDIA_DIR" ]; then
    tar -czf "$BACKUP_DIR/media_$DATE.tar.gz" -C "$MEDIA_DIR" .
    log_success "Бэкап медиа создан: media_$DATE.tar.gz"
else
    log_info "Медиа директория не найдена, пропускаем"
fi

# 3. Бэкап конфигурации
log_info "Бэкап конфигурации..."
tar -czf "$BACKUP_DIR/config_$DATE.tar.gz" \
    "$APP_DIR/.env" \
    /etc/nginx/sites-available/schoolcrm \
    /etc/supervisor/conf.d/schoolcrm*.conf \
    2>/dev/null || true
log_success "Бэкап конфигурации создан: config_$DATE.tar.gz"

# 4. Удаление старых бэкапов
log_info "Удаление бэкапов старше $RETENTION_DAYS дней..."
find "$BACKUP_DIR" -name "*.gz" -mtime +$RETENTION_DAYS -delete
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete

log_success "Бэкап завершён: $DATE"
log_info "Файлы бэкапа:"
ls -lh "$BACKUP_DIR"/*_$DATE* 2>/dev/null || true
FILE_EOF
    chmod +x "$INSTALL_DIR/scripts/backup.sh"

    # -------------------------------------------------------------------------
    # scripts/update.sh
    # -------------------------------------------------------------------------
    write_file "scripts/update.sh" << 'FILE_EOF'
#!/bin/bash
#
# Скрипт обновления School CRM
#
# Использование:
#   sudo ./update.sh
#   sudo ./update.sh --backup-first
#   sudo ./update.sh --from-git

set -e

APP_NAME="schoolcrm"
APP_USER="schoolcrm"
APP_DIR="/opt/schoolcrm"
BACKUP_FIRST=false
FROM_GIT=false

# Обработка аргументов
for arg in "$@"; do
    case $arg in
        --backup-first)
            BACKUP_FIRST=true
            ;;
        --from-git)
            FROM_GIT=true
            ;;
    esac
done

log_info() {
    echo -e "\033[0;34m[INFO]\033[0m $1"
}

log_success() {
    echo -e "\033[0;32m[OK]\033[0m $1"
}

log_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1"
}

# Проверка зависимостей
check_dependencies() {
    local missing=()
    
    if ! command -v supervisorctl &> /dev/null; then
        missing+=("supervisor")
    fi
    
    if ! command -v git &> /dev/null; then
        missing+=("git")
    fi
    
    if ! command -v python3 &> /dev/null; then
        missing+=("python3")
    fi
    
    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Отсутствуют зависимости: ${missing[*]}"
        exit 1
    fi
}

# Проверка root
if [ "$EUID" -ne 0 ]; then
    log_error "Скрипт должен быть запущен с правами root"
    exit 1
fi

check_dependencies

cd "$APP_DIR"

log_info "Начало обновления School CRM"

# Бэкап перед обновлением
if [ "$BACKUP_FIRST" = true ]; then
    log_info "Создание бэкапа перед обновлением..."
    if [ -f scripts/backup.sh ]; then
        bash scripts/backup.sh
    else
        DATE=$(date +%Y%m%d_%H%M%S)
        sudo -u postgres pg_dump schoolcrm | gzip > /var/backups/schoolcrm/pre_update_$DATE.sql.gz
    fi
    log_success "Бэкап создан"
fi

# Загрузка изменений из Git
if [ "$FROM_GIT" = true ]; then
    log_info "Загрузка изменений из Git..."
    git pull origin main || git pull origin master || true
fi

# Остановка сервисов
log_info "Остановка сервисов..."
supervisorctl stop all || true

# Установка зависимостей
log_info "Обновление зависимостей Python..."
sudo -u "$APP_USER" bash -c "cd $APP_DIR && source venv/bin/activate && pip install --upgrade pip && pip install -r requirements.txt"

# Применение миграций
log_info "Применение миграций..."
sudo -u "$APP_USER" bash -c "cd $APP_DIR && source venv/bin/activate && python manage.py migrate --noinput"

# Сборка статики
log_info "Сборка статики..."
sudo -u "$APP_USER" bash -c "cd $APP_DIR && source venv/bin/activate && python manage.py collectstatic --noinput"

# Запуск сервисов
log_info "Запуск сервисов..."
supervisorctl start all

# Проверка статуса
sleep 3
log_info "Статус сервисов:"
supervisorctl status

log_success "Обновление завершено!"
log_info "Проверьте логи: tail -f /var/log/schoolcrm/*.log"
FILE_EOF
    chmod +x "$INSTALL_DIR/scripts/update.sh"

    # -------------------------------------------------------------------------
    # scripts/restore.sh
    # -------------------------------------------------------------------------
    write_file "scripts/restore.sh" << 'FILE_EOF'
#!/bin/bash
#
# Скрипт восстановления School CRM из бэкапа
#
# Использование:
#   sudo ./restore.sh /path/to/backup.sql.gz
#   sudo ./restore.sh --latest
#   sudo ./restore.sh --list

set -e

APP_NAME="schoolcrm"
BACKUP_DIR="/var/backups/schoolcrm"
DB_NAME="schoolcrm"
DB_USER="schoolcrm"

log_info() {
    echo -e "\033[0;34m[INFO]\033[0m $1"
}

log_success() {
    echo -e "\033[0;32m[OK]\033[0m $1"
}

log_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1"
}

log_warning() {
    echo -e "\033[1;33m[WARNING]\033[0m $1"
}

# Проверка целостности бэкапа
verify_backup() {
    local backup_file="$1"
    
    log_info "Проверка целостности бэкапа: $backup_file"
    
    if [ ! -f "$backup_file" ]; then
        log_error "Файл не найден: $backup_file"
        return 1
    fi
    
    if [ ! -s "$backup_file" ]; then
        log_error "Файл пустой: $backup_file"
        return 1
    fi
    
    if ! gzip -t "$backup_file" 2>/dev/null; then
        log_error "Файл повреждён или не является gzip: $backup_file"
        return 1
    fi
    
    if ! gunzip -c "$backup_file" | head -n 10 | grep -q "PostgreSQL database dump"; then
        log_warning "Файл может не быть PostgreSQL дампом"
    fi
    
    log_success "Бэкап прошёл проверку целостности"
    return 0
}

# Проверка root
if [ "$EUID" -ne 0 ]; then
    log_error "Скрипт должен быть запущен с правами root"
    exit 1
fi

# Список бэкапов
if [ "$1" = "--list" ]; then
    log_info "Доступные бэкапы:"
    ls -lh "$BACKUP_DIR"/*.gz 2>/dev/null | grep "db_" | awk '{print $9, $5}' || log_error "Бэкапы не найдены"
    exit 0
fi

# Восстановление последнего
if [ "$1" = "--latest" ]; then
    BACKUP_FILE=$(ls -t "$BACKUP_DIR"/db_*.sql.gz 2>/dev/null | head -n1)
    if [ -z "$BACKUP_FILE" ]; then
        log_error "Бэкапы не найдены в $BACKUP_DIR"
        exit 1
    fi
    log_info "Используется последний бэкап: $BACKUP_FILE"
else
    BACKUP_FILE="$1"
fi

# Проверка существования файла
if [ ! -f "$BACKUP_FILE" ]; then
    log_error "Файл бэкапа не найден: $BACKUP_FILE"
    exit 1
fi

# Проверка целостности
if ! verify_backup "$BACKUP_FILE"; then
    log_error "Бэкап не прошёл проверку. Восстановление отменено."
    exit 1
fi

# Подтверждение
log_warning "ВНИМАНИЕ: Это действие полностью заменит текущую базу данных!"
read -p "Продолжить? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    log_info "Восстановление отменено"
    exit 0
fi

# Остановка сервисов
log_info "Остановка сервисов..."
supervisorctl stop all || true

# Создание бэкапа перед восстановлением
log_info "Создание бэкапа текущей базы..."
DATE=$(date +%Y%m%d_%H%M%S)
sudo -u postgres pg_dump "$DB_NAME" | gzip > "$BACKUP_DIR/pre_restore_$DATE.sql.gz"
log_success "Бэкап создан: pre_restore_$DATE.sql.gz"

# Удаление текущей базы
log_info "Удаление текущей базы данных..."
sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;"
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"

# Восстановление
log_info "Восстановление из бэкапа: $BACKUP_FILE"
gunzip -c "$BACKUP_FILE" | sudo -u postgres psql "$DB_NAME"

# Запуск сервисов
log_info "Запуск сервисов..."
supervisorctl start all

sleep 3
log_info "Статус сервисов:"
supervisorctl status

log_success "Восстановление завершено!"
log_info "Проверьте работу приложения: curl http://localhost/health/"
FILE_EOF
    chmod +x "$INSTALL_DIR/scripts/restore.sh"

    log_success "Скрипты обслуживания записаны"
}

# =============================================================================
# ШАГ 33: Management команда для тестовых данных
# =============================================================================

write_seed_command() {
    log_step "Шаг 33/9: Создание команды seed_test_data"

    # -------------------------------------------------------------------------
    # apps/core/management/commands/seed_test_data.py
    # -------------------------------------------------------------------------
    write_file "apps/core/management/commands/seed_test_data.py" << 'FILE_EOF'
"""
Management command для заполнения базы тестовыми данными.

Использование:
    python manage.py seed_test_data
"""

from django.core.management.base import BaseCommand
from django.contrib.auth import get_user_model
from django.utils import timezone
import random

User = get_user_model()

class Command(BaseCommand):
    help = 'Заполняет базу тестовыми данными для демонстрации'

    def handle(self, *args, **options):
        self.stdout.write('Начало загрузки тестовых данных...')

        # Создаём директора
        director, _ = User.objects.get_or_create(
            email='director@schoolcrm.local',
            defaults={
                'username': 'director',
                'first_name': 'Иван',
                'last_name': 'Директоров',
                'role': 'director',
                'is_staff': True,
            }
        )
        director.set_password('password123')
        director.save()
        self.stdout.write(self.style.SUCCESS('✓ Директор создан'))

        # Создаём заместителя директора
        viceprincipal, _ = User.objects.get_or_create(
            email='viceprincipal@schoolcrm.local',
            defaults={
                'username': 'viceprincipal',
                'first_name': 'Петр',
                'last_name': 'Замдиректоров',
                'role': 'vice_principal',
                'is_staff': True,
            }
        )
        viceprincipal.set_password('password123')
        viceprincipal.save()
        self.stdout.write(self.style.SUCCESS('✓ Заместитель директора создан'))

        # Создаём учителей
        for i in range(1, 6):
            teacher, _ = User.objects.get_or_create(
                email=f'teacher{i}@schoolcrm.local',
                defaults={
                    'username': f'teacher{i}',
                    'first_name': f'Учитель{i}',
                    'last_name': f'Учителев{i}',
                    'role': 'teacher',
                }
            )
            teacher.set_password('password123')
            teacher.save()
        self.stdout.write(self.style.SUCCESS('✓ 5 учителей создано'))

        # Создаём классных руководителей
        for i in range(1, 4):
            homeroom, _ = User.objects.get_or_create(
                email=f'homeroom{i}@schoolcrm.local',
                defaults={
                    'username': f'homeroom{i}',
                    'first_name': f'Классный{i}',
                    'last_name': f'Руководителев{i}',
                    'role': 'homeroom_teacher',
                }
            )
            homeroom.set_password('password123')
            homeroom.save()
        self.stdout.write(self.style.SUCCESS('✓ 3 классных руководителя создано'))

        # Создаём учеников и родителей
        for class_num in range(1, 4):
            for student_num in range(1, 11):
                student_email = f'student{class_num}{student_num:02d}@schoolcrm.local'
                parent_email = f'parent{class_num}{student_num:02d}@schoolcrm.local'

                student, _ = User.objects.get_or_create(
                    email=student_email,
                    defaults={
                        'username': f'student{class_num}{student_num:02d}',
                        'first_name': f'Ученик{class_num}-{student_num}',
                        'last_name': f'Учеников{class_num}-{student_num}',
                        'role': 'student',
                    }
                )
                student.set_password('password123')
                student.save()

                parent, _ = User.objects.get_or_create(
                    email=parent_email,
                    defaults={
                        'username': f'parent{class_num}{student_num:02d}',
                        'first_name': f'Родитель{class_num}-{student_num}',
                        'last_name': f'Родителев{class_num}-{student_num}',
                        'role': 'parent',
                    }
                )
                parent.set_password('password123')
                parent.save()

        self.stdout.write(self.style.SUCCESS('✓ 30 учеников и 30 родителей создано'))

        # Создаём поставщика питания
        nutrition, _ = User.objects.get_or_create(
            email='nutrition@schoolcrm.local',
            defaults={
                'username': 'nutrition',
                'first_name': 'Поставщик',
                'last_name': 'Питания',
                'role': 'nutrition_provider',
            }
        )
        nutrition.set_password('password123')
        nutrition.save()
        self.stdout.write(self.style.SUCCESS('✓ Поставщик питания создан'))

        self.stdout.write(self.style.SUCCESS('\n✅ Тестовые данные успешно загружены!'))
        self.stdout.write(self.style.WARNING('\n⚠️  Не забудьте сменить пароли после первого входа!'))
FILE_EOF

    # -------------------------------------------------------------------------
    # apps/core/management/commands/register_mattermost_users.py
    # -------------------------------------------------------------------------
    write_file "apps/core/management/commands/register_mattermost_users.py" << 'FILE_EOF'
"""
Management command для массовой регистрации пользователей в Mattermost.

Использование:
    python manage.py register_mattermost_users --role teacher --count 10 --export xls
    python manage.py register_mattermost_users --role parent --count 50 --export txt
    python manage.py register_mattermost_users --role student --count 100

Опции:
    --role      Роль пользователя: teacher, parent, student, admin
    --count     Количество пользователей для регистрации (по умолчанию 10)
    --export    Формат экспорта: txt, xls, csv (по умолчанию txt)
    --output    Путь к файлу экспорта (по умолчанию /tmp/mattermost_users.{format})
"""

from django.core.management.base import BaseCommand, CommandError
from django.contrib.auth import get_user_model
from django.utils.crypto import get_random_string
from datetime import datetime
import os
import subprocess

User = get_user_model()

# Роли Mattermost
MATTERMOST_ROLES = {
    'admin': 'system_admin',
    'teacher': 'teacher',
    'parent': 'parent',
    'student': 'student',
}

class Command(BaseCommand):
    help = 'Массовая регистрация пользователей в Mattermost с автогенерацией паролей'

    def add_arguments(self, parser):
        parser.add_argument(
            '--role',
            type=str,
            choices=['admin', 'teacher', 'parent', 'student'],
            default='teacher',
            help='Роль пользователей (admin, teacher, parent, student)'
        )
        parser.add_argument(
            '--count',
            type=int,
            default=10,
            help='Количество пользователей для регистрации'
        )
        parser.add_argument(
            '--export',
            type=str,
            choices=['txt', 'xls', 'csv'],
            default='txt',
            help='Формат экспорта списка пользователей'
        )
        parser.add_argument(
            '--output',
            type=str,
            default=None,
            help='Путь к файлу экспорта'
        )
        parser.add_argument(
            '--mattermost-url',
            type=str,
            default='http://localhost:8065',
            help='URL Mattermost сервера'
        )
        parser.add_argument(
            '--mattermost-admin-email',
            type=str,
            default='admin@schoolcrm.local',
            help='Email администратора Mattermost'
        )

    def generate_password(self, length=12):
        """Генерация случайного пароля"""
        return get_random_string(length, allowed_chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%')

    def generate_username(self, role, index):
        """Генерация имени пользователя"""
        role_prefix = {
            'admin': 'mmadmin',
            'teacher': 'teacher',
            'parent': 'parent',
            'student': 'student',
        }
        return f"{role_prefix.get(role, 'user')}{index:03d}"

    def generate_email(self, username):
        """Генерация email"""
        return f"{username}@schoolcrm.local"

    def create_user_in_db(self, username, email, password, role, first_name, last_name):
        """Создание пользователя в базе данных Django"""
        # Проверяем валидность роли
        valid_roles = ['DIRECTOR', 'DEPUTY', 'CLASS_TEACHER', 'TEACHER', 'STUDENT', 'PARENT']
        if role not in valid_roles:
            role = 'TEACHER'  # роль по умолчанию
        
        user, created = User.objects.get_or_create(
            email=email,
            defaults={
                'username': username,
                'first_name': first_name,
                'last_name': last_name,
                'role': role.lower(),
            }
        )
        if created:
            user.set_password(password)
            user.save()
        return user, created

    def create_user_in_mattermost(self, username, email, password, first_name, last_name, mm_url, mm_admin_email):
        """
        Создание пользователя в Mattermost через API.
        Для упрощения используем curl запросы.
        В production рекомендуется использовать официальный Python SDK Mattermost.
        """
        # Получаем токен администратора (упрощённая версия)
        # В реальности нужно сначала аутентифицироваться
        login_data = f'{{"login_id": "{mm_admin_email}", "password": "admin_password"}}'
        
        try:
            # Логин администратора для получения токена
            login_result = subprocess.run([
                'curl', '-s', '-X', 'POST',
                '-H', 'Content-Type: application/json',
                '-d', login_data,
                f'{mm_url}/api/v4/users/login'
            ], capture_output=True, text=True, timeout=10)
            
            # Извлекаем токен из заголовков
            token = login_result.headers.get('Token', '') if hasattr(login_result, 'headers') else ''
            
            if not token:
                # Если не получили токен, пробуем создать пользователя напрямую
                # Это упрощённый вариант без реальной аутентификации
                self.stdout.write(self.style.WARNING(f'⚠️  Не удалось получить токен Mattermost. Пользователь создан только в БД.'))
                return False
            
            # Создаём пользователя
            user_data = f'''{{
                "email": "{email}",
                "username": "{username}",
                "first_name": "{first_name}",
                "last_name": "{last_name}",
                "nickname": "",
                "position": "",
                "roles": "{MATTERMOST_ROLES.get("teacher", "teacher")}",
                "locale": "ru",
                "password": "{password}"
            }}'''
            
            create_result = subprocess.run([
                'curl', '-s', '-X', 'POST',
                '-H', 'Content-Type: application/json',
                '-H', f'Authorization: Bearer {token}',
                '-d', user_data,
                f'{mm_url}/api/v4/users'
            ], capture_output=True, text=True, timeout=10)
            
            if create_result.returncode == 0:
                return True
            else:
                self.stdout.write(self.style.WARNING(f'⚠️  Ошибка при создании в Mattermost: {create_result.stderr}'))
                return False
                
        except Exception as e:
            self.stdout.write(self.style.WARNING(f'⚠️  Ошибка подключения к Mattermost: {str(e)}'))
            return False

    def export_to_txt(self, users_data, output_path):
        """Экспорт в TXT формат"""
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write("=" * 80 + "\n")
            f.write("СПИСОК ЗАРЕГИСТРИРОВАННЫХ ПОЛЬЗОВАТЕЛЕЙ MATTERMOST\n")
            f.write(f"Дата генерации: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write("=" * 80 + "\n\n")
            
            f.write(f"{'№':<5} {'Username':<20} {'Email':<35} {'Роль':<10} {'Пароль':<15}\n")
            f.write("-" * 80 + "\n")
            
            for i, user in enumerate(users_data, 1):
                f.write(f"{i:<5} {user['username']:<20} {user['email']:<35} {user['role']:<10} {user['password']:<15}\n")
            
            f.write("\n" + "=" * 80 + "\n")
            f.write(f"Всего пользователей: {len(users_data)}\n")
            f.write("=" * 80 + "\n")
        
        return output_path

    def export_to_csv(self, users_data, output_path):
        """Экспорт в CSV формат"""
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write("№,Username,Email,Роль,Пароль,First Name,Last Name\n")
            for i, user in enumerate(users_data, 1):
                f.write(f'{i},{user["username"]},{user["email"]},{user["role"]},{user["password"]},{user["first_name"]},{user["last_name"]}\n')
        return output_path

    def export_to_xls(self, users_data, output_path):
        """
        Экспорт в XLS формат.
        Используем простой HTML-based Excel файл для совместимости.
        """
        html_content = '''<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <style>
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid black; padding: 8px; text-align: left; }
        th { background-color: #4CAF50; color: white; }
        tr:nth-child(even) { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <h2>СПИСОК ЗАРЕГИСТРИРОВАННЫХ ПОЛЬЗОВАТЕЛЕЙ MATTERMOST</h2>
    <p>Дата генерации: ''' + datetime.now().strftime('%Y-%m-%d %H:%M:%S') + '''</p>
    <table>
        <tr>
            <th>№</th>
            <th>Username</th>
            <th>Email</th>
            <th>Роль</th>
            <th>Пароль</th>
            <th>Имя</th>
            <th>Фамилия</th>
        </tr>
'''
        for i, user in enumerate(users_data, 1):
            html_content += f'''        <tr>
            <td>{i}</td>
            <td>{user['username']}</td>
            <td>{user['email']}</td>
            <td>{user['role']}</td>
            <td>{user['password']}</td>
            <td>{user['first_name']}</td>
            <td>{user['last_name']}</td>
        </tr>
'''
        
        html_content += f'''    </table>
    <p>Всего пользователей: {len(users_data)}</p>
</body>
</html>
'''
        
        # Сохраняем как .xls (Excel откроет HTML как таблицу)
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(html_content)
        
        return output_path

    def handle(self, *args, **options):
        role = options['role']
        count = options['count']
        export_format = options['export']
        output_path = options['output']
        mm_url = options['mattermost_url']
        mm_admin_email = options['mattermost_admin_email']

        # Определяем путь экспорта по умолчанию
        if not output_path:
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            output_path = f'/tmp/mattermost_users_{role}_{timestamp}.{export_format}'

        self.stdout.write(self.style.SUCCESS(f'\n🚀 Начало массовой регистрации пользователей...'))
        self.stdout.write(f'   Роль: {role}')
        self.stdout.write(f'   Количество: {count}')
        self.stdout.write(f'   Формат экспорта: {export_format}')
        self.stdout.write(f'   Файл экспорта: {output_path}\n')

        users_data = []
        success_count = 0
        db_only_count = 0

        first_names = {
            'admin': ['Александр', 'Дмитрий', 'Сергей', 'Андрей', 'Ольга', 'Елена', 'Наталья'],
            'teacher': ['Иван', 'Петр', 'Алексей', 'Михаил', 'Анна', 'Мария', 'Екатерина'],
            'parent': ['Владимир', 'Николай', 'Борис', 'Татьяна', 'Светлана', 'Ирина'],
            'student': ['Максим', 'Артем', 'Даниил', 'София', 'Алина', 'Виктория'],
        }
        
        last_names = {
            'admin': ['Админов', 'Директоров', 'Управляющий'],
            'teacher': ['Учителев', 'Преподавателей', 'Педагогов'],
            'parent': ['Родителев', 'Папин', 'Мамин'],
            'student': ['Учеников', 'Школьников', 'Студентов'],
        }

        for i in range(1, count + 1):
            username = self.generate_username(role, i)
            email = self.generate_email(username)
            password = self.generate_password()
            
            # Генерируем имя и фамилию
            fn_list = first_names.get(role, ['Пользователь'])
            ln_list = last_names.get(role, ['Пользователей'])
            first_name = fn_list[i % len(fn_list)]
            last_name = ln_list[i % len(ln_list)]

            # Создаём в БД Django
            user, created = self.create_user_in_db(username, email, password, role, first_name, last_name)
            
            if created:
                success_count += 1
                
                # Пробуем создать в Mattermost
                mm_created = self.create_user_in_mattermost(
                    username, email, password, first_name, last_name, mm_url, mm_admin_email
                )
                
                if mm_created:
                    self.stdout.write(self.style.SUCCESS(f'✓ [{i}/{count}] {username} ({email}) - создан в БД и Mattermost'))
                else:
                    db_only_count += 1
                    self.stdout.write(self.style.WARNING(f'⚠ [{i}/{count}] {username} ({email}) - создан только в БД'))
                
                users_data.append({
                    'username': username,
                    'email': email,
                    'password': password,
                    'role': role,
                    'first_name': first_name,
                    'last_name': last_name,
                })
            else:
                self.stdout.write(self.style.WARNING(f'⚠ [{i}/{count}] {username} уже существует'))

        # Экспортируем данные
        if users_data:
            if export_format == 'txt':
                exported_path = self.export_to_txt(users_data, output_path)
            elif export_format == 'csv':
                exported_path = self.export_to_csv(users_data, output_path)
            elif export_format == 'xls':
                exported_path = self.export_to_xls(users_data, output_path)
            else:
                exported_path = self.export_to_txt(users_data, output_path)

            self.stdout.write(self.style.SUCCESS(f'\n✅ Регистрация завершена!'))
            self.stdout.write(f'   Успешно создано в БД: {success_count}')
            self.stdout.write(f'   Создано только в БД (Mattermost недоступен): {db_only_count}')
            self.stdout.write(f'   Файл экспорта: {exported_path}')
            self.stdout.write(self.style.WARNING('\n⚠️  Сохраните файл с паролями в безопасном месте!'))
        else:
            self.stdout.write(self.style.WARNING('\n⚠️  Пользователи не были созданы'))
FILE_EOF

    log_success "Команда seed_test_data создана"
    log_success "Команда register_mattermost_users создана"
}

# =============================================================================
# ШАГ 32: Документация
# =============================================================================

write_documentation() {
    log_step "Шаг 32/9: Документация"

    # -------------------------------------------------------------------------
    # README.md
    # -------------------------------------------------------------------------
    write_file "README.md" << 'FILE_EOF'
# School CRM

Мульти-тенантная система управления школой.

## Описание

Школьный журнал, расписание, мессенджер, аналитика и многое другое.

## Требования

- Python 3.11+
- PostgreSQL 15+
- Redis 7+
- Nginx 1.22+

## Установка

```bash
chmod +x install.sh
sudo ./install.sh /opt/schoolcrm
```

## Использование

После установки откроите веб-интерфейс по адресу `http://your-server-ip`.

## Документация

Полная документация доступна в директории `docs/`.

## Лицензия

MIT License
FILE_EOF

    log_success "Документация создана"
}

# =============================================================================
# ШАГ 34: Установка системных зависимостей
# =============================================================================

install_system_dependencies() {
    log_step "Шаг 34/9: Установка системных зависимостей"

    log_info "Обновление системы..."
    apt-get update -qq
    apt-get upgrade -y -qq

    log_info "Установка системных зависимостей..."
    apt-get install -y -qq \
        software-properties-common \
        build-essential \
        libpq-dev \
        libffi-dev \
        libssl-dev \
        python3-dev \
        python3-pip \
        python3-venv \
        postgresql \
        postgresql-contrib \
        redis-server \
        nginx \
        supervisor \
        git \
        curl \
        wget \
        unzip \
        ufw \
        gnupg2 \
        pass \
        lsb-release \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release

    # Проверка и установка Docker если требуется для Mattermost
    if [ "$INSTALL_MATTERMOST" = true ] && ! command -v docker &> /dev/null; then
        log_info "Установка Docker для Mattermost..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm -f get-docker.sh
        systemctl enable docker
        systemctl start docker
        log_success "Docker установлен"
    fi

    # Проверка и установка Docker Compose если требуется
    if [ "$INSTALL_MATTERMOST" = true ] && ! command -v docker compose &> /dev/null; then
        log_info "Установка Docker Compose..."
        mkdir -p /usr/local/lib/docker/cli-plugins
        curl -SL https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
        ln -s /usr/local/lib/docker/cli-plugins/docker-compose /usr/bin/docker-compose || true
        log_success "Docker Compose установлен"
    fi

    log_success "Системные зависимости установлены"
}

# =============================================================================
# ШАГ 35: Настройка PostgreSQL
# =============================================================================

setup_postgresql() {
    log_step "Шаг 35/9: Настройка PostgreSQL"

    # Генерация пароля БЕЗ спецсимволов (hex вместо base64)
    DB_PASSWORD=$(openssl rand -hex 24)
    
    # Сохраняем пароль во временный файл
    echo "DB_PASSWORD=$DB_PASSWORD" > /tmp/.db_password

    systemctl enable postgresql
    systemctl start postgresql

    # Ждём готовности PostgreSQL
    log_info "Ожидание готовности PostgreSQL..."
    for i in $(seq 1 30); do
        if sudo -u postgres pg_isready -q 2>/dev/null; then
            break
        fi
        sleep 1
    done

    # Настраиваем аутентификацию по паролю для локальных подключений
    log_info "Настройка аутентификации PostgreSQL..."
    
    # Находим путь к pg_hba.conf
    PG_HBA=$(find /etc/postgresql -name "pg_hba.conf" -path "*/main/*" 2>/dev/null | head -1)
    
    if [ -n "$PG_HBA" ]; then
        # Резервная копия
        cp "$PG_HBA" "${PG_HBA}.bak" 2>/dev/null || true
        
        # Заменяем peer на md5 для локальных подключений (используем | как разделитель)
        sed -i 's|^local\s\+all\s\+all\s\+peer|local   all             all                                     md5|' "$PG_HBA"
        # Заменяем scram-sha-256/peer на md5 для host подключений IPv4
        sed -i 's|^host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+\(peer\|scram-sha-256\|ident\)|host    all             all             127.0.0.1/32            md5|' "$PG_HBA"
        # Заменяем scram-sha-256/peer на md5 для host подключений IPv6
        sed -i 's|^host\s\+all\s\+all\s\+::1\/128\s\+\(peer\|scram-sha-256\|ident\)|host    all             all             ::1/128                 md5|' "$PG_HBA"
        
        # Перезагружаем PostgreSQL для применения настроек
        systemctl restart postgresql
        sleep 2
    else
        log_warning "Не удалось найти pg_hba.conf"
    fi

    # Создаём БД и пользователя с проверкой существования
    log_info "Создание базы данных и пользователя..."
    
    # Проверяем, существует ли пользователь
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null | grep -q 1; then
        log_info "Пользователь $DB_USER уже существует, обновляем пароль..."
        sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
    else
        log_info "Создаём пользователя $DB_USER..."
        sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
    fi

    # Создаём БД если не существует
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null | grep -q 1; then
        log_info "База данных $DB_NAME уже существует"
    else
        sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"
    fi

    # Назначаем привилегии
    sudo -u postgres psql -c "ALTER USER $DB_USER CREATEDB;"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"

    # Проверяем подключение с паролем
    log_info "Проверка подключения к БД..."
    if PGPASSWORD="$DB_PASSWORD" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" > /dev/null 2>&1; then
        log_success "Подключение к БД успешно"
    else
        log_warning "Проверка подключения не прошла, но продолжаем..."
    fi

    log_success "PostgreSQL настроен"
}

# =============================================================================
# ШАГ 36: Настройка Redis
# =============================================================================

setup_redis() {
    log_step "Шаг 36/9: Настройка Redis"

    # Генерация пароля для Redis
    REDIS_PASSWORD=$(openssl rand -base64 24)

    # Сохраняем пароль
    echo "REDIS_PASSWORD=$REDIS_PASSWORD" > /tmp/.redis_password

    # Настраиваем Redis на использование пароля
    if grep -q "^# requirepass" /etc/redis/redis.conf; then
        sed -i "s/^# requirepass.*/requirepass $REDIS_PASSWORD/" /etc/redis/redis.conf
    else
        echo "requirepass $REDIS_PASSWORD" >> /etc/redis/redis.conf
    fi

    systemctl enable redis-server
    systemctl restart redis-server

    log_success "Redis настроен"
}

# =============================================================================
# ШАГ 37: Настройка Nginx
# =============================================================================

setup_nginx() {
    log_step "Шаг 37/9: Настройка Nginx"

    # Создаём пользователя и группу приложения если не существуют
    if ! id "$APP_USER" &>/dev/null; then
        log_info "Создание пользователя $APP_USER..."
        groupadd -f "$APP_GROUP"
        useradd -r -g "$APP_GROUP" -s /bin/false -d "$INSTALL_DIR" "$APP_USER"
        log_success "Пользователь $APP_USER создан"
    fi

    # Проверяем существование группы www-data (создаём если нет)
    if ! getent group www-data &>/dev/null; then
        log_info "Создание группы www-data..."
        groupadd www-data
    fi

    # Создаём сокет-директорию
    mkdir -p /run/schoolcrm
    chown "$APP_USER:www-data" /run/schoolcrm
    chmod 755 /run/schoolcrm

    # Конфигурация Nginx
    write_file "/etc/nginx/sites-available/$APP_NAME" << FILE_EOF
upstream schoolcrm_app {
    server unix:/run/schoolcrm/gunicorn.sock fail_timeout=0;
}

upstream schoolcrm_daphne {
    server unix:/run/schoolcrm/daphne.sock fail_timeout=0;
}

server {
    listen 80;
    server_name _;
    
    client_max_body_size 20M;
    
    # Статика
    location /static/ {
        alias $INSTALL_DIR/staticfiles/;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # Медиа
    location /media/ {
        alias /var/media/;
        expires 7d;
    }
    
    # WebSocket
    location /ws/ {
        proxy_pass http://schoolcrm_daphne;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Основное приложение
    location / {
        proxy_pass http://schoolcrm_app;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
    }
    
    # Health check
    location /health/ {
        proxy_pass http://schoolcrm_app;
        access_log off;
    }
}
FILE_EOF

    # Активируем конфигурацию
    ln -sf "/etc/nginx/sites-available/$APP_NAME" "/etc/nginx/sites-enabled/"
    rm -f /etc/nginx/sites-enabled/default

    # Проверяем конфигурацию
    nginx -t

    # Перезапускаем Nginx
    systemctl restart nginx

    log_success "Nginx настроен"
}

# =============================================================================
# ШАГ 38: Настройка Supervisor
# =============================================================================

setup_supervisor() {
    log_step "Шаг 38/9: Настройка Supervisor"

    # Создаём директорию для логов перед настройкой Supervisor
    mkdir -p /var/log/schoolcrm
    mkdir -p /run/schoolcrm
    
    # Читаем пароли
    source /tmp/.db_password
    source /tmp/.redis_password

    # Gunicorn
    cat > /etc/supervisor/conf.d/${APP_NAME}_gunicorn.conf << FILE_EOF
[program:${APP_NAME}_gunicorn]
command=$INSTALL_DIR/venv/bin/gunicorn config.wsgi:application --workers 3 --threads 2 --worker-class gthread --bind unix:/run/schoolcrm/gunicorn.sock --access-logfile /var/log/schoolcrm/gunicorn-access.log --error-logfile /var/log/schoolcrm/gunicorn-error.log --timeout 30
directory=$INSTALL_DIR
user=$APP_USER
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/schoolcrm/gunicorn-out.log
environment=DB_PASSWORD="$DB_PASSWORD",REDIS_URL="redis://:$REDIS_PASSWORD@localhost:6379/0"
FILE_EOF

    # Daphne (WebSocket)
    cat > /etc/supervisor/conf.d/${APP_NAME}_daphne.conf << FILE_EOF
[program:${APP_NAME}_daphne]
command=$INSTALL_DIR/venv/bin/daphne -u /run/schoolcrm/daphne.sock config.asgi:application --proxy-headers --websocket-timeout 600
directory=$INSTALL_DIR
user=$APP_USER
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/schoolcrm/daphne.log
environment=DB_PASSWORD="$DB_PASSWORD",REDIS_URL="redis://:$REDIS_PASSWORD@localhost:6379/2"
FILE_EOF

    # Celery Worker
    cat > /etc/supervisor/conf.d/${APP_NAME}_celery.conf << FILE_EOF
[program:${APP_NAME}_celery]
command=$INSTALL_DIR/venv/bin/celery -A config worker --loglevel=info --concurrency=4
directory=$INSTALL_DIR
user=$APP_USER
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/schoolcrm/celery-worker.log
environment=DB_PASSWORD="$DB_PASSWORD",REDIS_URL="redis://:$REDIS_PASSWORD@localhost:6379/0"
FILE_EOF

    # Celery Beat
    cat > /etc/supervisor/conf.d/${APP_NAME}_celery_beat.conf << FILE_EOF
[program:${APP_NAME}_celery_beat]
command=$INSTALL_DIR/venv/bin/celery -A config beat --loglevel=info --schedule=/tmp/celerybeat-schedule
directory=$INSTALL_DIR
user=$APP_USER
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/schoolcrm/celery-beat.log
environment=DB_PASSWORD="$DB_PASSWORD",REDIS_URL="redis://:$REDIS_PASSWORD@localhost:6379/0"
FILE_EOF

    # Перезагружаем Supervisor
    supervisorctl reread
    supervisorctl update

    log_success "Supervisor настроен"
}

# =============================================================================
# ШАГ 39: Установка окружения
# =============================================================================

setup_environment() {
    log_step "Шаг 39/9: Установка окружения"

    cd "$INSTALL_DIR"

    # Читаем пароли
    source /tmp/.db_password
    source /tmp/.redis_password

    # Создаём необходимые директории с mkdir -p перед chown
    mkdir -p /var/log/schoolcrm
    mkdir -p /var/media
    mkdir -p /var/backups/schoolcrm

    # Генерация SECRET_KEY
    SECRET_KEY=$(python3 -c 'from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())' 2>/dev/null || openssl rand -base64 64)

    # Создаём .env файл
    cat > .env << FILE_EOF
# Конфигурация School CRM
# Сгенерировано автоматически $(date)

DEBUG=False
SECRET_KEY=$SECRET_KEY
ALLOWED_HOSTS=$(hostname -f),localhost,127.0.0.1

# База данных
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_HOST=localhost
DB_PORT=5432
DB_SSL_MODE=prefer

# Redis
REDIS_URL=redis://:$REDIS_PASSWORD@localhost:6379/0

# Тенанты
TENANT_BASE_DOMAIN=$(hostname -f)

# Email
EMAIL_BACKEND=django.core.mail.backends.console.EmailBackend
DEFAULT_FROM_EMAIL=noreply@$(hostname -f)

# Jitsi
JITSI_DOMAIN=meet.jit.si
FILE_EOF

    # Создаём виртуальное окружение (от root, чтобы избежать проблем с правами)
    log_info "Создание виртуального окружения..."
    python3 -m venv venv

    # Устанавливаем владельца на venv перед установкой пакетов
    chown -R "$APP_USER:$APP_GROUP" venv

    # Устанавливаем зависимости (от имени пользователя приложения)
    log_info "Установка зависимостей Python..."
    sudo -u "$APP_USER" bash -c "cd $INSTALL_DIR && source venv/bin/activate && pip install --upgrade pip --no-cache-dir"
    sudo -u "$APP_USER" bash -c "cd $INSTALL_DIR && source venv/bin/activate && pip install -r requirements.txt --no-cache-dir"


    # =============================================================================
    # ВАЖНО: Устанавливаем права ДО запуска команд от имени пользователя приложения
    # Это необходимо, чтобы Django мог создать файлы логов, статики и т.д.
    # =============================================================================
    log_info "Настройка прав доступа..."
    chown -R "$APP_USER:$APP_GROUP" "$INSTALL_DIR"
    chown -R "$APP_USER:$APP_GROUP" "/var/log/schoolcrm"
    chown -R "$APP_USER:$APP_GROUP" "/var/media"
    chown -R "$APP_USER:$APP_GROUP" "/var/backups/schoolcrm"

    # Применяем миграции
    log_info "Применение миграций..."
    sudo -u "$APP_USER" bash -c "cd $INSTALL_DIR && source venv/bin/activate && python manage.py migrate --noinput"

    # Собираем статику
    log_info "Сборка статики..."
    sudo -u "$APP_USER" bash -c "cd $INSTALL_DIR && source venv/bin/activate && python manage.py collectstatic --noinput"

    # Создаём суперпользователя
    log_info "Создание суперпользователя..."
    sudo -u "$APP_USER" bash -c "cd $INSTALL_DIR && source venv/bin/activate && python manage.py shell" << 'EOF'
from apps.users.models import User
if not User.objects.filter(email='admin@schoolcrm.local').exists():
    User.objects.create_superuser(
        email='admin@schoolcrm.local',
        password='admin123',
        first_name='Администратор',
        last_name='Системы'
    )
    print('✅ Суперпользователь создан')
else:
    print('ℹ️  Суперпользователь уже существует')
EOF

    log_success "Окружение установлено"
}

# =============================================================================
# ШАГ 40: Настройка бэкапов
# =============================================================================

setup_backups() {
    log_step "Шаг 40/9: Настройка автоматических бэкапов"

    # Добавляем в cron
    (crontab -l 2>/dev/null; echo "0 2 * * * $INSTALL_DIR/scripts/backup.sh >> /var/log/schoolcrm/backup.log 2>&1") | crontab -

    log_success "Автоматические бэкапы настроены (ежедневно в 02:00)"
}

# =============================================================================
# ШАГ 40бис: Установка и настройка Certbot (SSL сертификаты)
# =============================================================================

install_certbot() {
    log_step "Шаг 40бис/9: Установка и настройка Certbot для SSL"

    log_info "Установка Certbot и получение SSL сертификата..."

    # Проверка наличия домена
    DOMAIN=""
    read -p "Введите доменное имя для SSL сертификата (оставьте пустым для самоподписанного): " DOMAIN

    if [ -z "$DOMAIN" ]; then
        log_info "Домен не указан. Генерация самоподписанного SSL сертификата..."
        
        # Создаём директорию для сертификатов
        mkdir -p /etc/ssl/schoolcrm
        
        # Генерируем самоподписанный сертификат на 365 дней
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /etc/ssl/schoolcrm/server.key \
            -out /etc/ssl/schoolcrm/server.crt \
            -subj "/C=RU/ST=Moscow/L=Moscow/O=SchoolCRM/CN=$(hostname -f)" \
            2>/dev/null
        
        log_success "Самоподписанный сертификат создан"
        log_info "Сертификат: /etc/ssl/schoolcrm/server.crt"
        log_info "Ключ: /etc/ssl/schoolcrm/server.key"
        log_warning "⚠️  Самоподписанный сертификат будет действовать 365 дней"
        log_warning "⚠️  Браузеры будут показывать предупреждение о безопасности"
        
        # Настраиваем перевыпуск самоподписанного сертификата
        cat > /etc/cron.d/schoolcrm-selfsigned << CRON_EOF
# Перевыпуск самоподписанного SSL сертификата каждые 30 дней
0 3 1 * * root openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/schoolcrm/server.key -out /etc/ssl/schoolcrm/server.crt -subj "/C=RU/ST=Moscow/L=Moscow/O=SchoolCRM/CN=$(hostname -f)" 2>/dev/null && systemctl reload nginx
CRON_EOF
        
        chmod 644 /etc/cron.d/schoolcrm-selfsigned
        log_success "Настроен автоматический перевыпуск самоподписанного сертификата (1-го числа каждого месяца)"
        
    else
        log_info "Домен указан: $DOMAIN"
        
        # Установка Certbot
        apt-get update -qq
        apt-get install -y -qq certbot python3-certbot-nginx
        
        # Останавливаем Nginx временно для получения сертификата (если нужно)
        # или используем standalone mode на порту 80
        
        # Получаем сертификат через Certbot
        log_info "Получение SSL сертификата от Let's Encrypt..."
        
        # Проверяем доступность порта 80
        if ! curl -s --connect-timeout 5 http://$DOMAIN > /dev/null 2>&1; then
            log_warning "⚠️  Домен $DOMAIN недоступен. Убедитесь, что DNS настроен правильно."
            log_warning "⚠️  Продолжение установки с самоподписанным сертификатом..."
            
            # Генерируем самоподписанный как fallback
            mkdir -p /etc/ssl/schoolcrm
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout /etc/ssl/schoolcrm/server.key \
                -out /etc/ssl/schoolcrm/server.crt \
                -subj "/C=RU/ST=Moscow/L=Moscow/O=SchoolCRM/CN=$DOMAIN" \
                2>/dev/null
            
            CERT_PATH="/etc/ssl/schoolcrm/server.crt"
            KEY_PATH="/etc/ssl/schoolcrm/server.key"
        else
            # Получаем настоящий сертификат от Let's Encrypt
            certbot certonly --standalone -d $DOMAIN -d www.$DOMAIN \
                --email admin@$DOMAIN --agree-tos --non-interactive \
                || {
                    log_warning "⚠️  Не удалось получить сертификат Let's Encrypt"
                    log_warning "⚠️  Используем самоподписанный сертификат"
                    
                    mkdir -p /etc/ssl/schoolcrm
                    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                        -keyout /etc/ssl/schoolcrm/server.key \
                        -out /etc/ssl/schoolcrm/server.crt \
                        -subj "/C=RU/ST=Moscow/L=Moscow/O=SchoolCRM/CN=$DOMAIN" \
                        2>/dev/null
                    
                    CERT_PATH="/etc/ssl/schoolcrm/server.crt"
                    KEY_PATH="/etc/ssl/schoolcrm/server.key"
                }
            
            # Если Certbot успешен, используем его пути
            if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
                CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
                KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
                log_success "SSL сертификат Let's Encrypt получен успешно"
                
                # Настраиваем автопродление через systemd timer
                log_info "Настройка автоматического продления SSL сертификата..."
                
                # Создаём скрипт продления
                cat > /usr/local/bin/renew-schoolcrm-ssl.sh << 'RENEW_SCRIPT'
#!/bin/bash
# Скрипт продления SSL сертификата для School CRM
# Запускается по таймеру каждые 12 часов

CERT_DOMAIN="$1"
if [ -z "$CERT_DOMAIN" ]; then
    echo "Usage: $0 <domain>"
    exit 1
fi

# Пробуем продлить сертификат
certbot renew --quiet --deploy-hook "systemctl reload nginx"

# Проверяем статус продления
if [ $? -eq 0 ]; then
    echo "$(date): SSL сертификат успешно продлён для $CERT_DOMAIN" >> /var/log/schoolcrm/ssl-renewal.log
else
    echo "$(date): Ошибка продления SSL сертификата для $CERT_DOMAIN" >> /var/log/schoolcrm/ssl-renewal.log
fi
RENEW_SCRIPT
                
                chmod +x /usr/local/bin/renew-schoolcrm-ssl.sh
                
                # Создаём systemd service
                cat > /etc/systemd/system/schoolcrm-ssl-renewal.service << SERVICE_EOF
[Unit]
Description=School CRM SSL Certificate Renewal
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/renew-schoolcrm-ssl.sh $DOMAIN
SERVICE_EOF
                
                # Создаём systemd timer для проверки каждые 12 часов
                cat > /etc/systemd/system/schoolcrm-ssl-renewal.timer << TIMER_EOF
[Unit]
Description=Run School CRM SSL renewal twice daily
Requires=schoolcrm-ssl-renewal.service

[Timer]
OnCalendar=*-*-* 00:00:00
OnCalendar=*-*-* 12:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
TIMER_EOF
                
                # Активируем таймер
                systemctl daemon-reload
                systemctl enable schoolcrm-ssl-renewal.timer
                systemctl start schoolcrm-ssl-renewal.timer
                
                log_success "Systemd таймер настроен для проверки продления SSL каждые 12 часов"
                log_info "Статус таймера: $(systemctl is-active schoolcrm-ssl-renewal.timer)"
                
                # Также добавляем в cron для совместимости
                (crontab -l 2>/dev/null; echo "0 */12 * * * /usr/local/bin/renew-schoolcrm-ssl.sh $DOMAIN") | crontab -
                log_success "Дублирование задачи продления в cron (каждые 12 часов)"
            else
                log_warning "⚠️  Используются резервные сертификаты"
            fi
        fi
    fi
    
    # Обновляем конфигурацию Nginx для использования SSL
    log_info "Обновление конфигурации Nginx для SSL..."
    
    # Находим основной конфиг сайта и обновляем его
    if [ -f /etc/nginx/sites-available/schoolcrm ]; then
        # Резервная копия
        cp /etc/nginx/sites-available/schoolcrm /etc/nginx/sites-available/schoolcrm.bak
        
        # Проверяем, есть ли уже SSL настройка
        if ! grep -q "ssl_certificate" /etc/nginx/sites-available/schoolcrm; then
            # Добавляем SSL настройки с корректными upstream'ами
            cat > /etc/nginx/sites-available/schoolcrm << 'NGINX_SSL'
# Upstream для Gunicorn (Django)
upstream schoolcrm_app {
    server unix:/run/schoolcrm/gunicorn.sock fail_timeout=0;
}

# Upstream для Daphne (WebSockets)
upstream schoolcrm_daphne {
    server unix:/run/schoolcrm/daphne.sock fail_timeout=0;
}

server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name _;

    # Пути к сертификатам будут заменены скриптом
    ssl_certificate /etc/ssl/schoolcrm/server.crt;
    ssl_certificate_key /etc/ssl/schoolcrm/server.key;

    # SSL настройки
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Основное приложение (Django/Gunicorn)
    location / {
        proxy_pass http://schoolcrm_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 60s;
        proxy_read_timeout 60s;
    }

    # WebSocket соединения (Daphne)
    location /ws/ {
        proxy_pass http://schoolcrm_daphne;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
    }
}
NGINX_SSL
        fi
        
        # Перезагружаем Nginx
        nginx -t && systemctl reload nginx
        log_success "Nginx перезагружен с SSL настройками"
    fi
    
    log_success "SSL настройка завершена"
    
    # Вывод информации
    if [ -n "$DOMAIN" ] && [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        log_info "Домен: $DOMAIN"
        log_info "Сертификат действителен до: $(openssl x509 -enddate -noout -in /etc/letsencrypt/live/$DOMAIN/fullchain.pem 2>/dev/null | cut -d= -f2)"
        log_info "Автопродление: включено (проверка каждые 12 часов)"
    else
        log_info "Тип сертификата: самоподписанный"
        log_info "Действителен до: $(openssl x509 -enddate -noout -in /etc/ssl/schoolcrm/server.crt 2>/dev/null | cut -d= -f2)"
        log_info "Автоперевыпуск: 1-го числа каждого месяца"
    fi
}

# =============================================================================
# ШАГ 41: Запуск сервисов
# =============================================================================

start_services() {
    log_step "Шаг 41/9: Запуск сервисов"

    # Запускаем все сервисы через Supervisor
    supervisorctl start all

    # Ждём запуска
    sleep 3

    # Проверяем статус
    log_info "Статус сервисов:"
    supervisorctl status

    # Проверяем health check
    log_info "Проверка health check..."
    if curl -s http://localhost/health/ | grep -q "healthy"; then
        log_success "Приложение работает корректно!"
    else
        log_warning "Приложение ещё не готово. Проверьте логи."
    fi
}

# =============================================================================
# ШАГ 42: Установка Jitsi Meet (опционально)
# =============================================================================

install_jitsi() {
    log_step "Шаг 42/9: Установка Jitsi Meet сервера"

    log_info "Установка Jitsi Meet для видеоконференций..."

    # Добавляем репозиторий Jitsi
    curl -s https://download.jitsi.org/jitsi-key.gpg.key | gpg --dearmor > /usr/share/keyrings/jitsi-keyring.gpg
    echo 'deb [signed-by=/usr/share/keyrings/jitsi-keyring.gpg] https://download.jitsi.org stable/' > /etc/apt/sources.list.d/jitsi-stable.list

    # Обновляем пакеты
    apt-get update -qq

    # Устанавливаем Jitsi Meet (без интерактивного запроса hostname)
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jitsi-meet

    # Настраиваем Jitsi Meet автоматически
    JITSI_HOSTNAME=$(hostname -f)
    /usr/share/jitsi-meet/scripts/configure-letsencrypt.sh "$JITSI_HOSTNAME" || true

    log_success "Jitsi Meet установлен"
    log_info "URL Jitsi Meet: https://$JITSI_HOSTNAME/"
    log_warning "⚠️  Для работы Jitsi требуется SSL сертификат и открытый порт 443"
}

# =============================================================================
# ШАГ 42бис: Установка Mattermost сервера
# =============================================================================

install_mattermost() {
    log_step "Шаг 42бис/9: Установка Mattermost сервера"

    log_info "Установка Mattermost для внутренней коммуникации..."

    # Проверка наличия Docker
    if ! command -v docker &> /dev/null; then
        log_info "Установка Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm -f get-docker.sh
    fi

    # Создаём директорию для Mattermost
    MATTERMOST_DIR="/opt/mattermost"
    mkdir -p "$MATTERMOST_DIR"
    cd "$MATTERMOST_DIR"

    # Генерация паролей для Mattermost
    MM_DB_PASSWORD=$(openssl rand -base64 24)
    MM_ADMIN_PASSWORD=$(openssl rand -base64 12)

    # Сохраняем пароль администратора
    echo "MM_ADMIN_PASSWORD=$MM_ADMIN_PASSWORD" > /tmp/.mattermost_admin_password
    chmod 600 /tmp/.mattermost_admin_password

    # Создаём docker-compose.yml для Mattermost
    cat > docker-compose.yml << 'DOCKER_EOF'
version: '3.8'
services:
  mattermost-db:
    image: postgres:13-alpine
    container_name: mattermost-db
    restart: always
    environment:
      POSTGRES_USER: mmuser
      POSTGRES_PASSWORD: ${MM_DB_PASSWORD}
      POSTGRES_DB: mattermost
    volumes:
      - mattermost-db-data:/var/lib/postgresql/data
    networks:
      - mattermost-network

  mattermost-app:
    image: mattermost/mattermost-team-edition:latest
    container_name: mattermost-app
    restart: always
    depends_on:
      - mattermost-db
    environment:
      MM_SQLSETTINGS_DRIVERNAME: postgres
      MM_SQLSETTINGS_DATASOURCE: postgres://mmuser:${MM_DB_PASSWORD}@mattermost-db:5432/mattermost?sslmode=disable&connect_timeout=10
      MM_SERVICESETTINGS_SITEURL: http://${MM_HOSTNAME}:8065
      MM_PLUGINSETTINGS_ENABLEUPLOADS: true
    ports:
      - "8065:8065"
    volumes:
      - mattermost-data:/mattermost
    networks:
      - mattermost-network

volumes:
  mattermost-db-data:
  mattermost-data:

networks:
  mattermost-network:
    driver: bridge
DOCKER_EOF

    # Экспортируем переменные окружения
    export MM_DB_PASSWORD="$MM_DB_PASSWORD"
    export MM_HOSTNAME=$(hostname -f)
    
    # Записываем пароль БД в файл для последующего использования
    echo "MM_DB_PASSWORD=$MM_DB_PASSWORD" >> /tmp/.mattermost_db_password

    # Запускаем Mattermost через Docker Compose
    log_info "Запуск Mattermost через Docker Compose..."
    docker compose up -d

    # Ждём запуска сервиса
    log_info "Ожидание запуска Mattermost (это может занять несколько минут)..."
    sleep 30

    # Проверяем статус
    if docker compose ps | grep -q "mattermost-app.*Up"; then
        log_success "Mattermost установлен и запущен"
        log_info "URL Mattermost: http://$(hostname -f):8065/"
        log_info "Логин администратора: admin@schoolcrm.local"
        log_info "Пароль администратора: $MM_ADMIN_PASSWORD (сохранён в /tmp/.mattermost_admin_password)"
        log_warning "⚠️  Смените пароль администратора после первого входа!"
    else
        log_warning "⚠️  Mattermost запущен, но возможна ошибка при старте. Проверьте логи: docker compose logs"
    fi
}

# =============================================================================
# ШАГ 43: Загрузка тестовых данных (опционально)
# =============================================================================

load_test_data() {
    log_step "Шаг 43/9: Загрузка тестовых данных"

    log_info "Заполнение базы данных тестовыми данными..."

    cd "$INSTALL_DIR"

    # Активируем виртуальное окружение
    source venv/bin/activate

    # Применяем миграции (если ещё не применены)
    python manage.py migrate --noinput

    # Создаём суперпользователя если не существует
    log_info "Создание суперпользователя admin@schoolcrm.local..."
    python manage.py shell << 'PYTHON_EOF'
from django.contrib.auth import get_user_model
User = get_user_model()
if not User.objects.filter(email='admin@schoolcrm.local').exists():
    User.objects.create_superuser('admin@schoolcrm.local', 'admin123')
    print('Суперпользователь создан')
else:
    print('Суперпользователь уже существует')
PYTHON_EOF

    # Загружаем тестовые данные через management command
    log_info "Создание тестовых пользователей и структур..."
    python manage.py seed_test_data

    log_success "Тестовые данные загружены"
    log_info "Созданы:"
    log_info "  - Директор школы (director@schoolcrm.local / password123)"
    log_info "  - Заместитель директора (viceprincipal@schoolcrm.local / password123)"
    log_info "  - Учителя (teacher1..5@schoolcrm.local / password123)"
    log_info "  - Классные руководители (homeroom1..3@schoolcrm.local / password123)"
    log_info "  - Ученики (student1..30@schoolcrm.local / password123)"
    log_info "  - Родители (parent1..30@schoolcrm.local / password123)"
    log_info "  - Поставщик питания (nutrition@schoolcrm.local / password123)"
    log_info "  - Учебные классы, предметы, расписание"
    log_warning "⚠️  Смените пароли после первого входа!"
}

# =============================================================================
# Финальная статистика
# =============================================================================

print_final_stats() {
    log_step "🎉 Установка завершена успешно!"

    # Читаем пароли
    source /tmp/.db_password
    source /tmp/.redis_password

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          School CRM установлен успешно!                  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    log_success "Статистика установки:"
    log_info "  Директорий создано: $DIRS_CREATED"
    log_info "  Файлов создано: $FILES_CREATED"
    echo ""
    log_success "📋 Информация для доступа:"
    log_info "  URL: http://$(hostname -f)/"
    log_info "  Admin Email: admin@schoolcrm.local"
    log_info "  Admin Password: admin123"
    echo ""
    log_success "🗄️  База данных:"
    log_info "  Database: $DB_NAME"
    log_info "  User: $DB_USER"
    log_info "  Password: (см. $INSTALL_DIR/.env)"
    echo ""
    log_success "📁 Директории:"
    log_info "  Приложение: $INSTALL_DIR"
    log_info "  Логи: /var/log/schoolcrm"
    log_info "  Медиа: /var/media"
    log_info "  Бэкапы: /var/backups/schoolcrm"
    echo ""
    log_success "🔧 Полезные команды:"
    log_info "  Статус сервисов: sudo supervisorctl status"
    log_info "  Логи: tail -f /var/log/schoolcrm/*.log"
    log_info "  Бэкап: sudo $INSTALL_DIR/scripts/backup.sh"
    log_info "  Обновление: sudo $INSTALL_DIR/scripts/update.sh"
    log_info "  Восстановление: sudo $INSTALL_DIR/scripts/restore.sh --latest"
    echo ""
    log_success "📚 Документация:"
    log_info "  README: $INSTALL_DIR/README.md"
    log_info "  Архитектура: $INSTALL_DIR/docs/ARCHITECTURE.md"
    log_info "  Развёртывание: $INSTALL_DIR/docs/DEPLOY.md"
    echo ""

    # Информация о Mattermost если установлен
    if [ "$INSTALL_MATTERMOST" = true ]; then
        log_success "💬 Mattermost:"
        log_info "  URL: http://$(hostname -f):8065/"
        log_info "  Admin Email: admin@schoolcrm.local"
        if [ -f /tmp/.mattermost_admin_password ]; then
            source /tmp/.mattermost_admin_password
            log_info "  Admin Password: $MM_ADMIN_PASSWORD"
        fi
        log_info "  Команда регистрации: python manage.py register_mattermost_users --role teacher --count 10 --export xls"
        echo ""
    fi
    
    # Информация о Jitsi если установлен
    if [ "$INSTALL_JITSI" = true ]; then
        log_success "📹 Jitsi Meet:"
        log_info "  URL: https://$(hostname -f)/"
        echo ""
    fi
    # Информация о SSL сертификате если установлен
    if [ "$INSTALL_CERTBOT" = true ]; then
        log_success "🔒 SSL сертификат:"
        if [ -f "/etc/letsencrypt/live/$(hostname -f)/fullchain.pem" ]; then
            log_info "  Тип: Let's Encrypt (доверенный)"
            log_info "  Действителен до: $(openssl x509 -enddate -noout -in /etc/letsencrypt/live/$(hostname -f)/fullchain.pem 2>/dev/null | cut -d= -f2)"
            log_info "  Автопродление: включено (проверка каждые 12 часов)"
        else
            log_info "  Тип: самоподписанный"
            log_info "  Действителен до: $(openssl x509 -enddate -noout -in /etc/ssl/schoolcrm/server.crt 2>/dev/null | cut -d= -f2)"
            log_info "  Автоперевыпуск: 1-го числа каждого месяца"
        fi
        echo ""
    fi

    log_warning "⚠️  Важно:"
    log_info "  1. Смените пароль администратора после первого входа"
    if [ "$INSTALL_CERTBOT" != true ]; then
        log_info "  2. Установите SSL сертификат: sudo ./install.sh --certbot"
    else
        log_info "  2. SSL сертификат установлен и настроено автопродление"
    fi
    log_info "  3. Настройте firewall: sudo ufw allow 'Nginx Full' && sudo ufw enable"
    echo ""
}

# =============================================================================
# ГЛАВНАЯ ФУНКЦИЯ
# =============================================================================

main() {
    # Парсинг аргументов командной строки
    parse_args "$@"
    
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║     School CRM — Единый скрипт установки                 ║"
    echo "║     Версия 1.0.0                                         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    log_info "Директория установки: $INSTALL_DIR"
    
    # Отображение опций установки
    if [ "$INSTALL_TEST_DATA" = true ]; then
        log_info "Опция: Установка тестовых данных включена"
    fi
    if [ "$INSTALL_JITSI" = true ]; then
        log_info "Опция: Установка Jitsi Meet включена"
    fi
    if [ "$INSTALL_MATTERMOST" = true ]; then
        log_info "Опция: Установка Mattermost включена"
    fi
    if [ "$INSTALL_CERTBOT" = true ]; then
        log_info "Опция: Установка SSL сертификата (Certbot) включена"
    fi

    # Перенаправление вывода в лог с сохранением в консоли
    exec > >(tee -a "$LOG_FILE") 2>&1

    # Предполётные проверки
    check_root
    check_os
    check_resources

    # Шаг 1-33: Создание файлов проекта
    create_structure
    write_root_files
    write_config_files
    write_settings_files
    write_middleware_files
    write_core_app
    write_tenants_app
    write_users_app
    write_stubs_app
    write_management_app
    write_references_app
    write_schedule_app
    write_grades_app
    write_lessons_app
    write_groups_app
    write_exams_app
    write_calendar_app
    write_news_app
    write_nutrition_app
    write_chats_app
    write_notifications_app
    write_video_app
    write_analytics_app
    write_reports_app
    write_api_external_app
    write_webhooks_app
    write_integrations_app
    write_base_templates
    write_page_templates
    write_static_files
    write_maintenance_scripts
    write_documentation
    write_seed_command

    # Шаг 34-41: Системная установка
    install_system_dependencies
    setup_postgresql
    setup_redis
    setup_nginx
    setup_supervisor
    setup_environment
    setup_backups
    
    # Установка SSL сертификатов (Certbot)
    if [ "$INSTALL_CERTBOT" = true ]; then
        install_certbot
    else
        log_info "SSL сертификат не установлен. Для установки используйте опцию --certbot"
    fi
    
    start_services

    # Установка Jitsi Meet (опционально)
    if [ "$INSTALL_JITSI" = true ]; then
        install_jitsi
    fi

    # Установка Mattermost (опционально)
    if [ "$INSTALL_MATTERMOST" = true ]; then
        install_mattermost
    fi

    # Загрузка тестовых данных (опционально)
    if [ "$INSTALL_TEST_DATA" = true ]; then
        load_test_data
    fi

    # Финальная статистика
    print_final_stats

    # Удаляем временные файлы с паролями
    rm -f /tmp/.db_password /tmp/.redis_password /tmp/.mattermost_admin_password /tmp/.mattermost_db_password

    log_success "Установка полностью завершена!"
}

# =============================================================================
# ЗАПУСК
# =============================================================================

# Запускаем главную функцию с аргументами
main "$@"
