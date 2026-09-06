//! Rust implementation of the socket-facing cmux CLI boundary.
//!
//! The Swift CLI remains the compatibility oracle during migration. This
//! crate keeps the wire contract small and explicit so each command can be
//! ported and tested without changing the app protocol.

use std::env;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus};
use std::time::Duration;

use serde_json::{Value, json};
use uuid::Uuid;

const VERSION: &str = env!("CMUX_CLI_VERSION");
const BUILD: &str = env!("CMUX_CLI_BUILD");
const COMMIT: &str = env!("CMUX_CLI_COMMIT");
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Program {
    Cmux,
    CodeRouter,
}

#[derive(Debug, Eq, PartialEq)]
enum CliError {
    Usage(String),
    Runtime(String),
    Exit(i32, String),
}

impl CliError {
    fn code(&self) -> i32 {
        match self {
            Self::Usage(_) => 2,
            Self::Runtime(_) => 1,
            Self::Exit(code, _) => *code,
        }
    }

    fn message(&self) -> &str {
        match self {
            Self::Usage(message) | Self::Runtime(message) | Self::Exit(_, message) => message,
        }
    }
}

#[derive(Debug, Default, Eq, PartialEq)]
struct GlobalOptions {
    socket: Option<PathBuf>,
    password: Option<String>,
    json: bool,
    id_format: Option<String>,
    window: Option<String>,
}

#[derive(Debug, Eq, PartialEq)]
enum CommandLine {
    Help,
    Version,
    Ping(Vec<String>),
    Capabilities(Vec<String>),
    Context(Vec<String>),
    Identify(Vec<String>),
    ListWindows(Vec<String>),
    CurrentWindow(Vec<String>),
    NewWindow(Vec<String>),
    FocusWindow(Vec<String>),
    CloseWindow(Vec<String>),
    ListNotifications(Vec<String>),
    LegacyV1 { command: String, arguments: Vec<String> },
    SocketV2 { command: String, arguments: Vec<String> },
    Cr(Vec<String>),
    CodeRouter(Vec<String>),
    AiAccounts(Vec<String>),
    Rpc { method: String, params: Value },
}

/// Run one CLI invocation. The return value is the process exit status.
pub fn run(args: Vec<String>, program: Program) -> i32 {
    match run_inner(args, program) {
        Ok(()) => 0,
        Err(CliError::Exit(code, message)) => {
            if !message.is_empty() {
                eprintln!("Error: {message}");
            }
            code
        }
        Err(error) => {
            eprintln!("Error: {}", error.message());
            error.code()
        }
    }
}

fn run_inner(args: Vec<String>, program: Program) -> Result<(), CliError> {
    let (options, command) = parse_args(&args, program)?;
    match command {
        CommandLine::Help => {
            println!("{}", usage(program));
            Ok(())
        }
        CommandLine::Version => {
            if COMMIT.is_empty() {
                println!("cmux {VERSION} ({BUILD})");
            } else {
                println!("cmux {VERSION} ({BUILD}) [{COMMIT}]");
            }
            Ok(())
        }
        CommandLine::Ping(arguments) => {
            reject_no_arguments("ping", &arguments)?;
            let response = socket(&options)?.send_v1("ping")?;
            println!("{response}");
            Ok(())
        }
        CommandLine::Capabilities(arguments) => {
            if arguments.iter().any(|argument| argument == "--help" || argument == "-h") {
                println!("Usage: cmux capabilities\n\nPrint server capabilities as JSON.");
                return Ok(());
            }
            let offline = arguments.iter().any(|argument| argument == "--offline");
            if arguments.iter().any(|argument| argument != "--json" && argument != "--offline") {
                reject_no_arguments("capabilities", &arguments)?;
            }
            if offline {
                print_capabilities();
            } else {
                let result = socket(&options)?.send_v2("system.capabilities", json!({}))?;
                print_result(&result, true);
            }
            Ok(())
        }
        CommandLine::Context(arguments) => {
            reject_no_arguments("context", &arguments)?;
            print_context(&options);
            Ok(())
        }
        CommandLine::Identify(arguments) => run_identify(arguments, options),
        CommandLine::ListWindows(arguments) => run_list_windows(arguments, options),
        CommandLine::CurrentWindow(arguments) => run_current_window(arguments, options),
        CommandLine::NewWindow(arguments) => {
            reject_no_arguments("new-window", &arguments)?;
            let response = socket(&options)?.send_v1("new_window")?;
            println!("{response}");
            Ok(())
        }
        CommandLine::FocusWindow(arguments) => {
            let window = option_value(&arguments, "--window")
                .or_else(|| options.window.clone())
                .ok_or_else(|| CliError::Usage("focus-window requires --window".into()))?;
            let response = socket(&options)?.send_v1(&format!("focus_window {window}"))?;
            println!("{response}");
            Ok(())
        }
        CommandLine::CloseWindow(arguments) => {
            let window = option_value(&arguments, "--window")
                .or_else(|| options.window.clone())
                .ok_or_else(|| CliError::Usage("close-window requires --window".into()))?;
            let response = socket(&options)?.send_v1(&format!("close_window {window}"))?;
            println!("{response}");
            Ok(())
        }
        CommandLine::ListNotifications(arguments) => run_list_notifications(arguments, options),
        CommandLine::LegacyV1 { command, arguments } => {
            let command = if command == "set_app_focus" {
                let value = arguments
                    .first()
                    .ok_or_else(|| CliError::Usage("set-app-focus requires a value".into()))?;
                if arguments.len() > 1 {
                    return Err(CliError::Usage(format!(
                        "set-app-focus: unexpected argument '{}'",
                        arguments[1]
                    )));
                }
                format!("set_app_focus {value}")
            } else {
                if !arguments.is_empty() {
                    return Err(CliError::Usage(format!(
                        "{command}: unexpected argument '{}'",
                        arguments[0]
                    )));
                }
                command
            };
            let response = socket(&options)?.send_v1(&command)?;
            println!("{response}");
            Ok(())
        }
        CommandLine::SocketV2 { command, arguments } => {
            run_socket_v2_command(&command, arguments, options)
        }
        CommandLine::Cr(arguments) => run_coderouter(arguments, options, program, true),
        CommandLine::CodeRouter(arguments) => {
            if program == Program::Cmux
                && arguments.first().map(String::as_str) == Some("broker-config")
            {
                let result = socket(&options)?.send_v2("coderouter.broker_config", json!({}))?;
                let directory = result
                    .get("data_dir")
                    .and_then(Value::as_str)
                    .filter(|value| !value.trim().is_empty())
                    .ok_or_else(|| {
                        CliError::Exit(
                            127,
                            "CodeRouter broker returned no temporary data directory.".into(),
                        )
                    })?;
                if options.json {
                    print_result(&result, true);
                } else {
                    println!("{directory}");
                }
                Ok(())
            } else {
                run_coderouter(arguments, options, program, false)
            }
        }
        CommandLine::AiAccounts(arguments) => run_ai_accounts(arguments, options),
        CommandLine::Rpc { method, params } => {
            let result = socket(&options)?.send_v2(&method, params)?;
            print_result(&result, options.json);
            Ok(())
        }
    }
}

fn parse_args(args: &[String], program: Program) -> Result<(GlobalOptions, CommandLine), CliError> {
    let mut options = GlobalOptions::default();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "-h" | "--help" if program == Program::CodeRouter => {
                return Ok((options, CommandLine::CodeRouter(vec!["--help".into()])));
            }
            "-h" | "--help" => return Ok((options, CommandLine::Help)),
            "-v" | "--version" if program == Program::CodeRouter => {
                return Ok((options, CommandLine::CodeRouter(vec!["--version".into()])));
            }
            "-v" | "--version" => return Ok((options, CommandLine::Version)),
            "--json" => {
                options.json = true;
                index += 1;
            }
            "--socket" | "--password" | "--id-format" | "--window" => {
                let name = args[index].clone();
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| CliError::Usage(format!("{name} requires a value")))?;
                if value.starts_with('-') && name == "--socket" {
                    return Err(CliError::Usage(format!("{name} requires a value")));
                }
                match name.as_str() {
                    "--socket" => options.socket = Some(PathBuf::from(value)),
                    "--password" => options.password = Some(value.clone()),
                    "--id-format" => {
                        if !matches!(value.as_str(), "refs" | "uuids" | "both") {
                            return Err(CliError::Usage(
                                "--id-format requires refs, uuids, or both".into(),
                            ));
                        }
                        options.id_format = Some(value.clone());
                    }
                    "--window" => options.window = Some(value.clone()),
                    _ => unreachable!("handled global option"),
                }
                index += 2;
            }
            value if value.starts_with("--socket=") => {
                options.socket = Some(PathBuf::from(value.trim_start_matches("--socket=")));
                index += 1;
            }
            value if value.starts_with("--password=") => {
                options.password = Some(value.trim_start_matches("--password=").to_string());
                index += 1;
            }
            value if value.starts_with("--id-format=") => {
                let format = value.trim_start_matches("--id-format=");
                if !matches!(format, "refs" | "uuids" | "both") {
                    return Err(CliError::Usage(
                        "--id-format requires refs, uuids, or both".into(),
                    ));
                }
                options.id_format = Some(format.to_string());
                index += 1;
            }
            value if value.starts_with("--window=") => {
                options.window = Some(value.trim_start_matches("--window=").to_string());
                index += 1;
            }
            _ => break,
        }
    }

    let command = args.get(index).map(String::as_str);
    let command = match (program, command) {
        (Program::CodeRouter, None) => CommandLine::CodeRouter(Vec::new()),
        (Program::CodeRouter, Some(_)) => CommandLine::CodeRouter(args[index..].to_vec()),
        (_, None) => {
            return Err(CliError::Usage(
                "Missing command. Usage: cmux <path>|<command> [options]. Run 'cmux --help' for the full command list.".into(),
            ));
        }
        (_, Some("version")) => CommandLine::Version,
        (_, Some("ping")) => CommandLine::Ping(args[index + 1..].to_vec()),
        (_, Some("capabilities")) => CommandLine::Capabilities(args[index + 1..].to_vec()),
        (_, Some("context")) => CommandLine::Context(args[index + 1..].to_vec()),
        (_, Some("identify")) => CommandLine::Identify(args[index + 1..].to_vec()),
        (_, Some("list-windows")) => CommandLine::ListWindows(args[index + 1..].to_vec()),
        (_, Some("current-window")) => CommandLine::CurrentWindow(args[index + 1..].to_vec()),
        (_, Some("new-window")) => CommandLine::NewWindow(args[index + 1..].to_vec()),
        (_, Some("focus-window")) => CommandLine::FocusWindow(args[index + 1..].to_vec()),
        (_, Some("close-window")) => CommandLine::CloseWindow(args[index + 1..].to_vec()),
        (_, Some("list-notifications")) => {
            CommandLine::ListNotifications(args[index + 1..].to_vec())
        }
        (
            _,
            Some(
                command @ ("notify"
                | "dismiss-notification"
                | "mark-notification-read"
                | "open-notification"
                | "jump-to-unread"
                | "open-browser"
                | "navigate"
                | "browser-back"
                | "browser-forward"
                | "browser-reload"
                | "get-url"
                | "focus-webview"
                | "is-webview-focused"
                | "auth"
                | "login"
                | "logout"
                | "browser"
                | "new-workspace"
                | "close-workspace"
                | "select-workspace"
                | "rename-workspace"
                | "new-pane"
                | "new-surface"),
            ),
        ) => {
            CommandLine::SocketV2 { command: command.into(), arguments: args[index + 1..].to_vec() }
        }
        (
            _,
            Some(
                command @ ("list-workspaces" | "current-workspace" | "list-panes"
                | "list-pane-surfaces" | "list-panels" | "focus-pane" | "focus-panel"
                | "read-screen" | "send" | "send-key"),
            ),
        ) => {
            CommandLine::SocketV2 { command: command.into(), arguments: args[index + 1..].to_vec() }
        }
        (
            _,
            Some(
                command
                @ ("close-surface" | "surface-health" | "debug-terminals" | "trigger-flash"),
            ),
        ) => {
            CommandLine::SocketV2 { command: command.into(), arguments: args[index + 1..].to_vec() }
        }
        (_, Some("refresh-surfaces")) => CommandLine::LegacyV1 {
            command: "refresh_surfaces".into(),
            arguments: args[index + 1..].to_vec(),
        },
        (_, Some("reload-config")) => CommandLine::LegacyV1 {
            command: "reload_config".into(),
            arguments: args[index + 1..].to_vec(),
        },
        (_, Some("simulate-app-active")) => CommandLine::LegacyV1 {
            command: "simulate_app_active".into(),
            arguments: args[index + 1..].to_vec(),
        },
        (_, Some("set-app-focus")) => CommandLine::LegacyV1 {
            command: "set_app_focus".into(),
            arguments: args[index + 1..].to_vec(),
        },
        (_, Some("__sidebar_footer_icon_balance")) => CommandLine::LegacyV1 {
            command: "__sidebar_footer_icon_balance".into(),
            arguments: args[index + 1..].to_vec(),
        },
        (_, Some("__internal_flags")) => CommandLine::LegacyV1 {
            command: "__internal_flags".into(),
            arguments: args[index + 1..].to_vec(),
        },
        (_, Some("iroh-diag")) => CommandLine::LegacyV1 {
            command: "iroh_diag".into(),
            arguments: args[index + 1..].to_vec(),
        },
        (_, Some("cr")) => CommandLine::Cr(args[index + 1..].to_vec()),
        (_, Some("coderouter")) => CommandLine::CodeRouter(args[index + 1..].to_vec()),
        (_, Some("ai-accounts")) => CommandLine::AiAccounts(args[index + 1..].to_vec()),
        (_, Some("rpc")) => parse_rpc(&args[index + 1..])?,
        (_, Some("help")) => CommandLine::Help,
        (_, Some(unknown)) => {
            return Err(CliError::Usage(format!(
                "Unknown command '{unknown}'. Run 'cmux --help' for the full command list."
            )));
        }
    };
    Ok((options, command))
}

