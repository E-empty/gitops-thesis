"""Unit tests for the common API exposed by every service."""

from __future__ import annotations

import runpy
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from common import create_app


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SERVICES = ("gateway-service", "users-service", "orders-service")


def _load_service(service_name: str):
    module = runpy.run_path(
        str(REPOSITORY_ROOT / "app" / service_name / "main.py"),
        run_name=f"test_{service_name.replace('-', '_')}",
    )
    return module["app"]


@pytest.mark.parametrize("service_name", SERVICES)
def test_service_entrypoint_exposes_operational_endpoints(
    service_name: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("APP_VERSION", "1.2.3")
    monkeypatch.setenv("POD_NAME", f"{service_name}-test-pod")
    monkeypatch.delenv("APP_FAILURE_MODE", raising=False)

    client = TestClient(_load_service(service_name))

    root = client.get("/")
    assert root.status_code == 200
    assert root.json() == {
        "service": service_name,
        "version": "1.2.3",
        "hostname": f"{service_name}-test-pod",
        "message": f"{service_name} is running",
        "status": "ok",
    }

    health = client.get("/health")
    assert health.status_code == 200
    assert health.json() == {
        "service": service_name,
        "status": "healthy",
        "hostname": f"{service_name}-test-pod",
    }

    ready = client.get("/ready")
    assert ready.status_code == 200
    assert ready.json()["status"] == "ready"

    version = client.get("/version")
    assert version.status_code == 200
    assert version.json() == {
        "service": service_name,
        "version": "1.2.3",
        "hostname": f"{service_name}-test-pod",
    }


def test_readiness_failure_mode_is_deterministic(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("APP_FAILURE_MODE", "readiness")
    client = TestClient(create_app("users-service"))

    assert client.get("/health").status_code == 200
    response = client.get("/ready")
    assert response.status_code == 503
    assert response.json()["status"] == "not-ready"
    assert response.json()["failure_mode"] == "readiness"


def test_http_failure_mode_keeps_diagnostics_available(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("APP_FAILURE_MODE", "http")
    monkeypatch.setenv("APP_VERSION", "broken-version")
    client = TestClient(create_app("orders-service"))

    assert client.get("/").status_code == 500
    assert client.get("/ready").status_code == 503
    assert client.get("/health").status_code == 200
    assert client.get("/version").json()["version"] == "broken-version"


def test_unknown_failure_mode_stops_a_misconfigured_release(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("APP_FAILURE_MODE", "surprise")

    with pytest.raises(RuntimeError, match="Unsupported APP_FAILURE_MODE"):
        create_app("gateway-service")
