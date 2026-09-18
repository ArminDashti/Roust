//! Full local uninstall (`roust uninstall`).

use anyhow::{Context, Result};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::Duration;

use crate::config::{clear_roust_hosts, clear_roust_nrpt};
use crate::elevation;
use crate::service;
use crate::setup;

fn stop_listeners_on_port(port: u16, label: &str) {
    println!(">> Stopping listeners on {label} port {port}");
    let script = format!(
        "Get-NetTCPConnection -LocalPort {port} -State Listen -ErrorAction SilentlyContinue | \
         ForEach-Object {{ Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }}"
    );
    let _ = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            &script,
        ])
        .status();
}

fn kill_named_processes(names: &[&str]) {
    let self_pid = std::process::id();
    for name in names {
        let script = format!(
            "Get-Process -Name '{name}' -ErrorAction SilentlyContinue | \
             Where-Object {{ $_.Id -ne {self_pid} }} | \
             Stop-Process -Force -ErrorAction SilentlyContinue"
        );
        let _ = Command::new("powershell.exe")
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                &script,
            ])
            .status();
    }
}

fn remove_dir_best_effort(path: &Path, label: &str) {
    if !path.exists() {
        println!(">> {label}: not present ({})", path.display());
        return;
    }
    println!(">> Removing {label}: {}", path.display());
    match fs::remove_dir_all(path) {
        Ok(()) => println!("OK  removed {}", path.display()),
        Err(err) => eprintln!("WARN could not remove {}: {err}", path.display()),
    }
}

/// Schedule install-dir delete after this process exits (own image may be inside it).
fn schedule_install_dir_delete(dir: &Path) -> Result<()> {
    let dir_str = dir
        .canonicalize()
        .unwrap_or_else(|_| dir.to_path_buf())
        .display()
        .to_string();
    // Strip \\?\ prefix if present for cmd.exe.
    let cleaned = dir_str
        .strip_prefix(r"\\?\")
        .unwrap_or(&dir_str)
        .to_string();
    println!(">> Scheduling delete of install dir after exit: {cleaned}");
    let cmdline = format!(
        "ping 127.0.0.1 -n 4 >nul & rmdir /s /q \"{cleaned}\""
    );
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x00000200;
        const DETACHED_PROCESS: u32 = 0x00000008;
        Command::new("cmd.exe")
            .args(["/C", &cmdline])
            .creation_flags(CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS)
            .spawn()
            .context("spawn delayed install-dir delete")?;
    }
    #[cfg(not(windows))]
    {
        let _ = cmdline;
    }
    Ok(())
}

fn maybe_clear_dev_state(install_dir: &Path) {
    let Some(name) = install_dir.file_name().and_then(|n| n.to_str()) else {
        return;
    };
    if !name.eq_ignore_ascii_case("Roust") {
        return;
    }
    let Some(repo_root) = install_dir.parent() else {
        return;
    };
    if !repo_root.join("roust-api").join("Cargo.toml").is_file() {
        return;
    }
    let state = repo_root.join(".armin").join("state");
    remove_dir_best_effort(&state, "dev state (.armin/state)");
}

pub fn run() -> Result<()> {
    elevation::ensure_elevated()?;

    println!(">> Full local Roust uninstall");

    stop_listeners_on_port(5173, "WebUI");
    stop_listeners_on_port(8787, "API");
    // Give ports a moment after kill.
    thread::sleep(Duration::from_millis(300));

    match service::is_installed() {
        Ok(true) => {
            println!(">> Uninstalling Windows service");
            if let Err(err) = service::uninstall() {
                eprintln!("WARN service uninstall: {err:#}");
            }
        }
        Ok(false) => println!(">> Windows service not installed; skipping"),
        Err(err) => eprintln!("WARN service check: {err:#}"),
    }

    kill_named_processes(&["roust-api", "roust"]);

    println!(">> Clearing NRPT dns exceptions");
    if let Err(err) = clear_roust_nrpt() {
        eprintln!("WARN NRPT clear: {err:#}");
    }
    println!(">> Clearing hosts-file overrides");
    if let Err(err) = clear_roust_hosts() {
        eprintln!("WARN hosts clear: {err:#}");
    }

    let install_dir = service::exe_install_dir()?;
    if let Err(err) = setup::unregister_install_dir_from_user_path(&install_dir) {
        eprintln!("WARN PATH unregister: {err:#}");
    } else {
        println!("OK  removed install dir from user PATH (if present)");
    }

    if let Ok(program_data) = std::env::var("ProgramData") {
        let pd = PathBuf::from(program_data).join("roust");
        remove_dir_best_effort(&pd, "ProgramData\\roust");
    }

    maybe_clear_dev_state(&install_dir);

    // Kill other roust processes again before scheduling rmdir.
    kill_named_processes(&["roust-api"]);

    schedule_install_dir_delete(&install_dir)?;

    println!("OK  Uninstall initiated. Install directory will be removed shortly after exit.");
    Ok(())
}