fn reject_no_arguments(command: &str, arguments: &[String]) -> Result<(), CliError> {
    let allowed_json = arguments.iter().all(|argument| argument == "--json");
    if !arguments.is_empty() && !allowed_json {
        let argument = &arguments[0];
        return Err(CliError::Usage(format!("{command}: unexpected argument '{argument}'")));
    }
    Ok(())
}

fn print_capabilities() {
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "schema": 1,
            "implementation": "cmux-cli-rust",
            "production": false,
            "capabilities": [
                {
                    "id": "cmux.rpc",
                    "status": "experimental",
                    "aliases": ["rpc"],
                    "lifecycle": "instant",
                    "permissions": ["socket.control"],
                    "input": {"method": "string", "params": "object"},
                    "output": "json.result",
                    "verification": "response.ok == true"
                },
                {
                    "id": "coderouter.account.add",
                    "status": "experimental",
                    "aliases": ["cr add codex", "ai-accounts upload codex"],
                    "lifecycle": "instant",
                    "permissions": ["socket.control", "account.write"],
                    "input": {"provider": "codex", "label": "string?", "teamId": "string?", "validate": "boolean?"},
                    "output": "ai_account",
                    "verification": "account.id exists"
                },
                {
                    "id": "coderouter.exec",
                    "status": "delegated",
                    "aliases": ["coderouter", "cr"],
                    "lifecycle": "detached",
                    "permissions": ["process.exec", "network.coderouter"],
                    "input": {"argv": "string[]"},
                    "output": "child.exit",
                    "verification": "child.exit == 0"
                }
            ]
        }))
        .expect("capability catalog is valid JSON")
    );
}

fn print_context(options: &GlobalOptions) {
    let socket_path = socket_path(options);
    let socket = socket_path.as_ref().map(|path| path.display().to_string());
    let socket_password_source = if options.password.is_some() {
        Some("argument")
    } else if env::var_os("CMUX_SOCKET_PASSWORD").is_some() {
        Some("environment")
    } else if socket_password_file().is_some() {
        Some("file")
    } else if socket_password_keychain(socket_path.as_deref()).is_some() {
        Some("keychain")
    } else {
        None
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "workspace_id": env::var("CMUX_WORKSPACE_ID").ok(),
            "surface_id": env::var("CMUX_SURFACE_ID").ok(),
            "tab_id": env::var("CMUX_TAB_ID").ok(),
            "socket": socket,
            "socket_password_source": socket_password_source,
            "coderouter_data_dir_configured": env::var_os("CODEROUTER_DATA_DIR").is_some()
        }))
        .expect("context is valid JSON")
    );
}

fn run_identify(arguments: Vec<String>, options: GlobalOptions) -> Result<(), CliError> {
    let mut params = serde_json::Map::new();
    let include_caller = !arguments.iter().any(|argument| argument == "--no-caller");
    if let Some(window) = option_value(&arguments, "--window").or(options.window.clone()) {
        params.insert("window_id".into(), Value::String(window));
    }
    if include_caller {
        let workspace =
            option_value(&arguments, "--workspace").or_else(|| env::var("CMUX_WORKSPACE_ID").ok());
        let surface =
            option_value(&arguments, "--surface").or_else(|| env::var("CMUX_SURFACE_ID").ok());
        if workspace.is_some() || surface.is_some() {
            let mut caller = serde_json::Map::new();
            if let Some(workspace) = workspace {
                caller.insert("workspace_id".into(), Value::String(workspace));
            }
            if let Some(surface) = surface {
                caller.insert("surface_id".into(), Value::String(surface));
            }
            params.insert("caller".into(), Value::Object(caller));
        }
    }
    reject_known_options(
        "identify",
        &arguments,
        &["--no-caller", "--window", "--workspace", "--surface"],
    )?;
    let result = socket(&options)?.send_v2("system.identify", Value::Object(params))?;
    let result = format_ids(result, options.id_format.as_deref().unwrap_or("refs"));
    println!(
        "{}",
        serde_json::to_string_pretty(&result).map_err(|error| CliError::Runtime(format!(
            "Could not encode identify response: {error}"
        )))?
    );
    Ok(())
}

fn run_list_windows(arguments: Vec<String>, options: GlobalOptions) -> Result<(), CliError> {
    let json_output = options.json || arguments.iter().any(|argument| argument == "--json");
    reject_known_options("list-windows", &arguments, &["--json"])?;
    let response = socket(&options)?.send_v1("list_windows")?;
    if json_output {
        println!(
            "{}",
            serde_json::to_string(&parse_windows(&response))
                .map_err(|error| CliError::Runtime(format!("Could not encode windows: {error}")))?
        );
    } else {
        println!("{response}");
    }
    Ok(())
}

fn run_current_window(arguments: Vec<String>, options: GlobalOptions) -> Result<(), CliError> {
    let json_output = options.json || arguments.iter().any(|argument| argument == "--json");
    reject_known_options("current-window", &arguments, &["--json"])?;
    let response = socket(&options)?.send_v1("current_window")?;
    if json_output {
        println!("{}", json!({"window_id": response}));
    } else {
        println!("{response}");
    }
    Ok(())
}

fn run_list_notifications(arguments: Vec<String>, options: GlobalOptions) -> Result<(), CliError> {
    let json_output = options.json || arguments.iter().any(|argument| argument == "--json");
    reject_known_options("list-notifications", &arguments, &["--json"])?;
    let response = socket(&options)?.send_v1("list_notifications")?;
    if json_output {
        println!(
            "{}",
            serde_json::to_string(&parse_notifications(&response)).map_err(|error| {
                CliError::Runtime(format!("Could not encode notifications: {error}"))
            })?
        );
    } else {
        println!("{response}");
    }
    Ok(())
}

fn run_notification_clear(arguments: Vec<String>, options: GlobalOptions) -> Result<(), CliError> {
    let mut command = String::from("clear_notifications");
    if let Some(workspace) = option_value(&arguments, "--workspace") {
        command.push_str(" --tab=");
        command.push_str(&workspace);
    }
    if let Some(surface) = option_value(&arguments, "--surface") {
        command.push_str(" --panel=");
        command.push_str(&surface);
    }
    let response = socket(&options)?.send_v1(&command)?;
    println!("{response}");
    Ok(())
}

fn parse_notifications(response: &str) -> Vec<Value> {
    if response == "No notifications" {
        return Vec::new();
    }
    response
        .lines()
        .filter_map(|line| {
            let (_, payload) = line.split_once(':')?;
            let fields = payload.split('|').collect::<Vec<_>>();
            if fields.len() < 7 {
                return None;
            }
            let mut value = json!({
                "id": fields[0],
                "workspace_id": fields[1],
                "surface_id": if fields[2] == "none" { Value::Null } else { Value::String(fields[2].into()) },
                "is_read": fields[3] == "read",
                "title": fields[4],
                "subtitle": fields[5],
                "body": fields[6..].join("|"),
                "created_at": Value::Null,
                "tab_title": Value::Null,
            });
            if fields.len() >= 9 {
                value["created_at"] = Value::String(fields[fields.len() - 2].into());
                value["tab_title"] = Value::String(fields[fields.len() - 1].into());
                value["body"] = Value::String(fields[6..fields.len() - 2].join("|"));
            }
            Some(value)
        })
        .collect()
}

fn option_value(arguments: &[String], name: &str) -> Option<String> {
    arguments
        .iter()
        .position(|argument| argument == name)
        .and_then(|index| arguments.get(index + 1))
        .cloned()
        .or_else(|| {
            arguments.iter().find_map(|argument| {
                argument.strip_prefix(&format!("{name}=")).map(ToOwned::to_owned)
            })
        })
}

fn parse_bool(value: &str, flag: &str) -> Result<Value, CliError> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Ok(Value::Bool(true)),
        "0" | "false" | "no" | "off" => Ok(Value::Bool(false)),
        _ => Err(CliError::Usage(format!("{flag} must be true or false"))),
    }
}

