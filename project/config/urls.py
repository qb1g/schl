"""
School CRM URL Configuration.
"""

from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from django.contrib.auth import views as auth_views

urlpatterns = [
    path('admin/', admin.site.urls),
    
    # Auth URLs
    path('login/', auth_views.LoginView.as_view(template_name='base/login.html'), name='login'),
    path('logout/', auth_views.LogoutView.as_view(), name='logout'),
    
    # Dashboard
    path('dashboard/', include('apps.core.urls', namespace='core')),
    
    # Apps
    path('users/', include('apps.users.urls', namespace='users')),
    path('schedule/', include('apps.schedule.urls', namespace='schedule')),
    path('grades/', include('apps.grades.urls', namespace='grades')),
    path('lessons/', include('apps.lessons.urls', namespace='lessons')),
    path('groups/', include('apps.groups.urls', namespace='groups')),
    path('exams/', include('apps.exams.urls', namespace='exams')),
    path('calendar/', include('apps.calendar.urls', namespace='calendar')),
    path('news/', include('apps.news.urls', namespace='news')),
    path('nutrition/', include('apps.nutrition.urls', namespace='nutrition')),
    path('chats/', include('apps.chats.urls', namespace='chats')),
    path('notifications/', include('apps.notifications.urls', namespace='notifications')),
    path('video/', include('apps.video.urls', namespace='video')),
    path('analytics/', include('apps.analytics.urls', namespace='analytics')),
    path('reports/', include('apps.reports.urls', namespace='reports')),
]

# Serve static and media files in development
if settings.DEBUG:
    urlpatterns += static(settings.STATIC_URL, document_root=settings.STATIC_ROOT)
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
