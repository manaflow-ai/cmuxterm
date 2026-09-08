/**
 * The account and machine name every cmux Cloud machine promises, shared by
 * the image definition (services/vms/images/devbox), the bake and verify
 * scripts, the cmux-tui daemon contract, and the tests that pin all of them.
 *
 * ONE account owns everything a person touches on a machine: the terminals the
 * cmux-tui daemon opens, the desktop session, the provider's default exec and
 * SSH user, and whatever an agent writes. It is not root — coding agents
 * refuse to run as root (`claude --dangerously-skip-permissions` exits before
 * it starts) — and it holds passwordless sudo, so administering the machine is
 * one `sudo` away.
 *
 * It is the base image's uid-1000 account, renamed rather than added:
 * Freestyle's exec API resolves its default `linuxUser` to "the account
 * holding uid 1000", so a rename keeps the provider's own surfaces landing in
 * the same home as cmux's terminals instead of splitting the machine between
 * two near-identical accounts.
 */

/** The work user: uid 1000 on every cmux Cloud machine. */
export const DEVBOX_WORK_USER = "cmux";
export const DEVBOX_WORK_HOME = `/home/${DEVBOX_WORK_USER}`;
export const DEVBOX_WORK_UID = 1000;

/**
 * The machine's hostname, and so the `\h` in the shell prompt. Freestyle's
 * base image boots as `freestyle-vm`; the bake renames it before snapshotting
 * and the name travels with the memory image, so every cmux Cloud machine
 * says `cmux`.
 */
export const DEVBOX_HOSTNAME = "cmux";

/**
 * Renames the base image's uid-1000 account to the work user and sets the
 * machine name. Idempotent: a re-bake over an already-renamed machine skips
 * the rename and re-asserts the rest. Run as root, before any layer that
 * writes into the home or names the user — the NOPASSWD policy the base ships
 * names the OLD account, so it is replaced here rather than left dangling.
 */
export function devboxWorkUserSetupCommand(): string {
  const user = DEVBOX_WORK_USER;
  const home = DEVBOX_WORK_HOME;
  const host = DEVBOX_HOSTNAME;
  return `
set -e
if ! id -u ${user} >/dev/null 2>&1; then
  old="$(getent passwd ${DEVBOX_WORK_UID} | cut -d: -f1)"
  test -n "$old"
  pkill -KILL -u "$old" 2>/dev/null || true
  sleep 1
  usermod -l ${user} -d ${home} -m "$old"
  groupmod -n ${user} "$old"
fi
# The base's own NOPASSWD policy names the old account. Drop every sudoers
# drop-in that does not name the work user, then write ours.
for f in /etc/sudoers.d/*; do
  [ -f "$f" ] || continue
  grep -q '^${user}[[:space:]]' "$f" || rm -f "$f"
done
printf '${user} ALL=(ALL) NOPASSWD:ALL\\n' > /etc/sudoers.d/91-cmux-work-user
chmod 0440 /etc/sudoers.d/91-cmux-work-user
# The prompt renders \\h, so the machine name is user-visible. hostnamectl sets
# the live kernel name (what a resumed snapshot keeps) and /etc/hostname.
hostnamectl set-hostname ${host}
printf '${host}\\n' > /etc/hostname
sed -i 's/^\\(127\\.0\\.1\\.1[[:space:]]\\+\\).*$/\\1${host}/' /etc/hosts
grep -q '^127\\.0\\.1\\.1[[:space:]]' /etc/hosts || printf '127.0.1.1\\t${host}\\n' >> /etc/hosts
# Prove the contract rather than trusting the steps above.
[ "$(id -u ${user})" = ${DEVBOX_WORK_UID} ]
[ "$(getent passwd ${DEVBOX_WORK_UID} | cut -d: -f1)" = ${user} ]
[ "$(getent passwd ${user} | cut -d: -f6)" = ${home} ]
test -d ${home}
sudo -n -u ${user} sudo -n true
[ "$(hostname)" = ${host} ]
[ "$(cat /etc/hostname)" = ${host} ]
grep -q '^127\\.0\\.1\\.1[[:space:]]\\+${host}$' /etc/hosts
echo work-user-ok
`.trim();
}
