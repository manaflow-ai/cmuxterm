import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { devboxDir, devboxSshHostKeyRegenerateCommand } from "../scripts/devbox-image-common";

const keyNames = ["ssh_host_ed25519_key", "ssh_host_ed25519_key.pub", "ssh_host_rsa_key", "ssh_host_rsa_key.pub"];
const supervisor = readFileSync(path.join(devboxDir, "cmux-devbox-boot"), "utf8");
const supervisorFunctions = supervisor.slice(0, supervisor.indexOf("\nwhile true; do"));

function rekeyCommand(owner: "bake" | "supervisor"): string {
  return owner === "bake" ? devboxSshHostKeyRegenerateCommand() : `${supervisorFunctions}\nrekey_ssh_host`;
}

function runRekey(owner: "bake" | "supervisor", failure: string) {
  const root = mkdtempSync(path.join(tmpdir(), "cmux-rekey-test-"));
  const ssh = path.join(root, "etc/ssh");
  const systemd = path.join(root, "run/systemd/system");
  const bin = path.join(root, "bin");
  const realMv = spawnSync("which", ["mv"], { encoding: "utf8" }).stdout.trim();
  try {
    for (const dir of [ssh, systemd, bin]) mkdirSync(dir, { recursive: true });
    for (const name of keyNames) writeFileSync(path.join(ssh, name), `old ${name}\n`);
    const executable = (name: string, body: string) => writeFileSync(path.join(bin, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
    executable("ssh-keygen", `
      [ "$FAILURE" != generate ] || exit 1
      while [ "$#" -gt 0 ]; do
        if [ "$1" = -f ]; then shift; staging=$1; fi
        shift
      done
      for name in ssh_host_ed25519_key ssh_host_rsa_key; do
        printf 'new %s\\n' "$name" > "$staging/etc/ssh/$name"
        printf 'new %s.pub\\n' "$name" > "$staging/etc/ssh/$name.pub"
      done
    `);
    executable("sshd", "exit 0");
    executable("systemctl", `
      printf '%s\\n' "$*" >> "$TEST_ROOT/restarts"
      [ "$FAILURE" != restart ]
    `);
    executable("mv", `
      if [ "$FAILURE" = replace ]; then
        for arg do
          case "$arg" in */.cmux-rekey.*/etc/ssh/ssh_host_rsa_key) exit 1;; esac
        done
      fi
      exec '${realMv}' "$@"
    `);
    // Run the real shell logic against disposable filesystem paths and
    // fault-injected commands; no root access or host sshd changes are needed.
    const command = rekeyCommand(owner)
      .replace(/(\$staging"?)?\/etc\/ssh/g, (match, staging) => staging ? match : ssh)
      .replaceAll("/run/systemd/system", systemd);
    const result = spawnSync("sh", ["-c", command], {
      encoding: "utf8",
      timeout: 5000,
      env: { PATH: `${bin}:${process.env.PATH}`, FAILURE: failure, TEST_ROOT: root },
    });
    return {
      status: result.status,
      stderr: result.stderr,
      keys: keyNames.map((name) => readFileSync(path.join(ssh, name), "utf8")),
    };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

describe.each(["bake", "supervisor"] as const)("%s SSH host-key replacement", (owner) => {
  test("installs every generated key on success", () => {
    const result = runRekey(owner, "none");
    expect(result).toMatchObject({ status: 0, stderr: "" });
    expect(result.keys).toEqual(keyNames.map((name) => `new ${name}\n`));
  });

  test.each(["generate", "replace", "restart"])("reports %s failure and preserves the complete original key set", (failure) => {
    const result = runRekey(owner, failure);
    expect(result.status).not.toBe(0);
    expect(result.keys).toEqual(keyNames.map((name) => `old ${name}\n`));
  });
});
