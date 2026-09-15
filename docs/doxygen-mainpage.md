# i.MX8P Docker Development Environment {#mainpage}

This site is the documentation portal for `wdfk-prog/imx8p-dev-docker`.

The project freezes a legacy **Ubuntu 20.04 + NXP/FSL i.MX8P Yocto SDK + CMake 3.20.6** development environment inside Docker while keeping the application source code on the host through bind mounts.

## Start Here

- [Project README](../README.md) — complete setup, build, migration, release, CI/CD, and troubleshooting guide.
- [Toolchain and Thrift](toolchain-and-thrift.md) — explains the host/target Thrift split and normalized Yocto compiler environment.
- [Permissions and Migration](permissions-and-migration.md) — explains SDK permissions and host UID/GID mapping.
- [Offline Image Migration](offline-image-migration.md) — explains large-image export, import, disk planning, and migration.

## Automation

The repository uses two different automation environments on purpose:

1. **GitHub-hosted runner** — lightweight Shell/Compose checks and Doxygen Pages publication. It does not contain the proprietary/local NXP SDK.
2. **Self-hosted `imx8p-sdk` runner** — release-only full Docker image build, `verify-imx8p-env` verification, and GHCR publication. The SDK stays on that trusted runner and is never uploaded as a Git repository artifact.

See the project README for the required public-repository runner security settings, runner labels, repository variables, GHCR limits, and release workflow.

## Repository Scope

This repository currently contains Dockerfiles, POSIX shell tooling, Compose configuration, and Markdown documentation. The actual UTrack application source is intentionally outside this repository and is bind-mounted into `/workspace` during development.
