import { spawnSync } from "node:child_process";
import { chmodSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";
import type { Freestyle } from "freestyle";
import { FreestyleProvider } from "../services/vms/drivers/freestyle";
import { CMUX_TUI_BINARY_PATH, shellQuote } from "../services/vms/drivers/cmuxTuiDaemon";

for (const publicationFails of [false, true]) {
  test(`attaching to a healthy baked daemon enforces public client publication (failure: ${publicationFails})`, async () => {
    const root = mkdtempSync(join(tmpdir(), "cmux-freestyle-attach-"));
    const privateHome = join(root, "private");
    const binary = join(privateHome, "cmux-tui");
    const publicPath = join(root, "cmux-tui");
    const shims = join(root, "shims");
    const calls = join(root, "calls");
    try {
      mkdirSync(privateHome, { mode: 0o700 });
      mkdirSync(shims);
      writeFileSync(join(root, "bake-instance-id"), "baked\n");
      writeFileSync(join(root, "daemon-instance-id"), "vm-instance\n");
      writeFileSync(join(root, "tcp6"), "00000000000000000000000000000000:0539 \n");
      for (const name of ["systemctl", "pgrep"]) {
        writeFileSync(join(shims, name), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
      }
      writeFileSync(join(shims, "curl"), "#!/bin/sh\nprintf 'vm-instance\\n'\n", { mode: 0o755 });
      if (publicationFails) {
        writeFileSync(join(shims, "cp"), "#!/bin/sh\necho publication-denied >&2\nexit 13\n", { mode: 0o755 });
      }
      writeFileSync(binary, [
        "#!/bin/sh",
        'printf "%s\\n" "$*" >> "$CMUX_TEST_CALLS"',
        'case "$*" in',
        `  'remote-probe --json') echo '{"build_identity":"abc123","remote_protocol":12,"version":"0.13.0"}' ;;`,
        `  'remote enroll devices --session cloud --json') echo '[{"fingerprint":"fp-1","revoked_at_unix":null}]' ;;`,
        "  '--version') echo cmux-fixture ;;",
        "  *) exit 64 ;;",
        "esac",
        "",
      ].join("\n"), { mode: 0o755 });
      symlinkSync(binary, publicPath);
      let execCount = 0;
      const vm = {
        exec: async ({ command }: { command: string }) => {
          execCount += 1;
          // Keep the provider's full shell program, substituting only guest paths.
          const paths = [
            [CMUX_TUI_BINARY_PATH, binary],
            ["/usr/local/bin/cmux-tui.tmp.XXXXXX", `${publicPath}.tmp.XXXXXX`],
            ["/usr/local/bin/cmux-tui", publicPath],
            ["/etc/cmux/bake-instance-id", join(root, "bake-instance-id")],
            ["/etc/cmux/daemon-instance-id", join(root, "daemon-instance-id")],
            ["/proc/net/tcp6", join(root, "tcp6")],
          ];
          const env = { ...process.env, PATH: `${shims}:${process.env.PATH}`, CMUX_TEST_CALLS: calls };
          for (const [index, [guest, local]] of paths.entries()) {
            const variable = `CMUX_TEST_PATH_${index}`;
            command = command.replaceAll(shellQuote(guest), `"$${variable}"`).replaceAll(guest, `"$${variable}"`);
            Object.assign(env, { [variable]: local });
          }
          const result = spawnSync("/bin/sh", ["-c", command], { env, encoding: "utf8", timeout: 5_000 });
          if (result.error) throw result.error;
          return { statusCode: result.status, stdout: result.stdout, stderr: result.stderr };
        },
      };
      const provider = new FreestyleProvider({
        client: () => ({ vms: { ref: () => vm } }) as unknown as Freestyle,
        resolveDaemonSource: async () => { throw new Error("a healthy daemon must keep its pinned binary"); },
      });
      const attach = provider.openCmuxRemote("vm-test", {
        deviceFingerprint: "fp-1",
        providerMetadata: { networkIpv4: "10.0.0.5" },
      });
      if (publicationFails) {
        await expect(attach).rejects.toThrow("openCmuxRemote(vm-test) failed");
        expect(execCount).toBe(3);
        expect(lstatSync(publicPath).isSymbolicLink()).toBe(true);
      } else {
        expect((await attach).route).toBe("ws://10.0.0.5:1337/v1/link");
        expect(execCount).toBe(1);
        expect(lstatSync(publicPath).isSymbolicLink()).toBe(false);
        expect(readFileSync(calls, "utf8").trim().split("\n")).toEqual([
          "remote-probe --json",
          "remote enroll devices --session cloud --json",
        ]);
        chmodSync(privateHome, 0o000);
        const launched = spawnSync(publicPath, ["--version"], { env: { ...process.env, CMUX_TEST_CALLS: calls }, encoding: "utf8" });
        expect(launched.status).toBe(0);
        expect(launched.stdout).toBe("cmux-fixture\n");
      }
    } finally {
      chmodSync(privateHome, 0o700);
      rmSync(root, { recursive: true, force: true });
    }
  });
}