fn reject_known_options(
    command: &str,
    arguments: &[String],
    allowed: &[&str],
) -> Result<(), CliError> {
    let mut index = 0;
    while index < arguments.len() {
        let argument = &arguments[index];
        if allowed.contains(&argument.as_str()) {
            if ["--window", "--workspace", "--surface"].contains(&argument.as_str()) {
                if arguments.get(index + 1).is_none() {
                    return Err(CliError::Usage(format!("{argument} requires a value")));
                }
                index += 2;
            } else {
                index += 1;
            }
        } else if allowed.iter().any(|name| argument.starts_with(&format!("{name}="))) {
            index += 1;
        } else {
            return Err(CliError::Usage(format!("{command}: unexpected argument '{argument}'")));
        }
    }
    Ok(())
}

fn parse_windows(response: &str) -> Vec<Value> {
    if response == "No windows" {
        return Vec::new();
    }
    response
        .lines()
        .filter_map(|line| {
            let key = line.starts_with('*');
            let cleaned = line.trim_matches(|character| character == '*' || character == ' ');
            let parts = cleaned.split_whitespace().collect::<Vec<_>>();
            if parts.len() < 2 {
                return None;
            }
            let index = parts[0].trim_end_matches(':').parse::<u64>().ok()?;
            let id = parts[1];
            let selected_workspace_id = parts.iter().find_map(|part| {
                part.strip_prefix("selected_workspace=").filter(|value| *value != "none")
            });
            let workspace_count = parts
                .iter()
                .find_map(|part| part.strip_prefix("workspaces=")?.parse::<u64>().ok())
                .unwrap_or(0);
            let mut value = json!({
                "index": index,
                "id": id,
                "key": key,
                "workspace_count": workspace_count,
            });
            value["selected_workspace_id"] = selected_workspace_id
                .map(|value| Value::String(value.to_string()))
                .unwrap_or(Value::Null);
            Some(value)
        })
        .collect()
}

fn format_ids(value: Value, mode: &str) -> Value {
    match value {
        Value::Array(values) => {
            Value::Array(values.into_iter().map(|value| format_ids(value, mode)).collect())
        }
        Value::Object(mut object) => {
            for value in object.values_mut() {
                let current = std::mem::take(value);
                *value = format_ids(current, mode);
            }
            match mode {
                "refs" => {
                    if object.get("ref").is_some() && object.get("id").is_some() {
                        object.remove("id");
                    }
                    let keys = object.keys().cloned().collect::<Vec<_>>();
                    for key in keys {
                        if let Some(prefix) = key.strip_suffix("_id")
                            && object.contains_key(&format!("{prefix}_ref"))
                        {
                            object.remove(&key);
                        }
                        if let Some(prefix) = key.strip_suffix("_ids")
                            && object.contains_key(&format!("{prefix}_refs"))
                        {
                            object.remove(&key);
                        }
                    }
                }
                "uuids" => {
                    if object.get("ref").is_some() && object.get("id").is_some() {
                        object.remove("ref");
                    }
                    let keys = object.keys().cloned().collect::<Vec<_>>();
                    for key in keys {
                        if let Some(prefix) = key.strip_suffix("_ref")
                            && object.contains_key(&format!("{prefix}_id"))
                        {
                            object.remove(&key);
                        }
                        if let Some(prefix) = key.strip_suffix("_refs")
                            && object.contains_key(&format!("{prefix}_ids"))
                        {
                            object.remove(&key);
                        }
                    }
                }
                "both" => {}
                _ => unreachable!("id format is validated during argument parsing"),
            }
            Value::Object(object)
        }
        value => value,
    }
}

