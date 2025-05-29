#!/bin/bash
set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
status() { echo -e "\n${BLUE}>>> $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warning() { echo -e "${YELLOW}⚠ $*${NC}"; }
error() { echo -e "${RED}✗ $*${NC}"; exit 1; }

# Check root
if [ "$(id -u)" -ne 0 ]; then
    error "Script must be run as root. Use sudo or switch to root user."
fi

# 1. System Limits Optimization
status "Optimizing system limits..."

# Configure system-wide limits
if ! grep -q "# Kuzco Optimization" /etc/security/limits.conf; then
    cat <<EOF >> /etc/security/limits.conf

# Kuzco Optimization
* soft nofile 1048576
* hard nofile 1048576
* soft nproc unlimited
* hard nproc unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft nproc unlimited
root hard nproc unlimited
EOF
    success "Added limits to /etc/security/limits.conf"
else
    success "System limits already configured (skipped)"
fi

# Configure systemd limits
if [ ! -f /etc/systemd/system.conf.d/limits.conf ]; then
    mkdir -p /etc/systemd/system.conf.d/
    cat <<EOF > /etc/systemd/system.conf.d/limits.conf
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
EOF
    success "Added systemd limits configuration"
else
    success "Systemd limits already configured (skipped)"
fi

# Configure pam limits
if [ -f /etc/pam.d/common-session ] && ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
    echo "session required pam_limits.so" >> /etc/pam.d/common-session
    success "Added PAM limits configuration"
elif [ ! -f /etc/pam.d/common-session ]; then
    warning "PAM common-session file not found"
else
    success "PAM limits already configured (skipped)"
fi

# 2. Kernel Parameters Optimization
status "Optimizing kernel parameters..."

if [ ! -f /etc/sysctl.d/99-kuzco.conf ]; then
    cat <<EOF > /etc/sysctl.d/99-kuzco.conf
# Network
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192

# Memory
vm.swappiness=10
vm.dirty_ratio=60
vm.dirty_background_ratio=2

# File handles
fs.file-max=1048576
fs.nr_open=1048576

# Other
kernel.pid_max=4194304
EOF
    sysctl -p /etc/sysctl.d/99-kuzco.conf >/dev/null 2>&1
    success "Kernel parameters optimized"
else
    success "Kernel parameters already optimized (skipped)"
fi

# 3. Disable Unnecessary Services
status "Disabling unnecessary services..."

services_to_disable=(
    avahi-daemon
    cups
    bluetooth
    ModemManager
)

for service in "${services_to_disable[@]}"; do
    if systemctl is-enabled "$service" 2>/dev/null | grep -q "enabled"; then
        systemctl disable --now "$service" >/dev/null 2>&1 && \
            success "Disabled $service" || \
            warning "Failed to disable $service"
    else
        success "$service already disabled (skipped)"
    fi
done

# 5. Final System Updates
status "Performing final updates..."

if command -v apt-get >/dev/null; then
    apt-get update >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get -y upgrade >/dev/null 2>&1 || warning "Update failed"
    apt-get -y autoremove >/dev/null 2>&1
    apt-get clean >/dev/null 2>&1
elif command -v yum >/dev/null; then
    yum -y update >/dev/null 2>&1 || warning "Update failed"
    yum -y autoremove >/dev/null 2>&1
    yum clean all >/dev/null 2>&1
elif command -v dnf >/dev/null; then
    dnf -y update >/dev/null 2>&1 || warning "Update failed"
    dnf -y autoremove >/dev/null 2>&1
    dnf clean all >/dev/null 2>&1
fi

# 5. Apply All Changes
status "Applying all changes..."
systemctl daemon-reload >/dev/null 2>&1 && \
    success "Systemd daemon reloaded" || \
    warning "Failed to reload systemd daemon"

echo -e "\n${GREEN}✔ Optimization complete!${NC}"
echo -e "${YELLOW}Some changes require a reboot to take full effect.${NC}"
echo -e "Run this command to reboot: ${GREEN}reboot${NC}"

echo -e "\n${BLUE}Verification commands after reboot:${NC}"
echo "1. Check file limits: ${GREEN}ulimit -n${NC} (should show 1048576)"
echo "2. Check kernel settings: ${GREEN}sysctl -a | grep -e file_max -e swappiness${NC}"
echo "3. Check disabled services: ${GREEN}systemctl list-unit-files | grep -E 'avahi|cups|bluetooth|ModemManager'${NC}"
