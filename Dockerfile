# syntax=docker/dockerfile:1

# stage 1: build deps into an isolated venv
FROM python:3.11-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

# copy just the manifest first so this layer stays cached
COPY app/requirements.txt ./requirements.txt

RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip==26.1.2 setuptools==83.0.0 wheel==0.47.0 \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# stage 2: minimal, non-root runtime image
FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    PORT=8000

RUN python -m pip install --no-cache-dir --upgrade pip==26.1.2 setuptools==83.0.0 wheel==0.47.0 \
    && rm -rf /root/.cache/pip

# dedicated non-root, non-login system user/group
RUN groupadd --system --gid 10001 appgroup \
    && useradd --system --uid 10001 --gid appgroup --no-create-home \
       --shell /usr/sbin/nologin appuser

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY app/ /app/

# app files owned by the non-root user, not group/world-writable
RUN chown -R appuser:appgroup /app \
    && chmod -R 550 /app

USER appuser:appgroup

EXPOSE 8000

# container-level healthcheck, mainly for docker-compose / plain `docker run`
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0) if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).status == 200 else sys.exit(1)"

ENTRYPOINT ["uvicorn", "main:app"]
CMD ["--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips=*"]