fn run_socket_v2_command(
    command: &str,
    arguments: Vec<String>,
    options: GlobalOptions,
) -> Result<(), CliError> {
    let json_output = options.json || arguments.iter().any(|argument| argument == "--json");
    if command == "browser" {
        return run_browser_command(arguments, options, json_output);
    }
    let id_format = option_value(&arguments, "--id-format")
        .or_else(|| options.id_format.clone())
        .unwrap_or_else(|| "refs".into());
    if !matches!(id_format.as_str(), "refs" | "uuids" | "both") {
        return Err(CliError::Usage("--id-format requires refs, uuids, or both".into()));
    }
    let mut params = context_params(&arguments, &options)?;
    let method = match command {
        "list-workspaces" => "workspace.list",
        "current-workspace" => "workspace.current",
        "list-panes" => "pane.list",
        "list-pane-surfaces" => "pane.surfaces",
        "list-panels" => "surface.list",
        "focus-pane" => "pane.focus",
        "focus-panel" => "surface.focus",
        "read-screen" => "surface.read_text",
        "send" => {
            let text = trailing_text(&arguments, "send")?;
            params.insert("text".into(), Value::String(unescape_send_text(&text)));
            "surface.send_text"
        }
        "send-key" => {
            let key = trailing_key(&arguments, "send-key")?;
            params.insert("key".into(), Value::String(key));
            "surface.send_key"
        }
        "notify" => {
            if arguments.iter().any(|argument| argument == "--clear") {
                return run_notification_clear(arguments, options);
            }
            let title =
                option_value(&arguments, "--title").unwrap_or_else(|| "Notification".into());
            let subtitle = option_value(&arguments, "--subtitle").unwrap_or_default();
            let body = option_value(&arguments, "--body").unwrap_or_default();
            params.insert("title".into(), Value::String(title));
            params.insert("subtitle".into(), Value::String(subtitle));
            params.insert("body".into(), Value::String(body));
            if arguments.iter().any(|argument| argument == "--reply") {
                params.insert("reply_shape".into(), Value::String("text".into()));
            }
            if params.get("surface_id").is_some() || params.get("workspace_id").is_some() {
                "notification.create"
            } else {
                "notification.create_for_caller"
            }
        }
        "dismiss-notification" => {
            let id = option_value(&arguments, "--id");
            let all_read = arguments.iter().any(|argument| argument == "--all-read");
            if id.is_some() == all_read {
                return Err(CliError::Usage(
                    "dismiss-notification requires exactly one of --id or --all-read".into(),
                ));
            }
            if let Some(id) = id {
                params.insert("id".into(), Value::String(id));
            } else {
                params.insert("all_read".into(), Value::Bool(true));
            }
            "notification.dismiss"
        }
        "mark-notification-read" => {
            let id = option_value(&arguments, "--id");
            let workspace = option_value(&arguments, "--workspace");
            let all = arguments.iter().any(|argument| argument == "--all");
            if [id.is_some(), workspace.is_some(), all].into_iter().filter(|value| *value).count()
                != 1
            {
                return Err(CliError::Usage(
                    "mark-notification-read requires exactly one selector: --id, --workspace, or --all".into(),
                ));
            }
            params.clear();
            if let Some(id) = id {
                params.insert("id".into(), Value::String(id));
            } else if let Some(workspace) = workspace {
                params.insert("tab_id".into(), Value::String(workspace));
                if let Some(surface) = option_value(&arguments, "--surface") {
                    params.insert("surface_id".into(), Value::String(surface));
                }
            } else {
                params.insert("all".into(), Value::Bool(true));
            }
            "notification.mark_read"
        }
        "open-notification" => {
            let id = option_value(&arguments, "--id")
                .ok_or_else(|| CliError::Usage("open-notification requires --id".into()))?;
            params.clear();
            params.insert("id".into(), Value::String(id));
            "notification.open"
        }
        "jump-to-unread" => {
            if !arguments.is_empty() {
                return Err(CliError::Usage("jump-to-unread accepts no arguments".into()));
            }
            params.clear();
            "notification.jump_to_unread"
        }
        "open-browser" => {
            let url = trailing_text(&arguments, "open-browser")?;
            params.insert("url".into(), Value::String(url));
            "browser.open_split"
        }
        "navigate" => {
            let url = trailing_text(&arguments, "navigate")?;
            params.insert("url".into(), Value::String(url));
            "browser.navigate"
        }
        "browser-back" => "browser.back",
        "browser-forward" => "browser.forward",
        "browser-reload" => "browser.reload",
        "get-url" => "browser.url.get",
        "focus-webview" => "browser.focus_webview",
        "is-webview-focused" => "browser.is_webview_focused",
        "auth" | "login" | "logout" => {
            params.clear();
            let subcommand = if command == "auth" {
                arguments.first().map(String::as_str).unwrap_or("status")
            } else {
                command
            };
            match subcommand {
                "status" => "auth.status",
                "login" => "auth.begin_sign_in",
                "logout" => "auth.sign_out",
                other => {
                    return Err(CliError::Usage(format!("auth: unknown subcommand '{other}'")));
                }
            }
        }
        "new-workspace" => {
            // Keep the legacy command on the v2 resource API. The Swift CLI
            // sends the same fields and then writes --command to the new
            // workspace after creation.
            params.clear();
            let workspace_args = arguments.as_slice();
            if let Some(cwd) = option_value(workspace_args, "--cwd") {
                params.insert("cwd".into(), Value::String(cwd));
            }
            if let Some(title) = option_value(workspace_args, "--name") {
                params.insert("title".into(), Value::String(title));
            }
            if let Some(description) = option_value(workspace_args, "--description") {
                params.insert("description".into(), Value::String(description));
            }
            if let Some(group) = option_value(workspace_args, "--group") {
                params.insert("group_id".into(), Value::String(group));
            }
            if let Some(placement) = option_value(workspace_args, "--group-placement") {
                params.insert("group_placement".into(), Value::String(placement));
            }
            if let Some(reference) = option_value(workspace_args, "--group-reference") {
                params.insert("group_reference_workspace_id".into(), Value::String(reference));
            }
            if let Some(layout) = option_value(workspace_args, "--layout") {
                let layout = serde_json::from_str::<Value>(&layout).map_err(|error| {
                    CliError::Usage(format!(
                        "new-workspace: --layout value must be valid JSON: {error}"
                    ))
                })?;
                if !layout.is_object() {
                    return Err(CliError::Usage(
                        "new-workspace: --layout value must be a JSON object".into(),
                    ));
                }
                params.insert("layout".into(), layout);
            }
            if let Some(window) = option_value(workspace_args, "--window") {
                params.insert("window_id".into(), Value::String(window));
            } else if let Some(window) = options.window.clone() {
                params.insert("window_id".into(), Value::String(window));
            }
            if let Some(focus) = option_value(workspace_args, "--focus") {
                params.insert("focus".into(), parse_bool(&focus, "--focus")?);
            }
            let command_text = option_value(workspace_args, "--command");
            let result = socket(&options)?.send_v2("workspace.create", Value::Object(params))?;
            let result = format_ids(result, &id_format);
            if !json_output {
                let handle = result
                    .get("workspace_ref")
                    .or_else(|| result.get("workspace_id"))
                    .or_else(|| result.get("workspace"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if handle.is_empty() {
                    print_result(&result, false);
                } else {
                    println!("OK {handle}");
                }
            } else {
                print_result(&result, true);
            }
            if let Some(command_text) = command_text {
                let workspace_id = result
                    .get("workspace_ref")
                    .or_else(|| result.get("workspace_id"))
                    .or_else(|| result.get("workspace"))
                    .cloned()
                    .unwrap_or(Value::Null);
                if !workspace_id.is_null() {
                    let mut send_params = serde_json::Map::new();
                    send_params.insert("workspace_id".into(), workspace_id);
                    send_params.insert(
                        "text".into(),
                        Value::String(unescape_send_text(&(command_text + "\\n"))),
                    );
                    let _ = socket(&options)?
                        .send_v2("surface.send_text", Value::Object(send_params))?;
                }
            }
            return Ok(());
        }
        "close-workspace" | "select-workspace" | "rename-workspace" => {
            let workspace = option_value(&arguments, "--workspace")
                .or_else(|| env::var("CMUX_WORKSPACE_ID").ok());
            if command != "rename-workspace" && workspace.is_none() {
                return Err(CliError::Usage(format!("{command} requires --workspace")));
            }
            params.clear();
            if let Some(window) =
                option_value(&arguments, "--window").or_else(|| options.window.clone())
            {
                params.insert("window_id".into(), Value::String(window));
            }
            if let Some(workspace) = workspace {
                params.insert("workspace_id".into(), Value::String(workspace));
            }
            let method = match command {
                "close-workspace" => "workspace.close",
                "select-workspace" => "workspace.select",
                "rename-workspace" => {
                    let title = option_value(&arguments, "--title").or_else(|| {
                        let mut values = Vec::new();
                        let mut index = 0;
                        while index < arguments.len() {
                            if arguments[index] == "--" {
                                values.extend(arguments[index + 1..].iter().cloned());
                                break;
                            }
                            if arguments[index].starts_with("--") {
                                index += 2;
                            } else {
                                values.push(arguments[index].clone());
                                index += 1;
                            }
                        }
                        (!values.is_empty()).then(|| values.join(" "))
                    });
                    let title =
                        title.filter(|value| !value.trim().is_empty()).ok_or_else(|| {
                            CliError::Usage("rename-workspace requires a title".into())
                        })?;
                    params.insert("title".into(), Value::String(title));
                    "workspace.rename"
                }
                _ => unreachable!(),
            };
            let result =
                format_ids(socket(&options)?.send_v2(method, Value::Object(params))?, &id_format);
            print_result(&result, json_output);
            return Ok(());
        }
        "new-pane" | "new-surface" => {
            if let Some(window) =
                option_value(&arguments, "--window").or_else(|| options.window.clone())
            {
                params.insert("window_id".into(), Value::String(window));
            }
            if let Some(workspace) = option_value(&arguments, "--workspace")
                .or_else(|| env::var("CMUX_WORKSPACE_ID").ok())
            {
                params.insert("workspace_id".into(), Value::String(workspace));
            }
            if let Some(kind) = option_value(&arguments, "--type") {
                params.insert("type".into(), Value::String(kind));
            }
            if let Some(direction) = option_value(&arguments, "--direction") {
                params.insert("direction".into(), Value::String(direction));
            }
            if let Some(url) = option_value(&arguments, "--url") {
                params.insert("url".into(), Value::String(url));
            }
            if let Some(placement) = option_value(&arguments, "--placement") {
                params.insert("placement".into(), Value::String(placement));
            }
            if let Some(pane) = option_value(&arguments, "--pane") {
                params.insert("pane_id".into(), Value::String(pane));
            }
            if let Some(provider) = option_value(&arguments, "--provider") {
                params.insert("provider_id".into(), Value::String(provider));
            }
            if let Some(renderer) = option_value(&arguments, "--renderer") {
                params.insert("renderer_kind".into(), Value::String(renderer));
            }
            if let Some(cwd) = option_value(&arguments, "--working-directory")
                .or_else(|| option_value(&arguments, "--cwd"))
            {
                params.insert("working_directory".into(), Value::String(cwd));
            }
            if let Some(focus) = option_value(&arguments, "--focus") {
                params.insert("focus".into(), parse_bool(&focus, "--focus")?);
            }
            let method = if command == "new-pane" { "pane.create" } else { "surface.create" };
            let result =
                format_ids(socket(&options)?.send_v2(method, Value::Object(params))?, &id_format);
            print_result(&result, json_output);
            return Ok(());
        }
        "close-surface" => "surface.close",
        "surface-health" => "surface.health",
        "debug-terminals" => "debug.terminals",
        "trigger-flash" => "surface.trigger_flash",
        _ => unreachable!("parser only creates known socket commands"),
    };
    if command == "read-screen" {
        let scrollback = arguments.iter().any(|argument| argument == "--scrollback");
        if scrollback {
            params.insert("scrollback".into(), Value::Bool(true));
        }
        if let Some(lines) = option_value(&arguments, "--lines") {
            let lines = lines.parse::<u64>().map_err(|_| {
                CliError::Usage("read-screen: --lines must be greater than 0".into())
            })?;
            if lines == 0 {
                return Err(CliError::Usage("read-screen: --lines must be greater than 0".into()));
            }
            params.insert("lines".into(), Value::Number(lines.into()));
            params.insert("scrollback".into(), Value::Bool(true));
        }
    }
    let result = socket(&options)?.send_v2(method, Value::Object(params))?;
    let result = format_ids(result, &id_format);
    if (command == "auth" || command == "login" || command == "logout") && !json_output {
        if command == "logout"
            || (command == "auth" && arguments.first().map(String::as_str) == Some("logout"))
        {
            println!("Signed out.");
        } else if result.get("signed_in").and_then(Value::as_bool) == Some(true) {
            println!("Signed in.");
            if let Some(email) = result.pointer("/user/email").and_then(Value::as_str) {
                println!("  email:    {email}");
            }
        } else {
            println!("Not signed in.");
        }
    } else if command == "get-url" && !json_output {
        println!("{}", result.get("url").and_then(Value::as_str).unwrap_or_default());
    } else if command == "is-webview-focused" && !json_output {
        println!("{}", result.get("focused").and_then(Value::as_bool).unwrap_or(false));
    } else if command == "read-screen" && !json_output {
        println!("{}", result.get("text").and_then(Value::as_str).unwrap_or_default());
    } else {
        print_result(&result, json_output);
    }
    Ok(())
}

/// Execute the high-value browser namespace commands. The Swift CLI has a
/// larger browser surface; this function keeps the common automation verbs on
/// the same v2 methods so agents can use the bundled CLI without a second
/// browser client.
fn run_browser_command(
    arguments: Vec<String>,
    options: GlobalOptions,
    json_output: bool,
) -> Result<(), CliError> {
    let verbs_without_surface = [
        "open",
        "open-split",
        "new",
        "navigate",
        "goto",
        "back",
        "forward",
        "reload",
        "snapshot",
        "eval",
        "wait",
        "click",
        "dblclick",
        "hover",
        "focus",
        "check",
        "uncheck",
        "scroll-into-view",
        "scrollintoview",
        "fill",
        "type",
        "press",
        "key",
        "keydown",
        "keyup",
        "url",
        "get-url",
        "focus-webview",
        "is-webview-focused",
    ];
    let mut command_args = arguments;
    let mut positional_surface = if command_args.first().is_some_and(|value| {
        !value.starts_with('-')
            && !verbs_without_surface.contains(&value.to_ascii_lowercase().as_str())
    }) {
        Some(command_args.remove(0))
    } else {
        None
    };
    let subcommand = command_args
        .first()
        .map(|value| value.to_ascii_lowercase())
        .ok_or_else(|| CliError::Usage("browser requires a subcommand".into()))?;
    let mut rest = command_args[1..].to_vec();
    if positional_surface.is_none()
        && option_value(&rest, "--surface").is_none()
        && rest.first().is_some_and(|value| {
            !value.starts_with('-')
                && !verbs_without_surface.contains(&value.to_ascii_lowercase().as_str())
        })
    {
        positional_surface = Some(rest.remove(0));
    }
    let mut params = context_params(&rest, &options)?;
    if let Some(surface) = positional_surface.or_else(|| option_value(&rest, "--surface")) {
        params.insert("surface_id".into(), Value::String(surface));
    }
    let surface_required = || {
        params
            .get("surface_id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
            .ok_or_else(|| {
                CliError::Usage(format!(
                    "browser {subcommand} requires a surface handle (use --surface <id>)"
                ))
            })
    };
    let has_flag = |name: &str| rest.iter().any(|value| value == name);
    let positional_values = |values: &[String], value_flags: &[&str]| {
        let mut result = Vec::new();
        let mut index = 0;
        while index < values.len() {
            let value = &values[index];
            if value == "--" {
                result.extend(values[index + 1..].iter().cloned());
                break;
            }
            if value_flags.contains(&value.as_str()) {
                index += 2;
            } else if value.starts_with("--") {
                index += 1;
            } else {
                result.push(value.clone());
                index += 1;
            }
        }
        result
    };
    let send = |method: &str, params: serde_json::Map<String, Value>| -> Result<Value, CliError> {
        let result = socket(&options)?.send_v2(method, Value::Object(params))?;
        let result = format_ids(result, options.id_format.as_deref().unwrap_or("refs"));
        print_result(&result, json_output);
        Ok(result)
    };

    match subcommand.as_str() {
        "open" | "open-split" | "new" => {
            let url =
                positional_values(&rest, &["--workspace", "--window", "--focus", "--profile"])
                    .join(" ");
            if !url.trim().is_empty() {
                params.insert("url".into(), Value::String(url));
            }
            if let Some(profile) = option_value(&rest, "--profile") {
                params.insert("profile".into(), Value::String(profile));
            }
            if let Some(focus) = option_value(&rest, "--focus") {
                params.insert("focus".into(), parse_bool(&focus, "--focus")?);
            }
            let _ = send("browser.open_split", params)?;
        }
        "navigate" | "goto" => {
            let surface = surface_required()?;
            let url = positional_values(&rest, &["--workspace", "--window"]).join(" ");
            if url.trim().is_empty() {
                return Err(CliError::Usage(format!("browser {subcommand} requires a URL")));
            }
            params.insert("surface_id".into(), Value::String(surface));
            params.insert("url".into(), Value::String(url));
            if has_flag("--snapshot-after") {
                params.insert("snapshot_after".into(), Value::Bool(true));
            }
            let _ = send("browser.navigate", params)?;
        }
        "back" | "forward" | "reload" => {
            let surface = surface_required()?;
            params.insert("surface_id".into(), Value::String(surface));
            if has_flag("--snapshot-after") {
                params.insert("snapshot_after".into(), Value::Bool(true));
            }
            let method = match subcommand.as_str() {
                "back" => "browser.back",
                "forward" => "browser.forward",
                _ => "browser.reload",
            };
            let _ = send(method, params)?;
        }
        "url" | "get-url" => {
            let surface = surface_required()?;
            params.insert("surface_id".into(), Value::String(surface));
            let result = socket(&options)?.send_v2("browser.url.get", Value::Object(params))?;
            let result = format_ids(result, options.id_format.as_deref().unwrap_or("refs"));
            if json_output {
                print_result(&result, true);
            } else {
                println!("{}", result.get("url").and_then(Value::as_str).unwrap_or_default());
            }
        }
        "focus-webview" | "is-webview-focused" => {
            let surface = surface_required()?;
            params.insert("surface_id".into(), Value::String(surface));
            let method = if subcommand == "focus-webview" {
                "browser.focus_webview"
            } else {
                "browser.is_webview_focused"
            };
            let result = socket(&options)?.send_v2(method, Value::Object(params))?;
            let result = format_ids(result, options.id_format.as_deref().unwrap_or("refs"));
            if json_output {
                print_result(&result, true);
            } else if subcommand == "is-webview-focused" {
                println!("{}", result.get("focused").and_then(Value::as_bool).unwrap_or(false));
            } else {
                print_result(&result, false);
            }
        }
        "snapshot" => {
            let surface = surface_required()?;
            params.insert("surface_id".into(), Value::String(surface));
            if let Some(selector) = option_value(&rest, "--selector") {
                params.insert("selector".into(), Value::String(selector));
            }
            for flag in ["--interactive", "-i", "--cursor", "--compact"] {
                if has_flag(flag) {
                    let key =
                        if flag == "-i" { "interactive" } else { flag.trim_start_matches('-') };
                    params.insert(key.into(), Value::Bool(true));
                }
            }
            if let Some(depth) = option_value(&rest, "--max-depth") {
                let depth = depth.parse::<u64>().map_err(|_| {
                    CliError::Usage("--max-depth must be a non-negative integer".into())
                })?;
                params.insert("max_depth".into(), Value::Number(depth.into()));
            }
            let result = socket(&options)?.send_v2("browser.snapshot", Value::Object(params))?;
            let result = format_ids(result, options.id_format.as_deref().unwrap_or("refs"));
            if json_output {
                print_result(&result, true);
            } else {
                println!(
                    "{}",
                    result.get("snapshot").and_then(Value::as_str).unwrap_or("Empty page")
                );
            }
        }
        "eval" => {
            let surface = surface_required()?;
            let script = option_value(&rest, "--script")
                .or_else(|| Some(positional_values(&rest, &["--workspace", "--window"]).join(" ")))
                .filter(|value| !value.trim().is_empty())
                .ok_or_else(|| CliError::Usage("browser eval requires a script".into()))?;
            params.insert("surface_id".into(), Value::String(surface));
            params.insert("script".into(), Value::String(script));
            let _ = send("browser.eval", params)?;
        }
        "wait" => {
            let surface = surface_required()?;
            params.insert("surface_id".into(), Value::String(surface));
            if let Some(selector) = option_value(&rest, "--selector") {
                params.insert("selector".into(), Value::String(selector));
            } else if let Some(selector) =
                positional_values(&rest, &["--workspace", "--window"]).first().cloned()
            {
                params.insert("selector".into(), Value::String(selector));
            }
            for (flag, key) in [
                ("--text", "text_contains"),
                ("--url", "url_contains"),
                ("--url-contains", "url_contains"),
                ("--load-state", "load_state"),
                ("--function", "function"),
            ] {
                if let Some(value) = option_value(&rest, flag) {
                    params.insert(key.into(), Value::String(value));
                }
            }
            if let Some(timeout) = option_value(&rest, "--timeout-ms") {
                let timeout = timeout
                    .parse::<u64>()
                    .map_err(|_| CliError::Usage("--timeout-ms must be an integer".into()))?;
                params.insert("timeout_ms".into(), Value::Number(timeout.into()));
            } else if let Some(timeout) = option_value(&rest, "--timeout") {
                let timeout = timeout
                    .parse::<f64>()
                    .map_err(|_| CliError::Usage("--timeout must be a number".into()))?;
                if !timeout.is_finite() || timeout < 0.0 {
                    return Err(CliError::Usage("--timeout must be a number".into()));
                }
                let timeout_ms = (timeout * 1000.0).max(1.0) as u64;
                params.insert("timeout_ms".into(), Value::Number(timeout_ms.into()));
            }
            let _ = send("browser.wait", params)?;
        }
        "click" | "dblclick" | "hover" | "focus" | "check" | "uncheck" | "scroll-into-view"
        | "scrollintoview" => {
            let surface = surface_required()?;
            let selector = option_value(&rest, "--selector")
                .or_else(|| positional_values(&rest, &["--workspace", "--window"]).first().cloned())
                .ok_or_else(|| {
                    CliError::Usage(format!("browser {subcommand} requires a selector"))
                })?;
            params.insert("surface_id".into(), Value::String(surface));
            params.insert("selector".into(), Value::String(selector));
            if has_flag("--snapshot-after") {
                params.insert("snapshot_after".into(), Value::Bool(true));
            }
            let method = match subcommand.as_str() {
                "click" => "browser.click",
                "dblclick" => "browser.dblclick",
                "hover" => "browser.hover",
                "focus" => "browser.focus",
                "check" => "browser.check",
                "uncheck" => "browser.uncheck",
                _ => "browser.scroll_into_view",
            };
            let _ = send(method, params)?;
        }
        "fill" | "type" => {
            let surface = surface_required()?;
            let values =
                positional_values(&rest, &["--workspace", "--window", "--selector", "--text"]);
            let selector = option_value(&rest, "--selector").or_else(|| values.first().cloned());
            let selector = selector.ok_or_else(|| {
                CliError::Usage(format!("browser {subcommand} requires a selector"))
            })?;
            let text = option_value(&rest, "--text")
                .or_else(|| {
                    if option_value(&rest, "--selector").is_some() {
                        (!values.is_empty()).then(|| values.join(" "))
                    } else {
                        (values.len() > 1).then(|| values[1..].join(" "))
                    }
                })
                .unwrap_or_default();
            if subcommand == "type" && text.is_empty() {
                return Err(CliError::Usage("browser type requires text".into()));
            }
            params.insert("surface_id".into(), Value::String(surface));
            params.insert("selector".into(), Value::String(selector));
            params.insert("text".into(), Value::String(text));
            if has_flag("--snapshot-after") {
                params.insert("snapshot_after".into(), Value::Bool(true));
            }
            let method = if subcommand == "type" { "browser.type" } else { "browser.fill" };
            let _ = send(method, params)?;
        }
        "press" | "key" | "keydown" | "keyup" => {
            let surface = surface_required()?;
            let key = option_value(&rest, "--key")
                .or_else(|| positional_values(&rest, &["--workspace", "--window"]).first().cloned())
                .ok_or_else(|| CliError::Usage(format!("browser {subcommand} requires a key")))?;
            params.insert("surface_id".into(), Value::String(surface));
            params.insert("key".into(), Value::String(key));
            if has_flag("--snapshot-after") {
                params.insert("snapshot_after".into(), Value::Bool(true));
            }
            let method = match subcommand.as_str() {
                "keydown" => "browser.keydown",
                "keyup" => "browser.keyup",
                _ => "browser.press",
            };
            let _ = send(method, params)?;
        }
        _ => return Err(CliError::Usage(format!("Unsupported browser subcommand: {subcommand}"))),
    }
    Ok(())
}

fn context_params(
    arguments: &[String],
    options: &GlobalOptions,
) -> Result<serde_json::Map<String, Value>, CliError> {
    let mut params = serde_json::Map::new();
    let workspace =
        option_value(arguments, "--workspace").or_else(|| env::var("CMUX_WORKSPACE_ID").ok());
    let surface = option_value(arguments, "--surface")
        .or_else(|| option_value(arguments, "--panel"))
        .or_else(|| env::var("CMUX_SURFACE_ID").ok());
    let window = option_value(arguments, "--window").or_else(|| options.window.clone());
    if let Some(window) = window {
        params.insert("window_id".into(), Value::String(window));
    }
    if let Some(workspace) = workspace {
        params.insert("workspace_id".into(), Value::String(workspace));
    }
    if let Some(surface) = surface {
        params.insert("surface_id".into(), Value::String(surface));
    }
    for name in [
        "--workspace",
        "--surface",
        "--panel",
        "--window",
        "--scrollback",
        "--lines",
        "--json",
        "--id-format",
    ] {
        reject_option(arguments, name)?;
    }
    Ok(params)
}

fn reject_option(arguments: &[String], name: &str) -> Result<(), CliError> {
    let mut index = 0;
    while index < arguments.len() {
        if arguments[index] == name {
            if arguments.get(index + 1).is_none() {
                return Err(CliError::Usage(format!("{name} requires a value")));
            }
            index += 2;
        } else {
            index += 1;
        }
    }
    Ok(())
}

fn trailing_text(arguments: &[String], command: &str) -> Result<String, CliError> {
    let mut index = 0;
    let mut values = Vec::new();
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--workspace" | "--surface" | "--panel" | "--window" | "--lines" => index += 2,
            value
                if value.starts_with("--workspace=")
                    || value.starts_with("--surface=")
                    || value.starts_with("--panel=")
                    || value.starts_with("--window=")
                    || value.starts_with("--lines=")
                    || value == "--scrollback" =>
            {
                index += 1;
            }
            "--" => {
                values.extend(arguments[index + 1..].iter().cloned());
                break;
            }
            value if value.starts_with('-') => {
                return Err(CliError::Usage(format!("{command}: unknown option '{value}'")));
            }
            value => {
                values.push(value.to_string());
                index += 1;
            }
        }
    }
    if values.is_empty() {
        return Err(CliError::Usage(format!("{command} requires text")));
    }
    Ok(values.join(" "))
}

fn trailing_key(arguments: &[String], command: &str) -> Result<String, CliError> {
    let key = arguments
        .iter()
        .rev()
        .find(|argument| !argument.starts_with('-'))
        .cloned()
        .ok_or_else(|| CliError::Usage(format!("{command} requires a key")))?;
    Ok(key)
}

fn unescape_send_text(value: &str) -> String {
    value.replace("\\n", "\n").replace("\\r", "\r").replace("\\t", "\t").replace("\\\\", "\\")
}

fn parse_rpc(args: &[String]) -> Result<CommandLine, CliError> {
    let method = args
        .first()
        .filter(|value| !value.is_empty())
        .cloned()
        .ok_or_else(|| CliError::Usage("rpc requires a method".into()))?;
    let params = match args.get(1) {
        Some(raw) => serde_json::from_str(raw)
            .map_err(|error| CliError::Usage(format!("rpc params are not valid JSON: {error}")))?,
        None => json!({}),
    };
    if args.len() > 2 {
        return Err(CliError::Usage("rpc accepts one JSON params object".into()));
    }
    Ok(CommandLine::Rpc { method, params })
}

fn usage(program: Program) -> &'static str {
    match program {
        Program::Cmux => {
            "cmux - control cmux via Unix socket\n\nUsage:\n  cmux [global-options] <command> [options]\n\nCommands:\n  cr <coderouter-args...>       Run CodeRouter\n  coderouter <args...>          Run CodeRouter\n  ai-accounts <list|upload|remove>\n  capabilities [--json|--offline] Describe available operations\n  context [--json]              Describe current agent context\n  ping                          Check the running cmux socket\n  identify [options]            Describe the caller and target\n  list-windows [--json]         List cmux windows\n  current-window [--json]       Print the current window\n  new-window                    Create a window\n  focus-window --window <id>    Focus a window\n  close-window --window <id>    Close a window\n  list-workspaces [--json]      List workspaces\n  current-workspace [--json]    Print the current workspace\n  new-workspace [options]       Create a workspace\n  close-workspace --workspace <id>\n  select-workspace --workspace <id>\n  rename-workspace [options]    Rename a workspace\n  list-panes [--json]           List panes\n  list-pane-surfaces [--json]   List surfaces in a pane\n  list-panels [--json]          List surfaces\n  new-pane [options]            Create a pane\n  new-surface [options]         Create a surface\n  read-screen [options]         Read terminal text\n  send [options] <text>         Send text to a terminal\n  send-key [options] <key>      Send a key to a terminal\n  notify [options]               Create or clear a notification\n  list-notifications [--json]    List notifications\n  dismiss-notification [options]\n  mark-notification-read [options]\n  open-notification --id <id>\n  jump-to-unread\n  open-browser <url>            Open a browser surface\n  browser <surface> <command>   Browser automation namespace\n  navigate --surface <id> <url> Navigate a browser surface\n  browser-back --surface <id>\n  browser-forward --surface <id>\n  browser-reload --surface <id>\n  get-url --surface <id>     Read a browser URL\n  focus-webview --surface <id>\n  is-webview-focused --surface <id>\n  close-surface --surface <id>\n  surface-health [--surface <id>]\n  debug-terminals\n  trigger-flash [--surface <id>]\n  refresh-surfaces\n  reload-config\n  set-app-focus <true|false>\n  simulate-app-active\n  auth [status|login|logout]\n  rpc <method> [json]            Send a v2 socket request\n  version                        Print the CLI version\n\nGlobal options:\n  --socket <path>                Override the cmux Unix socket\n  --password <value>             Authenticate to a password-protected socket\n  --id-format <refs|uuids|both>  Select identifier rendering\n  --window <id>                  Select a target window\n  --json                         Print JSON results\n  -h, --help                     Print this help\n  -v, --version                  Print the version"
        }
        Program::CodeRouter => {
            "coderouter - CodeRouter CLI shipped with cmux\n\nUsage:\n  coderouter [command] [options]\n\nWhen launched beside cmux, the bundled CodeRouter executable receives a\nshort-lived broker configuration from the same cmux session. No second\nauthentication flow is used."
        }
    }
}

