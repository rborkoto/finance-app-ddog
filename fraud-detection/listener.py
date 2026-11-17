"""
fraud-detection — STOMP message listener
Receives messages from fraud.score.queue, scores each transaction,
and logs a structured result record.
"""

import json
import logging
import os

import stomp

from scorer import score

logger = logging.getLogger("fraud_detection.listener")

class FraudScoreListener(stomp.ConnectionListener):
    """
    STOMP ConnectionListener that handles messages on fraud.score.queue.

    Each message body is expected to be a JSON object with at least:
      {
        "transaction_id": "txn-8f3a2c",
        "amount":         1500.00,
        "currency":       "EUR",
        "transaction_type": "payment",
        "account_id":     "acc-001"
      }
    """

    def __init__(self, conn: stomp.Connection) -> None:
        # stomp.py's Frame object does NOT carry a reference back to the
        # connection (there is no frame.connection attribute in this
        # library version) — acking must go through the Connection object
        # itself. Without this, every on_message() call raised
        # AttributeError: 'Frame' object has no attribute 'connection',
        # which killed the STOMP receiver background thread on the very
        # first message and silently broke consumption (no more frames
        # were ever processed on that connection again).
        super().__init__()
        self.conn = conn

    def on_error(self, frame: stomp.utils.Frame) -> None:
        logger.error(
            "Received STOMP error frame",
            extra={"stomp.error": frame.body},
        )

    def on_message(self, frame: stomp.utils.Frame) -> None:
        """
        Main message handler. Called once per inbound STOMP frame.

        Processing order:
          1. Parse JSON body
          2. Call scorer.score()
          3. Structured log of the result
          4. ACK the frame so the broker removes it from the queue
        """
        subscription_id = frame.headers.get("subscription", "unknown")
        message_id = frame.headers.get("message-id", "unknown")
        correlation_id = frame.headers.get("correlation-id", "")

        try:
            body = json.loads(frame.body)
        except (json.JSONDecodeError, TypeError) as exc:
            logger.error(
                "Failed to parse message body",
                extra={
                    "message_id": message_id,
                    "error": str(exc),
                },
            )
            # ACK even on parse failure to avoid poison-pill infinite redelivery.
            self.conn.ack(message_id, subscription_id)
            return

        transaction_id = body.get("transaction_id", "unknown")
        transaction_type = body.get("transaction_type", "unknown")
        amount = float(body.get("amount", 0.0))
        currency = body.get("currency", "UNKNOWN")

        result = score({"transaction_id": transaction_id, "amount": amount})

        logger.info(
            "Fraud score computed",
            extra={
                # Business context
                "transaction_id": transaction_id,
                "transaction.type": transaction_type,
                "payment.currency": currency,
                "fraud.score": result["score"],
                "fraud.score_bucket": result["bucket"],
                # Messaging context
                "messaging.destination": "fraud.score.queue",
                "jms.correlation_id": correlation_id,
                # Omit message_id from logs in production to avoid
                # high-cardinality log index bloat.
            },
        )

        self.conn.ack(message_id, subscription_id)
