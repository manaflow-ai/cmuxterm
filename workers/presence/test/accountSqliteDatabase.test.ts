import { Database, type SQLQueryBindings } from "bun:sqlite";
import { afterEach, describe, expect, test } from "bun:test";
import {
  ACCOUNT_SQLITE_MIGRATIONS,
  ACCOUNT_STORAGE_QUOTA_BYTES,
  accountPayloadBytes,
  assertAccountStorageQuota,
  pruneExpiredAccountState,
  runAccountSqliteMigrations,
  type AccountSqliteDatabase,
} from "../src/accountSqliteStorage";

const opened: Database[] = [];
afterEach(() => { for (const db of opened.splice(0)) db.close(); });
function database() {
  const db = new Database(":memory:", { strict: true });
  opened.push(db);
  const storage: AccountSqliteDatabase = {
    sql: { exec: (query, ...bindings) => db.query(query).all(...bindings as SQLQueryBindings[]) },
    transactionSync: <T>(callback: () => T): T => db.transaction(callback)(),
  };
  return { db, storage };
}
const now = 1_800_000_000_000;
function seedChallenge(db: Database, id: string, expiresAt = now + 60_000, payload = "{}") {
  db.run("INSERT INTO account_challenges (challenge_id, payload, expires_at) VALUES (?, ?, ?)",
    [id, payload, expiresAt]);
}
const upgrade = [...ACCOUNT_SQLITE_MIGRATIONS, {
  version: 2, name: "test_add_preference_note", statements: [
    "ALTER TABLE account_preferences ADD COLUMN note TEXT",
    "UPDATE account_preferences SET note = 'preserved'",
  ],
}];

describe("account schema on real SQLite", () => {
  test("fresh initialization and repeated activation preserve existing data", () => {
    const { db, storage } = database();
    runAccountSqliteMigrations(storage, now);
    seedChallenge(db, "keep");
    runAccountSqliteMigrations(storage, now + 1);
    expect(db.query("SELECT version FROM account_schema_migrations").all()).toEqual([{ version: 1 }]);
    expect(db.query("SELECT challenge_id FROM account_challenges").all()).toEqual([{ challenge_id: "keep" }]);
  });

  test("populated upgrade is applied once and preserves preferences", () => {
    const { db, storage } = database();
    runAccountSqliteMigrations(storage, now);
    db.run("INSERT INTO account_preferences (preference_key, payload, updated_at) VALUES ('relay', '{}', ?)", [now]);
    runAccountSqliteMigrations(storage, now + 1, upgrade);
    runAccountSqliteMigrations(storage, now + 2, upgrade);
    expect(db.query("SELECT payload, note FROM account_preferences").all()).toEqual([{ payload: "{}", note: "preserved" }]);
    expect(db.query("SELECT version FROM account_schema_migrations ORDER BY version").all()).toEqual([{ version: 1 }, { version: 2 }]);
  });

  test("failed migration rolls back DDL, data, and version marker together", () => {
    const { db, storage } = database();
    runAccountSqliteMigrations(storage, now);
    seedChallenge(db, "keep");
    expect(() => runAccountSqliteMigrations(storage, now + 1, [...ACCOUNT_SQLITE_MIGRATIONS, {
      version: 2, name: "test_failure", statements: [
        "CREATE TABLE partial_migration (id TEXT)",
        "DELETE FROM account_challenges",
        "INSERT INTO table_that_does_not_exist VALUES (1)",
      ],
    }])).toThrow();
    expect(db.query("SELECT name FROM sqlite_master WHERE name = 'partial_migration'").all()).toEqual([]);
    expect(db.query("SELECT challenge_id FROM account_challenges").all()).toEqual([{ challenge_id: "keep" }]);
    expect(db.query("SELECT version FROM account_schema_migrations").all()).toEqual([{ version: 1 }]);
  });

  test("refuses changed migration SQL and older code against a newer database", () => {
    const { storage } = database();
    runAccountSqliteMigrations(storage, now);
    expect(() => runAccountSqliteMigrations(storage, now, [{
      ...ACCOUNT_SQLITE_MIGRATIONS[0]!, statements: ["CREATE TABLE changed (id TEXT)"],
    }])).toThrow();
    runAccountSqliteMigrations(storage, now, upgrade);
    expect(() => runAccountSqliteMigrations(storage, now)).toThrow();
  });

  test("refuses migration sequence gaps before writing schema", () => {
    const { db, storage } = database();
    expect(() => runAccountSqliteMigrations(storage, now, [{ version: 2, name: "gap", statements: [] }])).toThrow();
    expect(db.query("SELECT name FROM sqlite_master WHERE name = 'account_schema_migrations'").all()).toEqual([]);
  });

  test("computes payload bytes from UTF-8 and rejects oversized writes in SQLite", () => {
    const { db, storage } = database();
    runAccountSqliteMigrations(storage, now);
    seedChallenge(db, "utf8", now + 1, "é");
    expect(accountPayloadBytes(storage.sql)).toBe(2);
    expect(() => seedChallenge(db, "large", now + 1, "x".repeat(65_537))).toThrow();
    expect(accountPayloadBytes(storage.sql)).toBe(2);
  });

  test("account byte limit is atomic and deletes release capacity", () => {
    const { db, storage } = database();
    runAccountSqliteMigrations(storage, now);
    const payload = "x".repeat(65_536);
    for (let i = 0; i < ACCOUNT_STORAGE_QUOTA_BYTES / payload.length; i++) seedChallenge(db, String(i), now + 1, payload);
    expect(() => seedChallenge(db, "overflow", now + 1, "x")).toThrow();
    expect(accountPayloadBytes(storage.sql)).toBe(ACCOUNT_STORAGE_QUOTA_BYTES);
    db.run("DELETE FROM account_challenges WHERE challenge_id = '0'");
    seedChallenge(db, "fits", now + 1, "x");
    expect(accountPayloadBytes(storage.sql)).toBe(ACCOUNT_STORAGE_QUOTA_BYTES - payload.length + 1);
  });

  test("cleanup is bounded and retains unexpired records", () => {
    const { db, storage } = database();
    runAccountSqliteMigrations(storage, now);
    for (let i = 0; i < 140; i++) seedChallenge(db, `old-${i}`, now);
    seedChallenge(db, "live", now + 60_000);
    pruneExpiredAccountState(storage.sql, now);
    expect(db.query("SELECT COUNT(*) AS n FROM account_challenges").get()).toEqual({ n: 13 });
    pruneExpiredAccountState(storage.sql, now);
    expect(db.query("SELECT challenge_id FROM account_challenges").all()).toEqual([{ challenge_id: "live" }]);
  });

  test.each([[], [{ value: -1 }], [{ value: "10" }], [{ value: Number.MAX_SAFE_INTEGER + 1 }]].map(rows => ({ rows })) )(
    "rejects unusable quota query results", ({ rows }) => {
      expect(() => assertAccountStorageQuota({ exec: () => rows })).toThrow();
    },
  );
});
