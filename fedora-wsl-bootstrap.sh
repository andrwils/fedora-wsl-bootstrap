#!/usr/bin/env bash
set -euo pipefail

cleanup_tmp_files() {
    [ -n "${WSL_CONF_TMP:-}" ] && rm -f "$WSL_CONF_TMP"
}

trap cleanup_tmp_files EXIT

# Phase 0: Preconditions
sudo -v || { echo "This script requires sudo access."; exit 1; }

# Phase 1: WSL configuration merge (/etc/wsl.conf)
echo "=== Ensuring /etc/wsl.conf exists ==="

WSL_CONF_TMP="$(mktemp)"

if sudo test -f /etc/wsl.conf; then
    sudo cat /etc/wsl.conf > "$WSL_CONF_TMP"
else
    : > "$WSL_CONF_TMP"
fi

ensure_wsl_conf_key() {
    local section="$1"
    local key="$2"
    local value="$3"
    local file_path="$4"
    local tmp_out

    tmp_out="$(mktemp)"

    awk -v section="$section" -v key="$key" -v value="$value" '
        BEGIN {
            section_found = 0
            in_section = 0
            key_written = 0
            key_lc = tolower(key)
        }
        {
            if ($0 ~ /^\[[^]]+\]$/) {
                if (in_section && !key_written) {
                    print key "=" value
                    key_written = 1
                }
                in_section = ($0 == "[" section "]")
                if (in_section) {
                    section_found = 1
                }
                print
                next
            }

            if (in_section) {
                eq_index = index($0, "=")
                if (eq_index > 0) {
                    current_key = substr($0, 1, eq_index - 1)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", current_key)
                    if (tolower(current_key) == key_lc) {
                        if (!key_written) {
                            print key "=" value
                            key_written = 1
                        }
                        next
                    }
                }
            }

            print
        }
        END {
            if (!section_found) {
                if (NR > 0) {
                    print ""
                }
                print "[" section "]"
                print key "=" value
            } else if (in_section && !key_written) {
                print key "=" value
            }
        }
    ' "$file_path" > "$tmp_out"

    mv "$tmp_out" "$file_path"
}

ensure_wsl_conf_key "boot" "systemd" "true" "$WSL_CONF_TMP"
ensure_wsl_conf_key "boot" "command" "mount --make-shared /" "$WSL_CONF_TMP"
ensure_wsl_conf_key "network" "generateresolvconf" "true" "$WSL_CONF_TMP"
ensure_wsl_conf_key "interop" "enabled" "true" "$WSL_CONF_TMP"
ensure_wsl_conf_key "interop" "appendwindowspath" "true" "$WSL_CONF_TMP"
ensure_wsl_conf_key "automount" "enabled" "true" "$WSL_CONF_TMP"
ensure_wsl_conf_key "automount" "mountfstab" "true" "$WSL_CONF_TMP"
ensure_wsl_conf_key "automount" "options" "\"metadata,uid=$(id -u),gid=$(id -g),umask=022,fmask=11,case=off\"" "$WSL_CONF_TMP"
ensure_wsl_conf_key "user" "default" "$(whoami)" "$WSL_CONF_TMP"

sudo tee /etc/wsl.conf >/dev/null < "$WSL_CONF_TMP"
rm -f "$WSL_CONF_TMP"

echo "/etc/wsl.conf merged with required settings"

# Phase 2: Early runtime readiness checks
echo "=== Early check: systemd user session availability ==="
if ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "ERROR: systemd user session is not ready."
    echo "Restart WSL from Windows with: wsl --shutdown"
    echo "Then start Fedora again and rerun this script."
    exit 1
fi

# Phase 3: Base system update
echo "=== Updating system ==="
# Note: on re-runs this performs a full system upgrade — intentional for a bootstrap script
sudo dnf5 -y update

# Phase 4: Core packages and Git defaults
echo "=== Installing core utilities ==="
sudo dnf5 -y install \
    git \
    curl \
    wget2-wget \
    unzip \
    tar \
    nano \
    vim-enhanced \
    htop \
    util-linux \
    jq

echo "=== Configuring Git defaults ==="
git config --global init.defaultBranch main
git config --global pull.rebase false

if [ -z "$(git config --global user.name 2>/dev/null || true)" ]; then
    read -rp "Git user name: " git_user_name
    git config --global user.name "$git_user_name"
fi

if [ -z "$(git config --global user.email 2>/dev/null || true)" ]; then
    read -rp "Git user email: " git_user_email
    git config --global user.email "$git_user_email"
fi

# Phase 5: Development toolchain
echo "=== Installing Development Tools ==="
sudo dnf5 -y install \
    gcc \
    gcc-c++ \
    make \
    automake \
    autoconf \
    libtool \
    patch \
    diffutils \
    findutils \
    gdb \
    strace \
    ltrace \
    pkgconf-pkg-config

# Phase 6: Platform CLIs (Vault, Helm, JFrog CLI, consul-template)
echo "=== Installing platform CLIs from official third-party repos ==="

