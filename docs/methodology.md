# Metodyka badań

## Pytanie badawcze

Środowisko służy do porównania czasu automatycznej synchronizacji, wykrywania i
naprawy driftu, odzyskania usuniętych zasobów, rollbacku oraz narzutu zasobowego
Argo CD i Flux CD przy tej samej aplikacji i deklaracji Kubernetes.

## Jednostka eksperymentalna

Jedną obserwacją jest pojedyncza iteracja scenariusza wykonana od potwierdzonego
stanu bazowego do potwierdzonego recovery. Seria to 10 prób pilotażowych albo
20–30 prób właściwych jednego scenariusza i jednego narzędzia.

## Zalecany wariant izolacji

Do wyników właściwych zalecany jest **wariant B — reset klastra między seriami**:

1. utworzyć klaster z tym samym plikiem Kind i przypiętym obrazem węzła;
2. zainstalować tylko badany kontroler oraz, dla CPU/RAM, Metrics Server;
3. poczekać na stabilizację i wykonać smoke test;
4. uruchomić pełną serię bez zmiany konfiguracji kontrolera;
5. zarchiwizować wyniki i wersje;
6. usunąć klaster;
7. odtworzyć go identycznie dla drugiego kontrolera.

Wariant A (`test-argocd`, `test-fluxcd`) jest dopuszczalny dla pilotażu i
debugowania. Sam namespace nie izoluje CPU, RAM, kube-apiservera ani I/O węzła;
nie powinien więc być podstawą wniosków o zużyciu zasobów.

## Kontrolowane zmienne

W obu seriach muszą pozostać identyczne:

- commit repozytorium, chart i wartości aplikacji;
- digesty lub tagi SHA trzech obrazów;
- image Kind, liczba węzłów i zasoby hosta/VM;
- liczba replik, requests/limits, sondy i strategia rollout;
- registry i warunki sieciowe;
- timeout, polling, liczba iteracji i kolejność scenariuszy;
- obecność/nieobecność Metrics Servera;
- czas stabilizacji po instalacji i między iteracjami.

Należy ograniczyć równoległe obciążenie hosta, aktualizacje systemu i inne
procesy. Dobrą praktyką jest losowanie kolejności narzędzi pomiędzy pełnymi
powtórzeniami środowiska, aby zmniejszyć efekt kolejności.

## Zmienne wynikowe

- czas całkowity od mutacji do recovery;
- czas do pierwszego obserwowalnego sygnału reakcji kontrolera;
- liczba nieudanych/timeoutowanych iteracji;
- CPU w millicores i pamięć w MiB kontrolerów podczas idle/sync/drift.

Skrypty przechowują timestampy UTC bezpośrednio, natomiast timeouty i
`total_seconds` liczą zegarem monotonicznym. Korekta NTP albo ręczna zmiana czasu
hosta nie skraca więc ani nie wydłuża całej obserwacji. Analiza wyprowadza czasy
faz z timestampów UTC, dlatego zegar hosta nadal powinien być synchronizowany.

## Operacjonalizacja detekcji i recovery

Statusy API kontrolerów nie są izomorficzne i mogą trwać krócej niż interwał
pollingu. Detekcja oznacza pierwszy zaobserwowany sygnał, że kontroler rozpoczął
reakcję. Dla Argo CD jest to `OutOfSync`, nowa operacja synchronizacji albo nowa
rewizja Application. Dla zmian Git we Flux jest to nowa rewizja artefaktu
GitRepository; dla driftu — nowy/aktywny warunek `Drifted` HelmRelease albo
zdarzenie driftu. Jeżeli stan przejściowy w całości mieści się między dwoma
odczytami, korekta właściwego zasobu służy jako jawny sygnał zapasowy.

| Test | Detekcja | Recovery |
| --- | --- | --- |
| scale drift | reakcja Application/HelmRelease; fallback: `spec.replicas` wraca do Git | wszystkie oczekiwane repliki Ready/Available |
| image drift | reakcja Application/HelmRelease; fallback: image wraca do Git | rollout obrazu jest w pełni Ready |
| delete | reakcja Application/HelmRelease; fallback: pojawia się Deployment o nowym UID | odtworzony Deployment jest Ready |
| config | reakcja na nową rewizję; fallback: zmienia się `checksum/config` | rollout jest Ready |
| new version | reakcja na nową rewizję; fallback: Deployment ma nowy tag | rollout Ready i `/version` ma wartość oczekiwaną |
| rollback | reakcja na rewizję rollbacku; fallback: wraca checksum baseline | rollout Ready i `/ready` potwierdza gotowość |
| controller restart | pojawia się nowy UID poda | nowy pod kontrolera ma Ready=True |

