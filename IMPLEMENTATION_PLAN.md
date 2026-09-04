# Plan implementacji środowiska badawczego GitOps

## 1. Cel i kryteria projektowe

Repozytorium będzie zawierało lekką aplikację demonstracyjną oraz kompletne,
powtarzalne środowisko do porównania Argo CD i Flux CD. Oba kontrolery będą
wdrażały te same obrazy za pomocą jednego chartu Helm. Różnice ograniczą się do
zasobów źródłowych właściwych dla danego kontrolera.

Najważniejsze zasady:

- jeden kod aplikacji i jeden chart Helm dla obu narzędzi;
- brak zewnętrznego stanu i bazy danych;
- obrazy wersjonowane niezmiennym tagiem (domyślnie SHA commita);
- surowe pomiary oraz diagnostyka zachowywane bez agregowania ich w Bashu;
- pojedynczy kontroler zarządza badanym wydaniem w danej serii;
- parametry środowiska i eksperymentów są jawne i możliwe do odtworzenia.

## 2. Docelowa struktura repozytorium

```text
.
├── .github/workflows/
│   ├── ci.yml
│   └── lint.yml
├── analysis/
│   ├── analyze_results.py
│   ├── test_analyze_results.py
│   └── fixtures/
├── app/
│   ├── common/
│   ├── gateway-service/
│   ├── users-service/
│   └── orders-service/
├── docs/
│   ├── architecture.md
│   ├── application.md
│   ├── argocd.md
│   ├── experiments.md
│   ├── fluxcd.md
│   ├── kubernetes.md
│   └── methodology.md
├── experiments/
│   ├── lib/common.sh
│   ├── change-config.sh
│   ├── delete-deployment.sh
│   ├── deploy-new-version.sh
│   ├── drift-image.sh
│   ├── drift-scale.sh
│   ├── resource-usage.sh
│   ├── restart-gitops-controller.sh
│   └── rollback.sh
├── gitops/
│   ├── argocd/
│   └── fluxcd/
├── helm/microservices-app/
│   ├── templates/
│   ├── Chart.yaml
│   └── values.yaml
├── scripts/
├── tests/
├── docker-compose.yml
├── Makefile
└── README.md
```

Każdy katalog serwisu będzie zawierał własne `Dockerfile`, `.dockerignore`,
plik zależności i cienki punkt wejścia. Wspólny, mały moduł FastAPI wyeliminuje
nieistotne różnice pomiędzy usługami, zachowując oddzielne obrazy i procesy.

## 3. Etapy implementacji i walidacja

### Etap 1 — aplikacja mikroserwisowa

1. Zaimplementować `gateway-service`, `users-service` i `orders-service` w
   FastAPI.
2. Dodać wymagane endpointy, identyfikację poda i kontrolowany tryb awarii.
3. Dodać testy jednostkowe endpointów.
4. Uruchomić testy i statyczną kontrolę składni.

### Etap 2 — Docker

1. Dodać trzy minimalne obrazy uruchamiane jako użytkownik nie-root.
2. Dodać `.dockerignore` i `docker-compose.yml` z healthcheckami.
3. Zweryfikować konfigurację Compose, a jeśli Docker jest dostępny — zbudować
   obrazy i wykonać test dymny.

### Etap 3 — Kubernetes i Helm

1. Utworzyć jeden chart generujący ConfigMap, Deployment i Service dla każdej
   usługi oraz opcjonalny Ingress dla gatewaya.
2. Udostępnić w `values.yaml` obrazy, repliki, zasoby, środowisko i parametry
   sond.
3. Dodać skrypty Kind, ręcznego wdrożenia, Metrics Servera i sprzątania.
4. Wykonać `helm lint` i `helm template`; pełny test Kind wykonać, jeśli lokalne
   narzędzia i daemon Docker są dostępne.

### Etap 4 — CI

1. Workflow testowy z testami Python oraz buildem i publikacją trzech obrazów
   do GHCR dla pushów na główną gałąź.
2. Osobny workflow lintujący Python, YAML oraz chart Helm.
3. Użyć uprawnień `packages: write`, wbudowanego `GITHUB_TOKEN` i tagów SHA;
   nie umieszczać sekretów w repozytorium.

### Etap 5 — Argo CD

1. Dodać deklaratywny `Application` z automatycznym prune i self-heal.
2. Dodać instalator przypinający wersję manifestu upstream oraz skrypt dostępu
   do UI.
3. Repozytorium i rewizję przekazywać jawnie; placeholdery pozostawić tam,
   gdzie nie znamy URL użytkownika.

