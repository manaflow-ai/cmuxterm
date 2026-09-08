import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";

// Every shim run spawns dozens of processes (sh + jq per step); give the suites room.
setDefaultTimeout(60_000);
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { createServer } from "node:net";
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
  test.each(["existing", "create", "create-failed", "missing-id"])("peer exec selects a supported workspace and fails closed (%s)", async (mode) => {
    const directory = mkdtempSync(join(tmpdir(), "cmux-peer-exec-"));
    const socket = join(directory, "peer.sock");
    const server = createServer();
    try {
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(socket, resolve);
      });
      const peers = join(directory, ".cmux", "peers");
      const links = join(directory, ".cmux", "peer-links");
      mkdirSync(peers, { recursive: true });
      mkdirSync(links, { recursive: true });
      writeFileSync(join(peers, "peer.json"), "{}");
      writeFileSync(join(links, "peer.sock-path"), socket);
      writeFileSync(join(links, "peer.pid"), String(process.pid));
      const shim = join(directory, "cmux");
      const daemon = join(directory, "cmux-tui");
      writeFileSync(shim, GUEST_CMUX_SHIM);
      writeFileSync(daemon, `#!/bin/sh
printf '%s\\n' "$*" >> "$HOME/calls"
case "$*" in
  *"workspace current show") [ "$MODE" = existing ] ;;
  *"workspace create --name main")
    [ "$MODE" != create-failed ] || exit 74
    if [ "$MODE" = missing-id ]; then printf '{}'; else printf '{"value":{"workspace_id":"ws_created"}}'; fi ;;
  *"workspace current run "*|*"workspace ws_created run "*) printf '%s\\n' "$*" ;;
  *) exit 91 ;;
esac
`);
      chmodSync(daemon, 0o755);
      const result = spawnSync("sh", [shim, "vm", "exec", "peer", "--", "printf", "hello"], {
        encoding: "utf8",
        timeout: 10_000,
        env: { NODE_ENV: "test", PATH: process.env.PATH, HOME: directory, CMUX_TUI_BIN: daemon, MODE: mode },
      });
      const calls = readFileSync(join(directory, "calls"), "utf8");
      expect(calls).toContain("workspace current show");
      if (mode === "existing") {
        expect(result.status).toBe(0);
        expect(calls).not.toContain("workspace create");
        expect(result.stdout).toContain("workspace current run");
      } else if (mode === "create") {
        expect(result.status).toBe(0);
        expect(result.stdout).toContain("workspace ws_created run");
      } else {
        expect(result.status).toBe(3);
        expect(calls).not.toContain(" run ");
      }
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      rmSync(directory, { recursive: true, force: true });
    }
  });

  test("localizes help and interpolated errors using the guest locale", () => {
    const help = runShim(["--help"], { LANG: "ja_JP.UTF-8" });
    expect(help.status).toBe(0);
    expect(help.stdout).toContain("クラウド");
    const invalid = runShim(["auth", "status", "--invalid"], { LC_MESSAGES: "ja_JP.UTF-8" });
    expect(invalid.status).toBe(2);
    expect(invalid.stderr).toContain("不明なオプション");
    expect(invalid.stderr).toContain("--invalid");
  });

  test("LC_ALL overrides other locale settings and unknown locales use English", () => {
    const overridden = runShim(["--help"], { LC_ALL: "C", LC_MESSAGES: "ja_JP.UTF-8", LANG: "ja_JP.UTF-8" });
    expect(overridden.status).toBe(0);
    expect(overridden.stdout).toContain("Cloud workspace CLI");
    const fallback = runShim(["auth", "status", "--invalid"], { LANG: "fr_FR.UTF-8" });
    expect(fallback.stderr).toContain("unknown option --invalid");
  });

  test.each([true, false])("peer connection consumes readiness or process exit (ready=%s)", (ready) => {
    let fixtureDirectory = "";
    try {
      const result = runShim(["vm", "connect", "peer"], {}, (directory) => {
        fixtureDirectory = directory;
        const peerDirectory = join(directory, ".cmux", "peers");
        mkdirSync(peerDirectory, { recursive: true });
        writeFileSync(join(peerDirectory, "peer.json"), JSON.stringify({ route: "test-route", invite: "one-use-invite" }));
        const client = join(directory, "client.cjs");
        writeFileSync(client, ready ? `
          const net = require("node:net");
          const socket = require("node:path").join(process.env.HOME, "peer.sock");
          const server = net.createServer();
          server.listen(socket, () => {
            process.stdout.write(JSON.stringify({ event: "connecting" }) + "\\n");
            process.stdout.write(JSON.stringify({ event: "connection-snapshot", local_socket: socket }) + "\\n");
          });
        ` : 'process.stderr.write("connection refused\\n"); process.exit(7);');
        writeFileSync(join(directory, "cmux-tui"), `#!/bin/sh\nexec '${process.execPath}' '${client}'\n`);
      });
      expect(result.status).toBe(ready ? 0 : 3);
      if (ready) {
        expect(result.stdout).toContain("OK connected peer socket=");
        const peer = JSON.parse(readFileSync(join(fixtureDirectory, ".cmux", "peers", "peer.json"), "utf8"));
        expect(peer.invite).toBeUndefined();
      } else {
        expect(result.stderr).toContain("link to 'peer' exited");
      }
    } finally {
      for (const filename of ["peer.pid", "peer.events.pid"]) {
        try {
          const processID = Number(readFileSync(join(fixtureDirectory, ".cmux", "peer-links", filename), "utf8"));
          if (Number.isInteger(processID) && processID > 1) process.kill(processID, "SIGTERM");
        } catch {}
      }
      if (fixtureDirectory) rmSync(fixtureDirectory, { recursive: true, force: true });
    }
  });

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

// ---------------------------------------------------------------------------
// Agent primitives shared with the Mac CLI: layout export/apply, env, the
// Mac-flavoured terminal verbs, and their peer forms. A stateful fake
// cmux-tui logs every argv (one call per `--END--`-terminated block) and
// answers creation verbs with CreatedTerminalPath / CreatedBrowserPath results
// whose ids embed the call number, so the exact op sequence is assertable.
// ---------------------------------------------------------------------------

