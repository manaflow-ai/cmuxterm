// Test-only entrypoint. Production never imports this module.
import { AccountControlPlane, type ControlPlaneEnv } from "../src/controlPlaneDo";

export class SandboxAccount extends AccountControlPlane {
  override async fetch(request: Request): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (path === "/inspect") {
      return Response.json({
        schema: Array.from(this.ctx.storage.sql.exec("SELECT version, name FROM account_schema_migrations")),
        rows: Array.from(this.ctx.storage.sql.exec("SELECT challenge_id, expires_at FROM account_challenges")),
        alarm: await this.ctx.storage.getAlarm(),
      });
    }
    if (path === "/seed") {
      const { id, expiresAt } = await request.json() as { id: string; expiresAt: number };
      this.ctx.storage.sql.exec(
        "INSERT INTO account_challenges (challenge_id, payload, expires_at) VALUES (?, '{}', ?)", id, expiresAt,
      );
      return Response.json({ ok: true });
    }
    if (path === "/set-alarm") {
      const { at } = await request.json() as { at: number };
      await this.ctx.storage.setAlarm(at);
      return Response.json({ ok: true });
    }
    if (path === "/alarm") {
      // The runtime removes the delivered alarm before calling alarm().
      await this.ctx.storage.deleteAlarm();
      await super.alarm();
      return Response.json({ ok: true });
    }
    return super.fetch(request);
  }
}
interface Env extends ControlPlaneEnv { ACCOUNT: DurableObjectNamespace<SandboxAccount> }
export default {
  fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const account = url.searchParams.get("account") ?? "a";
    return env.ACCOUNT.get(env.ACCOUNT.idFromName(account)).fetch(request);
  },
};
