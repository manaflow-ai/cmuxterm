#!/usr/bin/env bash
# Diagnostic branch only: collect outside the UI test runner's sandbox.
set -u
diagnostic_dir=$1
mkdir -p "$diagnostic_dir"
touch "$diagnostic_dir/started"
for ((attempt=0; attempt<2400; attempt++)); do
  request=$(find /private/tmp -maxdepth 1 -type f \
    -name 'cmux-ui-test-vault-interaction-*.json.sample-request' \
    -newer "$diagnostic_dir/started" -print -quit)
  if [[ -n "$request" ]]; then
    read -r app_pid < "$request" || true
    case "$app_pid" in ''|*[!0-9]*) echo 'Invalid sample PID'; exit 2;; esac
    state=${request%.sample-request}
    printf 'VAULT_HISTORY_SHELL_PID=%s\n' "$app_pid"
    date -u
    ps -p "$app_pid" -o pid=,ppid=,state=,%cpu=,comm= || true
    stat -f 'MAIN_RECORDER_MODIFIED=%m' "$state" || true
    sudo -n /usr/bin/sample "$app_pid" 10 -file "$diagnostic_dir/sample.txt" || true
    for ((observation=0; observation<4; observation++)); do
      date -u
      ps -p "$app_pid" -o pid=,ppid=,state=,%cpu=,comm= || true
      stat -f 'MAIN_RECORDER_MODIFIED=%m' "$state" || true
      sleep 5
    done
    cp "$state" "$diagnostic_dir/main-recorder.json" 2>/dev/null || true
    cp "$state.diagnostics" "$diagnostic_dir/app-diagnostics.json" 2>/dev/null || true
    find /Users/runner/Library/Logs/DiagnosticReports -maxdepth 1 -type f \
      -name 'cmux DEV*.ips' -newer "$diagnostic_dir/started" \
      -exec cp {} "$diagnostic_dir/" \; 2>/dev/null || true
    echo VAULT_HISTORY_SHELL_CAPTURE_FINISHED
    exit 0
  fi
  sleep 1
done
echo VAULT_HISTORY_SHELL_CAPTURE_NO_REQUEST
exit 1
