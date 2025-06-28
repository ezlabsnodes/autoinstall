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
* soft memlock unlimited
* hard memlock unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft nproc unlimited
root hard nproc unlimited
root soft memlock unlimited
root hard memlock unlimited
EOF
    success "Added limits to /etc/security/limits.conf"
else
    success "System limits already configured (skipped)"
fi

# Apply immediately where possible
ulimit -n 1048576 >/dev/null 2>&1 || warning "Couldn't increase current session limits (reboot required)"
success "Set immediate file descriptor limit attempt"

# Configure systemd limits
mkdir -p /etc/systemd/system.conf.d/
cat <<EOF > /etc/systemd/system.conf.d/limits.conf
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
DefaultLimitMEMLOCK=infinity
EOF
success "Configured systemd limits"

# Verify settings
status "Current limits verification:"
echo -e "${BLUE}Session limits:${NC}"
ulimit -a | grep -E 'open files|processes'
echo -e "\n${BLUE}System-wide limits:${NC}"
cat /proc/sys/fs/file-max
