"""ASGI entry point for orders-service."""

from common import create_app


app = create_app("orders-service")
