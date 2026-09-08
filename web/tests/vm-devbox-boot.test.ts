import { describe, expect, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { devboxDir } from "../scripts/devbox-image-common";

const boot = readFileSync(path.join(devboxDir, "cmux-devbox-boot"), "utf8");
const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function fixture(options: { clone?: boolean; coldBoot?: boolean; failRekey?: boolean; failRecovery?: boolean }) {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-boot-test-"));
  const config = path.join(root, "etc/cmux");
  const auth = path.join(root, "root/.local/state/cmux/remote/sessions/Y2xvdWQ/auth");
  const bin = path.join(root, "bin");
  const events = path.join(root, "events");
  for (const dir of [config, auth, bin, path.join(root, "root/.cmux/bin"), path.join(root, "usr/local/bin")]) {
    mkdirSync(dir, { recursive: true });
  }
  writeFileSync(path.join(config, "daemon-instance-id"), options.clone ? "builder\n" : "instance\n");
  writeFileSync(path.join(config, "bake-instance-id"), "builder\n");
  writeFileSync(path.join(config, "daemon-boot-id"), options.coldBoot ? "old-boot\n" : "current-boot\n");
  writeFileSync(path.join(root, "boot-id"), "current-boot\n");
  writeFileSync(path.join(auth, "identity.json"), "preserved daemon identity\n");
  writeFileSync(path.join(auth, "../runtime.json"), '{"lifecycle_id":"old-lifecycle"}\n');
  writeFileSync(events, "");
  const executable = (file: string, body: string) => writeFileSync(file, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  executable(path.join(bin, "curl"), 'case "$*" in *latest/api/token*) echo token;; *) echo instance;; esac');
  executable(path.join(root, "usr/local/bin/cmux-devbox-rekey"), `
    echo rekey >> "$TEST_ROOT/events"
    [ ! -e "$TEST_ROOT/fail-rekey" ]
  `);
  executable(path.join(root, "root/.cmux/bin/cmux-tui"), `
    case "$*" in
      *acknowledge-failed-finalization*)
        echo recover >> "$TEST_ROOT/events"
        [ ! -e "$TEST_ROOT/fail-recovery" ] || exit 1
        rm -f "$TEST_ROOT/root/.local/state/cmux/remote/sessions/Y2xvdWQ/runtime.json"
        ;;
      *"server start"*)
        echo start >> "$TEST_ROOT/events"
        exec /bin/sleep 30
        ;;
    esac
  `);
  if (options.failRekey) writeFileSync(path.join(root, "fail-rekey"), "");
  if (options.failRecovery) writeFileSync(path.join(root, "fail-recovery"), "");
  const redirected = boot
    .replaceAll("/root", `${root}/root`)
    .replaceAll("/etc/cmux", config)
    .replaceAll("/usr/local/bin", `${root}/usr/local/bin`)
    .replaceAll("/proc/sys/kernel/random/boot_id", `${root}/boot-id`);
  let child: ChildProcess | undefined;
  return {
    root,
    config,
    auth,
    events: () => readFileSync(events, "utf8").trim().split("\n").filter(Boolean),
    start: () => {
      child = spawn("sh", ["-c", redirected], {
        detached: true,
        stdio: "ignore",
        env: { NODE_ENV: "test", PATH: `${bin}:${process.env.PATH}`, TEST_ROOT: root },
      });
    },
    close: async () => {
      if (child?.pid) {
        try { process.kill(-child.pid, "SIGKILL"); } catch { /* The owned process already exited. */ }
        await new Promise<void>((resolve) => {
          if (child?.exitCode !== null || child?.signalCode !== null) resolve();
          else child.once("exit", () => resolve());
        });
      }
      rmSync(root, { recursive: true, force: true });
    },
  };
}

async function waitUntil(predicate: () => boolean) {
  const deadline = Date.now() + 4000;
  while (!predicate() && Date.now() < deadline) await delay(20);
  expect(predicate()).toBe(true);
}

describe("devbox supervisor identity lifecycle", () => {
  test("a clone retries failed rekeying before binding its id or starting the daemon", async () => {
    const f = fixture({ clone: true, failRekey: true });
    try {
      f.start();
      await waitUntil(() => f.events().filter((event) => event === "rekey").length >= 2);
      expect(f.events()).not.toContain("start");
      expect(readFileSync(path.join(f.config, "daemon-instance-id"), "utf8")).toBe("builder\n");
      rmSync(path.join(f.root, "fail-rekey"));
      await waitUntil(() => f.events().includes("start"));
      expect(readFileSync(path.join(f.config, "daemon-instance-id"), "utf8")).toBe("instance\n");
    } finally { await f.close(); }
  });

  test("same-instance supervisor restart keeps keys and daemon identity", async () => {
    const f = fixture({});
    try {
      f.start();
      await waitUntil(() => f.events().includes("start"));
      expect(f.events()).toEqual(["start"]);
      expect(readFileSync(path.join(f.auth, "identity.json"), "utf8")).toBe("preserved daemon identity\n");
    } finally { await f.close(); }
  });

  test("a cold boot finalizes the previous daemon before starting, without rekeying", async () => {
    const f = fixture({ coldBoot: true });
    try {
      f.start();
      await waitUntil(() => f.events().includes("start"));
      expect(f.events()).toEqual(["recover", "start"]);
      expect(readFileSync(path.join(f.config, "daemon-boot-id"), "utf8")).toBe("current-boot\n");
      expect(readFileSync(path.join(f.auth, "identity.json"), "utf8")).toBe("preserved daemon identity\n");
    } finally { await f.close(); }
  });

  test("failed cold-boot recovery preserves the prior boot marker and retries", async () => {
    const f = fixture({ coldBoot: true, failRecovery: true });
    try {
      f.start();
      await waitUntil(() => f.events().filter((event) => event === "recover").length >= 2);
      expect(f.events()).not.toContain("start");
      expect(readFileSync(path.join(f.config, "daemon-boot-id"), "utf8")).toBe("old-boot\n");
      expect(existsSync(path.join(f.auth, "../runtime.json"))).toBe(true);
      rmSync(path.join(f.root, "fail-recovery"));
      await waitUntil(() => f.events().includes("start"));
    } finally { await f.close(); }
  });
});
