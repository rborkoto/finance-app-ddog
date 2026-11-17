# fraud-detection

Python 3.11 service with no HTTP API.

Consumes payment events from `fraud.score.queue` on ActiveMQ Artemis over STOMP, scores each one by amount (`low`, `medium`, `high`), and logs the result as structured JSON.

Code: `main.py` (startup and logging), `listener.py` (STOMP consumer), `scorer.py` (scoring rules).

Manifest: `deploy/kubernetes/base/services/fraud-detection.yaml`.