fn run_coderouter(
    args: Vec<String>,
    options: GlobalOptions,
    program: Program,
    cmux_alias: bool,
) -> Result<(), CliError> {
    // `cr add codex` is a cmux-native path. The app reads ~/.codex/auth.json,
    // refreshes the existing cmux session, and uploads the credential. This
    // avoids a second login and keeps OAuth tokens out of argv and the socket.
    if cmux_alias
        && args.first().map(String::as_str) == Some("add")
        && args.get(1).map(String::as_str) == Some("codex")
    {
        let mut params = json!({"provider": "codex"});
        let json_output = apply_coderouter_codex_options(&mut params, &args[2..], options.json)?;
        let result = socket(&options)?.send_v2("aiAccounts.upload", params)?;
        if json_output {
            print_result(&result, true);
        } else {
            print_upload_result(&result, "codex");
        }
        return Ok(());
    }

    exec_real_coderouter(args, &options, program == Program::Cmux)
}

fn apply_coderouter_codex_options(
    params: &mut Value,
    args: &[String],
    mut json_output: bool,
) -> Result<bool, CliError> {
    let mut index = 0;
    while index < args.len() {
        if args[index] == "--label" || args[index] == "--team" {
            let value = args.get(index + 1).ok_or_else(|| {
                CliError::Usage(format!("cr add codex: {} requires a value", args[index]))
            })?;
            let key = if args[index] == "--team" { "teamId" } else { "label" };
            params[key] = Value::String(value.clone());
            index += 2;
        } else if args[index] == "--json" {
            json_output = true;
            index += 1;
        } else if args[index] == "--validate" {
            params["validate"] = Value::Bool(true);
            index += 1;
        } else if args[index].starts_with('-') {
            return Err(CliError::Usage(format!("cr add codex: unknown flag '{}'", args[index])));
        } else {
            return Err(CliError::Usage(format!(
                "cr add codex: unexpected argument '{}'",
                args[index]
            )));
        }
    }
    Ok(json_output)
}

