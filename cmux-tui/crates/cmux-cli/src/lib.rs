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
}

#[derive(Debug, Eq, PartialEq)]
enum CommandLine {
    Help,
    Version,
    Capabilities(Vec<String>),
    Context(Vec<String>),
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
            "--socket" | "--password" => {
                let name = args[index].clone();
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| CliError::Usage(format!("{name} requires a value")))?;
                if value.starts_with('-') && name == "--socket" {
                    return Err(CliError::Usage(format!("{name} requires a value")));
                }
                if name == "--socket" {
                    options.socket = Some(PathBuf::from(value));
                } else {
                    options.password = Some(value.clone());
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
        (_, Some("capabilities")) => CommandLine::Capabilities(args[index + 1..].to_vec()),
        (_, Some("context")) => CommandLine::Context(args[index + 1..].to_vec()),
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
    let socket = socket_path(options).map(|path| path.display().to_string());
    let socket_password_source = if options.password.is_some() {
        Some("argument")
    } else if env::var_os("CMUX_SOCKET_PASSWORD").is_some() {
        Some("environment")
    } else if socket_password_file().is_some() {
        Some("file")
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
            "cmux - control cmux via Unix socket\n\nUsage:\n  cmux [global-options] <command> [options]\n\nCommands:\n  cr <coderouter-args...>       Run CodeRouter\n  coderouter <args...>          Run CodeRouter\n  ai-accounts <list|upload|remove>\n  capabilities [--json|--offline] Describe available operations\n  context [--json]              Describe current agent context\n  rpc <method> [json]            Send a v2 socket request\n  version                        Print the CLI version\n\nGlobal options:\n  --socket <path>                Override the cmux Unix socket\n  --json                         Print JSON results\n  -h, --help                     Print this help\n  -v, --version                  Print the version"
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
    let value = value.trim().to_string();
    (!value.is_empty()).then_some(value)
}

fn socket_path(options: &GlobalOptions) -> Option<PathBuf> {
    socket_path_from_environment(
        options,
        env::var_os("CMUX_SOCKET_PATH"),
        env::var_os("CMUX_SOCKET"),
        env::var_os("HOME"),
    )
}

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
            Ok(Self { stream, password: resolve_socket_password(password) })
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
        if let Some(password) = &self.password {
            write_line(&mut stream, &format!("auth {password}"))?;
            let auth = read_response(&mut stream)?;
            if auth.starts_with("ERROR:") && !auth.contains("Unknown command 'auth'") {
                return Err(CliError::Runtime(auth));
            }
        }
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
}

fn resolve_socket_password(explicit: Option<String>) -> Option<String> {
    explicit
        .and_then(|value| (!value.trim().is_empty()).then_some(value))
        .or_else(|| {
            env::var("CMUX_SOCKET_PASSWORD")
                .ok()
                .and_then(|value| (!value.trim().is_empty()).then_some(value))
        })
        .or_else(socket_password_file)
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
            Some("secret-value".into())
        );
    }
}
