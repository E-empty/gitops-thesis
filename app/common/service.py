"""Common FastAPI application factory used by all demonstration services."""

from __future__ import annotations

import os
import socket
from typing import Final

from fastapi import FastAPI
from fastapi.responses import JSONResponse


DEFAULT_VERSION: Final = "0.0.0"
NORMAL_MODE: Final = "none"
READINESS_FAILURE_MODE: Final = "readiness"
HTTP_FAILURE_MODE: Final = "http"
SUPPORTED_FAILURE_MODES: Final = {
    NORMAL_MODE,
    READINESS_FAILURE_MODE,
    HTTP_FAILURE_MODE,
}


def _read_environment(name: str, default: str) -> str:
    """Return a trimmed environment value, falling back for missing/blank input."""

    value = os.getenv(name, default).strip()
    return value or default


def _hostname() -> str:
    """Prefer the Kubernetes pod name while remaining useful outside Kubernetes."""

    pod_name = os.getenv("POD_NAME", "").strip()
    return pod_name or socket.gethostname()


def create_app(service_name: str) -> FastAPI:
    """Create one of the stateless services with a shared operational API.

    ``APP_FAILURE_MODE`` provides a deterministic bad release for rollback tests:
    ``readiness`` fails only readiness, while ``http`` also fails the root request.
    Health and version endpoints deliberately stay available for diagnostics.
    """

    version = _read_environment("APP_VERSION", DEFAULT_VERSION)
    failure_mode = _read_environment("APP_FAILURE_MODE", NORMAL_MODE).lower()
    if failure_mode not in SUPPORTED_FAILURE_MODES:
        supported = ", ".join(sorted(SUPPORTED_FAILURE_MODES))
        raise RuntimeError(
            f"Unsupported APP_FAILURE_MODE={failure_mode!r}; expected one of: {supported}"
        )

    hostname = _hostname()
    app = FastAPI(
        title=service_name,
        version=version,
        description="Stateless demonstration service for GitOps experiments.",
    )

    def identity() -> dict[str, str]:
        return {
            "service": service_name,
            "version": version,
            "hostname": hostname,
        }

    @app.get("/", tags=["application"])
    def root():
        payload = {
            **identity(),
            "message": f"{service_name} is running",
        }
        if failure_mode == HTTP_FAILURE_MODE:
            return JSONResponse(status_code=500, content=payload | {"status": "error"})
        return payload | {"status": "ok"}

    @app.get("/health", tags=["probes"])
    def health() -> dict[str, str]:
        return {
            "service": service_name,
            "status": "healthy",
            "hostname": hostname,
        }

    @app.get("/ready", tags=["probes"])
    def ready():
        if failure_mode in {READINESS_FAILURE_MODE, HTTP_FAILURE_MODE}:
            return JSONResponse(
                status_code=503,
                content={
                    "service": service_name,
                    "status": "not-ready",
                    "hostname": hostname,
                    "failure_mode": failure_mode,
                },
            )
        return {
            "service": service_name,
            "status": "ready",
            "hostname": hostname,
        }

    @app.get("/version", tags=["application"])
    def application_version() -> dict[str, str]:
        return identity()

    return app
