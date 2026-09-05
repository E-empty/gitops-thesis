# Argo CD

## Zasoby

`gitops/argocd/application.yaml` definiuje `Application/microservices-app` w
namespace `argocd`. Źródłem jest katalog `helm/microservices-app`, Helm używa
release name `microservices-app`, a celem jest domyślnie `test-argocd`.

Polityka synchronizacji zawiera:

- automatyczną synchronizację;
- `prune: true`;
- `selfHeal: true`;
- automatyczne utworzenie namespace;
- brak automatycznego retry nieudanego syncu (`retry.limit: 0`), zgodnie z
  `upgrade.remediation.retries: 0` w badanym HelmRelease Flux;
- usuwanie z propagacją foreground i prune na końcu.

## Instalacja

Najpierw podmień repozytoria/tagi obrazów w `values.yaml`, wykonaj commit i push.
Następnie:

```bash
./scripts/install-argocd.sh \
  --repo-url https://github.com/<YOUR_GITHUB_USERNAME>/<YOUR_REPOSITORY>.git \
  --revision main \
  --context kind-gitops-thesis
```

Skrypt instaluje przypięte [Argo CD v3.5.0](https://github.com/argoproj/argo-cd/releases/tag/v3.5.0)
z oficjalnego manifestu, aplikuje
`reconciliation-config.yaml`, czeka na wszystkie Deploymenty i StatefulSety,
bez zapisywania poświadczeń renderuje placeholdery do pliku tymczasowego i
aplikuje Application. Instalacja kończy się dopiero, gdy Application jest
jednocześnie `Synced` i `Healthy` (domyślny timeout: 10 minut). Bez parametrów
repozytorium instaluje tylko kontroler. Kontekst można wskazać przez `--context`
lub `KUBE_CONTEXT`; bez nich używany jest wyłącznie `kind-gitops-thesis`.

ConfigMap ustawia `timeout.reconciliation: 60s`, jitter `0s` oraz
`controller.self.heal.backoff.timeout.seconds: "0"`. Ostatnia wartość wyłącza
stanowy exponential backoff między kolejnymi self-heal tej samej rewizji, aby
iteracja N nie dziedziczyła opóźnienia po iteracji N-1. Instalator restartuje
application-controller i repo-server. Watch zasobów Argo CD pozostaje aktywny i
jest naturalną cechą narzędzia; wyłączony jest wyłącznie mechanizm naruszający
niezależność powtarzanych prób.

Domyślne zachowanie Argo CD należy mierzyć w osobnej serii „native”. Po usunięciu
klucza `controller.self.heal.backoff.timeout.seconds`, restarcie
application-controllera i przekazaniu runnerowi
`--allow-argocd-self-heal-backoff` seria pokazuje narastanie `2, 6, 18, 54, 162,
300 s`. Nie wolno łączyć jej statystycznie z profilem kontrolowanym.
Repozytorium prywatne wymaga osobnej deklaratywnej konfiguracji credentiali w
Argo CD; token nie może znaleźć się w tym repozytorium.

## Obserwacja

```bash
kubectl -n argocd get applications.argoproj.io microservices-app -w
kubectl -n test-argocd get deployments,pods
./experiments/smoke-test.sh --tool argocd
```

Stan oczekiwany to `Synced` i `Healthy`. Eksperymenty nie wymuszają ręcznie
`argocd app sync`, ponieważ mierzą automatyczną reakcję kontrolera.

## UI

```bash
./scripts/argocd-ui.sh --port 8081
```

Skrypt wiąże port-forward tylko z `127.0.0.1`, pokazuje komendę odczytu
jednorazowego hasła i udostępnia UI pod `https://127.0.0.1:8081`. Port 8080 jest
zarezerwowany przez mapowanie HTTP klastra Kind. Certyfikat jest
domyślnie samopodpisany.

## Usuwanie przed serią Flux

Najbardziej wiarygodna procedura to usunięcie całego klastra. Samo usunięcie
Application z finalizerem usuwa również zarządzane zasoby, ale nie zeruje cache,
metryk ani obciążenia węzła.
