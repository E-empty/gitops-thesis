SHELL := bash

PYTHON ?= python3
TOOL ?= argocd
ITERATIONS ?= 10
SERVICE ?= gateway-service
REPO_URL ?=
REVISION ?= main
KUBE_CONTEXT ?= kind-gitops-thesis
APP_NAMESPACE ?= test-manual

.PHONY: help test lint build up down cluster delete-cluster helm-lint helm-template \
	deploy-manual install-argocd install-flux argocd-ui metrics smoke \
	experiment-drift-argocd experiment-drift-flux experiment-image-drift \
	experiment-delete experiment-resources analyze clean

help:
	@echo "Common targets:"
	@echo "  test | lint | build | up | down"
	@echo "  cluster | delete-cluster | helm-lint | helm-template | deploy-manual"
	@echo "  install-argocd REPO_URL=... | install-flux REPO_URL=... | argocd-ui"
	@echo "  experiment-drift-argocd | experiment-drift-flux | analyze | clean"

test:
	$(PYTHON) -m pytest tests analysis

lint:
	$(PYTHON) -m ruff check app tests analysis experiments/lib

build:
	docker compose build

up:
	docker compose up --build --wait -d

down:
	docker compose down --remove-orphans

cluster:
	bash ./scripts/create-cluster.sh

delete-cluster:
	bash ./scripts/delete-cluster.sh

helm-lint:
	helm lint helm/microservices-app

helm-template:
	helm template microservices-app helm/microservices-app --namespace "$(APP_NAMESPACE)"

deploy-manual:
	bash ./scripts/deploy-app-manually.sh --namespace "$(APP_NAMESPACE)" --context "$(KUBE_CONTEXT)"

install-argocd:
	@test -n "$(REPO_URL)" || (echo "REPO_URL is required" >&2; exit 2)
	bash ./scripts/install-argocd.sh --repo-url "$(REPO_URL)" --revision "$(REVISION)" --context "$(KUBE_CONTEXT)"

install-flux:
	@test -n "$(REPO_URL)" || (echo "REPO_URL is required" >&2; exit 2)
	bash ./scripts/install-fluxcd.sh --repo-url "$(REPO_URL)" --revision "$(REVISION)" --context "$(KUBE_CONTEXT)"

argocd-ui:
	bash ./scripts/argocd-ui.sh --context "$(KUBE_CONTEXT)"

metrics:
	bash ./scripts/install-metrics-server.sh --context "$(KUBE_CONTEXT)"

smoke:
	bash ./experiments/smoke-test.sh --tool "$(TOOL)" --service "$(SERVICE)" --context "$(KUBE_CONTEXT)"

experiment-drift-argocd:
	bash ./experiments/drift-scale.sh --tool argocd --iterations "$(ITERATIONS)" --service "$(SERVICE)" --context "$(KUBE_CONTEXT)"

experiment-drift-flux:
	bash ./experiments/drift-scale.sh --tool fluxcd --iterations "$(ITERATIONS)" --service "$(SERVICE)" --context "$(KUBE_CONTEXT)"

experiment-image-drift:
	bash ./experiments/drift-image.sh --tool "$(TOOL)" --iterations "$(ITERATIONS)" --service "$(SERVICE)" --context "$(KUBE_CONTEXT)"

experiment-delete:
	bash ./experiments/delete-deployment.sh --tool "$(TOOL)" --iterations "$(ITERATIONS)" --service "$(SERVICE)" --context "$(KUBE_CONTEXT)"

experiment-resources:
	bash ./experiments/resource-usage.sh --tool "$(TOOL)" --iterations "$(ITERATIONS)" --context "$(KUBE_CONTEXT)"

analyze:
	$(PYTHON) analysis/analyze_results.py --input-dir results --output-dir analysis/output --plots

clean:
	bash ./scripts/cleanup.sh --namespace "$(APP_NAMESPACE)" --context "$(KUBE_CONTEXT)"
