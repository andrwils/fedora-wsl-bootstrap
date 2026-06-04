# fedora-wsl-bootstrap — Agent Instructions

## Project Overview

Single-file Bash bootstrap script (`fedora-wsl-bootstrap.sh`) that provisions a fresh Fedora WSL instance: system packages, Docker CE, Podman, SSH key + systemd ssh-agent, and Git defaults.

## Key Conventions

- **Package manager**: `dnf5` (not `dnf` or `yum`)
- **Error handling**: Script uses `set -euo pipefail` — every new code path must be safe to run under these flags
- **Idempotency**: All operations must be safe to re-run. Check for existence before creating files, keys, or config blocks (see existing `[ ! -f ... ]` and `grep -q` patterns)
- **Privileged writes**: Use `sudo tee … >/dev/null <<EOF` to write files that require root; never `sudo echo … >`
- **User-space writes**: Use plain `tee` or `cat >>` for files in `$HOME`
- **Heredocs in functions**: Use `'EOF'` (single-quoted) when the heredoc content should NOT expand variables; use `EOF` (unquoted) when it should
- **Service management**: Prefer `systemctl --user` for user-space services; use `|| true` when enabling system services that may not start in minimal WSL environments

## Architecture

```
fedora-wsl-bootstrap.sh   # Single entrypoint — run as a normal user with sudo access
```

Sections in order:
1. `/etc/wsl.conf` — WSL configuration (systemd, automount, network)
2. System update + core utilities
3. Development tools (gcc, make, gdb, etc.)
4. Podman
5. Docker CE (custom repo at `/etc/yum.repos.d/docker-ce.repo`)
6. SSH key generation + systemd user `ssh-agent.service`
7. `.bashrc` / `.bash_profile` configuration
8. GitHub SSH host key preloading via GitHub Meta API
9. Git global defaults
10. Common directory creation (`~/projects`, `~/bin`)

## Testing / Validation

There is no automated test suite. To validate changes:
- Lint with `bash -n fedora-wsl-bootstrap.sh` (syntax check, no execution)
- Check for shellcheck issues: `shellcheck fedora-wsl-bootstrap.sh`

## Common Pitfalls

- **SSH key passphrase**: `ssh-keygen` is called without `-N` so it prompts the user interactively — never pass `-N ""` (empty passphrase)
- **Variable expansion in heredocs**: Forgetting to quote `EOF` when writing systemd unit files or repo configs causes unintended `$`-expansion
- **DNF vs DNF5**: This targets modern Fedora; always use `dnf5`, never `dnf`
- **`$FEDORA_RELEASE`**: Derived at runtime via `rpm -E %fedora`; do not hardcode version numbers
- **WSL systemd requirement**: `systemctl --user` commands require `systemd=true` in `wsl.conf`; the script sets this up first but a full WSL restart is needed before systemd is active
