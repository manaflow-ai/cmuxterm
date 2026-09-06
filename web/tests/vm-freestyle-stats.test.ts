import { describe, expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { ProviderError, type VMProvider } from "../services/vms/drivers/types";

describe("Freestyle VM stats", () => {
  for (const [state, expected] of [["running", "awake"], ["paused", "asleep"], ["stopped", "asleep"], ["starting", "unknown"]] as const) {
    test(`reports ${state} resources without waking or executing on the VM`, async () => {
      const reads: string[] = [];
      const client = {
        vms: {
          get: async (id: string) => {
            reads.push(id);
            return { state, resources: { cpu: 4, memory: 8192, storage: 65536 } };
          },
          ref: () => { throw new Error("stats must not start or execute on a VM"); },
        },
      } as unknown as Freestyle;
      const provider: VMProvider = new FreestyleProvider({
        client: () => client,
        resolveDaemonSource: async () => { throw new Error("stats must not install the daemon"); },
      });
      const stats = await provider.getStats?.("vm-stats");
      expect(stats).toMatchObject({ state: expected, cpus: 4, memoryTotalMb: 8192, diskTotalMb: 65536 });
      expect(reads).toEqual(["vm-stats"]);
      expect(stats?.sampledAt).toBeGreaterThan(0);
      expect(stats?.memoryUsedMb).toBeUndefined();
      expect(stats?.diskUsedMb).toBeUndefined();
    });
  }

  test("reports a provider read failure instead of inventing resource totals", async () => {
    const cause = new Error("provider unavailable");
    const provider: VMProvider = new FreestyleProvider({
      client: () => ({ vms: { get: async () => { throw cause; } } }) as unknown as Freestyle,
      resolveDaemonSource: async () => { throw new Error("unused"); },
    });
    await expect(provider.getStats?.("vm-stats")).rejects.toBeInstanceOf(ProviderError);
  });
});
