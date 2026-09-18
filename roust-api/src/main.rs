use anyhow::Result;
use roust::cli;
use roust::service;

fn main() -> Result<()> {
    if service::invoked_as_service() {
        return service::run_dispatcher();
    }

    cli::run()
}
