"""City Population API.

FastAPI service for storing/looking up city population data in
Elasticsearch. Has health checks, upsert and query endpoints, JSON logging,
and startup retry logic since Kubernetes doesn't guarantee the ES pod is
ready before this one starts.
"""

import asyncio
import json
import logging
import os
import sys
import time
import uuid
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from typing import Any, Optional

from elasticsearch import AsyncElasticsearch
from elasticsearch.exceptions import ConnectionError as ESConnectionError
from elasticsearch.exceptions import NotFoundError
from fastapi import FastAPI, Request, Response, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator

class JSONFormatter(logging.Formatter):
    """Single-line JSON log records, easy to ship to FluentBit/ELK."""

    def formatTime(self, record: logging.LogRecord, datefmt: Optional[str] = None) -> str:
        # always UTC so logs line up across pods/nodes in different timezones
        return datetime.fromtimestamp(record.created, tz=UTC).isoformat()

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if hasattr(record, "request_id"):
            payload["request_id"] = record.request_id
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def configure_logging() -> logging.Logger:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JSONFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(os.environ.get("LOG_LEVEL", "INFO").upper())
    # quiet down the noisy third-party loggers
    logging.getLogger("elastic_transport").setLevel(logging.WARNING)
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    return logging.getLogger("city-population-api")


logger = configure_logging()

# config, all from env vars


class Settings:
    ES_HOST: str = os.environ.get("ES_HOST", "http://localhost:9200")
    ES_USERNAME: Optional[str] = os.environ.get("ES_USERNAME")
    ES_PASSWORD: Optional[str] = os.environ.get("ES_PASSWORD")
    ES_INDEX: str = os.environ.get("ES_INDEX", "cities")
    ES_VERIFY_CERTS: bool = os.environ.get("ES_VERIFY_CERTS", "false").lower() == "true"
    ES_STARTUP_MAX_RETRIES: int = int(os.environ.get("ES_STARTUP_MAX_RETRIES", "30"))
    ES_STARTUP_RETRY_DELAY_SECONDS: float = float(
        os.environ.get("ES_STARTUP_RETRY_DELAY_SECONDS", "2")
    )
    ES_REQUEST_TIMEOUT: float = float(os.environ.get("ES_REQUEST_TIMEOUT", "10"))
    APP_VERSION: str = os.environ.get("APP_VERSION", "1.0.1")


settings = Settings()

INDEX_MAPPING = {
    "mappings": {
        "properties": {
            "city": {
                "type": "text",
                "fields": {"keyword": {"type": "keyword"}},
            },
            "population": {"type": "long"},
            "updated_at": {"type": "date"},
        }
    },
    "settings": {
        "number_of_shards": 1,
        # number_of_replicas depends on cluster size, left to helm/values.yaml
    },
}

es_client: Optional[AsyncElasticsearch] = None


def build_es_client() -> AsyncElasticsearch:
    kwargs: dict[str, Any] = {
        "hosts": [settings.ES_HOST],
        "verify_certs": settings.ES_VERIFY_CERTS,
        "request_timeout": settings.ES_REQUEST_TIMEOUT,
    }
    if settings.ES_USERNAME and settings.ES_PASSWORD:
        kwargs["basic_auth"] = (settings.ES_USERNAME, settings.ES_PASSWORD)
    return AsyncElasticsearch(**kwargs)


async def wait_for_elasticsearch(client: AsyncElasticsearch) -> None:
    """Poll until Elasticsearch answers. ES can take a while to form its
    cluster and go green, while this process starts almost instantly, so
    we retry instead of assuming it's ready."""
    attempt = 0
    while attempt < settings.ES_STARTUP_MAX_RETRIES:
        attempt += 1
        try:
            if await client.ping():
                health = await client.cluster.health()
                logger.info(
                    "Elasticsearch is reachable",
                    extra={"request_id": "startup"},
                )
                logger.info(json.dumps({"cluster_health": health.get("status")}))
                return
        except (ESConnectionError, Exception) as exc:  # noqa: BLE001
            logger.warning(
                f"Elasticsearch not ready yet (attempt {attempt}/"
                f"{settings.ES_STARTUP_MAX_RETRIES}): {exc}"
            )
        await asyncio.sleep(settings.ES_STARTUP_RETRY_DELAY_SECONDS)

    raise RuntimeError(
        f"Elasticsearch was not reachable after {settings.ES_STARTUP_MAX_RETRIES} "
        "attempts. Failing startup so the container/orchestrator can restart "
        "the Pod and retry."
    )


