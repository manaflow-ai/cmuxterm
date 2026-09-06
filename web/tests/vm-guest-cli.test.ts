import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { GUEST_CMUX_SHIM, GUEST_CMUX_SHIM_PATH, guestCliInstallCommand } from "../services/vms/guestCli";

/**
 * Runs the shim against a fake cmux-tui binary that prints its argv one word
 * per line, so a test can assert exactly what would reach the daemon.
 */
function runShim(
  args: string[],
  env: Record<string, string | undefined> = {},
  setup?: (directory: string) => void,
): { argv: string[]; status: number | null; stdout: string; stderr: string } {
  const dir = mkdtempSync(join(tmpdir(), "cmux-guest-cli-"));
  const shim = join(dir, "cmux");
  const fakeTui = join(dir, "cmux-tui");
  writeFileSync(shim, GUEST_CMUX_SHIM);
  chmodSync(shim, 0o755);
  writeFileSync(fakeTui, '#!/bin/sh\nprintf \'%s\\n\' "$@"\n');
  chmodSync(fakeTui, 0o755);
  setup?.(dir);
  const inheritedPath = env.PATH ?? process.env.PATH ?? "/usr/bin:/bin";
  const result = spawnSync("sh", [shim, ...args], {
    encoding: "utf8",
    timeout: 12_000,
    env: { NODE_ENV: "test", HOME: dir, CMUX_TUI_BIN: fakeTui, ...env, PATH: `${dir}:${inheritedPath}` },
  });
  const argv = result.stdout.length === 0 ? [] : result.stdout.replace(/\n$/, "").split("\n");
  return { argv, status: result.status, stdout: result.stdout, stderr: result.stderr };
}

const TERMINAL_ID = "term_0123456789abcdef0123456789abcdef";

