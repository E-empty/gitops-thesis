# Eksperymenty

## Wspólny interfejs

Wszystkie scenariusze shell korzystają z `experiments/lib/common.sh`, włączają
`set -euo pipefail`, zapisują czas w UTC z dokładnością do milisekund i przyjmują
następujące opcje:

| Opcja | Domyślna wartość | Znaczenie |
| --- | --- | --- |
| `--tool` | brak | wymagane: `argocd` albo `fluxcd` |
| `--iterations` | 10 | liczba powtórzeń/próbek |
| `--namespace` | `test-<tool>` | namespace aplikacji |
| `--service` | `gateway-service` | cel wybierany po stabilnej etykiecie |
| `--timeout` | 300 | limit każdej fazy oczekiwania w sekundach |
| `--poll-interval` | 1 | częstotliwość obserwacji w sekundach |
| `--results-dir` | `results` | katalog danych surowych |
| `--gitops-resource` | `microservices-app` | nazwa Application/HelmRelease |
| `--context` | `kind-gitops-thesis` | jawnie wybrany kube-context |

Scenariusze reconcile zapisują przed i po iteracji listę zasobów, YAML
Deploymentów, zdarzenia oraz status kontrolera. Restart kontrolera i pomiar
zasobów zapisują wyspecjalizowane surowe logi. Błąd lub timeout scenariusza
reconcile także tworzy wiersz CSV i snapshot diagnostyczny; skrypt kończy serię
niezerowym kodem, aby kolejne pomiary nie były wykonywane ze znanego złego stanu.

## Definicje znaczników czasu

Główne CSV ma kolumny:

```csv
tool,test,iteration,start_time,detection_time,recovery_time,total_seconds,status
```

- `start_time`: bezpośrednio przed mutacją klastra albo commitem rollbacku;
- `detection_time`: pierwsza obserwowalna reakcja kontrolera, z korektą zasobu
  jako fallbackiem, gdy stan przejściowy nie trafi w okno pollingu;
- `recovery_time`: zgodna specyfikacja i gotowy Deployment/endpoint;
- `total_seconds`: czas od startu do recovery/timeout, zmierzony zegarem
  monotonicznym;
- `status`: `success`, `detection_timeout`, `recovery_timeout` albo
  `command_error` dla nieoczekiwanej awarii polecenia po starcie pomiaru;
  obsłużone `SIGINT`/`SIGTERM` zapisuje status `interrupted`.

Przy nieudanej iteracji nieistniejący `detection_time` lub `recovery_time`
pozostaje pusty; `total_seconds` nadal wskazuje monotoniczny czas do zgłoszenia
błędu. Analizator nie traktuje końca timeoutu jako pozornego recovery.

Różne kontrolery mogą wykryć i naprawić prostą wartość w jednym reconcile, więc
detection i recovery bywają bliskie. Dla rolloutów recovery pozostaje późniejsze,
bo obejmuje gotowość podów.

## Scenariusze drift i recovery

### Skala

```bash
./experiments/drift-scale.sh --tool argocd --iterations 10 \
  --service gateway-service --drift-replicas 5
```

Skrypt odczytuje deklarowaną liczbę replik (domyślnie 2), wykonuje `kubectl
scale`, wykrywa reakcję kontrolera (z przywróceniem `spec.replicas` jako
fallbackiem), a następnie czeka na zgodność `observedGeneration`,
`updatedReplicas`, `readyReplicas` i `availableReplicas`.

### Obraz

```bash
./experiments/drift-image.sh --tool fluxcd --iterations 10 \
  --drift-image registry.invalid/gitops-thesis/drift-image:never
```

Zmiana `kubectl set image` nie trafia do Git. Domyślny nieistniejący obraz
zapobiega przypadkowemu uruchomieniu niekontrolowanego kodu. Detekcją jest sygnał
reakcji Application/HelmRelease (z powrotem obrazu jako fallbackiem), a recovery
— gotowy rollout.

### Usunięcie Deploymentu

```bash
./experiments/delete-deployment.sh --tool argocd --iterations 10
```

Skrypt zapisuje UID i usuwa Deployment bez czekania. Detekcja używa statusu
kontrolera, a nowy UID jest fallbackiem; recovery wymaga pełnej gotowości
odtworzonego obiektu.

## Scenariusze modyfikujące Git

`deploy-new-version.sh`, `change-config.sh` i `rollback.sh` tworzą commity oraz
wykonują push do obserwowanej gałęzi. Zabezpieczenia:

- wymagane jest całkowicie czyste drzewo robocze;
- aktywna gałąź musi być identyczna z `--branch`, a lokalny HEAD z aktualnym
  `refs/heads/<branch>` odczytanym przez `git ls-remote`;
- edytowany plik musi znajdować się wewnątrz repozytorium;
- minimalny edytor zmienia wyłącznie istniejący scalar w znanej mapie `services`;
- każda zmiana powrotna jest nowym `git revert`, nie `kubectl rollout undo`;
- po udanym pushu zmiany pułapka `EXIT`/`INT`/`TERM` utrzymuje obowiązek
  rollbacku aż do wypchnięcia commita przywracającego baseline;
