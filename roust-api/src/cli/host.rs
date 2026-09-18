//! Host route and NIC CLI commands.

use anyhow::{anyhow, Context, Result};
use clap::Subcommand;
use std::fs;
use std::path::Path;

use crate::config::{Config, DestinationKind, RoutingRule, TargetKind};
use crate::network::{discover_external_routes, enumerate_interfaces, rule_identity_key};
use crate::service;

use super::restart_if_running;

#[derive(Subcommand, Debug)]
pub enum RouteAction {
    /// List config + system host routes
    List,
    /// Add a routing rule
    Add {
        #[command(subcommand)]
        kind: AddKind,
    },
    /// Delete a config rule by index
    Delete {
        /// Zero-based index in routes.json
        index: usize,
    },
    /// Bulk-add private IP CIDRs as routes
    #[command(name = "private-ips")]
    PrivateIps {
        #[command(subcommand)]
        dest: PrivateIpsDest,
    },
}

#[derive(Subcommand, Debug)]
pub enum AddKind {
    /// Match traffic from one NIC onto another NIC's egress
    #[command(name = "nic-to-nic")]
    NicToNic {
        /// Source NIC (friendly / display / internal name)
        src: String,
        /// Destination NIC
        dst: String,
    },
    /// Match an IP or CIDR onto a NIC
    #[command(name = "ip-to-nic")]
    IpToNic {
        /// IPv4 address or CIDR (e.g. 10.0.0.1 or 10.0.0.0/8)
        target: String,
        /// Destination NIC
        nic: String,
    },
    /// Match a hostname onto a NIC
    #[command(name = "host-to-nic")]
    HostToNic {
        /// Hostname to match
        host: String,
        /// Destination NIC
        nic: String,
    },
}

#[derive(Subcommand, Debug)]
pub enum PrivateIpsDest {
    #[command(name = "to-nic")]
    ToNic {
        /// Destination NIC for every private CIDR
        nic: String,
    },
    #[command(name = "to-ip")]
    ToIp {
        /// Destination gateway IP for every private CIDR
        ip: String,
    },
}

#[derive(Subcommand, Debug)]
pub enum NicAction {
    /// List adapters
    List,
}

/// Pick TargetKind for `ip-to-nic`: CIDR if value contains `/`, else IP.
pub fn target_kind_for_ip_or_cidr(value: &str) -> TargetKind {
    if value.contains('/') {
        TargetKind::Cidr
    } else {
        TargetKind::Ip
    }
}

pub fn rule_from_add(kind: &AddKind) -> RoutingRule {
    match kind {
        AddKind::NicToNic { src, dst } => RoutingRule {
            target: TargetKind::Nic,
            target_value: src.clone(),
            destination: DestinationKind::Nic,
            destination_value: dst.clone(),
        },
        AddKind::IpToNic { target, nic } => RoutingRule {
            target: target_kind_for_ip_or_cidr(target),
            target_value: target.clone(),
            destination: DestinationKind::Nic,
            destination_value: nic.clone(),
        },
        AddKind::HostToNic { host, nic } => RoutingRule {
            target: TargetKind::Hostname,
            target_value: host.clone(),
            destination: DestinationKind::Nic,
            destination_value: nic.clone(),
        },
    }
}

fn load_or_empty(path: &Path) -> Result<Config> {
    if !path.exists() {
        return Ok(Config::new());
    }
    Config::load(path)
}

fn config_path() -> std::path::PathBuf {
    Config::default_config_path()
}

/// Load private CIDR list from install dir (`private_ips.json` or `private_ips_cidr.txt`).
pub fn load_private_cidrs(install_dir: &Path) -> Result<Vec<String>> {
    let json_path = install_dir.join("private_ips.json");
    if json_path.exists() {
        let body = fs::read_to_string(&json_path)
            .with_context(|| format!("read {}", json_path.display()))?;
        let cidrs: Vec<String> = serde_json::from_str(&body)
            .context("parse private_ips.json (expected JSON array of strings)")?;
        return Ok(cidrs
            .into_iter()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect());
    }
    let txt_path = install_dir.join("private_ips_cidr.txt");
    if txt_path.exists() {
        let body = fs::read_to_string(&txt_path)
            .with_context(|| format!("read {}", txt_path.display()))?;
        return Ok(body
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty())
            .collect());
    }
    Err(anyhow!(
        "private IP list not found (tried {} and {})",
        json_path.display(),
        txt_path.display()
    ))
}

pub fn private_ip_rules(cidrs: &[String], destination: DestinationKind, dest_value: &str) -> Vec<RoutingRule> {
    cidrs
        .iter()
        .map(|cidr| RoutingRule {
            target: TargetKind::Cidr,
            target_value: cidr.clone(),
            destination,
            destination_value: dest_value.to_string(),
        })
        .collect()
}

