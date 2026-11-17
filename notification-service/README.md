# notification-service

Go 1.23 service with no HTTP API.

Consumes alert messages from `alert.queue` on ActiveMQ Artemis over STOMP and sends stubbed email and SMS notifications. Logs structured JSON with `log/slog`.

Manifest: `deploy/kubernetes/base/services/notification-service.yaml`.