fn exec_real_coderouter(
    args: Vec<String>,
    options: &GlobalOptions,
    use_cmux_broker: bool,
) -> Result<(), CliError> {
    let current_exe = env::current_exe().ok();
    let candidates = [
        env::var_os("CMUX_CODEROUTER_PATH").map(PathBuf::from),
        env::current_exe()
            .ok()
            .and_then(|path| path.parent().map(|parent| parent.join("coderouter-bin"))),
        find_in_path("coderouter"),
        find_in_path("cr"),
    ];
    let path = candidates
        .into_iter()
        .flatten()
        .find(|path| path.is_file() && current_exe.as_ref().is_none_or(|current| current != path))
        .ok_or_else(|| {
            CliError::Exit(127, "Required CLI not found. Install the command and retry.".into())
        })?;
    let broker_available = socket_path(options).is_some_and(|path| path.exists());
    let should_try_broker =
        env::var_os("CODEROUTER_DATA_DIR").is_none() && (use_cmux_broker || broker_available);
    let broker_dir = if should_try_broker { Some(issue_broker_directory(options)?) } else { None };
    let mut command = Command::new(&path);
    command.args(args).env_clear().envs(
        env::vars().filter(|(key, _)| !key.starts_with("CMUX_") && !key.starts_with("CMUXD_")),
    );
    if let Some(directory) = &broker_dir {
        command.env("CODEROUTER_DATA_DIR", directory);
    }
    let status = match command.status() {
        Ok(status) => status,
        Err(error) => {
            if let Some(directory) = broker_dir {
                cleanup_broker_directory(directory)?;
            }
            return Err(CliError::Exit(127, format!("Could not start the required CLI: {error}")));
        }
    };
    if let Some(directory) = broker_dir {
        cleanup_broker_directory(directory)?;
    }
    let code = exit_code(status);
    if code == 0 { Ok(()) } else { Err(CliError::Exit(code, String::new())) }
}

fn issue_broker_directory(options: &GlobalOptions) -> Result<PathBuf, CliError> {
    let result = socket(options)?.send_v2("coderouter.broker_config", json!({}))?;
    let path = result
        .get("data_dir")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .filter(|path| path.is_dir())
        .ok_or_else(|| {
            CliError::Exit(127, "CodeRouter broker returned no temporary data directory.".into())
        })?;
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or_default();
    let expected_parent = env::temp_dir();
    if path.parent() != Some(expected_parent.as_path())
        || !name.starts_with("cmux-coderouter-broker-")
        || !path.join("coderouter/config.json").is_file()
    {
        return Err(CliError::Exit(
            127,
            "CodeRouter broker returned an invalid temporary data directory.".into(),
        ));
    }
    Ok(path)
}

fn cleanup_broker_directory(path: PathBuf) -> Result<(), CliError> {
    if !path.exists() {
        return Ok(());
    }
    std::fs::remove_dir_all(&path).map_err(|error| {
        CliError::Runtime(format!(
            "Could not remove temporary CodeRouter broker directory {}: {error}",
            path.display()
        ))
    })
}

fn find_in_path(name: &str) -> Option<PathBuf> {
    env::var_os("PATH")?
        .to_str()?
        .split(':')
        .map(Path::new)
        .map(|path| path.join(name))
        .find(|path| path.is_file())
}

fn exit_code(status: ExitStatus) -> i32 {
    status.code().unwrap_or(1)
}

fn run_ai_accounts(args: Vec<String>, options: GlobalOptions) -> Result<(), CliError> {
    let sub = args.first().map(String::as_str).unwrap_or("list");
    let mut params = json!({});
    match sub {
        "upload" => {
            let provider = args
                .get(1)
                .ok_or_else(|| CliError::Usage("ai-accounts upload requires a provider".into()))?;
            params["provider"] = Value::String(provider.clone());
            apply_common_options(&mut params, &args[2..])?;
            let result = socket(&options)?.send_v2("aiAccounts.upload", params)?;
            print_result(&result, options.json);
        }
        "list" | "ls" => {
            apply_common_options(&mut params, &args[1..])?;
            let result = socket(&options)?.send_v2("aiAccounts.list", params)?;
            print_result(&result, options.json);
        }
        "remove" | "rm" | "delete" => {
            let id = args.get(1).ok_or_else(|| {
                CliError::Usage("ai-accounts remove requires an account id".into())
            })?;
            params["id"] = Value::String(id.clone());
            apply_common_options(&mut params, &args[2..])?;
            let result = socket(&options)?.send_v2("aiAccounts.remove", params)?;
            print_result(&result, options.json);
        }
        "help" | "--help" | "-h" => println!("Usage: cmux ai-accounts <list|upload|remove>"),
        other => return Err(CliError::Usage(format!("Unknown ai-accounts subcommand: {other}"))),
    }
    Ok(())
}

fn print_upload_result(response: &Value, fallback_provider: &str) {
    let account = response.get("account").unwrap_or(response);
    let kind = account
        .get("kind")
        .or_else(|| account.get("provider"))
        .and_then(Value::as_str)
        .unwrap_or(fallback_provider);
    println!("OK uploaded {}", sanitize_terminal(kind));
    if let Some(id) = account.get("id").and_then(Value::as_str) {
        println!("  id:    {}", sanitize_terminal(id));
    }
    if let Some(label) =
        account.get("label").and_then(Value::as_str).filter(|value| !value.is_empty())
    {
        println!("  label: {}", sanitize_terminal(label));
    }
}

fn sanitize_terminal(value: &str) -> String {
    value
        .chars()
        .map(|character| if character.is_control() { '\u{FFFD}' } else { character })
        .collect()
}

fn apply_common_options(params: &mut Value, args: &[String]) -> Result<(), CliError> {
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--team" | "--label" | "--key" => {
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| CliError::Usage(format!("{} requires a value", args[index])))?;
                let key = match args[index].as_str() {
                    "--team" => "teamId",
                    "--label" => "label",
                    "--key" => "key",
                    _ => unreachable!("option handled above"),
                };
                params[key] = Value::String(value.clone());
                index += 2;
            }
            "--validate" => {
                params["validate"] = Value::Bool(true);
                index += 1;
            }
            other => return Err(CliError::Usage(format!("unknown flag '{other}'"))),
        }
    }
    Ok(())
}