async def ensure_index(client: AsyncElasticsearch) -> None:
    exists = await client.indices.exists(index=settings.ES_INDEX)
    if not exists:
        logger.info(f"Creating index '{settings.ES_INDEX}'")
        await client.indices.create(index=settings.ES_INDEX, body=INDEX_MAPPING)
    else:
        logger.info(f"Index '{settings.ES_INDEX}' already exists")


async def run_startup_sequence(app: FastAPI, client: AsyncElasticsearch) -> None:
    """Waits for Elasticsearch, then makes sure the index exists. Runs as a
    background task so uvicorn can open the port right away instead of
    blocking startup - /health/startup reflects the real state, and it's
    the startupProbe (not a crash) that decides whether to keep waiting."""
    try:
        await wait_for_elasticsearch(client)
        await ensure_index(client)
        app.state.es_ready = True
        app.state.startup_complete = True
        logger.info("Startup sequence complete")
    except Exception as exc:  # noqa: BLE001
        logger.exception("Fatal error during startup")
        app.state.es_ready = False
        app.state.startup_error = str(exc)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global es_client
    logger.info("Starting up City Population API")
    es_client = build_es_client()
    app.state.es_ready = False
    app.state.startup_complete = False
    app.state.startup_error = None

    startup_task = asyncio.create_task(run_startup_sequence(app, es_client))
    try:
        yield
    finally:
        logger.info("Shutting down City Population API")
        if not startup_task.done():
            startup_task.cancel()
            try:
                await startup_task
            except asyncio.CancelledError:
                pass
            except Exception:  # noqa: BLE001
                logger.exception("Startup task shutdown failed")
        if es_client is not None:
            await es_client.close()


app = FastAPI(
    title="City Population API",
    description="Upsert and query city population data backed by Elasticsearch.",
    version=settings.APP_VERSION,
    lifespan=lifespan,
)
# defaults so the health endpoints behave even before lifespan runs
# (e.g. plain TestClient(app) in tests skips it)
app.state.es_ready = False
app.state.startup_complete = False
app.state.startup_error = None


@app.middleware("http")
async def add_request_id_and_logging(request: Request, call_next):
    request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
    start = time.perf_counter()
    response: Response
    try:
        response = await call_next(request)
    except Exception:
        duration_ms = round((time.perf_counter() - start) * 1000, 2)
        logger.error(
            json.dumps(
                {
                    "event": "unhandled_exception",
                    "path": request.url.path,
                    "method": request.method,
                    "duration_ms": duration_ms,
                    "request_id": request_id,
                }
            )
        )
        raise
    duration_ms = round((time.perf_counter() - start) * 1000, 2)
    response.headers["X-Request-ID"] = request_id
    logger.info(
        json.dumps(
            {
                "event": "request_completed",
                "path": request.url.path,
                "method": request.method,
                "status_code": response.status_code,
                "duration_ms": duration_ms,
                "request_id": request_id,
            }
        )
    )
    return response


