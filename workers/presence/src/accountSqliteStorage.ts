/**
 * Storage contract for the account control plane.
 *
 * An account Durable Object owns one instance of this database. The schema is
 * intentionally small: application payloads are bounded and short lived, and
 * terminal/event data is never written here.
 */

export const ACCOUNT_STORAGE_QUOTA_BYTES = 8 * 1024 * 1024;
export const ACCOUNT_MAX_BINDINGS = 32;
export const ACCOUNT_MAX_PAYLOAD_BYTES = 64 * 1024;

const DAY_MS = 24 * 60 * 60 * 1000;

export const RETENTION_WINDOWS_MS = {
  challenge: 10 * 60 * 1000,
  pairGrant: DAY_MS,
  relayIssuance: DAY_MS,
  revocationTombstone: 30 * DAY_MS,
  inactiveBinding: 30 * DAY_MS,
} as const;

/** Minimal structural subset of Cloudflare's synchronous SqlStorage API. */
export interface SqliteExecutor {
  exec(query: string, ...bindings: unknown[]): Iterable<unknown>;
}

export interface AccountSqliteDatabase {
  readonly sql: SqliteExecutor;
  /** Cloudflare's synchronous transaction API. Tests may omit it because the
   * fake executor is already single threaded. */
  readonly transactionSync?: <T>(callback: () => T) => T;
}

export interface AccountSqliteMigration {
  readonly version: number;
  readonly name: string;
  readonly statements: readonly string[];
}

export class AccountStorageQuotaError extends Error {
  readonly code = "account_storage_quota_exceeded";

  constructor(readonly bytes: number) {
    super(`account SQLite quota exceeded (${bytes} bytes)`);
    this.name = "AccountStorageQuotaError";
  }
}

export class AccountBindingQuotaError extends Error {
  readonly code = "account_binding_quota_exceeded";

  constructor(readonly bindings: number) {
    super(`account binding quota exceeded (${bindings} bindings)`);
    this.name = "AccountBindingQuotaError";
  }
}

/** Create the schema idempotently. This function is safe to run on every DO
 * activation, so a class migration never needs to depend on application code
 * having run previously. */
const ACCOUNT_SCHEMA_STATEMENTS = [
  `CREATE TABLE IF NOT EXISTS account_bindings (
      binding_id TEXT PRIMARY KEY,
      endpoint_id TEXT NOT NULL,
      device_id TEXT NOT NULL,
      client_namespace TEXT NOT NULL,
      platform TEXT NOT NULL,
      payload TEXT NOT NULL,
      payload_bytes INTEGER NOT NULL,
      last_seen_at INTEGER NOT NULL,
      registered_at INTEGER NOT NULL,
      revoked_at INTEGER,
      tombstone_expires_at INTEGER
    )`,
  `CREATE UNIQUE INDEX IF NOT EXISTS account_bindings_endpoint_live
      ON account_bindings(endpoint_id) WHERE revoked_at IS NULL;
    `,
  `CREATE INDEX IF NOT EXISTS account_bindings_expiry
      ON account_bindings(revoked_at, tombstone_expires_at, last_seen_at)`,
  `CREATE TABLE IF NOT EXISTS account_challenges (
      challenge_id TEXT PRIMARY KEY,
      payload TEXT NOT NULL,
      payload_bytes INTEGER NOT NULL,
      expires_at INTEGER NOT NULL
    )`,
  `CREATE INDEX IF NOT EXISTS account_challenges_expiry
      ON account_challenges(expires_at)`,
  `CREATE TABLE IF NOT EXISTS account_pair_grants (
      grant_id TEXT PRIMARY KEY,
      payload TEXT NOT NULL,
      payload_bytes INTEGER NOT NULL,
      expires_at INTEGER NOT NULL
    )`,
  `CREATE INDEX IF NOT EXISTS account_pair_grants_expiry
      ON account_pair_grants(expires_at)`,
  `CREATE TABLE IF NOT EXISTS account_relay_issuances (
      issuance_id TEXT PRIMARY KEY,
      payload TEXT NOT NULL,
      payload_bytes INTEGER NOT NULL,
      expires_at INTEGER NOT NULL
    )`,
  `CREATE INDEX IF NOT EXISTS account_relay_issuances_expiry
      ON account_relay_issuances(expires_at)`,
  `CREATE TABLE IF NOT EXISTS account_preferences (
      preference_key TEXT PRIMARY KEY,
      payload TEXT NOT NULL,
      payload_bytes INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )`,
  `CREATE TABLE IF NOT EXISTS account_meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )`,
] as const;

/** Append-only schema history. Changing a previously deployed migration is a
 * data-loss bug: an object may have applied it before a later code deployment
 * reaches the same object. */
export const ACCOUNT_SQLITE_MIGRATIONS: readonly AccountSqliteMigration[] = [
  { version: 1, name: "account_state_tables", statements: ACCOUNT_SCHEMA_STATEMENTS },
];

