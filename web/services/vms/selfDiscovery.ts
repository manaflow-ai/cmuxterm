// What a Cloud VM can learn about itself and its siblings from inside.
//
// The guest holds no Stack token, so `GET /api/vm/self` authenticates with the
// route token the Freestyle TLS edge injects (bound to one `cloud_vms` row).
// That identity carries the team, and this module turns the team's machine
// rows into the one contract the guest `cmux self` / `cmux vm ls` verbs print.
// Pure: no database or framework imports, so the route test and the guest CLI
// test share it.
import type { TeamMachine } from "../coderouter/teamMachines";

export const VM_SELF_SCHEMA = 1;

export type VmSelfMachine = {
  /** The provider machine id: the `id` every Mac `cmux vm …` verb takes. */
  readonly id: string;
  /** The `cloud_vms` row id the route token is bound to. */
  readonly vmId: string;
  /** displayName, else slug, else id: what a person calls the machine. */
  readonly name: string;
  readonly displayName: string | null;
  readonly slug: string | null;
  readonly status: string;
  readonly createdAt: string;
  /** True on the machine that made the request. */
  readonly self: boolean;
};

export type VmSelfResponse = {
  readonly schema: typeof VM_SELF_SCHEMA;
  readonly machine: VmSelfMachine;
  readonly team: { readonly id: string };
  /** Live machines in the team, newest first, the caller included. */
  readonly machines: readonly VmSelfMachine[];
};

function machineName(machine: TeamMachine): string {
  return machine.displayName ?? machine.slug ?? machine.providerVmId ?? machine.vmId;
}

function selfMachine(machine: TeamMachine, selfVmId: string): VmSelfMachine | null {
  if (!machine.providerVmId) return null;
  return {
    id: machine.providerVmId,
    vmId: machine.vmId,
    name: machineName(machine),
    displayName: machine.displayName,
    slug: machine.slug,
    status: machine.status,
    createdAt: machine.createdAt,
    self: machine.vmId === selfVmId,
  };
}

/**
 * The guest-facing view of a team's machines. Destroyed rows and rows with no
 * provider id are hidden, the same filter the Mac's `cmux vm ls` applies.
 * Returns null when the caller's own row is not among them (destroyed while
 * its token was still in flight, or a mis-bound token): the route answers 404.
 */
export function vmSelfResponse(
  identity: { readonly teamId: string; readonly vmId: string },
  owned: readonly TeamMachine[],
): VmSelfResponse | null {
  const machines = owned
    .filter((machine) => !machine.destroyed)
    .map((machine) => selfMachine(machine, identity.vmId))
    .filter((machine): machine is VmSelfMachine => machine !== null);
  const machine = machines.find((entry) => entry.self);
  if (!machine) return null;
  return { schema: VM_SELF_SCHEMA, machine, team: { id: identity.teamId }, machines };
}
