//! Comprehensive health report for `roust doctor`.

use anyhow::Result;
use std::fs;
use std::net::TcpStream;
use std::path::Path;
use std::time::Duration;

use crate::config::{
    AppBindStore, Config, DnsExceptionStore, HostOverrideStore,
};
use crate::elevation;
use crate::network::{discover_external_routes, enumerate_interfaces, read_applied_ipv4_routes};
use crate::service;
use crate::wfp::resolve_bind_status;

use super::service_state_label;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Level {
    Pass,
    Warn,
    Fail,
}

struct Check {
    level: Level,
    name: &'static str,
    detail: String,
}

fn pass(name: &'static str, detail: impl Into<String>) -> Check {
    Check {
        level: Level::Pass,
        name,
        detail: detail.into(),
    }
}

fn warn(name: &'static str, detail: impl Into<String>) -> Check {
    Check {
        level: Level::Warn,
        name,
        detail: detail.into(),
    }
}

fn fail(name: &'static str, detail: impl Into<String>) -> Check {
    Check {
        level: Level::Fail,
        name,
        detail: detail.into(),
    }
}

fn level_tag(level: Level) -> &'static str {
    match level {
        Level::Pass => "PASS",
        Level::Warn => "WARN",
        Level::Fail => "FAIL",
    }
}

fn probe_tcp(addr: &str) -> bool {
    TcpStream::connect_timeout(
        &addr.parse().unwrap_or_else(|_| "127.0.0.1:1".parse().unwrap()),
        Duration::from_millis(400),
    )
    .is_ok()
}

fn file_check(install_dir: &Path, name: &str) -> Check {
    let path = install_dir.join(name);
    if path.is_file() {
        let size = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        pass(
            "file",
            format!("{} present ({} bytes)", path.display(), size),
        )
    } else {
        fail("file", format!("{} missing", path.display()))
    }
}

