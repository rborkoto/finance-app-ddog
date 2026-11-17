"""
fraud-detection — deterministic scoring stub

Returns a fraud risk score and bucket based solely on transaction amount.
In a real system this would call an ML model or rules engine.

Bucket thresholds:
  amount < 1_000   → low    (score 0.10)
  amount < 5_000   → medium (score 0.55)
  amount >= 5_000  → high   (score 0.90)
"""

from __future__ import annotations

from typing import Any


# Amount thresholds that define the bucket boundaries.
_LOW_THRESHOLD: float = 1_000.0
_MEDIUM_THRESHOLD: float = 5_000.0

# Representative scores for each bucket.
# These are fixed so that test assertions are deterministic.
_BUCKET_SCORES: dict[str, float] = {
    "low": 0.10,
    "medium": 0.55,
    "high": 0.90,
}


def score(transaction: dict[str, Any]) -> dict[str, Any]:
    """
    Score a transaction and return a result dict.

    Parameters
    ----------
    transaction:
        A dict that must contain at least:
          - ``amount``         (float) — the transaction amount in the
                               payment currency (absolute value is used).
          - ``transaction_id`` (str)   — used only for logging; not
                               consumed by the scoring logic itself.

    Returns
    -------
    dict with keys:
      ``score``  — float in [0, 1]; suitable for storage but NOT for tagging.
      ``bucket`` — str: "low" | "medium" | "high"; use this as tag value.

    Examples
    --------
    >>> score({"transaction_id": "txn-001", "amount": 500})
    {"score": 0.10, "bucket": "low"}

    >>> score({"transaction_id": "txn-002", "amount": 2500})
    {"score": 0.55, "bucket": "medium"}

    >>> score({"transaction_id": "txn-003", "amount": 9999})
    {"score": 0.90, "bucket": "high"}
    """
    amount = abs(float(transaction.get("amount", 0.0)))

    if amount < _LOW_THRESHOLD:
        bucket = "low"
    elif amount < _MEDIUM_THRESHOLD:
        bucket = "medium"
    else:
        bucket = "high"

    return {
        "score": _BUCKET_SCORES[bucket],
        "bucket": bucket,
    }
