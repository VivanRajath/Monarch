"""Root URLconf: the generated UI at /, its workflow endpoint, and the example tasks app at /tasks/."""

from django.contrib import admin
from django.urls import include, path, re_path

from . import monarch

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/workflows/<str:key>", monarch.run_workflow),
    path("tasks/", include("core.urls")),
    re_path(r"^(?P<path>.*)$", monarch.public_file),
]