### Etap 6 — Flux CD

1. Dodać `GitRepository` i `HelmRelease` wskazujące ten sam chart.
2. Dodać instalator kontrolerów Flux o przypiętej wersji.
3. Ustawić równoważne wartości aplikacji i udokumentować techniczne różnice w
   cyklu reconcile.

### Etap 7 — eksperymenty

1. Zbudować wspólną bibliotekę argumentów, zegara, logowania CSV, snapshotów i
   oczekiwania na detekcję oraz odzyskanie.
2. Zaimplementować drift skali/obrazu, usunięcie Deploymentu, zmianę
   konfiguracji, nową wersję, rollback Git i restart kontrolera.
3. Każdy scenariusz obsłuży `--tool`, `--iterations` (domyślnie 10), timeout i
   interwał odpytywania.
4. Resource usage zapisze próbki `kubectl top` w osobnym, dobrze zdefiniowanym
   formacie CSV.

### Etap 8 — analiza wyników

1. Wczytać wszystkie pomiary CSV i odrzucić pliki o innym schemacie.
2. Obliczyć per narzędzie i eksperyment: N, średnią, medianę, minimum, maksimum
   i odchylenie standardowe.
3. Zapisać podsumowanie CSV i opcjonalne wykresy, jeśli dostępny jest
   `matplotlib`.
4. Dodać testy analizy dla małego deterministycznego zbioru.

### Etap 9 — dokumentacja

1. Opisać wyłącznie faktycznie zaimplementowane elementy.
2. Dodać diagram Mermaid, instrukcję odtworzenia, macierz eksperymentów,
   ograniczenia pomiarów i procedurę czyszczenia.
3. Wykonać końcową kontrolę odwołań, składni skryptów, renderowania Helm i
   testów.

## 4. Decyzje architektoniczne

- **Python/FastAPI:** krótki i czytelny kod, łatwe testy HTTP oraz niewielka
  liczba zależności.
- **HelmRelease w Flux:** pozwala wdrożyć dokładnie ten sam lokalny chart Helm,
  którego używa `Application` Argo CD.
- **Reset klastra jako wariant referencyjny:** wyniki główne będą zbierane po
  odtworzeniu identycznego klastra między seriami. Oddzielne namespace pozostają
  wygodnym wariantem pilotażowym, ale nie eliminują wpływu drugiego kontrolera na
  zasoby węzła.
- **Detekcja obserwowana przez stan kontrolera:** początek reakcji jest mierzony
  na podstawie statusu Argo/Flux, a odzyskanie na podstawie rzeczywistego stanu
  zasobów i gotowości poda. Definicje te będą jawnie zapisane w metodologii.
- **Rollback przez Git:** eksperyment zmienia deklarację wersji, zapisuje commit,
  a powrót realizuje kolejnym commitem odwracającym zmianę; historia Git pozostaje
  źródłem prawdy.

## 5. Ryzyka i ograniczenia techniczne

- Nieznany URL repozytorium i właściciel GHCR wymagają placeholderów lub
  parametrów instalatora; konfiguracja nie będzie udawała gotowej do użycia bez
  ich podania.
- Pomiar „detekcji” nie ma identycznej reprezentacji w API obu kontrolerów.
  Skrypty zastosują udokumentowane, możliwie równoważne sygnały statusu.
- Domyślne interwały reconcile wpływają na wynik. Będą przypięte i raportowane,
  a wymuszenie reconcile nie będzie używane w scenariuszach mierzących reakcję
  okresową.
- `kubectl top` wymaga działającego Metrics Servera i czasu na ustabilizowanie
  metryk; próbki tuż po instalacji mogą być niedostępne.
- Eksperymenty wersji i rollbacku modyfikują Git i publikowane obrazy. Skrypt
  przed zmianą sprawdzi czyste drzewo robocze oraz wymagane parametry, a operacje
  push pozostaną jawne.
- Pełna walidacja Argo CD/Flux CD wymaga Dockera, Kind, dostępu do sieci i
  dostępnego repozytorium Git. Gdy środowisko lokalne ich nie zapewnia, walidacja
  statyczna zostanie oddzielona od testu integracyjnego i ograniczenie będzie
  wyraźnie zgłoszone.

## 6. Definition of Done dla implementacji

Za zakończone uznajemy tylko elementy, które mają kod, instrukcję użycia i
odpowiednią walidację. Test integracyjny wymagający usług zewnętrznych nie będzie
oznaczony jako wykonany, jeżeli środowisko go nie umożliwi; README poda dokładną
komendę pozwalającą go powtórzyć na maszynie badawczej.
