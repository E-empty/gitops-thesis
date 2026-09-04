# Flux CD

## Zasoby

Konfigurację tworzą:

- `GitRepository/microservices-app` w `flux-system`, pobierane co 1 minutę;
- `HelmRelease/microservices-app` w `flux-system`, wdrażane do `test-fluxcd`.

HelmRelease wskazuje `./helm/microservices-app`, ustawia `releaseName` zgodny z
Argo CD, tworzy namespace, ma retry instalacji oraz włączone
`driftDetection.mode: enabled`. To ostatnie jest konieczne dla eksperymentów z
ręczną zmianą skali lub obrazu bez zmiany rewizji Git.

Upgrade ma `disableWait: true` i zero prób remediation. Gotowość jest mierzona
identycznie dla obu narzędzi przez runner, a celowo błędna wersja pozostaje
aktywna do commita `git revert`. Bez tego Helm mógłby przez kilka minut blokować
reconcile albo wykonać własny rollback, co zafałszowałoby test rollbacku GitOps.

## Instalacja

Najpierw podmień obrazy w chartcie, wykonaj commit i push. Następnie:

```bash
./scripts/install-fluxcd.sh \
  --repo-url https://github.com/<YOUR_GITHUB_USERNAME>/<YOUR_REPOSITORY>.git \
  --revision main \
  --context kind-gitops-thesis
```

Skrypt instaluje przypięte [Flux v2.9.3](https://github.com/fluxcd/flux2/releases/tag/v2.9.3)
z oficjalnego manifestu, czeka na
dostępność deploymentów, ustawia idempotentnie
`--interval-jitter-percentage=0` dla source-controller i helm-controller, a
następnie restartuje je i czeka na rollout. Placeholdery renderuje wyłącznie do
katalogu tymczasowego. Po aplikacji zasobów czeka na `Ready=True` zarówno dla
GitRepository, jak i HelmRelease (domyślny timeout: 10 minut). Bez parametrów
repozytorium instaluje tylko kontrolery. Kontekst można wskazać przez `--context`
lub `KUBE_CONTEXT`; bez nich używany jest wyłącznie `kind-gitops-thesis`.

Repozytorium prywatne wymaga Secretu referencjonowanego przez
`GitRepository.spec.secretRef`; sekret należy utworzyć poza Git lub zaszyfrować
dedykowanym rozwiązaniem. Dostarczone manifesty celowo obsługują publiczne repo.

## Obserwacja i reconcile

```bash
kubectl -n flux-system get gitrepository,helmrelease
kubectl -n flux-system describe helmrelease microservices-app
kubectl -n test-fluxcd get deployments,pods
./experiments/smoke-test.sh --tool fluxcd
```

Warunki `Ready=True` dla źródła i wydania oznaczają poprawny stan. Skrypty
pomiarowe nie uruchamiają `flux reconcile`, ponieważ skróciłoby to zmierzony czas
reakcji. Interwał 1 minuty należy pozostawić identyczny we wszystkich iteracjach.

## Różnica względem Argo CD

Flux reprezentuje źródło i wydanie w dwóch CRD, a Argo CD w jednym Application.
Sygnały detekcji są mapowane na równoważne publiczne statusy: rewizję artefaktu
GitRepository dla zmian Git oraz warunek/zdarzenie driftu HelmRelease dla zmian
poza Git. Argo używa statusu, operacji i rewizji Application. Korekta właściwego
Deploymentu jest wspólnym fallbackiem, jeżeli krótki stan przejściowy zniknie
między odczytami. Szczegóły opisuje `methodology.md`.
