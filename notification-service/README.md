# notification-service

Go 1.22 microservice that consumes alert messages from `alert.queue` (ActiveMQ Artemis via STOMP)
and dispatches email/SMS notifications. Part of the Finance sample application.

**Technology stack:** Go 1.22, `go-stomp/stomp`, `log/slog` (stdlib structured JSON logging)

This service exposes no HTTP port — it is a pure message consumer.

---

## Local Development

```bash
cp .env.example .env
# Edit .env — set ACTIVEMQ_URL for your local broker
go run .
```

Build a static binary:

```bash
CGO_ENABLED=0 go build -o notification-service .
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `ACTIVEMQ_URL` | `stomp://localhost:61613` | Broker STOMP endpoint (`stomp://<user>:<pass>@<host>:<port>`) |
| `ALERT_QUEUE` | `alert.queue` | Queue this consumer subscribes to |