Definicja używa publicznego API obu kontrolerów, a recovery zawsze wymaga
rzeczywiście poprawnego i gotowego zasobu. Sygnał zapasowy daje górne oszacowanie
czasu detekcji, gdy krótki status kontrolera zostanie pominięty. Dla dokładniejszych
pomiarów można zmniejszyć `--poll-interval`, kosztem większego ruchu do API
servera; wartość musi pozostać identyczna dla obu narzędzi.

## Reconcile i naturalne różnice

Flux jawnie używa `interval: 1m`, Helm drift detection oraz jitter `0%` ustawiany
na source-controller i helm-controller. Argo CD ma ustawione
`timeout.reconciliation: 60s` i jitter `0s`, a Application korzysta z
automatycznej synchronizacji/self-heal. Okres pollingu Git jest więc jawnie
wyrównany, chociaż watch zasobów i wewnętrzny przebieg korekty pozostają naturalną
cechą narzędzia. Nie należy wywoływać `flux reconcile`, `argocd app sync` ani
ręcznie annotować zasobów podczas pomiaru. Konkretne ustawienia i wersje trzeba
zapisać przy wynikach.

Flux HelmRelease nie czeka wewnątrz akcji upgrade na readiness i nie ma
automatycznej remediation upgrade. Jest to konieczna różnica techniczna: wspólny
runner obserwuje readiness, a rollback ma zostać zainicjowany wyłącznie commitem
Git, tak jak w Argo CD. Instalacja początkowa nadal czeka i ma ograniczone retry.

## Protokół jednej serii

1. Zapisać `git rev-parse HEAD`, wersje CLI/kontrolerów, image węzła i parametry
   hosta.
2. Sprawdzić, że drzewo Git jest czyste i kontroler ma stan Ready/Healthy.
3. Wykonać smoke test wszystkich endpointów.
4. Odczekać ustalony czas stabilizacji, np. 5 minut.
5. Uruchomić scenariusz z jawnymi argumentami i przekierować także log terminala.
6. Nie wznawiać serii po timeout bez zdiagnozowania i odtworzenia baseline.
7. Po serii zapisać zdarzenia, logi kontrolera i metadane środowiska.
8. Skopiować cały katalog `results` do niezmiennego archiwum.

## Analiza i raportowanie

Raport powinien pokazać N udanych i N nieudanych oddzielnie. Dla udanych prób
raportowane są średnia, mediana, min, max i próbne odchylenie standardowe. Przy
rozkładach asymetrycznych mediana jest ważniejsza od samej średniej. Nie należy
usuwać obserwacji odstających bez z góry opisanej reguły i analizy przyczyny.

`kubectl top` ma ograniczoną rozdzielczość i opóźnienie Metrics Servera. Dane
CPU/RAM należy traktować jako porównanie lekkiego narzutu, nie profilowanie
procesu. Surowe próbki wszystkich podów kontrolera są zachowywane, a analiza
najpierw sumuje je per chwila pomiaru. Statystyka opisuje więc całkowity footprint
kontrolera, bez ukrywania różnej liczby komponentów.

Porównywany jest pełny, oficjalny manifest instalacyjny każdego narzędzia, nie
ręcznie przycięty zestaw procesów: wszystkie pody w `argocd` albo `flux-system`
wchodzą do próbki. Wynik opisuje koszt operacyjny wybranej dystrybucji domyślnej;
nie należy interpretować go jako benchmarku samych pętli application-controller
i helm-controller.

## Zagrożenia trafności

- cache obrazu i Git może skracać późniejsze iteracje;
- opóźnienia schedulerów, watch/API oraz chwilowe problemy sieciowe zwiększają
  wariancję mimo wyłączenia losowego jittera interwałów;
- jednowęzłowy Kind współdzieli zasoby z systemem hosta;
- polling kwantyzuje czas detekcji;
- nowe commity i webhooki mogą wpłynąć na sposób wykrycia zmiany;
- restart klastra nie gwarantuje identycznego stanu zewnętrznego registry;
- Metrics Server sam zużywa zasoby i nie powinien być obecny tylko w jednej
  porównywanej serii.

Te ograniczenia należy opisać w pracy i zachować surowe logi, aby wyniki były
audytowalne.
