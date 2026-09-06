import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { maxActiveVmsForPlan } from "../services/vms/entitlements";
import { VmRepository, VmRepositoryLive } from "../services/vms/repository";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { execVm, resizeVm } from "../services/vms/workflows";

const serialTest = (test as typeof test & { serial: typeof test }).serial;
const dbTest = process.env.CMUX_DB_TEST === "1" ? serialTest : test.skip;
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

/** Give every regression its own billing scope and remove it even on failure. */
async function withTeam(operation: (team: string) => Promise<void>) {
  const team = `review-${randomUUID()}`;
  try {
    await operation(team);
  } finally {
    await sql`delete from cloud_vm_bases where scope_id = ${team}`;
    await sql`delete from cloud_vms where billing_team_id = ${team}`;
  }
}

describe("VM review regressions", () => {
  dbTest("concurrent Base resets preserve the retryable conflict", () => withTeam(async team => {
    const input = {
      userId: team, billingTeamId: team, billingPlanId: "pro",
      billingCustomerType: "team" as const, provider: "freestyle" as const,
      image: "snapshot-test", maxActiveVms: 50,
    };
    const reset = () => Effect.runPromise(Effect.flatMap(VmRepository, repo =>
      repo.beginBaseReset(input).pipe(Effect.either),
    ).pipe(Effect.provide(VmRepositoryLive)));
    const outcomes = await Promise.all([reset(), reset()]);
    expect(outcomes.filter(result => result._tag === "Right")).toHaveLength(1);
    const rejected = outcomes.filter(result => result._tag === "Left");
    expect(rejected).toHaveLength(1);
    expect(rejected[0]?.left).toMatchObject({ _tag: "VmCreateInProgressError" });
    const [count] = await sql`select count(*)::integer as count from cloud_vms where billing_team_id = ${team}`;
    expect(count?.count).toBe(1);
  }));

  for (const operation of ["resize", "exec"] as const) {
    for (const allowance of [maxActiveVmsForPlan("team", {}, { seats: 4 }), null, 50]) {
      dbTest(`${operation} resumes a paused Team VM using allowance ${allowance}`, () => withTeam(async team => {
        await sql`
          insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
          select ${team}, ${team}, 'team', 'freestyle', ${team} || '-' || n, 'snapshot-test', 'running'
          from generate_series(1, 51) n
        `;
        const providerVmId = `${team}-paused`;
        await sql`
          insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
          values (${team}, ${team}, 'team', 'freestyle', ${providerVmId}, 'snapshot-test', 'paused')
        `;
        let resumes = 0;
        let operations = 0;
        let statsReads = 0;
        const provider = {
          getStatus: () => Effect.succeed("paused"),
          resume: () => Effect.sync(() => {
            resumes += 1;
            return { provider: "freestyle", providerVmId, image: "snapshot-test", status: "running", createdAt: Date.now() };
          }),
          getStats: () => Effect.sync(() => ({
            state: "awake", sampledAt: Date.now(), diskTotalMb: ++statsReads === 1 ? 32768 : 65536,
          })),
          resize: () => Effect.sync(() => { operations += 1; }),
          exec: () => Effect.sync(() => {
            operations += 1;
            return { exitCode: 0, stdout: "ok", stderr: "" };
          }),
        } as unknown as VmProviderGatewayShape;
        const input = {
          userId: team, billingTeamId: team, billingPlanId: "team", callerPlanId: "team",
          teamIds: [team], providerVmId, maxActiveVms: allowance,
          storageMb: 65536, command: "true", timeoutMs: 1000,
        };
        const program = operation === "resize"
          ? resizeVm(input).pipe(Effect.asVoid)
          : execVm(input).pipe(Effect.asVoid);
        const result = await Effect.runPromise(program.pipe(
          Effect.either,
          Effect.provide(Layer.mergeAll(VmRepositoryLive, Layer.succeed(VmProviderGateway, provider))),
        ));
        if (allowance === 50) {
          expect(result._tag).toBe("Left");
          if (result._tag === "Left") expect(result.left).toMatchObject({ _tag: "VmLimitExceededError", limit: 50 });
          expect(resumes).toBe(0);
          expect(operations).toBe(0);
        } else {
          expect(result._tag).toBe("Right");
          expect(resumes).toBe(1);
          expect(operations).toBe(1);
        }
      }));
    }
  }
});