const STATEFUL_FAKE_TUI = `#!/bin/sh
{ printf '%s\\n' "$@"; printf '%s\\n' "--END--"; } >> "$FAKE_LOG"
n=$(cat "$FAKE_STATE" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" > "$FAKE_STATE"
while [ $# -gt 0 ]; do
  case "$1" in
    --session|--socket) shift 2 ;;
    --json|--quiet|--jsonl) shift ;;
    *) break ;;
  esac
done
a="\${1:-}"; b="\${2:-}"; c="\${3:-}"; d="\${4:-}"
if [ "$a" = session ] && [ "$c" = snapshot ]; then cat "$FAKE_SNAPSHOT"; exit 0; fi
if [ "$a" = workspace ] && [ "$b" = create ]; then
  case "$*" in
    *--empty*)
      if [ "\${FAKE_NO_EMPTY:-0}" = 1 ]; then printf '{"error":{"code":"usage.invalid","message":"unknown flag --empty"}}\\n'; exit 2; fi
      printf '{"value":{"kind":"workspace","workspace_id":"ws_new%s"},"generation":"g","revision":%s,"replayed":false}\\n' "$n" "$n" ;;
    *) printf '{"value":{"kind":"terminal","workspace_id":"ws_new%s","screen_id":"screen_%s","pane_id":"pane_%s","tab_id":"tab_%s","terminal_id":"term_%s"},"generation":"g","revision":%s,"replayed":false}\\n' "$n" "$n" "$n" "$n" "$n" "$n" ;;
  esac
  exit 0
fi
if [ "$a" = workspace ] && [ "$b" = current ] && [ "$c" = show ]; then [ "\${FAKE_NO_CURRENT:-0}" = 1 ] && exit 1; printf '{"id":"ws_cur"}\\n'; exit 0; fi
if [ "$a" = workspace ] && [ "$c" = run ]; then printf '{"value":{"kind":"terminal","workspace_id":"%s","screen_id":"screen_%s","pane_id":"pane_%s","tab_id":"tab_%s","terminal_id":"term_%s"},"generation":"g","revision":%s,"replayed":false}\\n' "$b" "$n" "$n" "$n" "$n" "$n"; exit 0; fi
if [ "$a" = pane ] && [ "$c" = split ]; then printf '{"value":{"kind":"terminal","workspace_id":"ws_x","screen_id":"screen_1","pane_id":"pane_%s","tab_id":"tab_%s","terminal_id":"term_%s"},"generation":"g","revision":%s,"replayed":false}\\n' "$n" "$n" "$n" "$n"; exit 0; fi
if [ "$a" = pane ] && [ "$c" = run ]; then printf '{"value":{"kind":"terminal","workspace_id":"ws_x","screen_id":"screen_1","pane_id":"%s","tab_id":"tab_%s","terminal_id":"term_%s"},"generation":"g","revision":%s,"replayed":false}\\n' "$b" "$n" "$n" "$n"; exit 0; fi
if [ "$a" = pane ] && [ "$c" = tab ] && [ "$d" = create ]; then
  if [ "\${FAKE_NO_BROWSER:-0}" = 1 ]; then printf '{"error":{"code":"browser.unavailable","message":"no browser runtime"}}\\n'; exit 1; fi
  printf '{"value":{"kind":"browser","workspace_id":"ws_x","screen_id":"screen_1","pane_id":"%s","tab_id":"tab_%s","browser_id":"browser_%s"},"generation":"g","revision":%s,"replayed":false}\\n' "$b" "$n" "$n" "$n"; exit 0
fi
if [ "$a" = terminal ] && [ "$c" = screen ] && [ "$d" = wait ]; then
  case "$*" in
    *CMUX-ENV-\\(OK*) printf '{"matched":true,"text":"CMUX-ENV-READY\\\\nCMUX-ENV-OK keys=2 path=/root/.config/cmux/env\\\\n"}\\n'; exit 0 ;;
    *CMUX-ENV-READY*) printf '{"matched":%s,"text":"CMUX-ENV-READY\\\\n"}\\n' "\${FAKE_MATCHED:-true}"; exit 0 ;;
  esac
  printf '{"matched":%s,"text":"λ "}\\n' "\${FAKE_MATCHED:-true}"; exit 0
fi
if [ "$a" = terminal ] && [ "$c" = screen ] && [ "$d" = read ]; then printf '{"cols":80,"rows":24,"text":"hello screen"}\\n'; exit 0; fi
printf '{}\\n'
`;

/** A daemon snapshot: ws_main is a 0.6 horizontal split whose right half is a 0.3 vertical split over a 2-pane stack. */
const SNAPSHOT_FIXTURE = {
  workspaces: [
    { id: "ws_main", name: "main", index: 0, focused: true },
    { id: "ws_api", name: "api", index: 1, focused: false },
    { id: "ws_empty", name: "empty", index: 2, focused: false },
    { id: "ws_dup1", name: "dup", index: 3, focused: false },
    { id: "ws_dup2", name: "dup", index: 4, focused: false },
  ],
  screens: [
    {
      id: "screen_1",
      workspace_id: "ws_main",
      name: null,
      index: 0,
      focused: true,
      layout: {
        version: 1,
        screen_id: "screen_1",
        active_pane_id: "pane_1",
        zoomed_pane_id: null,
        root: {
          kind: "split",
          split_id: "split_1",
          direction: "horizontal",
          ratio: 0.6,
          first: { kind: "leaf", pane_id: "pane_1", tab_ids: ["tab_1", "tab_2"], active_tab_id: "tab_1" },
          second: {
            kind: "split",
            split_id: "split_2",
            direction: "vertical",
            ratio: 0.3,
            first: { kind: "leaf", pane_id: "pane_2", tab_ids: ["tab_3"] },
            second: { kind: "stack", pane_ids: ["pane_3", "pane_4"], expanded_pane_id: "pane_3" },
          },
        },
      },
    },
    {
      id: "screen_2",
      workspace_id: "ws_api",
      name: null,
      index: 0,
      focused: true,
      layout: { version: 1, screen_id: "screen_2", active_pane_id: "pane_5", zoomed_pane_id: null, root: { kind: "leaf", pane_id: "pane_5", tab_ids: ["tab_5"] } },
    },
  ],
  panes: [
    { id: "pane_1", screen_id: "screen_1", name: null, focused: true, zoomed: false },
    { id: "pane_2", screen_id: "screen_1", name: null, focused: false, zoomed: false },
    { id: "pane_3", screen_id: "screen_1", name: null, focused: false, zoomed: false },
    { id: "pane_4", screen_id: "screen_1", name: null, focused: false, zoomed: false },
    { id: "pane_5", screen_id: "screen_2", name: null, focused: true, zoomed: false },
  ],
  // tab_2 is listed before tab_1 on purpose: export must order tabs by index, not wire order.
  tabs: [
    { id: "tab_2", pane_id: "pane_1", name: null, index: 1, focused: false, content_kind: "browser", content_id: "browser_1" },
    { id: "tab_1", pane_id: "pane_1", name: "agent", index: 0, focused: true, content_kind: "terminal", content_id: "term_agent" },
    { id: "tab_3", pane_id: "pane_2", name: "tests", index: 0, focused: true, content_kind: "terminal", content_id: "term_tests" },
    { id: "tab_4a", pane_id: "pane_3", name: null, index: 0, focused: true, content_kind: "terminal", content_id: "term_logs" },
    { id: "tab_4b", pane_id: "pane_4", name: null, index: 0, focused: true, content_kind: "terminal", content_id: "term_shell" },
    { id: "tab_5", pane_id: "pane_5", name: null, index: 0, focused: true, content_kind: "terminal", content_id: "term_api" },
  ],
  terminals: [
    { id: "term_agent", tab_id: "tab_1", tab_ids: ["tab_1"], title: "claude", cwd: "/root/work/app", cols: 80, rows: 24, running: true, lifecycle: "running" },
    { id: "term_tests", tab_id: "tab_3", tab_ids: ["tab_3"], title: "bun", cwd: "/root/work/app", cols: 80, rows: 24, running: true, lifecycle: "running" },
    { id: "term_logs", tab_id: "tab_4a", tab_ids: ["tab_4a"], title: "tail", cwd: "/var/log", cols: 80, rows: 24, running: true, lifecycle: "running" },
    { id: "term_shell", tab_id: "tab_4b", tab_ids: ["tab_4b"], title: "bash", cols: 80, rows: 24, running: true, lifecycle: "running" },
    { id: "term_api", tab_id: "tab_5", tab_ids: ["tab_5"], title: "bash", cwd: "/root/work/api", cols: 80, rows: 24, running: true, lifecycle: "running" },
  ],
  browsers: [{ id: "browser_1", tab_id: "tab_2", url: "http://localhost:3000", title: "app", status: "ready" }],
  agents: [],
};

