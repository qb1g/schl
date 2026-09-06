# SchoolCRM — Система управления школой

Модульная CRM-система для автоматизации учебных заведений.

## Структура проекта

```
/workspace/
├── install_scripts/          # Скрипты установки (модульные)
│   ├── main.sh              # Главный скрипт установки
│   ├── config/              # Конфигурация и переменные
│   ├── utils/               # Утилиты (логирование)
│   ├── system/              # Системные зависимости
│   ├── database/            # Настройка БД (PostgreSQL, Redis)
│   ├── python/              # Python окружение
│   ├── django/              # Миграции и команды Django
│   └── permissions/         # Права доступа
├── project/                  # Исходный код проекта Django
│   ├── apps/                # Приложения Django
│   ├── config/              # Настройки Django
│   ├── templates/           # HTML шаблоны
│   ├── static/              # Статические файлы
│   ├── media/               # Медиа файлы
│   ├── manage.py            # Управление проектом
│   └── requirements.txt     # Python зависимости
└── README.md                # Этот файл
```

## Быстрый старт

### Установка на сервер

```bash
# Скопируйте папку install_scripts и project на сервер
sudo ./install_scripts/main.sh /opt/schoolcrm
```

### Ручной запуск (разработка)

```bash
cd project

# Создание виртуального окружения
python3 -m venv venv
source venv/bin/activate

# Установка зависимостей
pip install -r requirements.txt

# Настройка переменных окружения
export DB_NAME=schoolcrm
export DB_USER=schoolcrm
export DB_PASSWORD=your_password
export REDIS_PASSWORD=your_redis_password
export SECRET_KEY=your_secret_key

# Применение миграций
python manage.py migrate

# Создание суперпользователя
python manage.py createsuperuser

# Запуск сервера разработки
python manage.py runserver 0.0.0.0:8000
```

## Доступные приложения

- **users** — Пользователи (администраторы, учителя, ученики, родители)
- **core** — Базовая функциональность и дашборд
- **schedule** — Расписание занятий
- **grades** — Оценки и успеваемость
- **lessons** — Уроки
- **groups** — Классы и группы
- **exams** — Экзамены
- **calendar** — Календарь событий
- **news** — Новости школы
- **nutrition** — Питание
- **chats** — Чаты
- **notifications** — Уведомления
- **video** — Видеоконференции
- **analytics** — Аналитика
- **reports** — Отчёты

## Требования

- Python 3.10+
- PostgreSQL 12+
- Redis 6+
- Nginx (для production)
- Supervisor (для production)

## Документация

Полная документация находится в процессе разработки.

## Лицензия

MIT