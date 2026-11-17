FROM python:3.11-slim

WORKDIR /app

# Install dependencies first (layer-cached unless requirements.txt changes).
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source.
COPY main.py .
COPY logging_config.json .

# Non-root user for security best practice.
RUN adduser --disabled-password --gecos "" appuser
USER appuser

# Expose the application port (must match PORT in .env.example).
EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--log-config", "logging_config.json"]
