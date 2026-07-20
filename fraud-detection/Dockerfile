FROM python:3.11-slim

# ── BUILD ARGS ────────────────────────────────────────────────────────
# APP_VERSION is injected by CI so the image version label reflects the build.
# Usage: docker build --build-arg APP_VERSION=$(git rev-parse --short HEAD) .
ARG APP_VERSION=dev
LABEL org.opencontainers.image.version="${APP_VERSION}"

WORKDIR /app

# Install dependencies first (layer-cache friendly).
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py listener.py scorer.py ./

CMD ["python", "main.py"]
