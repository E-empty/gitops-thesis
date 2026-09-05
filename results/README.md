# Wyniki eksperymentów

Każdy pilotaż i każda seria właściwa powinny otrzymać osobny katalog przekazany
przez `--results-dir`, na przykład `results/controlled-20260905T120000Z`.
Wewnątrz skrypty automatycznie tworzą katalogi `argocd/`, `fluxcd/` i `logs/`.
Odrzucają ponowne użycie tego samego numeru iteracji danego scenariusza, aby nie
połączyć przypadkiem pilotażu z wynikami właściwymi.
Surowe pliki CSV i logi są ignorowane przez Git, ponieważ mogą być duże i
zależą od konkretnej sesji badawczej. Przed archiwizacją wyników należy skopiować
cały ten katalog wraz z informacją o commicie, wersjach narzędzi i konfiguracji
klastra użytej w danej serii.