// The in-VM `cmux` shim is shipped as driver-written bytes; a syntax error
// would surface only inside a live machine, so validate it here.
describe("in-VM cmux shim", () => {
  test("is valid POSIX sh", () => {
    const result = spawnSync("sh", ["-n"], { input: GUEST_CMUX_SHIM, encoding: "utf8" });
    expect(result.stderr).toBe("");
    expect(result.status).toBe(0);
  });

  test("fronts the machine's own cmux-tui and the peer-link verbs", () => {
    // Local verbs forward to the daemon binary on the daemon's session.
    expect(GUEST_CMUX_SHIM).toContain("/root/.cmux/bin/cmux-tui");
    expect(GUEST_CMUX_SHIM).toContain('--session "$LOCAL_SESSION"');
    // Peer links ride the same headless connect contract the Mac app uses:
    // remote connect --headless --json, socket named by the
    // connection-snapshot event's local_socket field.
    expect(GUEST_CMUX_SHIM).toContain("remote connect");
    expect(GUEST_CMUX_SHIM).toContain("--headless --json");
    expect(GUEST_CMUX_SHIM).toContain('select(.event=="connection-snapshot")');
    expect(GUEST_CMUX_SHIM).toContain(".local_socket");
    // The single-use invitation travels by file, never argv, and is dropped
    // from the peer file once consumed.
    expect(GUEST_CMUX_SHIM).toContain("--invite-file");
    expect(GUEST_CMUX_SHIM).toContain("del(.invite)");
    // Peer exec runs through a durable terminal on the peer, creating a
    // workspace when the fresh session has none.
    expect(GUEST_CMUX_SHIM).toContain('workspace "$target" run --on-exit close');
    expect(GUEST_CMUX_SHIM).toContain("workspace create --name main");
  });

  test("help exposes the shared auth, CodeRouter, and agent contract", () => {
    const run = runShim(["--help"]);
    expect(run.status).toBe(0);
    expect(run.stdout).toContain("cmux auth status [--json]");
    expect(run.stdout).toContain("cmux coderouter status|usage|models");
    expect(run.stdout).toContain("cmux coderouter agent <claude|codex|opencode|pi>");
    expect(run.stdout).toContain("cmux agent <claude|codex|opencode|pi>");
  });

  describe("auth status", () => {
    const fakeCurl = (status: string, body = "") => (directory: string) => {
      const curl = join(directory, "curl");
      writeFileSync(
        curl,
        `#!/bin/sh\ncase "$*" in\n  *-w*) printf '%s' '${status}' ;;\n  *) printf '%s' '${body.replace(/'/g, "'\\''")}' ;;\nesac\n`,
      );
      chmodSync(curl, 0o755);
    };

    test("reports daemon and accepted VM-bound route without exposing a token", () => {
      const run = runShim(
        ["auth", "status", "--json"],
        {
          CMUX_CODEROUTER_URL: "https://coderouter.cmux.internal",
          OPENAI_API_KEY: "cmux-vm-edge-placeholder",
        },
        fakeCurl("200"),
      );
      expect(run.status).toBe(0);
      const payload = JSON.parse(run.stdout) as Record<string, any>;
      expect(payload.authenticated).toBe(true);
      expect(payload.daemon).toMatchObject({ running: true, authenticated: true, session: "cloud" });
      expect(payload.tls).toEqual({ reachable: true });
      expect(payload.coderouter).toMatchObject({ configured: true, route_authenticated: "accepted", http_status: "200" });
      expect(run.stdout).not.toContain("crt_");
    });

    test("separates TLS reachability from a rejected route", () => {
      const run = runShim(
        ["auth", "status", "--json"],
        { CMUX_CODEROUTER_URL: "https://coderouter.cmux.internal" },
        fakeCurl("401"),
      );
      expect(run.status).not.toBe(0);
      const payload = JSON.parse(run.stdout) as Record<string, any>;
      expect(payload.authenticated).toBe(false);
      expect(payload.daemon.authenticated).toBe(true);
      expect(payload.tls).toEqual({ reachable: true });
      expect(payload.coderouter).toMatchObject({ route_authenticated: "rejected", http_status: "401" });
    });

    test("does not claim full authentication when the model plane is absent", () => {
      const run = runShim(["auth", "status", "--json"]);
      expect(run.status).not.toBe(0);
      const payload = JSON.parse(run.stdout) as Record<string, any>;
      expect(payload.authenticated).toBe(false);
      expect(payload.daemon).toMatchObject({ running: true, authenticated: true });
      expect(payload.coderouter).toMatchObject({ configured: false, route_authenticated: "not_configured" });
    });

    test("refuses a route token copied into the guest", () => {
      const run = runShim(
        ["auth", "status"],
        { OPENAI_API_KEY: "crt_should_not_be_here" },
      );
      expect(run.status).not.toBe(0);
      expect(run.stderr).toContain("refusing a coderouter route token");
    });
  });

  describe("CodeRouter agent entrypoints", () => {
    test("reads usage and models through the configured HTTPS edge", () => {
      const run = runShim(
        ["coderouter", "usage"],
        { CMUX_CODEROUTER_URL: "https://coderouter.cmux.internal" },
        (directory) => {
          const curl = join(directory, "curl");
          writeFileSync(
            curl,
            "#!/bin/sh\ncase \"$*\" in\n  *vm-usage/self*) printf '%s' '{\"kind\":\"ready\",\"vmId\":\"vm-test\"}' ;;\n  *v1/models*) printf '%s' '{\"data\":[{\"id\":\"test-model\"}]}' ;;\n  *) exit 1 ;;\nesac\n",
          );
          chmodSync(curl, 0o755);
        },
      );
      expect(run.status).toBe(0);
      expect(JSON.parse(run.stdout)).toEqual({ kind: "ready", vmId: "vm-test" });

      const models = runShim(
        ["coderouter", "models"],
        { CMUX_CODEROUTER_URL: "https://coderouter.cmux.internal" },
        (directory) => {
          const curl = join(directory, "curl");
          writeFileSync(curl, "#!/bin/sh\nprintf '%s' '{\"data\":[{\"id\":\"test-model\"}]}'\n");
          chmodSync(curl, 0o755);
        },
      );
      expect(models.status).toBe(0);
      expect(JSON.parse(models.stdout).data[0].id).toBe("test-model");
    });

    test("maps a bare prompt through the short agent alias", () => {
      const run = runShim(["agent", "claude", "reply exactly pong"], {}, (directory) => {
        const claude = join(directory, "claude");
        writeFileSync(claude, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
        chmodSync(claude, 0o755);
      });
      expect(run.status).toBe(0);
      expect(run.stdout.trim().split("\n")).toEqual(["-p", "reply exactly pong"]);
    });

    test("accepts the canonical separator before a guest prompt", () => {
      const run = runShim(["coderouter", "agent", "codex", "--", "reply exactly pong"], {}, (directory) => {
        const codex = join(directory, "codex");
        writeFileSync(codex, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
        chmodSync(codex, 0o755);
      });
      expect(run.status).toBe(0);
      expect(run.stdout.trim().split("\n")).toEqual(["exec", "reply exactly pong"]);
    });

    test("keeps cmux-tui's local agent scope available", () => {
      const run = runShim(["agent", "list"]);
      expect(run.status).toBe(0);
      expect(run.argv).toEqual(["--session", "cloud", "agent", "list"]);
    });

    test("passes provider subcommands through the coderouter prefix", () => {
      const run = runShim(["coderouter", "agent", "codex", "exec", "summarize"], {}, (directory) => {
        const codex = join(directory, "codex");
        writeFileSync(codex, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
        chmodSync(codex, 0o755);
      });
      expect(run.status).toBe(0);
      expect(run.stdout.trim().split("\n")).toEqual(["exec", "summarize"]);
    });

    test("keeps account login host-owned", () => {
      const run = runShim(["coderouter", "claude", "list"]);
      expect(run.status).toBe(2);
      expect(run.stderr).toContain("host-owned");
      expect(run.stderr).toContain("Stack tokens");
    });
  });

  // `cmux notify` is what agent hooks run inside a machine. cmux-tui has no
  // `notify` verb, so the shim must translate to `notification create` and tag
  // the daemon-assigned terminal so the Mac can attribute the notification to
  // the pane showing it. Nothing Mac-side (workspace/surface ids, sockets) may
  // travel in the other direction.
  describe("notify", () => {
    test("maps to notification create on the daemon session, tagged with this terminal", () => {
      const run = runShim(
        ["notify", "--title", "Build done", "--subtitle", "api", "--body", "3 tests passed", "--tab", "0", "--panel", "1", "--reply"],
        { CMUX_TUI_TERMINAL_ID: TERMINAL_ID },
      );
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      expect(run.argv).toEqual([
        "--session",
        "cloud",
        "--quiet",
        "notification",
        "create",
        "--title",
        "Build done",
        "--body",
        "api — 3 tests passed",
        "--terminal",
        TERMINAL_ID,
      ]);
    });

    test("omits --terminal outside a daemon PTY, drops levels the daemon rejects, defaults the title", () => {
      const withoutTerminal = runShim(["notify", "--body", "hi", "--level", "success"], { CMUX_TUI_TERMINAL_ID: undefined });
      expect(withoutTerminal.status).toBe(0);
      expect(withoutTerminal.argv).toEqual(["--session", "cloud", "--quiet", "notification", "create", "--title", "Notification", "--body", "hi"]);

      const withLevel = runShim(["notify", "--title=T", "--body=B", "--level=error", "--surface", "surface:3"], {
        CMUX_TUI_TERMINAL_ID: TERMINAL_ID,
      });
      expect(withLevel.status).toBe(0);
      expect(withLevel.argv).toEqual([
        "--session",
        "cloud",
        "--quiet",
        "notification",
        "create",
        "--title",
        "T",
        "--body",
        "B",
        "--level",
        "error",
        "--terminal",
        TERMINAL_ID,
      ]);
    });

    test("never forwards Mac socket or topology identity into the daemon", () => {
      const run = runShim(["notify", "--title", "T", "--workspace", "workspace:1", "--surface", "surface:2", "--window", "window:1"], {
        CMUX_TUI_TERMINAL_ID: TERMINAL_ID,
        CMUX_SOCKET_PATH: "/tmp/should-not-leak.sock",
        CMUX_WORKSPACE_ID: "11111111-1111-1111-1111-111111111111",
        CMUX_SURFACE_ID: "22222222-2222-2222-2222-222222222222",
      });
      expect(run.status).toBe(0);
      const joined = run.argv.join(" ");
      expect(joined).not.toContain("workspace:1");
      expect(joined).not.toContain("surface:2");
      expect(joined).not.toContain("window:1");
      expect(joined).not.toContain("1111");
      expect(joined).not.toContain("2222");
      expect(joined).not.toContain(".sock");
      expect(run.argv).toEqual(["--session", "cloud", "--quiet", "notification", "create", "--title", "T", "--body", "", "--terminal", TERMINAL_ID]);
    });
  });

  test("finds the daemon binary under the daemon's home when CMUX_TUI_BIN is unset", () => {
    // The root layout keeps the binary at /root/.cmux/bin; layout-aware bakes
    // symlink /usr/local/bin/cmux-tui. A dev Mac with either would shadow the
    // per-test fake, so only assert when neither exists on this host.
    const shadowed = ["/usr/local/bin/cmux-tui", "/root/.cmux/bin/cmux-tui"].some((path) => {
      try {
        return spawnSync("test", ["-x", path]).status === 0;
      } catch {
        return false;
      }
    });
    if (shadowed) return;
    const dir = mkdtempSync(join(tmpdir(), "cmux-guest-cli-home-"));
    const shim = join(dir, "cmux");
    writeFileSync(shim, GUEST_CMUX_SHIM);
    chmodSync(shim, 0o755);
    const binDir = join(dir, ".cmux", "bin");
    spawnSync("mkdir", ["-p", binDir]);
    const fakeTui = join(binDir, "cmux-tui");
    writeFileSync(fakeTui, '#!/bin/sh\nprintf \'home-fake\'; printf \' %s\' "$@"; echo\n');
    chmodSync(fakeTui, 0o755);
    const result = spawnSync("sh", [shim, "notify", "--title", "T"], {
      encoding: "utf8",
      env: { NODE_ENV: "test", PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: dir, CMUX_TUI_TERMINAL_ID: TERMINAL_ID },
    });
    expect(result.stderr).toBe("");
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("home-fake --session cloud --quiet notification create --title T --body  --terminal " + TERMINAL_ID);
  }, 20_000);

  test("install command is a safe atomic base64 write", () => {
    const command = guestCliInstallCommand();
    expect(command).toContain(`${GUEST_CMUX_SHIM_PATH}.tmp`);
    expect(command).toContain(`mv ${GUEST_CMUX_SHIM_PATH}.tmp ${GUEST_CMUX_SHIM_PATH}`);
    expect(command).toContain("chmod 0755");
    // The payload is base64: no shell metacharacters from the script body leak
    // into the exec command line.
    const encoded = command.match(/printf '%s' '([A-Za-z0-9+/=]+)'/);
    expect(encoded).not.toBeNull();
    expect(Buffer.from(encoded![1], "base64").toString("utf8")).toBe(GUEST_CMUX_SHIM);
  });
});
