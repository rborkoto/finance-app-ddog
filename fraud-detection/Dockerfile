FROM python:3.11-slim

ARG DD_VERSION=dev
LABEL org.opencontainers.image.version="${DD_VERSION}"

WORKDIR /app

# Install dependencies first (layer-cache friendly).
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py listener.py scorer.py ./

CMD ["python", "main.py"]
