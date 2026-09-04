# Aplikacja mikroserwisowa

## Usługi

Kod wspólny znajduje się w `app/common/service.py`, natomiast każdy katalog
`app/<service>/` ma własny punkt wejścia, zależności, `Dockerfile` i
`.dockerignore`. Usługi nie przechowują stanu i nie wymagają bazy danych.

| Usługa | Port w kontenerze | Port Docker Compose |
| --- | ---: | ---: |
| gateway-service | 8000 | 8000 |
| users-service | 8000 | 8001 |
| orders-service | 8000 | 8002 |

## API operacyjne

Każda usługa wystawia:

| Endpoint | Zastosowanie | Odpowiedź w trybie normalnym |
| --- | --- | --- |
| `GET /` | identyfikacja procesu | nazwa, wersja, hostname, status i komunikat |
| `GET /health` | liveness probe | HTTP 200 i `status=healthy` |
| `GET /ready` | readiness probe | HTTP 200 i `status=ready` |
| `GET /version` | weryfikacja wdrożenia | nazwa, `APP_VERSION` i hostname |

Hostname jest pobierany z `POD_NAME`, jeśli Kubernetes przekazał tę zmienną
przez Downward API; lokalnie używana jest nazwa hosta kontenera.

## Konfiguracja i kontrolowana awaria

- `APP_VERSION` — wersja raportowana przez `/` i `/version`, domyślnie `0.0.0`;
- `POD_NAME` — opcjonalna nazwa instancji;
- `APP_FAILURE_MODE=none` — działanie normalne;
- `APP_FAILURE_MODE=readiness` — `/ready` zwraca HTTP 503;
- `APP_FAILURE_MODE=http` — `/` zwraca HTTP 500, a `/ready` HTTP 503.

Nieznany failure mode zatrzymuje start aplikacji. Tryby awarii pozostawiają
`/health` i `/version` dostępne diagnostycznie; eksperyment rollbacku używa trybu
`readiness`.

## Uruchomienie lokalne

```bash
docker compose up --build --wait -d
curl http://localhost:8000/version
curl http://localhost:8001/health
curl http://localhost:8002/ready
docker compose down
```

Awarię można zasymulować bez zmiany kodu:

```bash
GATEWAY_FAILURE_MODE=readiness docker compose up --build gateway-service
```

## Testy

`tests/test_services.py` ładuje każdy punkt wejścia i sprawdza wszystkie cztery
endpointy, identyfikację poda oraz trzy tryby awarii. Uruchomienie:

```bash
python3 -m pip install -r requirements-dev.txt
python3 -m pytest tests analysis
```