fn print_result(value: &Value, json_output: bool) {
    if json_output {
        println!("{}", serde_json::to_string(value).unwrap_or_else(|_| "{}".into()));
    } else if let Some(message) = value.get("message").and_then(Value::as_str) {
        println!("{message}");
    } else {
        println!("{}", serde_json::to_string_pretty(value).unwrap_or_else(|_| "{}".into()));
    }
}

fn socket(options: &GlobalOptions) -> Result<SocketClient, CliError> {
    let path = socket_path(options)
        .ok_or_else(|| CliError::Runtime("Could not determine the cmux socket path".into()))?;
    SocketClient::connect(path, options.password.clone())
}

fn socket_password_file() -> Option<String> {
    socket_password_file_for_home(env::var_os("HOME"))
}

fn socket_password_file_for_home(home: Option<std::ffi::OsString>) -> Option<String> {
    let home = home?;
    let path = PathBuf::from(home).join(".local/state/cmux/socket-control-password");
    let value = std::fs::read_to_string(path).ok()?;
    let value = normalize_socket_password(value)?;
    Some(value)
}

fn socket_path(options: &GlobalOptions) -> Option<PathBuf> {
    if let Some(path) = options.socket.clone() {
        return Some(path);
    }
    if let Some(path) = env::var_os("CMUX_SOCKET_PATH").map(PathBuf::from) {
        return Some(path);
    }
    if let Some(path) = env::var_os("CMUX_SOCKET").map(PathBuf::from) {
        return Some(path);
    }
    let home = env::var_os("HOME").map(PathBuf::from);
    let state_directory = home.as_ref().map(|home| home.join(".local/state/cmux"));
    if let Some(path) = socket_marker_path(state_directory.as_deref()) {
        return Some(path);
    }
    state_directory
        .map(|path| path.join("cmux.sock"))
        .or_else(|| Some(PathBuf::from("/tmp/cmux.sock")))
}

fn socket_marker_path(state_directory: Option<&Path>) -> Option<PathBuf> {
    [
        state_directory.map(|path| path.join("last-socket-path")),
        Some(PathBuf::from("/tmp/cmux-last-socket-path")),
    ]
    .into_iter()
    .flatten()
    .find_map(|marker| {
        let value = std::fs::read_to_string(marker).ok()?;
        let value = value.trim_matches(|character| character == '\r' || character == '\n');
        (!value.trim().is_empty()).then(|| PathBuf::from(value))
    })
}

#[cfg(test)]
fn socket_path_from_environment(
    options: &GlobalOptions,
    socket_path: Option<std::ffi::OsString>,
    legacy_socket: Option<std::ffi::OsString>,
    home: Option<std::ffi::OsString>,
) -> Option<PathBuf> {
    options
        .socket
        .clone()
        .or_else(|| socket_path.map(PathBuf::from))
        .or_else(|| legacy_socket.map(PathBuf::from))
        .or_else(|| home.map(|home| PathBuf::from(home).join(".local/state/cmux/cmux.sock")))
        .or_else(|| Some(PathBuf::from("/tmp/cmux.sock")))
}

#[derive(Debug)]
struct SocketClient {
    stream: std::os::unix::net::UnixStream,
    password: Option<String>,
}

impl SocketClient {
    fn connect(path: PathBuf, password: Option<String>) -> Result<Self, CliError> {
        #[cfg(unix)]
        {
            let stream = std::os::unix::net::UnixStream::connect(&path).map_err(|error| {
                CliError::Runtime(format!(
                    "Failed to connect to socket at {}: {error}",
                    path.display()
                ))
            })?;
            stream.set_read_timeout(Some(DEFAULT_TIMEOUT)).ok();
            stream.set_write_timeout(Some(DEFAULT_TIMEOUT)).ok();
            Ok(Self { stream, password: resolve_socket_password(password, &path) })
        }
        #[cfg(not(unix))]
        {
            let _ = (path, password);
            Err(CliError::Runtime("Unix sockets are not supported on this platform".into()))
        }
    }

    fn send_v2(&self, method: &str, params: Value) -> Result<Value, CliError> {
        let mut stream =
            self.stream.try_clone().map_err(|error| CliError::Runtime(error.to_string()))?;
        authenticate_stream(&mut stream, self.password.as_deref())?;
        let request = json!({
            "id": Uuid::new_v4().to_string().to_uppercase(),
            "method": method,
            "params": params,
        });
        write_line(
            &mut stream,
            &serde_json::to_string(&request)
                .map_err(|error| CliError::Runtime(error.to_string()))?,
        )?;
        let raw = read_response(&mut stream)?;
        if raw.starts_with("ERROR:") {
            return Err(CliError::Runtime(raw));
        }
        let response: Value = serde_json::from_str(&raw)
            .map_err(|error| CliError::Runtime(format!("Invalid v2 response: {error}")))?;
        if response.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(response.get("result").cloned().unwrap_or_else(|| json!({})));
        }
        if let Some(error) = response.get("error") {
            let code = error.get("code").and_then(Value::as_str).unwrap_or("error");
            let message =
                error.get("message").and_then(Value::as_str).unwrap_or("Unknown v2 error");
            return Err(CliError::Runtime(format!("{code}: {message}")));
        }
        Err(CliError::Runtime("v2 request failed".into()))
    }

    fn send_v1(&self, command: &str) -> Result<String, CliError> {
        let mut stream =
            self.stream.try_clone().map_err(|error| CliError::Runtime(error.to_string()))?;
        authenticate_stream(&mut stream, self.password.as_deref())?;
        write_line(&mut stream, command)?;
        let response = read_response(&mut stream)?;
        if response.starts_with("ERROR:") {
            return Err(CliError::Runtime(response));
        }
        Ok(response)
    }
}

fn authenticate_stream(
    stream: &mut std::os::unix::net::UnixStream,
    password: Option<&str>,
) -> Result<(), CliError> {
    if let Some(password) = password {
        write_line(stream, &format!("auth {password}"))?;
        let auth = read_response(stream)?;
        if auth.starts_with("ERROR:") && !auth.contains("Unknown command 'auth'") {
            return Err(CliError::Runtime(auth));
        }
    }
    Ok(())
}

fn resolve_socket_password(explicit: Option<String>, socket_path: &Path) -> Option<String> {
    resolve_socket_password_from_sources(
        explicit,
        env::var("CMUX_SOCKET_PASSWORD").ok(),
        socket_password_file(),
        socket_password_keychain(Some(socket_path)),
    )
}

fn resolve_socket_password_from_sources(
    explicit: Option<String>,
    environment: Option<String>,
    file: Option<String>,
    keychain: Option<String>,
) -> Option<String> {
    explicit
        .and_then(normalize_socket_password)
        .or_else(|| environment.and_then(normalize_socket_password))
        .or_else(|| file.and_then(normalize_socket_password))
        .or_else(|| keychain.and_then(normalize_socket_password))
}

/// Reads the legacy password entry that older cmux versions stored in the
/// macOS login keychain. The password file remains authoritative when it
/// exists; this is only the final compatibility fallback.
fn socket_password_keychain(socket_path: Option<&Path>) -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        for service in keychain_services(socket_path) {
            if let Some(password) = security_framework::passwords::get_generic_password(
                &service,
                "local-socket-password",
            )
            .ok()
            .and_then(|value| String::from_utf8(value).ok())
            .and_then(normalize_socket_password)
            {
                return Some(password);
            }
        }
        None
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = socket_path;
        None
    }
}

#[cfg(target_os = "macos")]
fn keychain_services(socket_path: Option<&Path>) -> Vec<String> {
    const BASE: &str = "com.cmuxterm.app.socket-control";
    let scope =
        env::var("CMUX_TAG").ok().and_then(|value| sanitize_keychain_scope(&value)).or_else(|| {
            let name = socket_path?.file_name()?.to_str()?;
            ["cmux-debug-", "cmux-"].iter().find_map(|prefix| {
                name.strip_prefix(prefix)
                    .and_then(|value| value.strip_suffix(".sock"))
                    .and_then(sanitize_keychain_scope)
            })
        });
    scope.map_or_else(
        || vec![BASE.to_string()],
        |scope| vec![format!("{BASE}.{scope}"), BASE.to_string()],
    )
}

#[cfg(target_os = "macos")]
fn sanitize_keychain_scope(value: &str) -> Option<String> {
    let mut result = String::new();
    let mut previous_dot = false;
    for character in value.chars().flat_map(char::to_lowercase) {
        let allowed = character.is_ascii_alphanumeric() || matches!(character, '.' | '-');
        if allowed {
            result.push(character);
            previous_dot = false;
        } else if !previous_dot {
            result.push('.');
            previous_dot = true;
        }
    }
    let trimmed = result.trim_matches('.').to_string();
    (!trimmed.is_empty()).then_some(trimmed)
}

fn normalize_socket_password(value: String) -> Option<String> {
    let value = value.trim_matches(|character| character == '\r' || character == '\n').to_string();
    (!value.is_empty()).then_some(value)
}

fn write_line(stream: &mut std::os::unix::net::UnixStream, line: &str) -> Result<(), CliError> {
    stream
        .write_all(line.as_bytes())
        .map_err(|error| CliError::Runtime(format!("Failed to write to socket: {error}")))?;
    stream
        .write_all(b"\n")
        .map_err(|error| CliError::Runtime(format!("Failed to write to socket: {error}")))?;
    stream.flush().ok();
    Ok(())
}

