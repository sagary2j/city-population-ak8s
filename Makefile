SHELL := /bin/bash
.DEFAULT_GOAL := help

APP_DIR := app
VENV := $(APP_DIR)/.venv
PYTHON ?= python3
PIP := $(VENV)/bin/pip
PYTEST := $(VENV)/bin/pytest
RUFF := $(VENV)/bin/ruff
UVICORN := $(VENV)/bin/uvicorn
IMAGE_NAME ?= city-population-api
IMAGE_TAG ?= 1.0.0
HELM_RELEASE ?= city-population
HELM_CHART ?= ./helm

.PHONY: help install test lint run compose-up compose-down smoke-upsert smoke-query smoke-test docker-build helm-install helm-upgrade helm-uninstall clean

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_.-]+:.*##/ {printf "\033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

install: ## Create virtualenv and install app + dev dependencies
	$(PYTHON) -m venv $(VENV)
	$(PIP) install --upgrade pip
	$(PIP) install -r $(APP_DIR)/requirements-dev.txt

test: ## Run unit tests
	$(PYTEST) -q $(APP_DIR)/tests

lint: ## Run Ruff lint checks
	$(RUFF) check $(APP_DIR)

run: ## Run API locally (expects ES on localhost:9200)
	$(UVICORN) main:app --host 0.0.0.0 --port 8000 --app-dir $(APP_DIR)

compose-up: ## Start API + Elasticsearch with Docker Compose
	docker compose up --build -d

compose-down: ## Stop Docker Compose stack and remove volumes
	docker compose down -v

smoke-upsert: ## Upsert sample city population
	curl -sS -X POST http://localhost:8000/cities \
		-H "Content-Type: application/json" \
		-d '{"city":"Warsaw","population":1870000}'

smoke-query: ## Query sample city population
	curl -sS http://localhost:8000/cities/Warsaw

smoke-test: ## Run end-to-end API smoke test script
	./scripts/smoke-test.sh

docker-build: ## Build application container image
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

helm-install: ## Install Helm release
	helm install $(HELM_RELEASE) $(HELM_CHART) \
		--set app.image.repository=$(IMAGE_NAME) \
		--set app.image.tag=$(IMAGE_TAG)

helm-upgrade: ## Upgrade Helm release
	helm upgrade $(HELM_RELEASE) $(HELM_CHART) \
		--set app.image.repository=$(IMAGE_NAME) \
		--set app.image.tag=$(IMAGE_TAG)

helm-uninstall: ## Uninstall Helm release
	helm uninstall $(HELM_RELEASE)

clean: ## Remove local virtualenv and pytest cache
	rm -rf $(VENV) $(APP_DIR)/.pytest_cache