export function runAccountSqliteMigrations(
  database: AccountSqliteDatabase,
  nowMs: number,
): void {
  const { sql } = database;
  sql.exec(`
    CREATE TABLE IF NOT EXISTS account_schema_migrations (
      version INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      applied_at INTEGER NOT NULL
    )
  `);

  const applied = new Map<number, string>();
  for (const rawRow of sql.exec(
    "SELECT version, name FROM account_schema_migrations ORDER BY version",
  )) {
    const row = rawRow as { version?: unknown; name?: unknown };
    if (typeof row.version !== "number" || !Number.isSafeInteger(row.version)
      || typeof row.name !== "string") {
      throw new Error("invalid account schema migration row");
    }
    applied.set(row.version, row.name);
  }

  const highestKnown = ACCOUNT_SQLITE_MIGRATIONS.at(-1)?.version ?? 0;
  for (const [version, name] of applied) {
    if (version > highestKnown) throw new Error(`account schema is newer than this worker: v${version}`);
    const expected = ACCOUNT_SQLITE_MIGRATIONS.find((migration) => migration.version === version);
    if (!expected || expected.name !== name) {
      throw new Error(`account schema migration identity mismatch at v${version}`);
    }
  }

  const apply = (): void => {
    for (const migration of ACCOUNT_SQLITE_MIGRATIONS) {
      if (applied.has(migration.version)) continue;
      for (const statement of migration.statements) sql.exec(statement);
      sql.exec(
        "INSERT INTO account_schema_migrations (version, name, applied_at) VALUES (?, ?, ?)",
        migration.version,
        migration.name,
        nowMs,
      );
      applied.set(migration.version, migration.name);
    }
  };
  if (database.transactionSync) database.transactionSync(apply);
  else apply();
}

/** Compatibility name for callers that only have the SQL handle. New DO code
 * should pass the full DurableObjectStorage wrapper to the migration runner so
 * schema changes are applied in one synchronous transaction. */
export function ensureAccountSchema(sql: SqliteExecutor): void {
  runAccountSqliteMigrations({ sql }, Date.now());
}

/** Use one cutoff for every expiry delete. A single timestamp makes a cleanup
 * pass deterministic and prevents a clock tick from splitting a transaction. */
export function expiredBefore(nowMs: number): number {
  if (!Number.isSafeInteger(nowMs) || nowMs < 0) {
    throw new RangeError("nowMs must be a non-negative safe integer");
  }
  return nowMs;
}

/** Wake at least daily. Expiry-specific alarms can be scheduled earlier by a
 * caller that knows the next row deadline. */
export function retentionAlarmAt(nowMs: number): number {
  return expiredBefore(nowMs) + DAY_MS;
}

export function isPayloadWithinQuota(bytes: number): boolean {
  return Number.isSafeInteger(bytes) && bytes >= 0 && bytes <= ACCOUNT_MAX_PAYLOAD_BYTES;
}

function scalarNumber(sql: SqliteExecutor, query: string): number {
  const row = [...sql.exec(query)][0] as { value?: unknown } | undefined;
  const value = row?.value;
  return typeof value === "number" && Number.isSafeInteger(value) ? value : 0;
}

/** Delete all temporary state and inactive binding rows covered by the policy.
 * No unexpired row is touched. The caller should invoke this before writes and
 * from the DO alarm. */
export function pruneExpiredAccountState(sql: SqliteExecutor, nowMs: number): void {
  const now = expiredBefore(nowMs);
  sql.exec("DELETE FROM account_challenges WHERE expires_at <= ?", now);
  sql.exec("DELETE FROM account_pair_grants WHERE expires_at <= ?", now);
  sql.exec("DELETE FROM account_relay_issuances WHERE expires_at <= ?", now);
  sql.exec(
    "DELETE FROM account_bindings WHERE revoked_at IS NOT NULL AND tombstone_expires_at <= ?",
    now,
  );
  sql.exec(
    "DELETE FROM account_bindings WHERE revoked_at IS NULL AND last_seen_at <= ?",
    now - RETENTION_WINDOWS_MS.inactiveBinding,
  );
}

/** Return the approximate bytes held by user payload columns. SQLite's
 * `length` reports bytes for UTF-8 TEXT, which is the conservative measure we
 * need for the logical quota. */
export function accountPayloadBytes(sql: SqliteExecutor): number {
  return scalarNumber(sql, `
    SELECT COALESCE(SUM(payload_bytes), 0) AS value FROM (
      SELECT payload_bytes FROM account_bindings
      UNION ALL SELECT payload_bytes FROM account_challenges
      UNION ALL SELECT payload_bytes FROM account_pair_grants
      UNION ALL SELECT payload_bytes FROM account_relay_issuances
      UNION ALL SELECT payload_bytes FROM account_preferences
    )
  `);
}

export function assertAccountStorageQuota(sql: SqliteExecutor): void {
  const bytes = accountPayloadBytes(sql);
  if (bytes > ACCOUNT_STORAGE_QUOTA_BYTES) throw new AccountStorageQuotaError(bytes);
}

export function assertBindingQuota(sql: SqliteExecutor): void {
  const bindings = scalarNumber(
    sql,
    "SELECT COUNT(*) AS value FROM account_bindings WHERE revoked_at IS NULL",
  );
  if (bindings >= ACCOUNT_MAX_BINDINGS) throw new AccountBindingQuotaError(bindings);
}
