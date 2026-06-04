#!/usr/bin/env bash
set -euo pipefail

echo "=== Ensuring /etc/wsl.conf exists ==="

if [ ! -f /etc/wsl.conf ]; then
    echo "Creating /etc/wsl.conf (did not exist)"
    sudo tee /etc/wsl.conf >/dev/null <<EOF
[boot]
systemd=true
command = mount --make-shared /

[network]
generateResolvConf=true

[interop]
enabled=true
appendWindowsPath=true

[automount]
enabled=true
mountFsTab=true
options = "metadata,uid=1000,gid=1000,umask=022,fmask=11,case=off"

[user]
default=$(whoami)
EOF
else
    echo "/etc/wsl.conf already exists — leaving it untouched"
fi

echo "=== Updating system ==="
sudo dnf5 -y update

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
    pkgconf \
    pkgconf-m4 \
    pkgconf-pkg-config

echo "=== Installing Podman ==="
sudo dnf5 -y install podman

echo "=== Installing Docker CE ==="

FEDORA_RELEASE="$(rpm -E %fedora)"

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

echo "=== Setting up SSH key ==="

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
    echo "Generating new ED25519 SSH key"
    ssh-keygen -t ed25519 -C "$USER" -f "$HOME/.ssh/id_ed25519" -N ""
else
    echo "SSH key already exists — leaving it untouched"
fi

chmod 600 "$HOME/.ssh/id_ed25519"
chmod 644 "$HOME/.ssh/id_ed25519.pub"

echo "=== Installing systemd user ssh-agent service ==="

mkdir -p "$HOME/.config/systemd/user"

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

echo "=== Enabling ssh-agent user service ==="
systemctl --user daemon-reload
systemctl --user enable --now ssh-agent.service

echo "=== Adding SSH auto-load logic to .bashrc ==="

if ! grep -q "systemd-managed ssh-agent" "$HOME/.bashrc"; then
    cat >> "$HOME/.bashrc" <<'EOF'

# Use systemd-managed ssh-agent
export SSH_AUTH_SOCK=/run/user/$UID/ssh-agent.socket

# Load SSH key once per WSL boot
if ! ssh-add -l >/dev/null 2>&1; then
    echo "Loading SSH key into ssh-agent..."
    ssh-add ~/.ssh/id_ed25519
fi

EOF
fi

echo "=== Ensuring .bash_profile loads .bashrc ==="

if ! grep -q ".bashrc" "$HOME/.bash_profile" 2>/dev/null; then
    echo 'if [ -f ~/.bashrc ]; then . ~/.bashrc; fi' >> ~/.bash_profile
fi

echo "=== Preloading GitHub SSH host keys (GitHub Meta API) ==="

KNOWN_HOSTS="$HOME/.ssh/known_hosts"
touch "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"

if ! grep -q "github.com" "$KNOWN_HOSTS"; then
    echo "Adding GitHub SSH host keys via GitHub Meta API"
    curl -s https://api.github.com/meta | jq -r '.ssh_keys[]' \
        | sed 's/^/github.com /' >> "$KNOWN_HOSTS"
else
    echo "GitHub host keys already present — skipping"
fi

echo "=== Configuring Git defaults ==="
git config --global init.defaultBranch main
git config --global pull.rebase false

echo "=== Creating common directories ==="
mkdir -p "$HOME/projects" "$HOME/bin"

echo "=== Bootstrap complete ==="
echo "Systemd-managed ssh-agent with automatic key loading is enabled."
echo "You will be prompted once per WSL boot for your SSH key passphrase."
echo "All terminals will share the same agent and loaded key."
echo "Docker and Podman are installed and configured."
