import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "bun:test";
import { CMUX_TUI_BINARY_PATH, cmuxTuiInstallCommand } from "../services/vms/drivers/cmuxTuiDaemon";

test("the installed public client works without access to the daemon's private home", () => {
  const root = mkdtempSync(join(tmpdir(), "cmux-public-client-"));
  const privateHome = join(root, "private-home");
  const source = join(privateHome, ".cmux/bin/cmux-tui");
  const publicBin = join(root, "public-bin");
  const commandPath = join(publicBin, "cmux-tui");
  const shimBin = join(root, "shims");
  try {
    mkdirSync(join(privateHome, ".cmux/bin"), { recursive: true });
    chmodSync(privateHome, 0o700);
    mkdirSync(publicBin);
    mkdirSync(shimBin);
    const binary = "#!/bin/sh\nprintf 'cmux-fixture\\n'\n";
    writeFileSync(source, binary, { mode: 0o755 });
    if (spawnSync("sha256sum", ["--version"]).status !== 0) {
      writeFileSync(join(shimBin, "sha256sum"), "#!/bin/sh\nexec shasum -a 256 \"$@\"\n", { mode: 0o755 });
    }
    const sha256 = createHash("sha256").update(binary).digest("hex");
    // Execute the actual installer, remapping only its filesystem destinations.
    const command = cmuxTuiInstallCommand({ url: "https://example.invalid/must-not-download", sha256, commit: "fixture", builtAt: null })
      .replaceAll(CMUX_TUI_BINARY_PATH, source)
      .replaceAll("/root/.cmux/bin", join(privateHome, ".cmux/bin"))
      .replaceAll("/usr/local/bin/cmux-tui", commandPath);
    const installed = spawnSync("sh", ["-c", command], {
      env: { ...process.env, PATH: `${shimBin}:${process.env.PATH}` }, encoding: "utf8",
    });
    expect({ status: installed.status, stderr: installed.stderr }).toEqual({ status: 0, stderr: "" });
    expect(statSync(privateHome).mode & 0o777).toBe(0o700);
    expect(readFileSync(commandPath, "utf8")).toBe(binary);
    // Removing traversal simulates the normal work user's view of /root (0700).
    chmodSync(privateHome, 0o000);
    const launched = spawnSync(commandPath, ["--version"], { encoding: "utf8" });
    expect(launched.status).toBe(0);
    expect(launched.stdout).toBe("cmux-fixture\n");
  } finally {
    chmodSync(privateHome, 0o700);
    rmSync(root, { recursive: true, force: true });
  }
});
