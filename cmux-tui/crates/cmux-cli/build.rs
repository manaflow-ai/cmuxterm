use std::process::Command;

fn main() {
    let version = std::env::var("CMUX_CLI_VERSION").unwrap_or_else(|_| "0.64.22".into());
    let build = std::env::var("CMUX_CLI_BUILD").unwrap_or_else(|_| "rust-migration".into());
    let commit = Command::new("git")
        .args(["rev-parse", "--short=9", "HEAD"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_default();
    println!("cargo:rustc-env=CMUX_CLI_VERSION={version}");
    println!("cargo:rustc-env=CMUX_CLI_BUILD={build}");
    println!("cargo:rustc-env=CMUX_CLI_COMMIT={commit}");
    println!("cargo:rerun-if-env-changed=CMUX_CLI_VERSION");
    println!("cargo:rerun-if-env-changed=CMUX_CLI_BUILD");
}
