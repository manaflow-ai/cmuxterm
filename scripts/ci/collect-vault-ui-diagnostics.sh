#!/usr/bin/env bash
# Diagnostic branch only: collect outside the UI test runner's sandbox.
set -u
diagnostic_dir=$1
mkdir -p "$diagnostic_dir"
touch "$diagnostic_dir/started"
echo VAULT_HISTORY_SHELL_COLLECTOR_STARTED
date -u
for ((attempt=0; attempt<2400; attempt++)); do
  app_pid=$(tail -n 400 /tmp/xcodebuild-e2e.log 2>/dev/null \
    | sed -nE 's/.*VAULT_HISTORY_PROCESS_ID=([0-9]+).*/\1/p' | head -1)
  if [[ -n "$app_pid" ]]; then
    case "$app_pid" in ''|*[!0-9]*) echo 'Invalid sample PID'; exit 2;; esac
    state=''
    for candidate in /private/tmp/cmux-ui-test-vault-interaction-*.json.diagnostics; do
      [[ -f "$candidate" ]] || continue
      if [[ "$(jq -r '.pid' "$candidate" 2>/dev/null)" == "$app_pid" ]]; then
        state=${candidate%.diagnostics}
        break
      fi
    done
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
  if (( attempt % 60 == 0 )); then
    printf 'VAULT_HISTORY_WAITING_FOR_LOG_PID elapsed_seconds=%s\n' "$attempt"
  fi
  sleep 1
done
echo VAULT_HISTORY_SHELL_CAPTURE_NO_REQUEST
exit 1
