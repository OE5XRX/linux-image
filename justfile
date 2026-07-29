# OE5XRX linux-image dev commands. `just` (bare) lists everything.
set dotenv-load := true

_default:
    @just --list

# Scaffold .env from .env.example (does not overwrite)
init:
    scripts/ydev/init.sh

# Preflight: report what's missing for local (and remote) use
doctor:
    scripts/ydev/doctor.sh

# Prod-safety guard: fail if a dev-only package ever reaches the prod image
lint-dev-isolation:
    scripts/l0-dev-packages-lint.sh

mod local
mod remote
mod dev