const LAYOUT_DOC = {
  name: "dev",
  cwd: "work/app",
  env: { NODE_ENV: "development" },
  layout: {
    direction: "horizontal",
    split: 0.6,
    children: [
      { pane: { surfaces: [{ type: "terminal", name: "agent", command: "claude" }, { type: "browser", url: "http://localhost:3000", name: "app" }] } },
      {
        direction: "vertical",
        split: 0.3,
        children: [
          { pane: { surfaces: [{ type: "terminal", name: "tests", command: "bun test --watch", env: { CI: "1" } }] } },
          { pane: { surfaces: [{ type: "terminal", cwd: "/var/log", focus: true }] } },
        ],
      },
    ],
  },
};

const PROMPT_WAIT = ["screen", "wait", "--pattern", "λ|\\$ $|# $", "--timeout-ms", "8000"];

type StatefulRun = { calls: string[][]; status: number | null; stdout: string; stderr: string; home: string };

function makeStatefulDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "cmux-guest-prims-"));
  writeFileSync(join(dir, "cmux"), GUEST_CMUX_SHIM);
  chmodSync(join(dir, "cmux"), 0o755);
  writeFileSync(join(dir, "cmux-tui"), STATEFUL_FAKE_TUI);
  chmodSync(join(dir, "cmux-tui"), 0o755);
  writeFileSync(join(dir, "snapshot.json"), JSON.stringify(SNAPSHOT_FIXTURE));
  return dir;
}

/** Runs the shim in `dir` (HOME) against the stateful fake and returns every daemon call. */
function runStateful(dir: string, args: string[], env: Record<string, string | undefined> = {}, input?: string, shell = "sh"): StatefulRun {
  const log = join(dir, "calls.log");
  writeFileSync(log, "");
  writeFileSync(join(dir, "state"), "");
  const result = spawnSync(shell, [join(dir, "cmux"), ...args], {
    encoding: "utf8",
    timeout: 20_000,
    input,
    env: {
      NODE_ENV: "test",
      HOME: dir,
      CMUX_TUI_BIN: join(dir, "cmux-tui"),
      FAKE_LOG: log,
      FAKE_STATE: join(dir, "state"),
      FAKE_SNAPSHOT: join(dir, "snapshot.json"),
      PATH: `${dir}:${process.env.PATH ?? "/usr/bin:/bin"}`,
      ...env,
    },
  });
  const calls: string[][] = [];
  let current: string[] = [];
  for (const line of readFileSync(log, "utf8").split("\n")) {
    if (line === "--END--") {
      calls.push(current);
      current = [];
    } else if (line !== "" || current.length > 0) {
      current.push(line);
    }
  }
  return { calls, status: result.status, stdout: result.stdout, stderr: result.stderr, home: dir };
}

/** Argv with the routing prefix (`--session cloud` / `--socket …`) removed. */
const stripRoute = (call: string[]) => call.slice(2);

