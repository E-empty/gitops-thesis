# Kubernetes, Kind i Helm

## Klaster lokalny

`scripts/create-cluster.sh` tworzy klaster `gitops-thesis` z pliku
`scripts/kind-config.yaml`. Węzeł control-plane otrzymuje etykietę
`ingress-ready=true`, a porty hosta `8080` i `8443` są mapowane odpowiednio na
porty węzła 80 i 443. Skrypt domyślnie przypina wieloarchitekturowy obraz
`kindest/node:v1.33.4@sha256:25a6018e48dfcaee478f4a59af81157a437f15e6e140bf103f85a2e7cd0cbbf2`;
`--image` lub `KIND_NODE_IMAGE` służą do jawnego, udokumentowanego override'u.
Tag i digest pochodzą z oficjalnych informacji o wydaniu
[kind v0.30.0](https://github.com/kubernetes-sigs/kind/releases/tag/v0.30.0).

```bash
./scripts/check-requirements.sh
./scripts/create-cluster.sh
kubectl cluster-info --context kind-gitops-thesis
```

Nazwa, obraz węzła, config i timeout są parametrami skryptu. Dla właściwego
badania należy zapisać wynik `kind version`, obraz `kindest/node` i wersję
Kubernetes. Usuwanie klastra jest jawne:

```bash
./scripts/delete-cluster.sh --name gitops-thesis
```

## Wspólny chart

Chart znajduje się w `helm/microservices-app`. `values.yaml` zawiera mapę
`services.gateway`, `services.users`, `services.orders`. Dla każdej usługi można
niezależnie zmienić:

- `enabled`, `name`, `replicas`;
- `image.repository`, `image.tag`, `image.pullPolicy`;
- port kontenera i parametry `Service`;
- dowolne wartości `env` przekazywane przez ConfigMap;
- requests/limits;
- pełne parametry liveness/readiness probe.

Globalne `imageRegistry` i `imageOwner` pozwalają zastąpić trzy repozytoria
jednym ustawieniem. Ingress ma własne `enabled`, `className`, annotations, hosts,
paths i TLS. Schema JSON wcześnie odrzuca błędne typy i brak wymaganych pól.

Walidacja bez klastra:

```bash
helm lint helm/microservices-app
helm template microservices-app helm/microservices-app --namespace test-render
```

## Ręczne wdrożenie kontrolne

Domyślne repozytoria obrazów zawierają `<YOUR_GITHUB_USERNAME>`, więc skrypt
odmówi wdrożenia bez podania prawidłowych wartości:

```bash
./scripts/deploy-app-manually.sh \
  --namespace test-manual \
  --registry ghcr.io \
  --image-owner <YOUR_GITHUB_USERNAME> \
  --tag <PUBLISHED_GIT_SHA> \
  --app-version 1.0.0 \
  --atomic
```

Skrypt najpierw wykonuje lint i render, potem `helm upgrade --install --wait`.
Do lokalnego obrazu w Kind można użyć `kind load docker-image` i przekazać
per-service repo/tag przez `--set-string`.

## Ingress

Chart nie instaluje kontrolera Ingress, aby nie dodawać wspólnego obciążenia bez
potrzeby. Jeśli badanie wymaga dostępu przez Ingress, należy zainstalować tę samą
wersję ingress-nginx w obu seriach, włączyć `ingress.enabled` i kierować żądania
na `http://microservices.local:8080`. Smoke test nie wymaga Ingressu — używa
proxy API Kubernetes.

## Metrics Server

```bash
./scripts/install-metrics-server.sh
kubectl top pods -A
```

Instalator przypina [Metrics Server v0.7.2](https://github.com/kubernetes-sigs/metrics-server/releases/tag/v0.7.2)
i na Kind dodaje `--kubelet-insecure-tls`. Jest to
lokalny kompromis wynikający z certyfikatów kubeleta w Kind; nie jest zaleceniem
dla klastra produkcyjnego. Przed pomiarem należy zaczekać na dostępność metryk.