fn read_response(stream: &mut std::os::unix::net::UnixStream) -> Result<String, CliError> {
    let mut bytes = Vec::new();
    let mut byte = [0_u8; 1];
    let mut saw_newline = false;
    loop {
        match stream.read(&mut byte) {
            Ok(0) if bytes.is_empty() => {
                return Err(CliError::Runtime("Socket closed before reply".into()));
            }
            Ok(0) => break,
            Ok(_) if byte[0] == b'\n' && !saw_newline => {
                saw_newline = true;
                stream.set_read_timeout(Some(Duration::from_millis(120))).ok();
            }
            Ok(_) if byte[0] == b'\n' => bytes.push(byte[0]),
            Ok(_) => bytes.push(byte[0]),
            Err(error)
                if saw_newline
                    && (error.kind() == std::io::ErrorKind::WouldBlock
                        || error.kind() == std::io::ErrorKind::TimedOut) =>
            {
                break;
            }
            Err(error) => {
                return Err(CliError::Runtime(format!("Socket read error: {error}")));
            }
        }
    }
    stream.set_read_timeout(Some(DEFAULT_TIMEOUT)).ok();
    while bytes.last() == Some(&b'\n') || bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    String::from_utf8(bytes).map_err(|_| CliError::Runtime("Invalid UTF-8 response".into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::os::unix::net::UnixListener;
    use std::thread;

    #[test]
    fn parses_native_coderouter_command() {
        let args = vec!["cr".into(), "add".into(), "codex".into(), "--label".into(), "work".into()];
        let (_, command) = parse_args(&args, Program::Cmux).unwrap();
        assert_eq!(command, CommandLine::Cr(args[1..].to_vec()));
    }

    #[test]
    fn parses_startup_and_window_commands() {
        let (_, ping) = parse_args(&["ping".into()], Program::Cmux).unwrap();
        assert_eq!(ping, CommandLine::Ping(Vec::new()));
        let (_, identify) =
            parse_args(&["identify".into(), "--no-caller".into()], Program::Cmux).unwrap();
        assert_eq!(identify, CommandLine::Identify(vec!["--no-caller".into()]));
        let (_, list) =
            parse_args(&["list-windows".into(), "--json".into()], Program::Cmux).unwrap();
        assert_eq!(list, CommandLine::ListWindows(vec!["--json".into()]));
        let (_, send) = parse_args(
            &["send".into(), "--surface".into(), "surface:1".into(), "hello".into()],
            Program::Cmux,
        )
        .unwrap();
        assert_eq!(
            send,
            CommandLine::SocketV2 {
                command: "send".into(),
                arguments: vec!["--surface".into(), "surface:1".into(), "hello".into()]
            }
        );
        let (_, notify) =
            parse_args(&["notify".into(), "--title".into(), "Build".into()], Program::Cmux)
                .unwrap();
        assert_eq!(
            notify,
            CommandLine::SocketV2 {
                command: "notify".into(),
                arguments: vec!["--title".into(), "Build".into()]
            }
        );
        let (_, navigate) = parse_args(
            &[
                "navigate".into(),
                "--surface".into(),
                "surface:1".into(),
                "https://example.com".into(),
            ],
            Program::Cmux,
        )
        .unwrap();
        assert_eq!(
            navigate,
            CommandLine::SocketV2 {
                command: "navigate".into(),
                arguments: vec![
                    "--surface".into(),
                    "surface:1".into(),
                    "https://example.com".into()
                ]
            }
        );
        let (_, focus) =
            parse_args(&["set-app-focus".into(), "true".into()], Program::Cmux).unwrap();
        assert_eq!(
            focus,
            CommandLine::LegacyV1 {
                command: "set_app_focus".into(),
                arguments: vec!["true".into()]
            }
        );
        let (_, auth) =
            parse_args(&["auth".into(), "status".into(), "--json".into()], Program::Cmux).unwrap();
        assert_eq!(
            auth,
            CommandLine::SocketV2 {
                command: "auth".into(),
                arguments: vec!["status".into(), "--json".into()]
            }
        );
        let (_, browser) = parse_args(
            &["browser".into(), "surface:1".into(), "snapshot".into(), "--interactive".into()],
            Program::Cmux,
        )
        .unwrap();
        assert_eq!(
            browser,
            CommandLine::SocketV2 {
                command: "browser".into(),
                arguments: vec!["surface:1".into(), "snapshot".into(), "--interactive".into()]
            }
        );
    }

    #[test]
    fn parses_workspace_and_surface_creation_commands() {
        for (name, expected) in [
            ("new-workspace", "new-workspace"),
            ("close-workspace", "close-workspace"),
            ("select-workspace", "select-workspace"),
            ("rename-workspace", "rename-workspace"),
            ("new-pane", "new-pane"),
            ("new-surface", "new-surface"),
        ] {
            let (_, command) =
                parse_args(&[name.into(), "--focus".into(), "true".into()], Program::Cmux).unwrap();
            assert_eq!(
                command,
                CommandLine::SocketV2 {
                    command: expected.into(),
                    arguments: vec!["--focus".into(), "true".into()]
                }
            );
        }
    }

    #[test]
    fn parses_boolean_flags_for_creation_commands() {
        assert_eq!(parse_bool("true", "--focus").unwrap(), Value::Bool(true));
        assert_eq!(parse_bool("0", "--focus").unwrap(), Value::Bool(false));
        assert!(parse_bool("maybe", "--focus").is_err());
    }

    #[test]
    fn standalone_coderouter_preserves_passthrough_arguments() {
        let args = vec!["status".into(), "--json".into()];
        let (_, command) = parse_args(&args, Program::CodeRouter).unwrap();
        assert_eq!(command, CommandLine::CodeRouter(args));
    }

    #[test]
    fn builds_codex_upload_request_without_credentials_in_argv() {
        let mut params = json!({"provider":"codex"});
        apply_coderouter_codex_options(&mut params, &["--label".into(), "work".into()], false)
            .unwrap();
        assert_eq!(params, json!({"provider":"codex","label":"work"}));
        assert!(!serde_json::to_string(&params).unwrap().contains("access_token"));
    }

    #[test]
    fn native_add_codex_uses_existing_socket_session() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("cmux.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let worker = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(line.trim()).unwrap();
            assert_eq!(request["method"], "aiAccounts.upload");
            assert_eq!(request["params"]["provider"], "codex");
            stream.write_all(b"{\"ok\":true,\"result\":{\"id\":\"acct_1\"}}\n").unwrap();
        });
        let stream = std::os::unix::net::UnixStream::connect(path).unwrap();
        let client = SocketClient { stream, password: None };
        let result = client.send_v2("aiAccounts.upload", json!({"provider":"codex"})).unwrap();
        assert_eq!(result["id"], "acct_1");
        worker.join().unwrap();
    }

    #[test]
    fn native_ping_uses_v1_command() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("cmux.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let worker = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
            assert_eq!(line.trim_end(), "ping");
            stream.write_all(b"PONG\n").unwrap();
        });
        let client = SocketClient::connect(path, None).unwrap();
        assert_eq!(client.send_v1("ping").unwrap(), "PONG");
        worker.join().unwrap();
    }

    #[test]
    fn parses_windows_v1_response_for_json_output() {
        let windows = parse_windows(
            "*0: win_1 selected_workspace=ws_1 workspaces=2\n1: win_2 selected_workspace=none workspaces=0",
        );
        assert_eq!(
            windows,
            vec![
                json!({
                    "index": 0,
                    "id": "win_1",
                    "key": true,
                    "workspace_count": 2,
                    "selected_workspace_id": "ws_1"
                }),
                json!({
                    "index": 1,
                    "id": "win_2",
                    "key": false,
                    "workspace_count": 0,
                    "selected_workspace_id": null
                })
            ]
        );
    }

    #[test]
    fn formats_identifier_pairs_for_refs_and_uuids() {
        let value = json!({
            "id": "uuid",
            "ref": "surface:1",
            "surface_id": "uuid",
            "surface_ref": "surface:1"
        });
        assert_eq!(
            format_ids(value.clone(), "refs"),
            json!({
                "ref": "surface:1",
                "surface_ref": "surface:1"
            })
        );
        assert_eq!(
            format_ids(value.clone(), "uuids"),
            json!({
                "id": "uuid",
                "surface_id": "uuid"
            })
        );
        assert_eq!(format_ids(value, "both")["id"], "uuid");
    }

    #[test]
    fn builds_surface_text_request_without_losing_context() {
        let options = GlobalOptions { json: true, ..GlobalOptions::default() };
        let params = context_params(
            &["--surface".into(), "surface:1".into(), "--workspace".into(), "workspace:1".into()],
            &options,
        )
        .unwrap();
        assert_eq!(params["surface_id"], "surface:1");
        assert_eq!(params["workspace_id"], "workspace:1");
        assert_eq!(
            trailing_text(&["hello".into(), "world".into()], "send").unwrap(),
            "hello world"
        );
        assert_eq!(unescape_send_text(r"hello\nworld"), "hello\nworld");
    }

    #[test]
    fn parses_notification_v1_response_for_json_output() {
        let notifications = parse_notifications(
            "0:note_1|ws_1|surface_1|unread|Build|CI|done|2026-09-06T00:00:00Z|Workspace",
        );
        assert_eq!(
            notifications,
            vec![json!({
                "id": "note_1",
                "workspace_id": "ws_1",
                "surface_id": "surface_1",
                "is_read": false,
                "title": "Build",
                "subtitle": "CI",
                "body": "done",
                "created_at": "2026-09-06T00:00:00Z",
                "tab_title": "Workspace"
            })]
        );
    }

    #[test]
    fn default_socket_path_matches_swift_contract() {
        let path = socket_path_from_environment(
            &GlobalOptions::default(),
            None,
            None,
            Some("/tmp/cmux-home".into()),
        )
        .unwrap();
        assert_eq!(path, PathBuf::from("/tmp/cmux-home/.local/state/cmux/cmux.sock"));
    }

    #[test]
    fn socket_marker_overrides_the_default_path() {
        let home = tempfile::tempdir().unwrap();
        let state = home.path().join(".local/state/cmux");
        std::fs::create_dir_all(&state).unwrap();
        std::fs::write(state.join("last-socket-path"), "/tmp/cmux-marked.sock\n").unwrap();
        assert_eq!(socket_marker_path(Some(&state)), Some("/tmp/cmux-marked.sock".into()));
    }

    #[test]
    fn capabilities_and_context_accept_json_suffix() {
        let (_, capabilities) =
            parse_args(&["capabilities".into(), "--json".into()], Program::Cmux).unwrap();
        assert_eq!(capabilities, CommandLine::Capabilities(vec!["--json".into()]));
        let (_, context) = parse_args(&["context".into(), "--json".into()], Program::Cmux).unwrap();
        assert_eq!(context, CommandLine::Context(vec!["--json".into()]));
    }

    #[test]
    fn capability_commands_reject_unknown_arguments() {
        let error = reject_no_arguments("capabilities", &["--bad".into()]).unwrap_err();
        assert_eq!(error.code(), 2);
        assert!(error.message().contains("unexpected argument"));
    }

    #[test]
    fn human_account_output_replaces_terminal_controls() {
        assert_eq!(sanitize_terminal("safe\u{1b}[31m"), "safe�[31m");
    }

    #[test]
    fn shared_socket_password_file_is_trimmed_without_exposing_contents() {
        let home = tempfile::tempdir().unwrap();
        let path = home.path().join(".local/state/cmux/socket-control-password");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "  secret-value  \n").unwrap();
        assert_eq!(
            socket_password_file_for_home(Some(home.path().as_os_str().to_os_string())),
            Some("  secret-value  ".into())
        );
    }

    #[test]
    fn socket_password_source_order_matches_swift_with_keychain_last() {
        assert_eq!(
            resolve_socket_password_from_sources(None, None, None, Some("legacy-keychain".into())),
            Some("legacy-keychain".into())
        );
        assert_eq!(
            resolve_socket_password_from_sources(
                Some(" explicit ".into()),
                Some("environment".into()),
                Some("file".into()),
                Some("keychain".into())
            ),
            Some(" explicit ".into())
        );
        assert_eq!(
            resolve_socket_password_from_sources(
                None,
                Some("\n".into()),
                Some(" file ".into()),
                Some("keychain".into())
            ),
            Some(" file ".into())
        );
    }
}