echo "=== Setting up HashiCorp official repository ==="
if [ ! -f /etc/yum.repos.d/hashicorp.repo ]; then
    sudo tee /etc/yum.repos.d/hashicorp.repo >/dev/null <<'EOF'
[hashicorp]
name=HashiCorp Stable - $basearch
baseurl=https://rpm.releases.hashicorp.com/fedora/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://rpm.releases.hashicorp.com/gpg
repo_gpgcheck=1
EOF
fi

sudo dnf5 -y install vault consul-template

echo "=== Installing Helm from official Fedora repository ==="
sudo dnf5 -y install helm

echo "=== Installing JFrog CLI ==="
sudo dnf5 -y install jfrog-cli-v2-jf

# Phase 7: Container runtimes (Podman + Docker)
echo "=== Installing Podman ==="
sudo dnf5 -y install podman

echo "=== Installing Docker CE ==="

FEDORA_RELEASE="$(rpm -E %fedora)"

echo "=== Importing Docker CE GPG key ==="
sudo rpm --import https://download.docker.com/linux/fedora/gpg

if [ ! -f /etc/yum.repos.d/docker-ce.repo ]; then
    sudo tee /etc/yum.repos.d/docker-ce.repo >/dev/null <<EOF
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=https://download.docker.com/linux/fedora/${FEDORA_RELEASE}/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/fedora/gpg
EOF
fi

sudo dnf5 -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "=== Enabling Docker service ==="
sudo systemctl enable --now docker || true

echo "=== Adding user to docker group ==="
sudo usermod -aG docker "$USER"

# Phase 8: SSH key and GitHub host trust
echo "=== Setting up SSH key ==="

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
    echo "Generating new ED25519 SSH key"
    ssh-keygen -t ed25519 -C "$USER" -f "$HOME/.ssh/id_ed25519"
else
    echo "SSH key already exists — leaving it untouched"
fi

chmod 600 "$HOME/.ssh/id_ed25519"
chmod 644 "$HOME/.ssh/id_ed25519.pub"

echo "=== Preloading GitHub SSH host keys (with fingerprint check) ==="

KNOWN_HOSTS="$HOME/.ssh/known_hosts"
touch "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"

# Static keys from https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# Update these if GitHub rotates their host keys (rare, always announced by GitHub).
if ! grep -qF "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl" "$KNOWN_HOSTS"; then
    echo "Adding GitHub SSH host keys (static, from GitHub docs)"
    # Remove any existing github.com entries first to avoid duplicates or stale keys.
    ssh-keygen -R github.com -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
    cat >> "$KNOWN_HOSTS" <<'EOF'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
EOF
else
    echo "GitHub SSH host keys already present — skipping"
fi

# Phase 9: User ssh-agent service and shell wiring
echo "=== Installing systemd user ssh-agent service ==="

mkdir -p "$HOME/.config/systemd/user"

if [ ! -f "$HOME/.config/systemd/user/ssh-agent.service" ]; then
    tee "$HOME/.config/systemd/user/ssh-agent.service" >/dev/null <<EOF
[Unit]
Description=User ssh-agent

[Service]
Type=simple
Environment=SSH_AUTH_SOCK=%t/ssh-agent.socket
ExecStart=/usr/bin/ssh-agent -D -a %t/ssh-agent.socket

[Install]
WantedBy=default.target
EOF
fi

echo "=== Enabling ssh-agent user service ==="
systemctl --user daemon-reload
systemctl --user enable --now ssh-agent.service

echo "=== Adding SSH auto-load logic to .bashrc ==="

if ! grep -q "systemd-managed ssh-agent" "$HOME/.bashrc"; then
    cat >> "$HOME/.bashrc" <<'EOF'

# Use systemd-managed ssh-agent
export SSH_AUTH_SOCK=/run/user/$UID/ssh-agent.socket

# Load SSH key once per WSL boot
# exit 0 = keys loaded, exit 1 = no keys, exit 2 = agent not running
_ssh_status=0; ssh-add -l >/dev/null 2>&1 || _ssh_status=$?
if [ "$_ssh_status" -eq 1 ]; then
    echo "Loading SSH key into ssh-agent..."
    ssh-add ~/.ssh/id_ed25519
fi

EOF
fi

echo "=== Ensuring .bash_profile loads .bashrc ==="

# Note: >> creates .bash_profile if it does not exist — this is intentional
if ! grep -q ".bashrc" "$HOME/.bash_profile" 2>/dev/null; then
    echo 'if [ -f ~/.bashrc ]; then . ~/.bashrc; fi' >> ~/.bash_profile
fi

# Phase 10: Developer workspace directories
echo "=== Creating common directories ==="
mkdir -p "$HOME/projects" "$HOME/bin"

# Phase 11: Completion summary
echo "=== Bootstrap complete ==="
echo "Systemd-managed ssh-agent with automatic key loading is enabled."
echo "You will be prompted once per WSL boot for your SSH key passphrase."
echo "All terminals will share the same agent and loaded key."
echo "Docker and Podman are installed and configured."