class CityUpsertRequest(BaseModel):
    city: str = Field(..., min_length=1, max_length=200, description="City name")
    population: int = Field(..., ge=0, description="Population count, must be >= 0")

    @field_validator("city")
    @classmethod
    def normalize_city(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("city must not be empty or whitespace")
        return v


class CityResponse(BaseModel):
    city: str
    population: int
    updated_at: Optional[str] = None


class ErrorResponse(BaseModel):
    error: str
    detail: str
    request_id: Optional[str] = None


def city_doc_id(city_name: str) -> str:
    """Normalize to a stable doc id so upserts of the same city (regardless
    of case/whitespace) update one document instead of creating dupes."""
    return city_name.strip().lower()


def get_client() -> AsyncElasticsearch:
    if es_client is None:
        raise RuntimeError("Elasticsearch client is not initialized")
    return es_client


@app.get("/health", tags=["operations"], deprecated=True)
@app.get("/health/live", tags=["operations"])
async def liveness() -> dict[str, str]:
    """Liveness probe. Deliberately doesn't touch Elasticsearch - a DB blip
    shouldn't get a healthy pod killed. Use /health/ready for that.

    /health is the old path, kept as an alias for /health/live."""
    return {"status": "OK"}


@app.get("/health/ready", tags=["operations"])
async def readiness() -> JSONResponse:
    """Readiness check. A plain ping() only proves ES answers, not that our
    index is usable, so we check cluster health scoped to our index -
    that catches connectivity issues, a missing index, and a red status
    (missing primary shards) in one call."""
    try:
        client = get_client()
        health = await client.cluster.health(index=settings.ES_INDEX, request_timeout=3)
        cluster_status = health.get("status")
        if cluster_status == "red":
            raise RuntimeError(f"cluster health is red for index '{settings.ES_INDEX}'")
        return JSONResponse(
            {
                "status": "OK",
                "elasticsearch": "reachable",
                "cluster_status": cluster_status,
            }
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("Readiness probe failed", exc_info=exc)
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content={"status": "UNAVAILABLE", "elasticsearch": str(exc)},
        )


@app.get("/health/startup", tags=["operations"])
async def startup_probe(request: Request) -> JSONResponse:
    """Startup probe. Only returns 200 once ES is reachable and the index
    exists. Point the Kubernetes startupProbe here so liveness/readiness
    don't kick in until then (max wait is ES_STARTUP_MAX_RETRIES *
    ES_STARTUP_RETRY_DELAY_SECONDS)."""
    if getattr(request.app.state, "startup_complete", False):
        return JSONResponse(
            {
                "status": "OK",
                "elasticsearch": "reachable",
                "index": settings.ES_INDEX,
            }
        )
    content: dict[str, str] = {"status": "STARTING"}
    startup_error = getattr(request.app.state, "startup_error", None)
    if startup_error:
        content["detail"] = startup_error
    return JSONResponse(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        content=content,
    )


@app.post(
    "/cities",
    status_code=status.HTTP_200_OK,
    response_model=CityResponse,
    tags=["cities"],
)
async def upsert_city(payload: CityUpsertRequest, request: Request) -> CityResponse:
    client = get_client()
    doc_id = city_doc_id(payload.city)
    now = datetime.now(UTC).isoformat()
    body = {
        "city": payload.city,
        "population": payload.population,
        "updated_at": now,
    }
    try:
        await client.index(index=settings.ES_INDEX, id=doc_id, document=body)
    except Exception as exc:  # noqa: BLE001
        request_id = request.headers.get("X-Request-ID", "unknown")
        logger.error(f"Failed to upsert city '{payload.city}': {exc}")
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content=ErrorResponse(
                error="upstream_unavailable",
                detail="Could not write to the data store. Please retry.",
                request_id=request_id,
            ).model_dump(),
        )
    return CityResponse(**body)


@app.get(
    "/cities/{city_name}",
    response_model=CityResponse,
    responses={404: {"model": ErrorResponse}},
    tags=["cities"],
)
async def get_city(city_name: str, request: Request):
    client = get_client()
    doc_id = city_doc_id(city_name)
    request_id = request.headers.get("X-Request-ID", "unknown")
    try:
        result = await client.get(index=settings.ES_INDEX, id=doc_id)
    except NotFoundError:
        return JSONResponse(
            status_code=status.HTTP_404_NOT_FOUND,
            content=ErrorResponse(
                error="city_not_found",
                detail=f"No population data found for city '{city_name}'.",
                request_id=request_id,
            ).model_dump(),
        )
    except Exception as exc:  # noqa: BLE001
        logger.error(f"Failed to fetch city '{city_name}': {exc}")
        return JSONResponse(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            content=ErrorResponse(
                error="upstream_unavailable",
                detail="Could not read from the data store. Please retry.",
                request_id=request_id,
            ).model_dump(),
        )
    source = result["_source"]
    return CityResponse(**source)


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    request_id = request.headers.get("X-Request-ID", "unknown")
    logger.exception(f"Unhandled exception for {request.method} {request.url.path}")
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content=ErrorResponse(
            error="internal_server_error",
            detail="An unexpected error occurred.",
            request_id=request_id,
        ).model_dump(),
    )


if __name__ == "__main__":
    import uvicorn

    # 0.0.0.0 is fine here, this only ever runs inside a container
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=False)  # nosec B104