describe("in-VM cmux shim: agent primitives", () => {
  test("is valid for dash too when it is installed (the image's /bin/sh is dash)", () => {
    if (!existsSync("/bin/dash")) return;
    const result = spawnSync("/bin/dash", ["-n"], { input: GUEST_CMUX_SHIM, encoding: "utf8" });
    expect(result.stderr).toBe("");
    expect(result.status).toBe(0);
  });

  test("help lists the layout, env, terminal, and peer verbs", () => {
    const run = runShim(["--help"]);
    expect(run.status).toBe(0);
    for (const line of [
      "cmux layout export [--workspace <ws>] [--raw]",
      "cmux layout apply [--workspace <ws>|--name <n>] [--cwd <dir>] [<file>|-]",
      "cmux env set|ls|rm|path",
      "cmux send [--terminal <id>] <text>",
      "cmux send-key [--terminal <id>] <key> [key...]",
      "cmux read-screen [--terminal <id>] [--json]",
      "cmux terminal send|read|wait|close <id>",
      "cmux vm terminal send|read|wait|close <peer> <term>",
      "cmux vm workspace new|rename|close|rm <peer>",
      "cmux vm agent <peer> --agent <claude|codex|opencode|pi>",
      "cmux vm layout export|apply <peer>",
      "cmux env set|ls|rm|path",
    ]) {
      expect(run.stdout).toContain(line);
    }
    const envHelp = runShim(["env", "help"]);
    for (const line of ["cmux env receive [--stdin]", "CMUX-ENV-READY / CMUX-ENV-OK / CMUX-ENV-ERR", "cmux env set -"]) {
      expect(envHelp.stdout).toContain(line);
    }
    for (const line of [
      "cmux env set|ls|rm|path",
    ]) {
      expect(run.stdout).toContain(line);
    }
    const vmHelp = runShim(["vm", "help"]);
    expect(vmHelp.stdout).toContain("cmux vm agent <machine> --agent");
    expect(vmHelp.stdout).toContain("cmux vm env set|ls|rm|path <machine>");
  });

  describe("local Mac-flavoured verbs", () => {
    test("send defaults to the caller's terminal, --terminal overrides, nothing else is an error", () => {
      const dir = makeStatefulDir();
      const mine = runStateful(dir, ["send", "hi", "there"], { CMUX_TUI_TERMINAL_ID: TERMINAL_ID });
      expect(mine.status).toBe(0);
      expect(mine.calls).toEqual([["--session", "cloud", "terminal", TERMINAL_ID, "write", "--text", "hi there"]]);

      const other = runStateful(dir, ["send", "--terminal", "term_other", "ls -la"], { CMUX_TUI_TERMINAL_ID: TERMINAL_ID });
      expect(other.calls).toEqual([["--session", "cloud", "terminal", "term_other", "write", "--text", "ls -la"]]);

      const none = runStateful(dir, ["send", "hi"], { CMUX_TUI_TERMINAL_ID: undefined });
      expect(none.status).toBe(2);
      expect(none.stderr).toContain("--terminal <term_id>");
      expect(none.calls).toEqual([]);
    });

    test("send-key and read-screen map to keys and screen read", () => {
      const dir = makeStatefulDir();
      const keys = runStateful(dir, ["send-key", "ctrl+c", "enter"], { CMUX_TUI_TERMINAL_ID: TERMINAL_ID });
      expect(keys.calls).toEqual([["--session", "cloud", "terminal", TERMINAL_ID, "keys", "ctrl+c", "enter"]]);
      const screen = runStateful(dir, ["read-screen", "--terminal", "term_2", "--json"]);
      expect(screen.status).toBe(0);
      expect(screen.calls).toEqual([["--session", "cloud", "--json", "terminal", "term_2", "screen", "read"]]);
      expect(JSON.parse(screen.stdout).text).toBe("hello screen");
    });

    test("terminal send types text first, then the comma-separated keys; `--` makes the rest literal", () => {
      const dir = makeStatefulDir();
      const run = runStateful(dir, ["terminal", "send", "term_1", "bun", "test", "--keys", "enter,ctrl+c", "--", "--json"]);
      expect(run.status).toBe(0);
      expect(run.calls.map(stripRoute)).toEqual([
        ["terminal", "term_1", "write", "--text", "bun test --json"],
        ["terminal", "term_1", "keys", "enter", "ctrl+c"],
      ]);
      const keysOnly = runStateful(dir, ["terminal", "send", "term_1", "--keys", "enter"]);
      expect(keysOnly.calls.map(stripRoute)).toEqual([["terminal", "term_1", "keys", "enter"]]);
      const nothing = runStateful(dir, ["terminal", "send", "term_1"]);
      expect(nothing.status).toBe(2);
      expect(nothing.calls).toEqual([]);
    });

    test("terminal read/wait/close; wait converts seconds to ms and exits 1 when the screen never matches", () => {
      const dir = makeStatefulDir();
      const read = runStateful(dir, ["terminal", "read", "term_9"]);
      expect(read.calls.map(stripRoute)).toEqual([["terminal", "term_9", "screen", "read"]]);
      const wait = runStateful(dir, ["terminal", "wait", "term_1", "--pattern", "pass|fail", "--timeout", "2.5"]);
      expect(wait.status).toBe(0);
      expect(wait.stdout).toContain("OK matched /pass|fail/ on term_1");
      expect(wait.calls).toEqual([["--session", "cloud", "--json", "terminal", "term_1", "screen", "wait", "--pattern", "pass|fail", "--timeout-ms", "2500"]]);
      const missed = runStateful(dir, ["terminal", "wait", "term_1", "--pattern", "pass"], { FAKE_MATCHED: "false" });
      expect(missed.status).toBe(1);
      expect(missed.stderr).toContain("timed out after 30s");
      expect(missed.calls[0]).toContain("30000");
      const noPattern = runStateful(dir, ["terminal", "wait", "term_1"]);
      expect(noPattern.status).toBe(2);
      const close = runStateful(dir, ["terminal", "close", "term_1"]);
      expect(close.calls.map(stripRoute)).toEqual([["terminal", "term_1", "close"]]);
    });

    test("cmux-tui's own id-first terminal grammar still passes through untouched", () => {
      const dir = makeStatefulDir();
      expect(runStateful(dir, ["terminal", "term_x", "keys", "enter"]).calls).toEqual([["--session", "cloud", "terminal", "term_x", "keys", "enter"]]);
      expect(runStateful(dir, ["terminal", "list"]).calls).toEqual([["--session", "cloud", "terminal", "list"]]);
    });

    test("new-workspace, tree, and new-split (from the caller's pane, else the focused pane; right/down only)", () => {
      const dir = makeStatefulDir();
      expect(runStateful(dir, ["new-workspace", "--name", "t"]).calls).toEqual([["--session", "cloud", "workspace", "create", "--name", "t"]]);
      expect(runStateful(dir, ["new-workspace"]).calls).toEqual([["--session", "cloud", "workspace", "create"]]);
      const tree = runStateful(dir, ["tree", "--json"]);
      expect(tree.calls).toEqual([["--session", "cloud", "--json", "session", "current", "snapshot"]]);
      expect(JSON.parse(tree.stdout).workspaces[0].id).toBe("ws_main");

      const fromCaller = runStateful(dir, ["new-split", "down"], { CMUX_TUI_TERMINAL_ID: "term_logs" });
      expect(fromCaller.status).toBe(0);
      expect(fromCaller.calls.map(stripRoute)).toEqual([["--json", "session", "current", "snapshot"], ["pane", "pane_3", "split", "--down"]]);
      const focused = runStateful(dir, ["new-split", "right"], { CMUX_TUI_TERMINAL_ID: undefined });
      expect(focused.status).toBe(0);
      expect(focused.calls.at(-1)).toEqual(["--session", "cloud", "pane", "pane_1", "split", "--right"]);
      const explicit = runStateful(dir, ["new-split", "right", "--pane", "pane_9"]);
      expect(explicit.calls).toEqual([["--session", "cloud", "pane", "pane_9", "split", "--right"]]);
      const left = runStateful(dir, ["new-split", "left"]);
      expect(left.status).toBe(2);
      expect(left.stderr).toContain("right or down");
    });
  });

  describe("layout export", () => {
    test("turns the focused workspace's LayoutDocument into the declarative document (tabs by index, stack → vertical splits)", () => {
      const dir = makeStatefulDir();
      const run = runStateful(dir, ["layout", "export"]);
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      expect(run.calls).toEqual([["--session", "cloud", "--json", "session", "current", "snapshot"]]);
      expect(JSON.parse(run.stdout)).toEqual({
        name: "main",
        cwd: dir,
        layout: {
          direction: "horizontal",
          split: 0.6,
          children: [
            { pane: { surfaces: [{ type: "terminal", name: "agent", cwd: "/root/work/app" }, { type: "browser", url: "http://localhost:3000" }] } },
            {
              direction: "vertical",
              split: 0.3,
              children: [
                { pane: { surfaces: [{ type: "terminal", name: "tests", cwd: "/root/work/app" }] } },
                {
                  direction: "vertical",
                  split: 0.5,
                  children: [{ pane: { surfaces: [{ type: "terminal", cwd: "/var/log" }] } }, { pane: { surfaces: [{ type: "terminal" }] } }],
                },
              ],
            },
          ],
        },
      });
    });

    test("selects by id or unique name, refuses ambiguous names, and --raw prints the daemon document", () => {
      const dir = makeStatefulDir();
      const api = runStateful(dir, ["layout", "export", "--workspace", "api"]);
      expect(api.status).toBe(0);
      expect(JSON.parse(api.stdout)).toEqual({ name: "api", cwd: dir, layout: { pane: { surfaces: [{ type: "terminal", cwd: "/root/work/api" }] } } });
      const byId = runStateful(dir, ["layout", "export", "--workspace", "ws_api"]);
      expect(JSON.parse(byId.stdout).name).toBe("api");
      const dup = runStateful(dir, ["layout", "export", "--workspace", "dup"]);
      expect(dup.status).toBe(2);
      expect(dup.stderr).toContain("ws_dup1 ws_dup2");
      const missing = runStateful(dir, ["layout", "export", "--workspace", "nope"]);
      expect(missing.status).toBe(2);
      expect(missing.stderr).toContain("no workspace 'nope'");
      const empty = runStateful(dir, ["layout", "export", "--workspace", "ws_empty"]);
      expect(empty.status).toBe(1);
      expect(empty.stderr).toContain("no layout yet");
      const raw = runStateful(dir, ["layout", "export", "--raw"]);
      expect(JSON.parse(raw.stdout).root.kind).toBe("split");
      expect(JSON.parse(raw.stdout).screen_id).toBe("screen_1");
    });
  });

  describe("layout apply", () => {
    test("builds a 3-pane document with the exact op sequence and reports every surface", () => {
      const dir = makeStatefulDir();
      writeFileSync(join(dir, "dev.json"), JSON.stringify(LAYOUT_DOC));
      const run = runStateful(dir, ["layout", "apply", "--json", join(dir, "dev.json")]);
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      const base = `${dir}/work/app`;
      expect(run.calls.map(stripRoute)).toEqual([
        ["--json", "workspace", "create", "--empty", "--name", "dev"],
        // slot 0: the root pane is the first leaf's first terminal itself (exact argv, no placeholder).
        ["--json", "workspace", "ws_new1", "run", "--on-exit", "keep", "--cwd", base, "--name", "agent", "--", "env", "NODE_ENV=development", "bash", "-l"],
        // split before either half is filled; the new pane starts in the second child's first cwd.
        ["--json", "pane", "pane_2", "split", "--right", "--ratio", "0.6", "--cwd", base],
        ["--json", "terminal", "term_2", ...PROMPT_WAIT],
        ["--json", "terminal", "term_2", "write", "--text", "claude"],
        ["--json", "terminal", "term_2", "keys", "enter"],
        ["--json", "pane", "pane_2", "tab", "create", "browser", "--url", "http://localhost:3000", "--name", "app"],
        ["--json", "pane", "pane_3", "split", "--down", "--ratio", "0.3", "--cwd", "/var/log"],
        // a split-created pane: real terminal first (workspace env + surface env), then its placeholder dies.
        ["--json", "pane", "pane_3", "run", "--on-exit", "keep", "--cwd", base, "--name", "tests", "--", "env", "NODE_ENV=development", "CI=1", "bash", "-l"],
        ["--json", "terminal", "term_3", "close"],
        ["--json", "terminal", "term_9", ...PROMPT_WAIT],
        ["--json", "terminal", "term_9", "write", "--text", "bun test --watch"],
        ["--json", "terminal", "term_9", "keys", "enter"],
        ["--json", "pane", "pane_8", "run", "--on-exit", "keep", "--cwd", "/var/log", "--", "env", "NODE_ENV=development", "bash", "-l"],
        ["--json", "terminal", "term_8", "close"],
        ["--json", "pane", "pane_8", "focus"],
      ]);
      expect(JSON.parse(run.stdout)).toEqual({
        workspace_id: "ws_new1",
        workspace_name: "dev",
        panes: [
          {
            pane_id: "pane_2",
            surfaces: [
              { type: "terminal", name: "agent", terminal_id: "term_2", tab_id: "tab_2" },
              { type: "browser", name: "app", browser_id: "browser_7", tab_id: "tab_7" },
            ],
          },
          { pane_id: "pane_3", surfaces: [{ type: "terminal", name: "tests", terminal_id: "term_9", tab_id: "tab_9" }] },
          { pane_id: "pane_8", surfaces: [{ type: "terminal", terminal_id: "term_14", tab_id: "tab_14" }] },
        ],
        warnings: [],
      });
      const human = runStateful(dir, ["layout", "apply", join(dir, "dev.json")]);
      expect(human.stdout.trim()).toBe("OK workspace=ws_new1 name=dev panes=3 surfaces=4");
    });

    test("--workspace builds inside an EMPTY existing workspace and refuses one that already has panes", () => {
      const dir = makeStatefulDir();
      writeFileSync(join(dir, "dev.json"), JSON.stringify(LAYOUT_DOC));
      const busy = runStateful(dir, ["layout", "apply", "--workspace", "ws_main", join(dir, "dev.json")]);
      expect(busy.status).toBe(1);
      expect(busy.stderr).toContain("ws_main already has a layout (4 panes)");
      expect(busy.calls.map(stripRoute)).toEqual([["--json", "session", "current", "snapshot"]]);
      const empty = runStateful(dir, ["layout", "apply", "--workspace", "empty", join(dir, "dev.json")]);
      expect(empty.status).toBe(0);
      expect(empty.stdout.trim()).toBe("OK workspace=ws_empty name=empty panes=3 surfaces=4");
      expect(empty.calls.map(stripRoute)[1].slice(0, 4)).toEqual(["--json", "workspace", "ws_empty", "run"]);
      expect(empty.calls.some((call) => stripRoute(call).slice(0, 3).join(" ") === "--json workspace create")).toBe(false);
      const both = runStateful(dir, ["layout", "apply", "--workspace", "x", "--name", "y", join(dir, "dev.json")]);
      expect(both.status).toBe(2);
      expect(both.calls).toEqual([]);
    });

    test("an older daemon without --empty: the starter terminal is the root placeholder and is replaced", () => {
      const dir = makeStatefulDir();
      const doc = { pane: { surfaces: [{ type: "terminal", name: "shell" }] } };
      const run = runStateful(dir, ["layout", "apply", "--json", "-"], { FAKE_NO_EMPTY: "1" }, JSON.stringify(doc));
      expect(run.status).toBe(0);
      expect(run.calls.map(stripRoute)).toEqual([
        ["--json", "workspace", "create", "--empty", "--name", "layout"],
        ["--json", "workspace", "create", "--name", "layout"],
        ["--json", "pane", "pane_2", "run", "--on-exit", "keep", "--cwd", dir, "--name", "shell", "--", "bash", "-l"],
        ["--json", "terminal", "term_2", "close"],
        ["--json", "pane", "pane_2", "focus"],
      ]);
      expect(JSON.parse(run.stdout).panes).toEqual([{ pane_id: "pane_2", surfaces: [{ type: "terminal", name: "shell", terminal_id: "term_3", tab_id: "tab_3" }] }]);
    });

    test("a browser surface the daemon cannot open becomes a warning and the pane keeps its shell", () => {
      const dir = makeStatefulDir();
      const doc = {
        direction: "vertical",
        children: [{ pane: { surfaces: [{ type: "terminal" }] } }, { pane: { surfaces: [{ type: "browser", url: "http://localhost:8080" }, { type: "project", cwd: "x" }] } }],
      };
      const run = runStateful(dir, ["layout", "apply", "--json", "--name", "web", "-"], { FAKE_NO_BROWSER: "1" }, JSON.stringify(doc));
      expect(run.status).toBe(0);
      const ops = run.calls.map(stripRoute);
      expect(ops).toContainEqual(["--json", "pane", "pane_3", "tab", "create", "browser", "--url", "http://localhost:8080"]);
      // The placeholder shell (term_3) stays: nothing closes it.
      expect(ops.some((call) => call[1] === "terminal" && call[3] === "close")).toBe(false);
      const summary = JSON.parse(run.stdout);
      expect(summary.workspace_name).toBe("web");
      expect(summary.panes).toEqual([{ pane_id: "pane_2", surfaces: [{ type: "terminal", terminal_id: "term_2", tab_id: "tab_2" }] }]);
      expect(summary.warnings.length).toBe(2);
      expect(summary.warnings[0]).toContain("http://localhost:8080");
      expect(summary.warnings[1]).toContain("Mac-only");
      expect(run.stderr).toContain("warning");
    });

    test("accepts a saved layout wrapper and a bare node; rejects malformed documents with the JSON path", () => {
      const dir = makeStatefulDir();
      const saved = { name: "dev", description: "x", workspace: { name: "from-saved", cwd: "~/src", layout: { pane: { surfaces: [{ type: "terminal", cwd: "app" }] } } } };
      const savedRun = runStateful(dir, ["layout", "apply", "-"], {}, JSON.stringify(saved));
      expect(savedRun.status).toBe(0);
      expect(savedRun.calls.map(stripRoute)[0]).toEqual(["--json", "workspace", "create", "--empty", "--name", "from-saved"]);
      expect(savedRun.calls.map(stripRoute)[1]).toEqual(["--json", "workspace", "ws_new1", "run", "--on-exit", "keep", "--cwd", `${dir}/src/app`, "--", "bash", "-l"]);

      const bare = runStateful(dir, ["layout", "apply", "-"], {}, JSON.stringify({ pane: { surfaces: [{ type: "terminal" }] } }));
      expect(bare.status).toBe(0);
      expect(bare.stdout).toContain("name=layout");

      const cases: Array<[unknown, string]> = [
        [{ direction: "horizontal", children: [{ pane: { surfaces: [] } }] }, "$.children: split needs exactly 2 children"],
        [{ pane: { surfaces: [{ type: "widget" }] } }, "$.pane.surfaces[0].type: must be terminal, browser, or project"],
        [{ layout: { direction: "diagonal", children: [{ pane: { surfaces: [{ type: "terminal" }] } }, { pane: { surfaces: [{ type: "terminal" }] } }] } }, "$.layout.direction: must be horizontal or vertical"],
        [{ direction: "vertical", children: [{ pane: { surfaces: [{ type: "terminal" }] } }, { pane: { surfaces: [{ type: "browser" }] } }] }, "$.children[1].pane.surfaces[0].url: browser surface needs url"],
        [{ workspace: { layout: { pane: { surfaces: [] } } } }, "$.workspace.layout.pane.surfaces: needs at least one surface"],
        [{ name: "nothing here" }, "$: no layout found"],
      ];
      for (const [doc, message] of cases) {
        const run = runStateful(dir, ["layout", "apply", "-"], {}, JSON.stringify(doc));
        expect(run.status).toBe(2);
        expect(run.stderr).toContain(message);
        expect(run.calls).toEqual([]);
      }
      const notJson = runStateful(dir, ["layout", "apply", "-"], {}, "not json");
      expect(notJson.status).toBe(2);
      expect(notJson.stderr).toContain("not valid JSON");
    });
  });

  describe("env", () => {
    test("set writes sorted, quoted exports with mode 0600 and installs the shell hook exactly once", () => {
      const dir = makeStatefulDir();
      const run = runStateful(dir, ["env", "set", "FOO=bar", "BAZ=it's here", "ZED=1"]);
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      expect(run.stdout).toContain("OK set 3 variables");
      const file = join(dir, ".config", "cmux", "env");
      expect(readFileSync(file, "utf8")).toBe(
        "# managed by cmux env; KEY='value' lines; edit with cmux env set/rm\nexport BAZ='it'\\''s here'\nexport FOO='bar'\nexport ZED='1'\n",
      );
      expect(statSync(file).mode & 0o777).toBe(0o600);
      const hook = '[ -f "$HOME/.config/cmux/env" ] && . "$HOME/.config/cmux/env" # cmux-env-hook';
      runStateful(dir, ["env", "set", "FOO=again"]);
      for (const rc of [".profile", ".bashrc"]) {
        const text = readFileSync(join(dir, rc), "utf8");
        expect(text.split(hook).length - 1).toBe(1);
      }
      expect(existsSync(join(dir, ".bash_profile"))).toBe(false);
      // The file is real shell: sourcing it yields the values, quotes and all.
      const sourced = spawnSync("sh", ["-c", `. "${file}"; printf '%s|%s|%s' "$FOO" "$BAZ" "$ZED"`], { encoding: "utf8" });
      expect(sourced.stdout).toBe("again|it's here|1");
    });

    test("--from-file and stdin understand dotenv comments, export prefixes, and quotes; later keys win", () => {
      const dir = makeStatefulDir();
      writeFileSync(join(dir, "dot.env"), "# comment\nexport API_KEY=\"abc def\"\nDB_URL='postgres://x'\n\nPLAIN=1\r\nPLAIN=2\n");
      const fromFile = runStateful(dir, ["env", "set", "--from-file", join(dir, "dot.env")]);
      expect(fromFile.status).toBe(0);
      const fromStdin = runStateful(dir, ["env", "set", "-"], {}, "X=1\nexport  Y = spaced\n");
      expect(fromStdin.status).toBe(0);
      const shown = runStateful(dir, ["env", "ls", "--show"]);
      expect(shown.stdout).toBe("API_KEY=abc def\nDB_URL=postgres://x\nPLAIN=2\nX=1\nY=spaced\n");
      const names = runStateful(dir, ["env", "ls"]);
      expect(names.stdout).toBe("API_KEY\nDB_URL\nPLAIN\nX\nY\n");
      const json = runStateful(dir, ["env", "ls", "--json", "--show"]);
      expect(JSON.parse(json.stdout)).toEqual({
        path: join(dir, ".config", "cmux", "env"),
        keys: ["API_KEY", "DB_URL", "PLAIN", "X", "Y"],
        values: { API_KEY: "abc def", DB_URL: "postgres://x", PLAIN: "2", X: "1", Y: "spaced" },
      });
      expect(JSON.parse(runStateful(dir, ["env", "ls", "--json"]).stdout)).toEqual({ path: join(dir, ".config", "cmux", "env"), keys: ["API_KEY", "DB_URL", "PLAIN", "X", "Y"] });
    });

    test("rm removes only the named keys; invalid keys and empty sets are usage errors; path prints the file", () => {
      const dir = makeStatefulDir();
      runStateful(dir, ["env", "set", "A=1", "B=2", "C=3"]);
      const rm = runStateful(dir, ["env", "rm", "A", "C"]);
      expect(rm.status).toBe(0);
      expect(runStateful(dir, ["env", "ls"]).stdout).toBe("B\n");
      expect(runStateful(dir, ["env", "set", "1BAD=x"]).status).toBe(2);
      expect(runStateful(dir, ["env", "set", "BAD-KEY=x"]).status).toBe(2);
      expect(runStateful(dir, ["env", "set", "novalue"]).status).toBe(2);
      expect(runStateful(dir, ["env", "set"]).status).toBe(2);
      expect(runStateful(dir, ["env", "rm"]).status).toBe(2);
      expect(runStateful(dir, ["env", "path"]).stdout.trim()).toBe(join(dir, ".config", "cmux", "env"));
      const fresh = makeStatefulDir();
      expect(runStateful(fresh, ["env", "ls"]).stdout).toContain("no machine env yet");
      expect(JSON.parse(runStateful(fresh, ["env", "ls", "--json"]).stdout)).toEqual({ path: join(fresh, ".config", "cmux", "env"), keys: [] });
    });

    test("env receive --stdin: READY first, then OK with the key count; values are byte-literal", () => {
      const dir = makeStatefulDir();
      const payload = "FOO=bar\nBAZ=it's  here \nURL=postgres://u:p%40ss@h/db?x=1\n";
      const b64 = Buffer.from(payload, "utf8").toString("base64").replace(/(.{20})/g, "$1\n");
      const run = runStateful(dir, ["env", "receive", "--stdin"], {}, `${b64}\n\nCMUX-ENV-END\n`);
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      const file = join(dir, ".config", "cmux", "env");
      expect(run.stdout).toBe(`CMUX-ENV-READY\nCMUX-ENV-OK keys=3 path=${file}\n`);
      expect(readFileSync(file, "utf8")).toBe(
        "# managed by cmux env; KEY='value' lines; edit with cmux env set/rm\nexport BAZ='it'\\''s  here '\nexport FOO='bar'\nexport URL='postgres://u:p%40ss@h/db?x=1'\n",
      );
      expect(statSync(file).mode & 0o777).toBe(0o600);
      expect(readFileSync(join(dir, ".profile"), "utf8")).toContain("cmux-env-hook");
      expect(run.calls).toEqual([]);
    });

    test("env receive refuses bad keys, truncated streams, and garbage without writing anything", () => {
      const dir = makeStatefulDir();
      const badKey = runStateful(dir, ["env", "receive", "--stdin"], {}, `${Buffer.from("OK=1\n1BAD=x\n").toString("base64")}\nCMUX-ENV-END\n`);
      expect(badKey.status).toBe(1);
      expect(badKey.stdout).toBe("CMUX-ENV-READY\nCMUX-ENV-ERR invalid-key 1BAD\n");
      expect(existsSync(join(dir, ".config", "cmux", "env"))).toBe(false);
      const noEnd = runStateful(dir, ["env", "receive", "--stdin"], {}, `${Buffer.from("A=1\n").toString("base64")}\n`);
      expect(noEnd.status).toBe(1);
      expect(noEnd.stdout).toBe("CMUX-ENV-READY\nCMUX-ENV-ERR eof\n");
      const garbage = runStateful(dir, ["env", "receive", "--stdin"], {}, "!!!not base64!!!\nCMUX-ENV-END\n");
      expect(garbage.status).toBe(1);
      expect(garbage.stdout).toContain("CMUX-ENV-ERR bad-base64");
      const empty = runStateful(dir, ["env", "receive", "--stdin"], {}, "CMUX-ENV-END\n");
      expect(empty.status).toBe(1);
      expect(empty.stdout).toContain("CMUX-ENV-ERR empty");
      expect(existsSync(join(dir, ".config", "cmux", "env"))).toBe(false);
    });

    test("agents started through the shim see the machine env", () => {
      const dir = makeStatefulDir();
      runStateful(dir, ["env", "set", "CMUX_TEST_TOKEN=from-env"]);
      const claude = join(dir, "claude");
      writeFileSync(claude, "#!/bin/sh\nprintf '%s\\n' \"$CMUX_TEST_TOKEN\"\n");
      chmodSync(claude, 0o755);
      const run = runStateful(dir, ["agent", "claude", "say hi"]);
      expect(run.status).toBe(0);
      expect(run.stdout.trim()).toBe("from-env");
    });
  });

  describe("peer forms", () => {
    // A live link: the shim reuses ~/.cmux/peer-links/<peer>.{pid,sock-path}
    // when the pid is alive and the socket exists, so the peer verbs can be
    // exercised without a cmux-remote daemon.
    let server: ReturnType<typeof createServer> | undefined;
    let sockPath = "";
    const peer = "brave-otter";

    function peerDir(): string {
      const dir = makeStatefulDir();
      mkdirSync(join(dir, ".cmux", "peers"), { recursive: true });
      mkdirSync(join(dir, ".cmux", "peer-links"), { recursive: true });
      writeFileSync(join(dir, ".cmux", "peers", `${peer}.json`), JSON.stringify({ route: "cmux-remote://example" }));
      writeFileSync(join(dir, ".cmux", "peer-links", `${peer}.pid`), String(process.pid));
      writeFileSync(join(dir, ".cmux", "peer-links", `${peer}.sock-path`), sockPath);
      return dir;
    }

    beforeAll(async () => {
      sockPath = `/tmp/cmux-gs-${process.pid}-${Math.random().toString(36).slice(2, 8)}.sock`;
      server = createServer();
      await new Promise<void>((resolve, reject) => {
        server!.once("error", reject);
        server!.listen(sockPath, resolve);
      });
    });
    afterAll(async () => {
      if (server) await new Promise<void>((resolve) => server!.close(() => resolve()));
      try {
        unlinkSync(sockPath);
      } catch {
        // already gone
      }
    });

    test("terminal verbs ride the peer's link socket with the same flags as locally", () => {
      const dir = peerDir();
      const send = runStateful(dir, ["vm", "terminal", "send", peer, "term_x", "bun test", "--keys", "enter"]);
      expect(send.stderr).toBe("");
      expect(send.status).toBe(0);
      expect(send.calls).toEqual([
        ["--socket", sockPath, "terminal", "term_x", "write", "--text", "bun test"],
        ["--socket", sockPath, "terminal", "term_x", "keys", "enter"],
      ]);
      expect(runStateful(dir, ["vm", "terminal", "read", peer, "term_x"]).calls).toEqual([["--socket", sockPath, "terminal", "term_x", "screen", "read"]]);
      expect(runStateful(dir, ["vm", "terminal", "wait", peer, "term_x", "--pattern", "ok", "--timeout", "1"]).calls).toEqual([
        ["--socket", sockPath, "--json", "terminal", "term_x", "screen", "wait", "--pattern", "ok", "--timeout-ms", "1000"],
      ]);
      expect(runStateful(dir, ["vm", "terminal", "close", peer, "term_x"]).calls).toEqual([["--socket", sockPath, "terminal", "term_x", "close"]]);
      expect(runStateful(dir, ["vm", "send", peer, "term_x", "hello", "world"]).calls).toEqual([["--socket", sockPath, "terminal", "term_x", "write", "--text", "hello world"]]);
      expect(runStateful(dir, ["vm", "send-key", peer, "term_x", "ctrl+c"]).calls).toEqual([["--socket", sockPath, "terminal", "term_x", "keys", "ctrl+c"]]);
      expect(runStateful(dir, ["vm", "read-screen", peer, "term_x", "--json"]).calls).toEqual([["--socket", sockPath, "--json", "terminal", "term_x", "screen", "read"]]);
      // cmux-tui's own grammar on the peer is untouched.
      expect(runStateful(dir, ["vm", "terminal", peer, "list"]).calls).toEqual([["--socket", sockPath, "terminal", "list"]]);
    });

    test("workspace new/rename/close/rm; rm kills every terminal viewed in the workspace first", () => {
      const dir = peerDir();
      expect(runStateful(dir, ["vm", "workspace", "new", peer, "--name", "tests"]).calls).toEqual([["--socket", sockPath, "workspace", "create", "--name", "tests"]]);
      expect(runStateful(dir, ["vm", "workspace", "rename", peer, "ws_a", "renamed"]).calls).toEqual([["--socket", sockPath, "workspace", "ws_a", "rename", "--name", "renamed"]]);
      expect(runStateful(dir, ["vm", "workspace", "close", peer, "ws_a"]).calls).toEqual([["--socket", sockPath, "workspace", "ws_a", "close"]]);
      const rm = runStateful(dir, ["vm", "workspace", "rm", peer, "ws_main"]);
      expect(rm.status).toBe(0);
      expect(rm.calls).toEqual([
        ["--socket", sockPath, "--json", "session", "current", "snapshot"],
        ["--socket", sockPath, "terminal", "term_agent", "close"],
        ["--socket", sockPath, "terminal", "term_logs", "close"],
        ["--socket", sockPath, "terminal", "term_shell", "close"],
        ["--socket", sockPath, "terminal", "term_tests", "close"],
        ["--socket", sockPath, "workspace", "ws_main", "close"],
      ]);
      expect(rm.stdout).toContain("4 terminals closed");
      // Passthrough for cmux-tui's own workspace grammar.
      expect(runStateful(dir, ["vm", "workspace", peer, "list"]).calls).toEqual([["--socket", sockPath, "workspace", "list"]]);
    });

    test("agent starts a durable terminal on the peer running the peer's own `cmux agent`", () => {
      const dir = peerDir();
      const run = runStateful(dir, ["vm", "agent", peer, "--agent", "claude", "--cwd", "/root/work/app", "--", "fix", "the tests"]);
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      expect(run.calls).toEqual([
        ["--socket", sockPath, "workspace", "current", "show"],
        ["--socket", sockPath, "--json", "workspace", "current", "run", "--on-exit", "keep", "--name", "claude", "--cwd", "/root/work/app", "--", "cmux", "agent", "claude", "fix", "the tests"],
      ]);
      expect(run.stdout).toContain(`OK terminal=term_2 workspace=current machine=${peer} agent=claude`);
      // No current workspace on the peer yet → `main` is created and used.
      const fresh = runStateful(dir, ["vm", "agent", peer, "codex", "--name", "docs", "--", "write docs"], { FAKE_NO_CURRENT: "1" });
      expect(fresh.status).toBe(0);
      expect(fresh.calls.map((call) => call.slice(2))).toEqual([
        ["workspace", "current", "show"],
        ["--json", "workspace", "create", "--name", "main"],
        ["--json", "workspace", "ws_new2", "run", "--on-exit", "keep", "--name", "docs", "--", "cmux", "agent", "codex", "write docs"],
      ]);
      expect(runStateful(dir, ["vm", "agent", peer, "--agent", "emacs", "--", "x"]).status).toBe(2);
      // `vm agent <peer> list` is still cmux-tui's agent scope on the peer.
      expect(runStateful(dir, ["vm", "agent", peer, "list"]).calls).toEqual([["--socket", sockPath, "agent", "list"]]);
    });

    test("vm env set delivers values only inside the typed base64 payload of the receive handshake", () => {
      const dir = peerDir();
      const secret = "s3cr3t value with spaces";
      const run = runStateful(dir, ["vm", "env", "set", peer, `TOKEN=${secret}`, "-"], {}, "OTHER=two\n");
      expect(run.stderr).toBe("");
      expect(run.status).toBe(0);
      const ops = run.calls.map((call) => call.slice(2));
      expect(ops[0]).toEqual(["workspace", "current", "show"]);
      expect(ops[1]).toEqual(["--json", "workspace", "current", "run", "--on-exit", "keep", "--name", "cmux env", "--", "cmux", "env", "receive"]);
      expect(ops[2]).toEqual(["--json", "terminal", "term_2", "screen", "wait", "--pattern", "CMUX-ENV-READY", "--timeout-ms", "15000"]);
      const writes = ops.filter((call) => call[1] === "terminal" && call[3] === "write");
      expect(writes.length).toBeGreaterThan(0);
      for (const write of writes) expect(write.slice(0, 5)).toEqual(["--json", "terminal", "term_2", "write", "--bytes-base64"]);
      const stream = Buffer.concat(writes.map((write) => Buffer.from(write[5], "base64"))).toString("utf8");
      const lines = stream.split("\n");
      expect(lines.at(-1)).toBe("");
      expect(lines.at(-2)).toBe("CMUX-ENV-END");
      const inner = lines.slice(0, -2).join("");
      expect(Buffer.from(inner, "base64").toString("utf8")).toBe(`TOKEN=${secret}\nOTHER=two\n`);
      expect(ops.at(-2)).toEqual(["--json", "terminal", "term_2", "screen", "wait", "--pattern", "CMUX-ENV-(OK|ERR)", "--timeout-ms", "30000"]);
      expect(ops.at(-1)).toEqual(["--json", "terminal", "term_2", "close"]);
      // The secret is nowhere in argv except inside the base64 payload.
      for (const call of run.calls) {
        for (const word of call) {
          if (call[3] === "write") continue;
          expect(word).not.toContain("s3cr3t");
        }
      }
      expect(run.stdout).toContain(`OK set 2 variables on ${peer}: TOKEN OTHER`);
      // A receiver that never says READY: the terminal is closed and the command fails.
      const notReady = runStateful(dir, ["vm", "env", "set", peer, "A=1"], { FAKE_MATCHED: "false" });
      expect(notReady.status).toBe(1);
      expect(notReady.stderr).toContain("never became ready");
      expect(notReady.calls.at(-1)?.slice(2)).toEqual(["--json", "terminal", "term_2", "close"]);
    });

    test("layout, env, exec, and tree on a peer use the same functions over the link socket", () => {
      const dir = peerDir();
      const exported = runStateful(dir, ["vm", "layout", "export", peer, "--workspace", "api"]);
      expect(exported.status).toBe(0);
      expect(exported.calls).toEqual([["--socket", sockPath, "--json", "session", "current", "snapshot"]]);
      expect(JSON.parse(exported.stdout).layout).toEqual({ pane: { surfaces: [{ type: "terminal", cwd: "/root/work/api" }] } });
      const applied = runStateful(dir, ["vm", "layout", "apply", peer, "--name", "remote", "-"], {}, JSON.stringify({ pane: { surfaces: [{ type: "terminal" }] } }));
      expect(applied.status).toBe(0);
      expect(applied.calls[0]).toEqual(["--socket", sockPath, "--json", "workspace", "create", "--empty", "--name", "remote"]);
      expect(runStateful(dir, ["vm", "env", "ls", peer, "--json"]).calls).toEqual([
        ["--socket", sockPath, "workspace", "current", "show"],
        ["--socket", sockPath, "workspace", "current", "run", "--on-exit", "close", "--", "cmux", "env", "ls", "--json"],
      ]);
      expect(runStateful(dir, ["vm", "env", "rm", peer, "K"]).calls.at(-1)).toEqual(["--socket", sockPath, "workspace", "current", "run", "--on-exit", "close", "--", "cmux", "env", "rm", "K"]);
      expect(runStateful(dir, ["vm", "exec", peer, "--", "echo", "hi there"]).calls.at(-1)).toEqual(["--socket", sockPath, "workspace", "current", "run", "--on-exit", "close", "--", "echo", "hi there"]);
      expect(runStateful(dir, ["vm", "tree", peer]).calls).toEqual([["--socket", sockPath, "--json", "session", "current", "snapshot"]]);
      const unlinked = runStateful(dir, ["vm", "terminal", "read", "unknown-peer", "term_x"]);
      expect(unlinked.status).toBe(2);
      expect(unlinked.stderr).toContain("no link for machine 'unknown-peer'");
      expect(unlinked.calls).toEqual([]);
    });
  });

  test("the whole apply flow also runs under dash (the image's sh)", () => {
    if (!existsSync("/bin/dash")) return;
    const dir = makeStatefulDir();
    const run = runStateful(dir, ["layout", "apply", "--json", "-"], {}, JSON.stringify(LAYOUT_DOC), "/bin/dash");
    expect(run.stderr).toBe("");
    expect(run.status).toBe(0);
    expect(JSON.parse(run.stdout).panes.map((pane: { pane_id: string }) => pane.pane_id)).toEqual(["pane_2", "pane_3", "pane_8"]);
    const env = runStateful(dir, ["env", "set", "A=x y"], {}, undefined, "/bin/dash");
    expect(env.status).toBe(0);
    expect(runStateful(dir, ["env", "ls", "--show"], {}, undefined, "/bin/dash").stdout).toBe("A=x y\n");
  });
});
