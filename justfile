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