pub fn run() -> Result<()> {
    let mut checks: Vec<Check> = Vec::new();
    let version = env!("CARGO_PKG_VERSION");

    let exe = std::env::current_exe().ok();
    let install_dir = service::exe_install_dir().ok();

    checks.push(pass(
        "version",
        format!(
            "roust {version}; exe={}",
            exe.as_ref()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "?".into())
        ),
    ));
    match &install_dir {
        Some(dir) => checks.push(pass("install-dir", dir.display().to_string())),
        None => checks.push(fail("install-dir", "could not resolve exe parent")),
    }

    if elevation::is_elevated() {
        checks.push(pass("elevation", "running as Administrator"));
    } else {
        checks.push(warn(
            "elevation",
            "not elevated (service control / route mutate need Admin)",
        ));
    }

    match service::is_installed() {
        Ok(true) => match service::query_state() {
            Ok(state) => checks.push(pass(
                "service",
                format!("installed; state={}", service_state_label(state)),
            )),
            Err(err) => checks.push(fail("service", format!("installed but query failed: {err:#}"))),
        },
        Ok(false) => checks.push(warn("service", "not installed")),
        Err(err) => checks.push(fail("service", format!("install check failed: {err:#}"))),
    }

    if let Some(dir) = &install_dir {
        let dll = file_check(dir, "WinDivert.dll");
        let dll_ok = dll.level == Level::Pass;
        checks.push(Check {
            name: "windivert-dll",
            ..dll
        });
        let sys = file_check(dir, "WinDivert64.sys");
        checks.push(Check {
            name: "windivert-sys",
            ..sys
        });
        if !dll_ok {
            // already recorded as FAIL
        }

        for name in ["private_ips.json", "private_ips_cidr.txt"] {
            let path = dir.join(name);
            if path.is_file() {
                checks.push(pass("private-ips-file", format!("{} present", path.display())));
            }
        }
        if !dir.join("private_ips.json").is_file() && !dir.join("private_ips_cidr.txt").is_file()
        {
            checks.push(warn(
                "private-ips-file",
                "private_ips.json / private_ips_cidr.txt not found under install dir",
            ));
        }

        let log_path = dir.join("logs").join("roust-service.log");
        if log_path.is_file() {
            if let Ok(meta) = fs::metadata(&log_path) {
                let mtime = meta.modified().ok();
                checks.push(pass(
                    "service-log",
                    format!(
                        "{} ({} bytes{})",
                        log_path.display(),
                        meta.len(),
                        mtime
                            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                            .map(|d| format!(", mtime_unix={}", d.as_secs()))
                            .unwrap_or_default()
                    ),
                ));
            }
        } else {
            checks.push(warn(
                "service-log",
                format!("{} missing (service may never have started)", log_path.display()),
            ));
        }
    }

    let routes_path = Config::default_config_path();
    if routes_path.exists() {
        match Config::load(&routes_path) {
            Ok(config) => {
                let n = config.get_rules().len();
                let mut bad = 0usize;
                for rule in config.get_rules() {
                    if rule.validate().is_err() {
                        bad += 1;
                    }
                }
                if bad == 0 {
                    checks.push(pass(
                        "routes.json",
                        format!("{} — {n} rule(s), all valid", routes_path.display()),
                    ));
                } else {
                    checks.push(fail(
                        "routes.json",
                        format!("{} — {n} rule(s), {bad} invalid", routes_path.display()),
                    ));
                }
            }
            Err(err) => checks.push(fail(
                "routes.json",
                format!("{} load error: {err:#}", routes_path.display()),
            )),
        }
    } else {
        checks.push(warn(
            "routes.json",
            format!("{} not found (empty config until created)", routes_path.display()),
        ));
    }

    let binds_path = AppBindStore::path_beside(&routes_path);
    match AppBindStore::load(&binds_path) {
        Ok(store) => {
            let binds = store.get_binds();
            let ifaces = enumerate_interfaces().unwrap_or_default();
            let mut healthy = 0usize;
            let mut nic_down = 0usize;
            let mut unresolved = 0usize;
            for bind in binds {
                match resolve_bind_status(bind, &ifaces) {
                    crate::config::AppBindStatus::Healthy => healthy += 1,
                    crate::config::AppBindStatus::NicDown => nic_down += 1,
                    crate::config::AppBindStatus::Unresolved => unresolved += 1,
                }
            }
            let detail = format!(
                "{} — {} bind(s): healthy={healthy} nic-down={nic_down} unresolved={unresolved}",
                binds_path.display(),
                binds.len()
            );
            if unresolved > 0 || nic_down > 0 {
                checks.push(warn("app-binds", detail));
            } else {
                checks.push(pass("app-binds", detail));
            }
        }
        Err(err) => checks.push(fail("app-binds", format!("{err:#}"))),
    }

    let dns_path = DnsExceptionStore::path_beside(&routes_path);
    match DnsExceptionStore::load(&dns_path) {
        Ok(store) => checks.push(pass(
            "dns-exceptions",
            format!(
                "{} — {} rule(s)",
                dns_path.display(),
                store.get_exceptions().len()
            ),
        )),
        Err(err) => checks.push(fail("dns-exceptions", format!("{err:#}"))),
    }

    let host_path = HostOverrideStore::path_beside(&routes_path);
    match HostOverrideStore::load(&host_path) {
        Ok(store) => checks.push(pass(
            "host-overrides",
            format!(
                "{} — {} rule(s)",
                host_path.display(),
                store.get_overrides().len()
            ),
        )),
        Err(err) => checks.push(fail("host-overrides", format!("{err:#}"))),
    }

    match enumerate_interfaces() {
        Ok(ifaces) => {
            let up = ifaces
                .iter()
                .filter(|i| i.status.eq_ignore_ascii_case("Up"))
                .count();
            let with_v4 = ifaces
                .iter()
                .filter(|i| {
                    i.ipv4_address
                        .as_ref()
                        .is_some_and(|ip| !ip.is_empty() && ip != "0.0.0.0")
                })
                .count();
            checks.push(pass(
                "nics",
                format!("{} adapter(s); Up={up}; with IPv4={with_v4}", ifaces.len()),
            ));
        }
        Err(err) => checks.push(fail("nics", format!("enumerate failed: {err:#}"))),
    }

    match read_applied_ipv4_routes() {
        Ok(rows) => checks.push(pass(
            "system-routes",
            format!("{} IPv4 forward row(s) (filtered view)", rows.len()),
        )),
        Err(err) => checks.push(fail("system-routes", format!("{err:#}"))),
    }

    let config_rules = if routes_path.exists() {
        Config::load(&routes_path)
            .map(|c| c.get_rules().to_vec())
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    match discover_external_routes(&config_rules) {
        Ok(ext) => checks.push(pass(
            "external-routes",
            format!("{} applied host route(s) not in config", ext.len()),
        )),
        Err(err) => checks.push(warn("external-routes", format!("{err:#}"))),
    }

    if probe_tcp("127.0.0.1:8787") {
        checks.push(pass("api", "127.0.0.1:8787 accepting connections"));
    } else {
        checks.push(warn(
            "api",
            "127.0.0.1:8787 not listening (roust-api may be stopped)",
        ));
    }
    if probe_tcp("127.0.0.1:5173") {
        checks.push(pass("webui", "127.0.0.1:5173 accepting connections"));
    } else {
        checks.push(warn(
            "webui",
            "127.0.0.1:5173 not listening (WebUI may be stopped)",
        ));
    }

    println!("roust doctor");
    println!("============");
    let mut fails = 0usize;
    let mut warns = 0usize;
    for c in &checks {
        println!("[{}] {}: {}", level_tag(c.level), c.name, c.detail);
        match c.level {
            Level::Fail => fails += 1,
            Level::Warn => warns += 1,
            Level::Pass => {}
        }
    }
    println!("------------");
    println!(
        "summary: {} check(s), {fails} FAIL, {warns} WARN",
        checks.len()
    );

    if fails > 0 {
        std::process::exit(1);
    }
    Ok(())
}