- po timeout lub przerwaniu skrypt automatycznie tworzy i wypycha `git revert`;
  gdy sam push rollbacku zawiedzie, ponawia go raz bez tworzenia drugiego reverta
  i pozostawia lokalny commit wraz z komendą naprawczą do diagnozy.

`SIGKILL`, utrata zasilania i awaria sieci po obu próbach push nie są możliwe do
obsłużenia pułapką procesu; przed kolejną serią trzeba wtedy wypchnąć pozostawiony
commit rollbacku i ponownie potwierdzić baseline.

Przed badaniem CI musi opublikować wszystkie tagi obrazów, a konfiguracja GitOps
musi śledzić tę samą gałąź, na którą skrypt wykonuje push.
Najbezpieczniej przeznaczyć do pomiarów osobną gałąź bez wymogu pull requestu,
dostępną wyłącznie dla operatora eksperymentu; chroniona `main` zwykle odrzuci
automatyczne commity scenariuszy.

### Nowa wersja

```bash
./experiments/deploy-new-version.sh --tool argocd --iterations 10 \
  --new-tag <PUBLISHED_GIT_SHA> --new-version 1.1.0
```

Skrypt zmienia tag i `APP_VERSION` wskazanej usługi. Detekcją jest reakcja na nową
rewizję Git (z nowym tagiem Deploymentu jako fallbackiem), recovery wymaga
docelowego tagu, gotowego Deploymentu oraz wersji `1.1.0` zwróconej przez
`/version`. Po pomiarze `git revert` przywraca baseline i skrypt czeka na jego
gotowość przed kolejną iteracją.

### Zmiana konfiguracji

```bash
./experiments/change-config.sh --tool fluxcd --iterations 10 --value thesis
```

Zmieniany jest neutralny `EXPERIMENT_CONFIG`. Helm przelicza
`checksum/config`, co uruchamia rollout. Detekcją jest reakcja na rewizję Git
(nowy checksum jest fallbackiem), recovery — zmieniony checksum i gotowość
rolloutu; następnie revert przywraca baseline.

### Rollback Git

```bash
./experiments/rollback.sh --tool argocd --iterations 10
```

Faza przygotowawcza commituje `APP_FAILURE_MODE=readiness` i czeka, aż nowy pod
nie przejdzie readiness. Nie jest ona wliczana do wyniku rollbacku. Pomiar zaczyna
się przed `git revert` złego commita. Detekcją jest reakcja na rewizję rollbacku
(powrót checksum jest fallbackiem), recovery wymaga wszystkich replik Ready oraz
odpowiedzi `status=ready` z `/ready`.

## Restart kontrolera

```bash
./experiments/restart-gitops-controller.sh --tool fluxcd --iterations 10
```

Domyślnym celem jest `argocd-application-controller` albo `helm-controller`.
Skrypt usuwa pod, wykrywa zastępczy UID i czeka na warunek Ready. Namespace i
selector można nadpisać. Ten test mierzy odporność procesu reconcile, a nie
rollout aplikacji.

## Smoke test

```bash
./experiments/smoke-test.sh --tool argocd --service gateway-service
```

Test używa proxy API Kubernetes, więc nie potrzebuje `curl` w obrazie,
Ingressu ani port-forward. Sprawdza JSON zwracany przez `/health`, `/ready` i
`/version`.

## Zużycie zasobów

Po instalacji Metrics Servera:

```bash
./experiments/resource-usage.sh --tool argocd --phase idle --iterations 30
./experiments/resource-usage.sh --tool argocd --phase sync --iterations 30 \
  --trigger-command './experiments/change-config.sh --tool argocd --iterations 1'
./experiments/resource-usage.sh --tool argocd --phase drift --iterations 30 \
  --trigger-command './experiments/drift-scale.sh --tool argocd --iterations 1'
```

Dla `sync` i `drift` skrypt wymaga `--trigger-command` i uruchamia go równolegle,
więc faza odpowiada rzeczywistej operacji. Polecenie powinno mieć własny timeout;
jego niezerowy kod zatrzymuje serię, ale zebrane próbki pozostają na dysku. CSV
zawiera raw Kubernetes quantity oraz wartości przeliczone na millicores i MiB dla
każdego poda kontrolera. Brak metryki jest zachowany jako `metrics_unavailable`,
a nie zamieniany na zero.

## Analiza

```bash
python3 analysis/analyze_results.py \
  --input-dir results --output-dir analysis/output --plots
```

Skrypt korzysta ze standardowej biblioteki Python. Dla każdego narzędzia i testu
oblicza osobno czas detekcji, czas od detekcji do recovery i czas całkowity oraz
ich N, średnią, medianę, minimum, maksimum i próbne odchylenie standardowe.
CPU i RAM najpierw sumuje po wszystkich podach w jednej chwili pomiaru, a dopiero
potem agreguje według narzędzia/fazy. Wiersze nieudane pozostają w surowych danych,
ale nie wchodzą do statystyk czasu; ich liczbę należy raportować oddzielnie.
`--plots` tworzy PNG, jeśli opcjonalny `matplotlib` jest dostępny.
