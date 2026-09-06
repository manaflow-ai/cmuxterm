// The in-VM `cmux` CLI: a POSIX shim over the machine's own cmux-tui binary.
//
// Every cmux Cloud machine runs the cmux-tui daemon (session "cloud"). This
// adapter keeps the shared cmux command family while mapping local resource
// commands to cmux-tui and cloud/agent commands to the machine's TLS edge.
// `cmux vm …` talks to OTHER machines through cmux-remote links the Mac
// granted with `cmux vm link <src> <dst>` (peer route files in ~/.cmux/peers).
// The adapter is provider-agnostic: it needs only the daemon binary, route
// files, and the standard CodeRouter environment; no provider SDK or Stack
// credential is copied into the guest.
//
// Installed by the driver at create/heal (see freestyle.ts bootstrap), so it
// reaches machines created from any existing snapshot.

export const GUEST_CMUX_SHIM_PATH = "/usr/local/bin/cmux";

export const GUEST_CMUX_SHIM = `#!/bin/sh
# cmux — in-VM CLI over this machine's cmux-tui daemon and linked peer machines.
# Local verbs forward to cmux-tui (session "cloud"). \`cmux vm …\` talks to peers
# this machine was linked to from the Mac (\`cmux vm link <src> <dst>\`).
set -eu

# The daemon binary lives under the daemon's home, which depends on the image
# layout (root daemon: /root; layout-aware bakes: the cmux user's home or the
# persistent-volume backing path, with /usr/local/bin/cmux-tui symlinked to it).
# Try the stable symlink first, then every known home.
cmux_tui_default() {
  for candidate in /usr/local/bin/cmux-tui /root/.cmux/bin/cmux-tui "\${HOME:-/root}/.cmux/bin/cmux-tui" \\
    /home/cmux/.cmux/bin/cmux-tui /cmux/home/.cmux/bin/cmux-tui; do
    if [ -x "\$candidate" ]; then printf '%s' "\$candidate"; return 0; fi
  done
  command -v cmux-tui 2>/dev/null || printf '%s' /root/.cmux/bin/cmux-tui
}
CMUX_TUI_BIN="\${CMUX_TUI_BIN:-\$(cmux_tui_default)}"
CMUX_GUEST_HOME="\${CMUX_GUEST_HOME:-\${HOME:-/root}/.cmux}"
PEERS_DIR="\$CMUX_GUEST_HOME/peers"
LINKS_DIR="\$CMUX_GUEST_HOME/peer-links"
LOCAL_SESSION="\${CMUX_TUI_SESSION:-cloud}"
# Session names are user input when the shim is reused outside the baked image.
# Keep them in the JSON/status output safe and deterministic.
case "\$LOCAL_SESSION" in
  ''|*[!A-Za-z0-9._-]*) LOCAL_SESSION=cloud ;;
esac

die() { printf '%s\\n' "cmux: \$1" >&2; exit "\${2:-1}"; }

[ -x "\$CMUX_TUI_BIN" ] || die "cmux-tui daemon binary not found at \$CMUX_TUI_BIN"

guest_usage() {
  cat <<'EOF'
cmux - Cloud workspace CLI

USAGE
  cmux <scope> <action> [options]

LOCAL WORKSPACE COMMANDS (this VM)
  cmux workspace list|create|<id> <action>
  cmux terminal list|<id> <action>
  cmux pane list|<id> <action>
  cmux session current snapshot|events
  cmux notification list|create

CLOUD AND AGENT COMMANDS
  cmux vm ls|connect|exec|tree <peer> ...
  cmux coderouter status|usage|models
  cmux coderouter agent <claude|codex|opencode|pi> [args...]
  cmux agent <claude|codex|opencode|pi> [args...]
  cmux agent list|report|hook ...    Local cmux-tui agent state/hooks
  cmux notify --title <text> [--subtitle <text>] [--body <text>]

AUTHENTICATION
  cmux auth status [--json]       Check this daemon and the injected CodeRouter edge
  cmux auth login|logout          Account sign-in is host-owned; run it on the Mac

This VM uses cmux-tui as its local transport. The Mac cmux CLI adds
Mac-window and account-management commands; no Stack token is copied into
this machine. CodeRouter requests use the Freestyle TLS edge, which injects
the short-lived machine credential on the wire.

Run cmux <scope> --help for the complete local resource grammar.
EOF
}

load_model_env() {
  if [ -f "\$HOME/.config/cmux/model-plane.env" ]; then
    . "\$HOME/.config/cmux/model-plane.env"
  elif [ -f /etc/cmux/model-plane.env ]; then
    . /etc/cmux/model-plane.env
  fi
  # A route token is an edge-held capability, never a guest credential. Refuse
  # a manually copied token instead of making it look like the supported path.
  for cmux_value in "\${OPENAI_API_KEY:-}" "\${ANTHROPIC_API_KEY:-}" "\${CMUX_CODEROUTER_URL:-}"; do
    case "\$cmux_value" in
      *crt_*) die "refusing a coderouter route token in the VM; use the Freestyle TLS edge" 2 ;;
    esac
  done
}

load_agent_config() {
  load_model_env
  if [ -f /etc/cmux/agent-config.sh ]; then
    . /etc/cmux/agent-config.sh
  fi
}

cmux_curl() {
  command -v curl >/dev/null 2>&1 || return 127
  if [ -f /usr/local/share/ca-certificates/freestyle-tls.crt ]; then
    curl --cacert /usr/local/share/ca-certificates/freestyle-tls.crt "\$@"
  else
    curl "\$@"
  fi
}

require_coderouter() {
  load_model_env
  cmux_coderouter_url="\${CMUX_CODEROUTER_URL:-}"
  [ -n "\$cmux_coderouter_url" ] || die "CodeRouter is not configured in this VM (CMUX_CODEROUTER_URL is missing)" 2
  case "\$cmux_coderouter_url" in
    https://*) ;;
    *) die "CodeRouter requires an https:// endpoint; refusing an insecure URL" 2 ;;
  esac
  case "\$cmux_coderouter_url" in
    *[!A-Za-z0-9:/._-]*)
      die "CodeRouter endpoint must be a bare https:// host" 2 ;;
  esac
  cmux_coderouter_key="\${OPENAI_API_KEY:-cmux-vm-edge-placeholder}"
}

guest_auth_status() {
  cmux_auth_json=0
  for cmux_arg in "\$@"; do
    case "\$cmux_arg" in
      --json) cmux_auth_json=1 ;;
      --help|-h) guest_usage; return 0 ;;
      *) die "auth status: unknown option \$cmux_arg" 2 ;;
    esac
  done
  load_model_env
  cmux_daemon_running=0
  if "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" server status >/dev/null 2>&1; then
    cmux_daemon_running=1
  fi
  cmux_model_configured=0
  cmux_tls_reachable=0
  cmux_route_auth=not_configured
  cmux_edge_status=000
  if [ -n "\${CMUX_CODEROUTER_URL:-}" ]; then
    cmux_model_configured=1
    case "\$CMUX_CODEROUTER_URL" in
      https://*)
        if cmux_edge_status="\$(cmux_curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 20 \
          -H "authorization: Bearer \${OPENAI_API_KEY:-cmux-vm-edge-placeholder}" \
          "\${CMUX_CODEROUTER_URL%/}/api/coderouter/vm-usage/self" 2>/dev/null)"; then :; else :; fi
        case "\$cmux_edge_status" in
          200) cmux_tls_reachable=1; cmux_route_auth=accepted ;;
          401|403) cmux_tls_reachable=1; cmux_route_auth=rejected ;;
          000|'') cmux_edge_status=000; cmux_route_auth=unreachable ;;
          *[!0-9]*) cmux_edge_status=000; cmux_route_auth=unreachable ;;
          *) cmux_tls_reachable=1; cmux_route_auth=unknown ;;
        esac
        ;;
      *) cmux_route_auth=insecure_url ;;
    esac
  fi
  cmux_authenticated=0
  cmux_daemon_authenticated=0
  if [ "\$cmux_daemon_running" -eq 1 ]; then
    cmux_daemon_authenticated=1
    [ "\$cmux_model_configured" -eq 1 ] && [ "\$cmux_route_auth" = accepted ] && cmux_authenticated=1
  fi
  cmux_daemon_bool=false
  cmux_daemon_auth_bool=false
  cmux_model_bool=false
  cmux_tls_bool=false
  cmux_authenticated_bool=false
  [ "\$cmux_daemon_running" -eq 1 ] && cmux_daemon_bool=true
  [ "\$cmux_daemon_authenticated" -eq 1 ] && cmux_daemon_auth_bool=true
  [ "\$cmux_model_configured" -eq 1 ] && cmux_model_bool=true
  [ "\$cmux_tls_reachable" -eq 1 ] && cmux_tls_bool=true
  [ "\$cmux_authenticated" -eq 1 ] && cmux_authenticated_bool=true
  if [ "\$cmux_auth_json" -eq 1 ]; then
    printf '{"authenticated":%s,"daemon":{"running":%s,"authenticated":%s,"session":"%s"},"tls":{"reachable":%s},"coderouter":{"configured":%s,"route_authenticated":"%s","http_status":"%s"},"control_plane":"host-only"}\\n' \
      "\$cmux_authenticated_bool" "\$cmux_daemon_bool" "\$cmux_daemon_auth_bool" "\$LOCAL_SESSION" \
      "\$cmux_tls_bool" "\$cmux_model_bool" "\$cmux_route_auth" "\$cmux_edge_status"
  else
    if [ "\$cmux_daemon_running" -eq 1 ]; then
      printf 'Daemon: running (session %s)\\n' "\$LOCAL_SESSION"
    else
      printf 'Daemon: unavailable (session %s)\\n' "\$LOCAL_SESSION"
    fi
    if [ "\$cmux_authenticated" -eq 1 ]; then
      printf 'Authentication: ready (daemon and CodeRouter route)\\n'
    else
      printf 'Authentication: incomplete (run cmux auth status --json for details)\\n'
    fi
    if [ "\$cmux_model_configured" -eq 0 ]; then
      printf 'CodeRouter: not configured\\n'
    elif [ "\$cmux_route_auth" = accepted ]; then
      printf 'CodeRouter: TLS edge reachable; route authenticated (HTTP %s)\\n' "\$cmux_edge_status"
    elif [ "\$cmux_route_auth" = rejected ]; then
      printf 'CodeRouter: TLS edge reachable; route rejected (HTTP %s)\\n' "\$cmux_edge_status"
    elif [ "\$cmux_route_auth" = insecure_url ]; then
      printf 'CodeRouter: refused insecure endpoint\\n'
    elif [ "\$cmux_route_auth" = unknown ]; then
      printf 'CodeRouter: TLS edge reachable; authentication indeterminate (HTTP %s)\\n' "\$cmux_edge_status"
    else
      printf 'CodeRouter: TLS edge unreachable\\n'
    fi
    printf 'Stack account tokens: host-only (never stored in this VM)\\n'
  fi
  [ "\$cmux_daemon_running" -eq 1 ] || return 1
  [ "\$cmux_authenticated" -eq 1 ] || return 1
}

guest_coderouter_usage() {
  for cmux_arg in "\$@"; do
    case "\$cmux_arg" in
      --json) ;;
      --help|-h) guest_usage; return 0 ;;
      *) die "coderouter usage: unknown option \$cmux_arg" 2 ;;
    esac
  done
  require_coderouter
  cmux_response="\$(cmux_curl -fsS --connect-timeout 5 --max-time 20 \
    -H "authorization: Bearer \$cmux_coderouter_key" \
    "\${cmux_coderouter_url%/}/api/coderouter/vm-usage/self" 2>&1)" || {
    printf '%s\\n' "\$cmux_response" >&2
    return 1
  }
  printf '%s\\n' "\$cmux_response"
}

guest_coderouter_models() {
  for cmux_arg in "\$@"; do
    case "\$cmux_arg" in
      --json) ;;
      --help|-h) guest_usage; return 0 ;;
      *) die "coderouter models: unknown option \$cmux_arg" 2 ;;
    esac
  done
  require_coderouter
  cmux_response="\$(cmux_curl -fsS --connect-timeout 5 --max-time 20 \
    -H "authorization: Bearer \$cmux_coderouter_key" -H "accept: application/json" \
    "\${cmux_coderouter_url%/}/v1/models" 2>&1)" || {
    printf '%s\\n' "\$cmux_response" >&2
    return 1
  }
  printf '%s\\n' "\$cmux_response"
}

guest_coderouter_agent() {
  cmux_agent="\${1:-}"
  [ -n "\$cmux_agent" ] || die "usage: cmux coderouter agent <claude|codex|opencode|pi> [args...]" 2
  if [ "\$cmux_agent" = "--agent" ]; then
    shift
    cmux_agent="\${1:-}"
    [ -n "\$cmux_agent" ] || die "usage: cmux coderouter agent <claude|codex|opencode|pi> [args...]" 2
  fi
  shift
  case "\$cmux_agent" in
    claude|codex|opencode|pi) ;;
    *) die "unsupported agent '\$cmux_agent' (choose claude, codex, opencode, or pi)" 2 ;;
  esac
  load_agent_config
  # Match the host vm-agent contract: a bare sentence becomes the provider's
  # one-shot form, while flags/subcommands are passed through byte-for-byte.
  if [ "\$#" -eq 0 ]; then
    exec "\$cmux_agent"
  fi
  if [ "\$1" = "--" ]; then
    shift
    [ "\$#" -gt 0 ] || die "usage: cmux coderouter agent <claude|codex|opencode|pi> [args...]" 2
    cmux_prompt="\$*"
    case "\$cmux_agent" in
      claude) set -- claude -p "\$cmux_prompt" ;;
      codex) set -- codex exec "\$cmux_prompt" ;;
      opencode) set -- opencode run "\$cmux_prompt" ;;
      pi) set -- pi -p "\$cmux_prompt" ;;
    esac
    exec "\$@"
  fi
  cmux_first="\$1"
  case "\$cmux_first" in
    -*|mcp|config|doctor|update|install|auth|setup-token|plugin|agents|exec|e|login|logout|apply|resume|completion|debug|sandbox|cloud|app-server|features|run|serve|web|models|upgrade|agent|session|export|import|github|acp|list)
      exec "\$cmux_agent" "\$@"
      ;;
    *)
      cmux_prompt="\$*"
      case "\$cmux_agent" in
        claude) set -- claude -p "\$cmux_prompt" ;;
        codex) set -- codex exec "\$cmux_prompt" ;;
        opencode) set -- opencode run "\$cmux_prompt" ;;
        pi) set -- pi -p "\$cmux_prompt" ;;
      esac
      exec "\$@"
      ;;
  esac
}

guest_agent_command() {
  case "\${1:-}" in
    claude|codex|opencode|pi|--agent)
      guest_coderouter_agent "\$@"
      ;;
    list|report|hook)
      exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" agent "\$@"
      ;;
    help|--help|-h|"")
      guest_usage
      ;;
    *)
      die "agent: expected claude, codex, opencode, pi, or a local agent command (list/report/hook); got \$1" 2
      ;;
  esac
}

guest_coderouter_command() {
  cmux_coderouter_sub="\${1:-help}"
  [ "\$#" -gt 0 ] && shift
  case "\$cmux_coderouter_sub" in
    status|auth) guest_auth_status "\$@" ;;
    usage|machines) guest_coderouter_usage "\$@" ;;
    models) guest_coderouter_models "\$@" ;;
    agent|run) guest_coderouter_agent "\$@" ;;
    help|--help|-h) guest_usage ;;
    claude|accounts|login|logout)
      die "team CodeRouter account management is host-owned; Stack tokens stay on the Mac. Run cmux coderouter \$cmux_coderouter_sub there" 2
      ;;
    *) die "unknown coderouter command '\$cmux_coderouter_sub' (try cmux coderouter help)" 2 ;;
  esac
}

host_only_command() {
  die "\$1 is host-owned; run it on the Mac cmux CLI (the VM uses scoped daemon/edge auth instead of Stack tokens)" 2
}

local_alias() {
  case "\$1" in
    list-workspaces)
      shift
      exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" workspace list "\$@"
      ;;
    current-workspace)
      shift
      exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" workspace current show "\$@"
      ;;
    list-panes)
      shift
      exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" pane list "\$@"
      ;;
    *) return 1 ;;
  esac
}

peer_file() { printf '%s/%s.json' "\$PEERS_DIR" "\$1"; }

# Establish (or reuse) the headless link to a peer; prints the peer's local mux
# socket path. The link subprocess outlives this command (nohup) so later verbs
# reuse it. Route files are written by the Mac's \`cmux vm link\`.
ensure_link() {
  peer="\$1"
  file="\$(peer_file "\$peer")"
  [ -f "\$file" ] || die "no link for machine '\$peer'. From the Mac: cmux vm link <this-machine> \$peer" 2
  mkdir -p "\$LINKS_DIR"
  sock_file="\$LINKS_DIR/\$peer.sock-path"
  pid_file="\$LINKS_DIR/\$peer.pid"
  if [ -f "\$sock_file" ] && [ -f "\$pid_file" ] && kill -0 "\$(cat "\$pid_file")" 2>/dev/null; then
    sock="\$(cat "\$sock_file")"
    if [ -S "\$sock" ]; then printf '%s' "\$sock"; return 0; fi
  fi
  route="\$(jq -r .route "\$file")"
  [ -n "\$route" ] && [ "\$route" != null ] || die "malformed peer file \$file" 2
  invite="\$(jq -r '.invite // empty' "\$file")"
  out_file="\$LINKS_DIR/\$peer.connect.jsonl"
  : > "\$out_file"
  set -- remote connect "\$route" --headless --json \\
    --device-name "vm-\$(hostname 2>/dev/null || echo guest)" \\
    --state-dir "\$CMUX_GUEST_HOME/peer-devices"
  if [ -n "\$invite" ]; then
    invite_file="\$LINKS_DIR/\$peer.invite"
    umask 077
    printf '%s' "\$invite" > "\$invite_file"
    set -- "\$@" --invite-file "\$invite_file"
  fi
  nohup "\$CMUX_TUI_BIN" "\$@" > "\$out_file" 2>>"\$LINKS_DIR/\$peer.log" &
  printf '%s' "\$!" > "\$pid_file"
  i=0
  while [ "\$i" -lt 150 ]; do
    # The headless client emits jsonl; the connection-snapshot event names the
    # local mux socket (field \`local_socket\`, same contract the Mac app parses).
    sock="\$(jq -r 'select(.event=="connection-snapshot") | .local_socket // empty' "\$out_file" 2>/dev/null | head -n 1 || true)"
    if [ -n "\$sock" ] && [ -S "\$sock" ]; then
      printf '%s' "\$sock" > "\$sock_file"
      # The single-use invitation is consumed by a successful connect.
      jq 'del(.invite)' "\$file" > "\$file.tmp" && mv "\$file.tmp" "\$file"
      printf '%s' "\$sock"
      return 0
    fi
    kill -0 "\$(cat "\$pid_file")" 2>/dev/null || die "link to '\$peer' exited; see \$LINKS_DIR/\$peer.log" 3
    i=\$((i + 1)); sleep 0.2
  done
  die "link to '\$peer' did not come up in 30s; see \$LINKS_DIR/\$peer.log" 3
}

case "\${1:-}" in
  --version|-v|version)
    printf 'cmux guest CLI (cmux-tui transport)\\n'
    exec "\$CMUX_TUI_BIN" --version
    ;;
  --help|help|"")
    guest_usage
    ;;
  auth)
    shift
    auth_sub="\${1:-status}"
    [ "\$#" -gt 0 ] && shift
    case "\$auth_sub" in
      status) guest_auth_status "\$@" ;;
      login|logout) host_only_command "cmux auth \$auth_sub" ;;
      help|--help|-h) guest_usage ;;
      *) die "unknown auth command '\$auth_sub' (try cmux auth status)" 2 ;;
    esac
    ;;
  login|logout)
    host_only_command "cmux \$1"
    ;;
  coderouter|cr)
    shift
    guest_coderouter_command "\$@"
    ;;
  agent)
    shift
    guest_agent_command "\$@"
    ;;
  ai-accounts|remotes)
    host_only_command "cmux \$1"
    ;;
  vm)
    shift
    sub="\${1:-}"; [ "\$#" -gt 0 ] && shift
    case "\$sub" in
      ls|list)
        # This machine, then every linked peer.
        printf '%s\\t%s\\n' "\$(hostname 2>/dev/null || echo local)" "(this machine)"
        if [ -d "\$PEERS_DIR" ]; then
          for f in "\$PEERS_DIR"/*.json; do
            [ -e "\$f" ] || continue
            name="\$(basename "\$f" .json)"
            state=linked
            pidf="\$LINKS_DIR/\$name.pid"
            if [ -f "\$pidf" ] && kill -0 "\$(cat "\$pidf")" 2>/dev/null; then state=connected; fi
            printf '%s\\t%s\\n' "\$name" "\$state"
          done
        fi
        ;;
      connect)
        peer="\${1:-}"; [ -n "\$peer" ] || die "usage: cmux vm connect <machine>" 2
        sock="\$(ensure_link "\$peer")"
        printf 'OK connected %s socket=%s\\n' "\$peer" "\$sock"
        ;;
      exec)
        peer="\${1:-}"; [ -n "\$peer" ] || die "usage: cmux vm exec <machine> -- <command…>" 2
        shift
        [ "\${1:-}" = "--" ] && shift
        [ "\$#" -gt 0 ] || die "usage: cmux vm exec <machine> -- <command…>" 2
        sock="\$(ensure_link "\$peer")"
        # A fresh session has no current workspace; create one and run in it by id.
        target=current
        if ! "\$CMUX_TUI_BIN" --socket "\$sock" workspace current get >/dev/null 2>&1; then
          created="\$("\$CMUX_TUI_BIN" --socket "\$sock" --json workspace create --name main 2>/dev/null | jq -r '.id // .workspace_id // .workspace.id // empty' | head -n 1)"
          [ -n "\$created" ] && target="\$created"
        fi
        exec "\$CMUX_TUI_BIN" --socket "\$sock" workspace "\$target" run --on-exit close -- "\$@"
        ;;
      tui|tree|workspace|terminal|session|pane|tab|screen|browser|agent)
        # cmux vm <verb> <machine> [args…] → the same cmux-tui verb on the peer.
        peer="\${1:-}"; [ -n "\$peer" ] || die "usage: cmux vm \$sub <machine> [args…]" 2
        shift
        sock="\$(ensure_link "\$peer")"
        if [ "\$sub" = tui ]; then exec "\$CMUX_TUI_BIN" --socket "\$sock"; fi
        if [ "\$sub" = tree ]; then exec "\$CMUX_TUI_BIN" --socket "\$sock" --json session current snapshot; fi
        exec "\$CMUX_TUI_BIN" --socket "\$sock" "\$sub" "\$@"
        ;;
      ""|help|--help|-h)
        cat <<'EOF'
cmux vm — talk to other cmux Cloud machines from inside this one.

  cmux vm ls                          linked machines and their link state
  cmux vm connect <machine>           bring up the link (done lazily otherwise)
  cmux vm exec <machine> -- <cmd…>    run a command on the peer (durable terminal)
  cmux vm tree <machine>              the peer's workspace/terminal snapshot
  cmux vm <resource> <machine> …      any cmux-tui resource verb on the peer

Links are granted from the Mac: cmux vm link <this-machine> <peer>.
Local verbs need no prefix: cmux workspace…, cmux terminal…, cmux session….
EOF
        ;;
      *) die "unknown vm subcommand '\$sub' (try: cmux vm help)" 2 ;;
    esac
    ;;
  notify)
    # Mac-CLI compatible \`cmux notify\` inside a machine (agent hooks call it
    # with --title/--subtitle/--body). cmux-tui's verb is \`notification create\`;
    # the notification lands in this machine's daemon ledger and the user's Mac
    # picks it up from the session event stream it already follows. The Mac
    # attributes it to the pane showing this terminal, so the daemon-assigned
    # CMUX_TUI_TERMINAL_ID is the only selector that means anything here: Mac
    # topology selectors are ignored, --subtitle folds into the body (cmux-tui
    # has no such field), and only the levels the daemon accepts are forwarded.
    # Nothing here can name a Mac workspace, surface, or socket.
    shift
    title=""; subtitle=""; body=""; level=""; terminal="\${CMUX_TUI_TERMINAL_ID:-}"
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        --title) title="\${2:-}"; shift; [ "\$#" -gt 0 ] && shift ;;
        --title=*) title="\${1#--title=}"; shift ;;
        --subtitle) subtitle="\${2:-}"; shift; [ "\$#" -gt 0 ] && shift ;;
        --subtitle=*) subtitle="\${1#--subtitle=}"; shift ;;
        --body) body="\${2:-}"; shift; [ "\$#" -gt 0 ] && shift ;;
        --body=*) body="\${1#--body=}"; shift ;;
        --level) level="\${2:-}"; shift; [ "\$#" -gt 0 ] && shift ;;
        --level=*) level="\${1#--level=}"; shift ;;
        --terminal) terminal="\${2:-}"; shift; [ "\$#" -gt 0 ] && shift ;;
        --terminal=*) terminal="\${1#--terminal=}"; shift ;;
        --workspace|--surface|--window|--tab|--panel) shift; [ "\$#" -gt 0 ] && shift ;;
        *) shift ;;
      esac
    done
    [ -n "\$title" ] || title=Notification
    if [ -n "\$subtitle" ]; then
      if [ -n "\$body" ]; then body="\$subtitle — \$body"; else body="\$subtitle"; fi
    fi
    set -- notification create --title "\$title" --body "\$body"
    case "\$level" in info|warning|error) set -- "\$@" --level "\$level" ;; esac
    if [ -n "\$terminal" ]; then set -- "\$@" --terminal "\$terminal"; fi
    exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" --quiet "\$@"
    ;;
  *)
    # Local daemon session. cmux-tui's own grammar is \`cmux <resource> <action>\`.
    local_alias "\$@" 2>/dev/null || exec "\$CMUX_TUI_BIN" --session "\$LOCAL_SESSION" "\$@"
    ;;
esac
`;

/** Shell command installing the shim (idempotent; safe to run on every heal). */
export function guestCliInstallCommand(): string {
  const encoded = Buffer.from(GUEST_CMUX_SHIM, "utf8").toString("base64");
  return [
    `printf '%s' '${encoded}' | base64 -d > ${GUEST_CMUX_SHIM_PATH}.tmp`,
    `chmod 0755 ${GUEST_CMUX_SHIM_PATH}.tmp`,
    `mv ${GUEST_CMUX_SHIM_PATH}.tmp ${GUEST_CMUX_SHIM_PATH}`,
  ].join(" && ");
}
