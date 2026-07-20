# ── Build stage ───────────────────────────────────────────────────────────────
# Use the build platform (native) then cross-compile for the target platform.
# This avoids QEMU emulation for Go toolchain commands (go mod download, go build)
# which crash on ARM hosts building for amd64 due to QEMU lfstack issues.
FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS builder

ARG TARGETOS=linux
ARG TARGETARCH=amd64

WORKDIR /app

# Install git for go mod download (some dependencies require it).
RUN apk add --no-cache git

COPY go.mod go.sum* ./
RUN GOFLAGS=-mod=mod go mod download
COPY . .
RUN GOFLAGS=-mod=mod CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /notification-service .

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM alpine:latest

# ca-certificates is required for TLS connections to external APIs (SMTP, SMS gateways).
RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app

COPY --from=builder /notification-service /app/notification-service

# Non-root user for container security best practices.
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

# Environment defaults — override at runtime via docker-compose or K8s ConfigMap/Secret.
ENV ACTIVEMQ_URL="stomp://activemq-artemis:61613"

EXPOSE 8083

CMD ["/app/notification-service"]