pub fn run_route(action: RouteAction) -> Result<()> {
    match action {
        RouteAction::List => {
            let path = config_path();
            let config = load_or_empty(&path)?;
            let config_rules = config.get_rules();
            let system = discover_external_routes(config_rules).unwrap_or_default();

            println!("config: {}", path.display());
            println!("config rules: {}", config_rules.len());
            for (i, rule) in config_rules.iter().enumerate() {
                println!("  [{i}] {}  (config)", rule.label());
            }
            println!("system routes (not in config): {}", system.len());
            for rule in &system {
                println!("  [-] {}  (system)", rule.label());
            }
            Ok(())
        }
        RouteAction::Add { kind } => {
            let path = config_path();
            let mut config = load_or_empty(&path)?;
            let rule = rule_from_add(&kind);
            config.add_rule(rule.clone())?;
            config.save(&path)?;
            println!("added: {}", rule.label());
            println!("config: {}", path.display());
            restart_if_running()?;
            Ok(())
        }
        RouteAction::Delete { index } => {
            let path = config_path();
            let mut config = load_or_empty(&path)?;
            if !config.remove_rule_at(index) {
                return Err(anyhow!("rule index {index} not found"));
            }
            config.save(&path)?;
            println!("deleted config rule index {index}");
            restart_if_running()?;
            Ok(())
        }
        RouteAction::PrivateIps { dest } => {
            let install_dir = service::exe_install_dir()?;
            let cidrs = load_private_cidrs(&install_dir)?;
            if cidrs.is_empty() {
                return Err(anyhow!("private IP list is empty"));
            }
            let (destination, dest_value) = match &dest {
                PrivateIpsDest::ToNic { nic } => (DestinationKind::Nic, nic.as_str()),
                PrivateIpsDest::ToIp { ip } => (DestinationKind::Ip, ip.as_str()),
            };
            let path = config_path();
            let mut config = load_or_empty(&path)?;
            let existing: std::collections::HashSet<String> =
                config.get_rules().iter().map(rule_identity_key).collect();
            let mut added = 0usize;
            let mut skipped = 0usize;
            for rule in private_ip_rules(&cidrs, destination, dest_value) {
                if existing.contains(&rule_identity_key(&rule)) {
                    skipped += 1;
                    continue;
                }
                match config.add_rule(rule) {
                    Ok(()) => added += 1,
                    Err(err) => {
                        // Overlap / validation: skip and continue bulk.
                        eprintln!("skip: {err:#}");
                        skipped += 1;
                    }
                }
            }
            config.save(&path)?;
            println!(
                "private-ips: added {added}, skipped {skipped} (list size {})",
                cidrs.len()
            );
            println!("config: {}", path.display());
            restart_if_running()?;
            Ok(())
        }
    }
}

pub fn run_nic(action: NicAction) -> Result<()> {
    match action {
        NicAction::List => {
            let ifaces = enumerate_interfaces()?;
            if ifaces.is_empty() {
                println!("no adapters found");
                return Ok(());
            }
            println!(
                "{:<6} {:<10} {:<20} {:<18} {}",
                "INDEX", "STATUS", "IPv4", "MAC", "NAME"
            );
            for iface in ifaces {
                let name = iface
                    .friendly_name
                    .as_deref()
                    .unwrap_or(iface.display_name.as_str());
                let ipv4 = iface.ipv4_address.as_deref().unwrap_or("-");
                println!(
                    "{:<6} {:<10} {:<20} {:<18} {}",
                    iface.if_index, iface.status, ipv4, iface.mac_address, name
                );
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ip_to_nic_picks_cidr_when_slash() {
        assert_eq!(target_kind_for_ip_or_cidr("10.0.0.0/8"), TargetKind::Cidr);
        assert_eq!(target_kind_for_ip_or_cidr("10.0.0.1"), TargetKind::Ip);
    }

    #[test]
    fn private_ip_rules_build_cidr_to_nic() {
        let rules = private_ip_rules(
            &["10.0.0.0/8".into(), "192.168.0.0/16".into()],
            DestinationKind::Nic,
            "Ethernet",
        );
        assert_eq!(rules.len(), 2);
        assert_eq!(rules[0].target, TargetKind::Cidr);
        assert_eq!(rules[0].destination, DestinationKind::Nic);
        assert_eq!(rules[0].destination_value, "Ethernet");
        assert_eq!(rules[1].target_value, "192.168.0.0/16");
    }

    #[test]
    fn rule_from_add_variants() {
        let nic = rule_from_add(&AddKind::NicToNic {
            src: "Wi-Fi".into(),
            dst: "Ethernet".into(),
        });
        assert_eq!(nic.target, TargetKind::Nic);
        assert_eq!(nic.destination, DestinationKind::Nic);

        let host = rule_from_add(&AddKind::HostToNic {
            host: "example.com".into(),
            nic: "Ethernet".into(),
        });
        assert_eq!(host.target, TargetKind::Hostname);
    }
}
