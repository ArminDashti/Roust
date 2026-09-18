//! User-facing `roust` CLI (service, doctor, host routes, uninstall).

mod doctor;
mod host;
mod uninstall;

use anyhow::Result;
use clap::{Parser, Subcommand};
use windows_service::service::ServiceState;

use crate::service;

#[derive(Parser, Debug)]
#[command(name = "roust")]
#[command(about = "Roust packet router: service control, host routes, diagnostics")]
#[command(subcommand_required = false)]
pub struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Install the Windows service (installer / scripts).
    #[arg(long = "install-service", hide = true)]
    install_service: bool,

    /// Unregister the Windows service only (installer / scripts).
    #[arg(long = "uninstall-service", hide = true)]
    uninstall_service: bool,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Control the Roust Windows service
    Service {
        #[command(subcommand)]
        action: ServiceAction,
    },
    /// Print a comprehensive health report
    Doctor,
    /// Host routes and NIC listing
    Host {
        #[command(subcommand)]
        cmd: HostCmd,
    },
    /// Full local uninstall (service, configs, install dir)
    Uninstall,
}

#[derive(Subcommand, Debug)]
enum ServiceAction {
    Start,
    Stop,
    Restart,
    Status,
}

#[derive(Subcommand, Debug)]
enum HostCmd {
    /// Manage destination routing rules in routes.json
    Route {
        #[command(subcommand)]
        action: host::RouteAction,
    },
    /// List network adapters
    Nic {
        #[command(subcommand)]
        action: host::NicAction,
    },
}

/// Restart the Windows service when it is currently Running.
pub(crate) fn restart_if_running() -> Result<()> {
    if !service::is_installed().unwrap_or(false) {
        return Ok(());
    }
    let state = service::query_state()?;
    if matches!(state, ServiceState::Running) {
        service::restart()?;
    }
    Ok(())
}

pub(crate) fn service_state_label(state: ServiceState) -> &'static str {
    match state {
        ServiceState::Stopped => "Stopped",
        ServiceState::StartPending => "StartPending",
        ServiceState::StopPending => "StopPending",
        ServiceState::Running => "Running",
        ServiceState::ContinuePending => "ContinuePending",
        ServiceState::PausePending => "PausePending",
        ServiceState::Paused => "Paused",
    }
}

/// Parse argv and run the selected CLI command.
pub fn run() -> Result<()> {
    let cli = Cli::parse();

    if cli.install_service {
        return service::install(false);
    }
    if cli.uninstall_service {
        return service::uninstall();
    }

    match cli.command {
        None => {
            use clap::CommandFactory;
            Cli::command().print_help()?;
            println!();
            std::process::exit(1);
        }
        Some(Commands::Service { action }) => match action {
            ServiceAction::Start => service::start(),
            ServiceAction::Stop => service::stop(),
            ServiceAction::Restart => service::restart(),
            ServiceAction::Status => {
                let installed = service::is_installed().unwrap_or(false);
                if !installed {
                    println!("service: not installed");
                    return Ok(());
                }
                match service::query_state() {
                    Ok(state) => {
                        println!("service: installed");
                        println!("state: {}", service_state_label(state));
                    }
                    Err(err) => {
                        println!("service: installed");
                        println!("state: error ({err:#})");
                    }
                }
                Ok(())
            }
        },
        Some(Commands::Doctor) => doctor::run(),
        Some(Commands::Host { cmd }) => match cmd {
            HostCmd::Route { action } => host::run_route(action),
            HostCmd::Nic { action } => host::run_nic(action),
        },
        Some(Commands::Uninstall) => uninstall::run(),
    }
}
