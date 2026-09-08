//! Cloud control through the signed-in app, with interactive connections in this
//! Rust process. The app owns authentication, route selection and the shared hub.
//! No Swift CLI subprocess, system tunnel, or second WireGuard identity is used.

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, UsageError};
use crate::localization::catalog;

pub(super) enum Plan {
    Request { method: &'static str, params: Value, view: View },
    Tui { vm: String },
}

pub(super) enum View {
    List,
    Text,
    Json,
}

pub(super) fn parse(args: &[String]) -> Result<Plan, UsageError> {
    let words = args.iter().map(String::as_str).collect::<Vec<_>>();
    let request = |method, params, view| Ok(Plan::Request { method, params, view });
    let valid_id = |value: &str| !value.is_empty() && !value.starts_with('-');
    match words.as_slice() {
        ["ls" | "list"] => request("vm.list", json!({}), View::List),
        ["tui", vm] if valid_id(vm) => Ok(Plan::Tui { vm: (*vm).into() }),
        ["tree", rest @ ..] => {
            let mut params = json!({});
            for value in rest {
                if *value == "--refresh" && params.get("refresh").is_none() {
                    params["refresh"] = json!(true);
                } else if valid_id(value) && params.get("machine").is_none() {
                    params["machine"] = json!(value);
                } else {
                    return Err(usage());
                }
            }
            request("surface.catalog", params, View::Json)
        }
        ["terminal", "new", vm, rest @ ..] if valid_id(vm) => {
            let mut params = json!({"id":vm,"open":false});
            match rest {
                [] => {}
                ["--name", name] if !name.is_empty() => params["name"] = json!(name),
                _ => return Err(usage()),
            }
            request("vm.terminal_new", params, View::Json)
        }
        ["terminal", action @ ("read" | "close"), vm, terminal]
            if valid_id(vm) && valid_id(terminal) =>
        {
            request(
                if *action == "read" { "vm.terminal_read" } else { "vm.terminal_close" },
                json!({"id":vm,"terminal_id":terminal}),
                if *action == "read" { View::Text } else { View::Json },
            )
        }
        ["terminal", "send", vm, terminal, rest @ ..] if valid_id(vm) && valid_id(terminal) => {
            let mut params = json!({"id":vm,"terminal_id":terminal});
            let mut text = Vec::new();
            let mut tail = rest.iter().copied();
            while let Some(value) = tail.next() {
                match value {
                    "--" => {
                        text.extend(tail);
                        break;
                    }
                    "--keys" if params.get("keys").is_none() => {
                        let keys = tail.next().ok_or_else(usage)?;
                        let keys = keys.split(',').map(str::trim).collect::<Vec<_>>();
                        if keys.iter().any(|key| key.is_empty() || key.starts_with('-')) {
                            return Err(usage());
                        }
                        params["keys"] = json!(keys);
                    }
                    value if value.starts_with('-') => return Err(usage()),
                    value => text.push(value),
                }
            }
            let text = text.join(" ");
            if !text.is_empty() {
                params["text"] = json!(text);
            }
            if params.get("text").is_none() && params.get("keys").is_none() {
                return Err(usage());
            }
            request("vm.terminal_write", params, View::Json)
        }
        _ => Err(usage()),
    }
}

fn usage() -> UsageError {
    UsageError::new(catalog().cloud_vm.help)
}

#[derive(Debug)]
struct AppFailure {
    code: String,
    message: String,
}

impl std::fmt::Display for AppFailure {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(out, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for AppFailure {}

pub(super) fn run(global: GlobalArgs, plan: Plan) -> i32 {
    if global.session.is_some()
        || global.machine.is_some()
        || (matches!(plan, Plan::Tui { .. }) && global.output != OutputMode::Human)
    {
        return super::wire::print_local_error(
            &json!({"code":"usage.invalid","message":catalog().cloud_vm.invalid_globals}),
            global.output,
            2,
        );
    }
    #[cfg(unix)]
    let result = run_unix(&global, plan);
    #[cfg(not(unix))]
    let result: anyhow::Result<i32> = {
        let _ = plan;
        Err(anyhow::anyhow!(catalog().cloud_vm.unix_required))
    };
    match result {
        Ok(code) => code,
        Err(error) => {
            let code = error
                .downcast_ref::<AppFailure>()
                .map_or("cloud.failed", |error| error.code.as_str());
            super::wire::print_local_error(
                &json!({"code":code,"message":format!("{error:#}")}),
                global.output,
                1,
            )
        }
    }
}

#[cfg(unix)]
fn run_unix(global: &GlobalArgs, plan: Plan) -> anyhow::Result<i32> {
    use std::io::Write;
    use std::path::PathBuf;
    use std::time::Duration;

    let socket = global
        .socket
        .clone()
        .or_else(|| {
            std::env::var_os("CMUX_SOCKET_PATH").filter(|v| !v.is_empty()).map(PathBuf::from)
        })
        .unwrap_or_else(|| PathBuf::from("/tmp/cmux.sock"));
    let (method, params, view, tui) = match plan {
        Plan::Request { method, params, view } => (method, params, view, false),
        Plan::Tui { vm } => (
            "vm.cmux_remote_info",
            json!({"id":vm,"client_capabilities":crate::remote_cli::PROBE_CAPABILITIES}),
            View::Json,
            true,
        ),
    };
    // Match the app's bounded Cloud provisioning deadline. Inventory and
    // terminal operations use the shorter ordinary request deadline.
    let timeout = Duration::from_secs(if tui { 16 * 60 } else { 180 });
    let result = app_request(&socket, method, params, timeout)?;
    if tui {
        let args = connect_args(&result)?;
        return Ok(crate::remote_cli::run(
            &args,
            &crate::usage(),
            crate::config::StartupConfigSnapshot::load,
        ));
    }
    if global.output == OutputMode::Quiet {
        return Ok(0);
    }
    let mut out = std::io::stdout().lock();
    if global.output != OutputMode::Human || matches!(view, View::Json) {
        serde_json::to_writer(&mut out, &result)?;
        writeln!(out)?;
    } else {
        match view {
            View::List => {
                let vms = result["vms"]
                    .as_array()
                    .ok_or_else(|| anyhow::anyhow!(catalog().cloud_vm.invalid_response))?;
                if vms.is_empty() {
                    writeln!(out, "{}", catalog().cloud_vm.empty)?;
                }
                for vm in vms {
                    let cell = |key| vm.get(key).and_then(Value::as_str).unwrap_or("");
                    writeln!(out, "{}\t{}\t{}", cell("id"), cell("status"), cell("displayName"))?;
                }
            }
            View::Text => {
                let text = result["text"]
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!(catalog().cloud_vm.invalid_response))?;
                out.write_all(text.as_bytes())?;
            }
            View::Json => unreachable!(),
        }
    }
    out.flush()?;
    Ok(0)
}

#[cfg(unix)]
fn connect_args(info: &Value) -> anyhow::Result<Vec<String>> {
    use anyhow::{anyhow, ensure};
    let messages = &catalog().cloud_vm;
    ensure!(info["trusted_carrier"].as_bool() == Some(true), messages.trust_required);
    let hub = info["wireguard_hub_socket"]
        .as_str()
        .filter(|p| std::path::Path::new(p).is_absolute())
        .ok_or_else(|| anyhow!(messages.hub_required))?;
    let route = info["route"].as_str().ok_or_else(|| anyhow!(messages.invalid_response))?;
    let url = url::Url::parse(route).map_err(|_| anyhow!(messages.invalid_response))?;
    ensure!(
        matches!(url.scheme(), "ws" | "wss")
            && url.host().is_some()
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none(),
        messages.invalid_response
    );
    if let Some(protocol) = info["daemon_build"]["remote_protocol"].as_u64() {
        ensure!(
            protocol == u64::from(cmux_remote_protocol::REMOTE_PROTOCOL_VERSION),
            messages.protocol_mismatch
        );
    }
    Ok(vec![
        "connect".into(),
        route.into(),
        "--carrier".into(),
        "--wireguard-hub".into(),
        hub.into(),
    ])
}

#[cfg(unix)]
fn app_request(
    socket: &std::path::Path,
    method: &str,
    params: Value,
    timeout: std::time::Duration,
) -> anyhow::Result<Value> {
    use anyhow::Context;
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    runtime.block_on(async {
        tokio::select! {
            result = tokio::time::timeout(timeout, app_exchange(socket, method, params)) => {
                result.context(catalog().cloud_vm.read_failed)?
            }
            result = crate::wait_for_shutdown_signal_async() => {
                result?;
                Err(anyhow::anyhow!(catalog().cloud_vm.read_failed))
            }
        }
    })
}

#[cfg(unix)]
async fn app_exchange(
    socket: &std::path::Path,
    method: &str,
    params: Value,
) -> anyhow::Result<Value> {
    use anyhow::{Context, ensure};
    use tokio::io::BufReader;
    use tokio::net::UnixStream;

    let messages = &catalog().cloud_vm;
    let stream = UnixStream::connect(socket).await.context(messages.app_required)?;
    cmux_remote::admin::verify_unix_peer_owner(&stream).context(messages.invalid_owner)?;
    let mut reader = BufReader::new(stream);
    let capability = std::env::var("CMUX_SOCKET_CAPABILITY").ok().filter(|v| !v.is_empty());
    if let Some(capability) = &capability {
        ensure!(!capability.chars().any(char::is_whitespace), messages.invalid_auth);
    }
    if let Some(password) = std::env::var("CMUX_SOCKET_PASSWORD").ok().filter(|v| !v.is_empty()) {
        ensure!(!password.contains(['\n', '\r']), messages.invalid_auth);
        app_send(&mut reader, &format!("auth {password}"), capability.as_deref()).await?;
        let auth = app_receive(&mut reader).await?;
        ensure!(auth.starts_with(b"OK"), messages.auth_failed);
    }
    let id = uuid::Uuid::new_v4().to_string();
    let line = serde_json::to_string(&json!({"id":id,"method":method,"params":params}))?;
    ensure!(line.len() <= 4 * 1024 * 1024, messages.request_too_large);
    app_send(&mut reader, &line, capability.as_deref()).await?;
    let bytes = app_receive(&mut reader).await?;
    ensure!(!bytes.starts_with(b"ERROR:"), messages.auth_failed);
    let response: Value = serde_json::from_slice(&bytes).context(messages.invalid_response)?;
    ensure!(response["id"].as_str() == Some(&id), messages.invalid_response);
    if response["ok"].as_bool() != Some(true) {
        let error = &response["error"];
        return Err(AppFailure {
            code: error["code"].as_str().unwrap_or("cloud.failed").to_owned(),
            message: error["message"].as_str().unwrap_or(messages.invalid_response).to_owned(),
        }
        .into());
    }
    ensure!(response["result"].is_object(), messages.invalid_response);
    Ok(response["result"].clone())
}

#[cfg(unix)]
async fn app_send(
    reader: &mut tokio::io::BufReader<tokio::net::UnixStream>,
    line: &str,
    capability: Option<&str>,
) -> anyhow::Result<()> {
    use tokio::io::AsyncWriteExt;
    if let Some(capability) = capability {
        reader.get_mut().write_all(format!("_cmux_capability_v1 {capability} ").as_bytes()).await?;
    }
    reader.get_mut().write_all(line.as_bytes()).await?;
    reader.get_mut().write_all(b"\n").await?;
    reader.get_mut().flush().await?;
    Ok(())
}

#[cfg(unix)]
async fn app_receive(
    reader: &mut tokio::io::BufReader<tokio::net::UnixStream>,
) -> anyhow::Result<Vec<u8>> {
    use anyhow::{Context, ensure};
    use tokio::io::{AsyncBufReadExt, AsyncReadExt};
    const MAX_RESPONSE: u64 = 16 * 1024 * 1024;
    let messages = &catalog().cloud_vm;
    let mut bytes = Vec::new();
    reader
        .take(MAX_RESPONSE + 1)
        .read_until(b'\n', &mut bytes)
        .await
        .context(messages.read_failed)?;
    ensure!(
        bytes.len() as u64 <= MAX_RESPONSE && bytes.last() == Some(&b'\n'),
        messages.invalid_response
    );
    Ok(bytes)
}
