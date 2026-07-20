"use strict";

const { Pool } = require("pg");
const pino = require("pino");

const logger = pino({
  level: process.env.LOG_LEVEL || "info",
  base: {
    service: process.env.SERVICE_NAME || "transaction-service",
    env: process.env.APP_ENV || "development",
    version: process.env.APP_VERSION || "0.0.0",
    component: "ledger",
  },
});

// ── PostgreSQL connection pool ────────────────────────────────────────
// A single pool is created lazily on first use and reused for the life of
// the process. Do NOT create a new Pool/Client per request — each one opens
// its own set of connections and background maintenance timers that are
// never reclaimed. That exact anti-pattern (a fresh client created per
// message, never closed) is what caused notification-service's memory leak
// and OOMKill — see the statsdClient fix in notification-service/main.go.
//
// POSTGRES_URL is shared with account-service and is JDBC-style
// ("jdbc:postgresql://host:port/db") since that's what Spring/JDBC expects.
// The `pg` driver wants a plain "postgresql://" URL instead, so strip the
// "jdbc:" prefix and inject credentials from POSTGRES_USER/POSTGRES_PASSWORD
// rather than introducing a second, Node-specific connection string.
let pool = null;

function getPool() {
  if (pool) return pool;

  // pg.Pool does NOT merge a credential-less connectionString with separate
  // user/password fields — the connectionString fully overrides them
  // (verified: passing both resulted in "no PostgreSQL user name specified
  // in startup packet", i.e. the user field was silently dropped).
  // Credentials must be embedded directly in the URL.
  const rawUrl =
    process.env.POSTGRES_URL || "jdbc:postgresql://postgres-ledger:5432/ledger";
  const withoutJdbcPrefix = rawUrl.replace(/^jdbc:/, "");
  const user = encodeURIComponent(process.env.POSTGRES_USER || "postgres");
  const password = encodeURIComponent(process.env.POSTGRES_PASSWORD || "");
  const withoutScheme = withoutJdbcPrefix.replace(/^postgresql:\/\//, "");
  const connectionString = `postgresql://${user}:${password}@${withoutScheme}`;

  pool = new Pool({
    connectionString,
    max: 10,
    idleTimeoutMillis: 30000,
  });

  pool.on("error", (err) => {
    // Emitted for errors on idle clients in the pool (e.g. connection
    // dropped). Logging here prevents an unhandled 'error' event from
    // crashing the whole process.
    logger.error(
      { err, "db.instance": "postgres-ledger" },
      "ledger.pool.error",
    );
  });

  return pool;
}

/**
 * Writes a payment record to the ledger and marks it settled.
 *
 * NOTE ON "settled": this sample app has no multi-day clearing workflow —
 * account-service and transaction-service both model instant, synchronous
 * payments. Rather than fabricate a fake asynchronous settlement pipeline,
 * transactions are inserted as 'pending' and then immediately updated to
 * 'settled' with settled_at = now(), representing same-day clearing for
 * demo purposes. In a real deployment, settled_at would instead be
 * populated asynchronously by a settlement/clearing integration.
 * batch-processor's ReconciliationJob reads exactly this status/settled_at
 * combination (see deploy/kubernetes/base/infrastructure/postgres-init.yaml).
 *
 * @param {object} params
 * @param {string} params.payment_id
 * @param {number} params.amount
 * @param {string} params.currency
 * @param {string} params.account_id
 * @returns {Promise<{committed: boolean}>}
 */
async function commit({ payment_id, amount, currency, account_id }) {
  try {
    const db = getPool();

    await db.query(
      `INSERT INTO transactions (id, amount, currency, account_id, status)
       VALUES ($1, $2, $3, $4, 'pending')
       ON CONFLICT (id) DO NOTHING`,
      [payment_id, amount, currency, account_id],
    );

    // Simulate same-day settlement — see the "NOTE ON settled" doc comment
    // above for why this happens synchronously in this sample app.
    await db.query(
      `UPDATE transactions
          SET status = 'settled', settled_at = now()
        WHERE id = $1`,
      [payment_id],
    );

    logger.info(
      {
        payment_id,
        amount,
        currency,
        account_id,
        "db.instance": "postgres-ledger",
        "db.operation": "INSERT",
      },
      "ledger.commit",
    );

    return { committed: true };
  } catch (err) {
    logger.error(
      { err, payment_id, "db.instance": "postgres-ledger" },
      "ledger.commit.failed",
    );

    throw err;
  }
}

module.exports = { commit };
