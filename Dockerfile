# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1: build dependencies into an isolated venv
# ---------------------------------------------------------------------------
FROM python:3.11-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

# Only the manifest is copied first to maximize Docker layer caching.
COPY app/requirements.txt ./requirements.txt

# Upgrade pip, setuptools, and wheel explicitly -- the versions bundled by
# `python -m venv` (via ensurepip) are pinned to whatever shipped with the
# base image and lag behind upstream security fixes (e.g. CVE-2026-24049 in
# wheel, CVE-2026-8643 in pip).
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2: minimal, non-root runtime image
# ---------------------------------------------------------------------------
FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    PORT=8000

# Dedicated non-root, non-login system user/group.
RUN groupadd --system --gid 10001 appgroup \
    && useradd --system --uid 10001 --gid appgroup --no-create-home \
       --shell /usr/sbin/nologin appuser

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY app/ /app/

# Ensure application files are owned by the non-root user and are not
# group/world-writable.
RUN chown -R appuser:appgroup /app \
    && chmod -R 550 /app

USER appuser:appgroup

EXPOSE 8000

# Container-level healthcheck in addition to the Kubernetes probes, useful
# for docker-compose / plain `docker run` local testing.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0) if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).status == 200 else sys.exit(1)"

ENTRYPOINT ["uvicorn", "main:app"]
CMD ["--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips=*"]
