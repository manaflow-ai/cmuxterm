import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { maxActiveVmsForPlan } from "../services/vms/entitlements";
import { VmRepository, VmRepositoryLive, type VmRepositoryShape } from "../services/vms/repository";

const dbTest = process.env.CMUX_DB_TEST === "1" ? test.serial : test.skip;
let sql: Sql;
beforeAll(() => {
  if (process.env.CMUX_DB_TEST === "1") {
    sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 1 });
  }
});
afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

const runRepo = <T>(operation: (repo: VmRepositoryShape) => Effect.Effect<T, unknown>) =>
  Effect.runPromise(Effect.flatMap(VmRepository, operation).pipe(Effect.provide(VmRepositoryLive)));

describe("independent Cloud VM limits", () => {
  test("retired deployment overrides cannot reduce the advertised paid allowance", () => {
    const env = { CMUX_VM_PAID_MAX_ACTIVE_VMS: "5", CMUX_VM_PLAN_PRO_MAX_ACTIVE_VMS: "5" };
    expect(maxActiveVmsForPlan("pro", env)).toBe(50);
    expect(maxActiveVmsForPlan("founders", env)).toBe(50);
    expect(maxActiveVmsForPlan("team", env, { seats: 4 })).toBe(200);
  });

  dbTest("admits the third machine, all 50 sizes, and exactly one concurrent final slot", async () => {
    const team = "team-independent-limits";
    await sql`delete from cloud_vms where billing_team_id = ${team}`;
    const input = {
      userId: "user-independent-limits", billingTeamId: team, billingPlanId: "pro",
      provider: "freestyle" as const, image: "snapshot-test", maxActiveVms: 50,
      resourceReservation: { vcpus: 2, memoryMb: 8192, diskMb: 32768 },
    };
    for (let i = 0; i < 49; i++) {
      const result = await runRepo(repo => repo.beginCreate({
        ...input, idempotencyKey: `independent-${i}`,
        // Include the largest machine: dimensions are per machine, not a pool.
        ...(i === 3 ? { resourceReservation: { vcpus: 16, memoryMb: 65536, diskMb: 262144 } } : {}),
      }));
      expect(result.inserted).toBe(true);
    }
    const results = await Promise.allSettled([49, 50].map(i =>
      runRepo(repo => repo.beginCreate({ ...input, idempotencyKey: `independent-${i}` })),
    ));
    expect(results.filter(result => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter(result => result.status === "rejected")).toHaveLength(1);
    const failure = await runRepo(repo => repo.beginCreate({ ...input, idempotencyKey: "over-limit" }).pipe(Effect.flip));
    expect(failure).toMatchObject({ _tag: "VmLimitExceededError", limit: 50 });
    const retry = await runRepo(repo => repo.beginCreate({ ...input, idempotencyKey: "independent-0" }));
    expect(retry.inserted).toBe(false);
    await sql`delete from cloud_vms where billing_team_id = ${team}`;
  });
});
