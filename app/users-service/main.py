"""ASGI entry point for users-service."""

from common import create_app


app = create_app("users-service")
