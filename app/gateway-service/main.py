"""ASGI entry point for gateway-service."""

from common import create_app


app = create_app("gateway-service")
