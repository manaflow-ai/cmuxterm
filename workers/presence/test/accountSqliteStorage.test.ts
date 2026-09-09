import { describe, expect, it } from "bun:test";
import {
  ACCOUNT_STORAGE_QUOTA_BYTES,
  ACCOUNT_MAX_BINDINGS,
  ACCOUNT_MAX_PAYLOAD_BYTES,
  RETENTION_WINDOWS_MS,
  retentionAlarmAt,
  expiredBefore,
  isPayloadWithinQuota,
  runAccountSqliteMigrations,
  type AccountSqliteDatabase,
  type SqliteExecutor,
} from "../src/accountSqliteStorage";

class RecordingSql implements SqliteExecutor {
  readonly statements: string[] = [];
  readonly applied: { version: number; name: string }[] = [];
  exec(query: string, ..._bindings: unknown[]): Iterable<unknown> {
    this.statements.push(query);
    if (query.includes("SELECT version, name FROM account_schema_migrations")) {
      return this.applied;
    }
    if (query.includes("INSERT INTO account_schema_migrations")) {
      this.applied.push({ version: 1, name: "account_state_tables" });
    }
    return [];
  }
}

describe("account SQLite retention policy", () => {
  it("keeps a logical quota well below the platform limit", () => {
    expect(ACCOUNT_STORAGE_QUOTA_BYTES).toBe(8 * 1024 * 1024);
    expect(ACCOUNT_STORAGE_QUOTA_BYTES).toBeLessThan(10 * 1024 * 1024 * 1024);
  });

  it("bounds active bindings and individual payloads", () => {
    expect(ACCOUNT_MAX_BINDINGS).toBe(32);
    expect(ACCOUNT_MAX_PAYLOAD_BYTES).toBe(64 * 1024);
    expect(isPayloadWithinQuota(ACCOUNT_MAX_PAYLOAD_BYTES)).toBe(true);
    expect(isPayloadWithinQuota(ACCOUNT_MAX_PAYLOAD_BYTES + 1)).toBe(false);
  });

  it("uses explicit expiry windows for every temporary record", () => {
    expect(RETENTION_WINDOWS_MS.challenge).toBe(10 * 60 * 1000);
    expect(RETENTION_WINDOWS_MS.pairGrant).toBe(24 * 60 * 60 * 1000);
    expect(RETENTION_WINDOWS_MS.relayIssuance).toBe(24 * 60 * 60 * 1000);
    expect(RETENTION_WINDOWS_MS.revocationTombstone).toBe(30 * 24 * 60 * 60 * 1000);
  });

  it("deletes through a monotonic cutoff", () => {
    const now = 1_700_000_000_000;
    expect(expiredBefore(now)).toBe(now);
    expect(retentionAlarmAt(now)).toBe(now + 24 * 60 * 60 * 1000);
  });

  it("records each schema version and is idempotent", () => {
    const sql = new RecordingSql();
    const database: AccountSqliteDatabase = {
      sql,
      transactionSync: <T>(callback: () => T): T => callback(),
    };
    runAccountSqliteMigrations(database, 1_700_000_000_000);
    const firstRun = sql.statements.length;
    runAccountSqliteMigrations(database, 1_700_000_000_001);
    expect(sql.statements.length).toBeGreaterThan(firstRun);
    expect(sql.statements.filter((statement) => statement.includes("INSERT INTO account_schema_migrations"))).toHaveLength(1);
  });
});
