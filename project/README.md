# School CRM — Система управления школой

## Описание

School CRM — это современная веб-система для управления образовательным процессом в школе.

## Возможности

- Управление пользователями (учителя, ученики, родители)
- Электронный журнал и оценки
- Расписание уроков
- Новости и объявления
- Видеоконференции (интеграция с Jitsi)
- Чаты и уведомления
- Отчеты и аналитика

## Структура проекта

```
/opt/schoolcrm/
├── config/              # Настройки Django
├── apps/                # Приложения Django
│   ├── users/          # Пользователи
│   ├── grades/         # Оценки
│   ├── schedule/       # Расписание
│   └── ...
├── templates/           # HTML шаблоны
├── static/             # Статические файлы
├── media/              # Загруженные файлы
└── logs/               # Логи приложения
```

## Установка

### Быстрая установка

```bash
sudo ./install_scripts/main.sh /opt/schoolcrm
```

### Модульная установка

Каждый модуль установки можно запустить отдельно:

```bash
# Установка системных зависимостей
source install_scripts/config/variables.sh
source install_scripts/utils/logging.sh
source install_scripts/system/dependencies.sh
install_system_dependencies

# Настройка PostgreSQL
source install_scripts/database/postgresql.sh
setup_postgresql

# Настройка Python окружения
source install_scripts/python/environment.sh
setup_environment
```

## Требования

- Ubuntu 20.04+ / Debian 11+
- 2 GB RAM (рекомендуется 4 GB)
- 10 GB свободного места
- root права

## Запуск

После установки система доступна по адресу:

```
http://<IP-адрес-сервера>/
```

Учетные данные администратора:
- Логин: `admin`
- Пароль: (показывается при установке)

## Логи

Лог установки сохраняется в `/tmp/schoolcrm_install_*.log`

Логи приложения:
- `/opt/schoolcrm/logs/gunicorn.log` — веб-сервер
- `/opt/schoolcrm/logs/celery.log` — фоновые задачи

## Поддержка

Для вопросов и предложений обращайтесь к разработчикам.
