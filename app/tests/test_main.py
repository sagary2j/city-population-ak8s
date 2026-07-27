"""
Unit tests for the City Population API.

The Elasticsearch client is mocked at the module level (main.es_client) so
these tests run fully offline and fast -- no real cluster is started, and
the app's startup `lifespan` (which performs real network retries against
Elasticsearch) is intentionally not triggered by using a plain
`TestClient(main.app)` instantiation rather than the `with TestClient(...)`
context-manager form.
"""

import os
import sys
from unittest.mock import AsyncMock, MagicMock

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import main  # noqa: E402
from elasticsearch.exceptions import NotFoundError  # noqa: E402


@pytest.fixture
def client():
    main.es_client = AsyncMock()
    return TestClient(main.app)


# --------------------------------------------------------------------------
# Health
# --------------------------------------------------------------------------


def test_health_returns_ok(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "OK"}


def test_health_does_not_touch_elasticsearch(client):
    """Liveness must never call out to the DB -- see README Part D on
    separating liveness from readiness."""
    client.get("/health")
    main.es_client.ping.assert_not_called()


def test_readiness_ok_when_es_reachable(client):
    main.es_client.ping = AsyncMock(return_value=True)
    response = client.get("/health/ready")
    assert response.status_code == 200
    assert response.json()["status"] == "OK"


def test_readiness_unavailable_when_es_unreachable(client):
    main.es_client.ping = AsyncMock(side_effect=ConnectionError("boom"))
    response = client.get("/health/ready")
    assert response.status_code == 503


# --------------------------------------------------------------------------
# Upsert
# --------------------------------------------------------------------------


def test_upsert_city_success(client):
    main.es_client.index = AsyncMock(return_value={"result": "created"})
    response = client.post("/cities", json={"city": "Warsaw", "population": 1863056})
    assert response.status_code == 200
    body = response.json()
    assert body["city"] == "Warsaw"
    assert body["population"] == 1863056
    assert "updated_at" in body
    main.es_client.index.assert_awaited_once()


def test_upsert_city_rejects_negative_population(client):
    response = client.post("/cities", json={"city": "Warsaw", "population": -5})
    assert response.status_code == 422


def test_upsert_city_rejects_empty_city_name(client):
    response = client.post("/cities", json={"city": "   ", "population": 100})
    assert response.status_code == 422


def test_upsert_city_rejects_missing_fields(client):
    response = client.post("/cities", json={"city": "Warsaw"})
    assert response.status_code == 422


def test_upsert_city_upstream_failure_returns_503(client):
    main.es_client.index = AsyncMock(side_effect=RuntimeError("cluster unavailable"))
    response = client.post("/cities", json={"city": "Warsaw", "population": 100})
    assert response.status_code == 503
    assert response.json()["error"] == "upstream_unavailable"


# --------------------------------------------------------------------------
# Query
# --------------------------------------------------------------------------


def test_get_city_found(client):
    main.es_client.get = AsyncMock(
        return_value={
            "_source": {
                "city": "Warsaw",
                "population": 1863056,
                "updated_at": "2026-01-01T00:00:00+0000",
            }
        }
    )
    response = client.get("/cities/Warsaw")
    assert response.status_code == 200
    assert response.json()["population"] == 1863056


def test_get_city_not_found_returns_structured_404(client):
    main.es_client.get = AsyncMock(
        side_effect=NotFoundError("not found", MagicMock(status=404), {"error": "not_found"})
    )
    response = client.get("/cities/Atlantis")
    assert response.status_code == 404
    body = response.json()
    assert body["error"] == "city_not_found"
    assert "Atlantis" in body["detail"]


def test_get_city_upstream_failure_returns_503(client):
    main.es_client.get = AsyncMock(side_effect=RuntimeError("cluster unavailable"))
    response = client.get("/cities/Warsaw")
    assert response.status_code == 503


# --------------------------------------------------------------------------
# Upsert idempotency (document ID derivation)
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("Warsaw", "warsaw"),
        ("  Warsaw  ", "warsaw"),
        ("WARSAW", "warsaw"),
        ("New York", "new york"),
    ],
)
def test_city_doc_id_is_normalized(raw, expected):
    assert main.city_doc_id(raw) == expected
