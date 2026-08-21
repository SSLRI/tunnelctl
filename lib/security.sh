#!/usr/bin/env bash

SYSCTL_FILE="/etc/sysctl.d/99-tunnelctl.conf"
F2B_JAIL="/etc/fail2ban/jail.d/tunnelctl.conf"
NFT_FILE="/etc/nftables.d/tunnelctl.nft"

managed_ports() {
    local ports="$SSH_PORT" extra
    [ -n "$SSH_EXTRA_PORT" ] && ports="$ports $SSH_EXTRA_PORT"
    [ "$ENABLE_TLS" = "yes" ] && ports="$ports $TLS_PORT"
    [ "$ENABLE_WS" = "yes" ] && ports="$ports $WS_PORT"
    [ "$ENABLE_TLS" = "yes" ] && [ "$ENABLE_WS" = "yes" ] && ports="$ports $WSTLS_PORT"
    for extra in $(active_ssh_ports); do
        ports="$ports $extra"
    done
    printf '%s' "$ports" | tr ' ' '\n' | awk 'NF' | sort -un | tr '\n' ' ' | sed 's/ $//'
}

firewall_backend() {
    if have ufw; then printf 'ufw'
    elif have firewall-cmd; then printf 'firewalld'
    elif have nft; then printf 'nftables'
    else printf 'none'
    fi
}

firewall_ufw() {
    local port
    for port in $(managed_ports); do
        ufw allow "$port/tcp" >/dev/null 2>&1
        ok "Allowed inbound tcp/$port"
    done
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    yes | ufw enable >/dev/null 2>&1 || ufw --force enable >/dev/null 2>&1
    ok "ufw is active with a default deny policy."
}

firewall_firewalld() {
    local port
    systemctl enable --now firewalld >/dev/null 2>&1
    for port in $(managed_ports); do
        firewall-cmd --permanent --add-port="$port/tcp" >/dev/null 2>&1
        ok "Allowed inbound tcp/$port"
    done
    firewall-cmd --reload >/dev/null 2>&1
    ok "firewalld reloaded."
}

firewall_nftables() {
    local port allow=""
    for port in $(managed_ports); do
        allow="${allow}${allow:+, }$port"
    done
    [ -n "$allow" ] || { bad "No ports to allow."; return 1; }
    mkdir -p /etc/nftables.d
    cat > "$NFT_FILE" <<EOF
table inet tunnelctl_fw {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iif lo accept
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept
        tcp dport { $allow } accept
        counter drop
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
    nft delete table inet tunnelctl_fw >/dev/null 2>&1 || true
    if nft -f "$NFT_FILE" 2>/dev/null; then
        touch /etc/nftables.conf
        if ! grep -q 'tunnelctl.nft' /etc/nftables.conf 2>/dev/null; then
            printf 'include "%s"\n' "$NFT_FILE" >> /etc/nftables.conf
        fi
        systemctl enable nftables >/dev/null 2>&1
        ok "nftables ruleset applied and persisted."
    else
        bad "nftables ruleset was rejected, nothing changed."
        return 1
    fi
}

firewall_apply() {
    local backend
    backend=$(firewall_backend)
    heading "Firewall ($backend)"
    note "Ports kept open: $(managed_ports)"
    case "$backend" in
        ufw)       firewall_ufw ;;
        firewalld) firewall_firewalld ;;
        nftables)  firewall_nftables ;;
        *) warn "No supported firewall found, install ufw or nftables." ;;
    esac
    log_event "firewall applied via $backend for ports $(managed_ports)"
}

firewall_status() {
    local backend
    backend=$(firewall_backend)
    heading "Firewall"
    field "Backend" "$backend"
    field "Open ports" "$(managed_ports)"
    case "$backend" in
        ufw) ufw status 2>/dev/null | sed 's/^/  /' | head -n 14 ;;
        firewalld) firewall-cmd --list-ports 2>/dev/null | sed 's/^/  /' ;;
        nftables) nft list table inet tunnelctl_fw 2>/dev/null | sed 's/^/  /' | head -n 18 ;;
    esac
    blank
}

fail2ban_apply() {
    have fail2ban-client || { warn "fail2ban is not installed."; return 1; }
    mkdir -p /etc/fail2ban/jail.d
    cat > "$F2B_JAIL" <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled  = true
port     = $(managed_ports | tr ' ' ',')
maxretry = 6
bantime  = 7200
EOF
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    sleep 1
    if svc_active fail2ban; then
        FAIL2BAN_ENABLED="yes"
        write_config
        ok "fail2ban is protecting the SSH ports."
    else
        bad "fail2ban did not start, check: journalctl -u fail2ban -n 30"
        return 1
    fi
}

sysctl_apply() {
    cat > "$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
fs.file-max = 1000000
EOF
    modprobe tcp_bbr >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1
    if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        ok "Network stack tuned, BBR is active."
    else
        warn "Network stack tuned, but this kernel does not offer BBR."
    fi
}

limits_apply() {
    if ! grep -q 'tunnelctl' /etc/security/limits.conf 2>/dev/null; then
        {
            printf '* soft nofile 65535 #tunnelctl\n'
            printf '* hard nofile 65535 #tunnelctl\n'
        } >> /etc/security/limits.conf
    fi
    mkdir -p /etc/systemd/system.conf.d
    printf '[Manager]\nDefaultLimitNOFILE=65535\n' > /etc/systemd/system.conf.d/tunnelctl.conf
    systemctl daemon-reexec >/dev/null 2>&1 || true
    ok "File descriptor limits raised."
}

security_report() {
    local cfg="$SSHD_DROPIN"
    heading "Hardening status"
    if [ -f "$cfg" ]; then
        field "Root login" "$(awk '/^PermitRootLogin/ {print $2; exit}' "$cfg")"
        field "Password auth" "$(awk '/^PasswordAuthentication/ {print $2; exit}' "$cfg")"
        field "Max auth tries" "$(awk '/^MaxAuthTries/ {print $2; exit}' "$cfg")"
    else
        field "SSH policy" "not applied yet"
    fi
    field "fail2ban" "$(svc_active fail2ban && echo running || echo off)"
    field "Congestion control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    field "Firewall backend" "$(firewall_backend)"
    if have fail2ban-client; then
        field "Banned right now" "$(fail2ban-client status sshd 2>/dev/null | \
            awk -F: '/Currently banned/ {gsub(/ /, "", $2); print $2}')"
    fi
    blank
}

menu_security() {
    local choice
    while :; do
        banner
        security_report
        firewall_status
        plain "1) Reapply firewall rules       4) Raise file limits"
        plain "2) Enable or refresh fail2ban   5) Show banned addresses"
        plain "3) Apply kernel tuning          0) Back"
        blank
        choice=$(ask "Select" "")
        case "$choice" in
            1) firewall_apply; pause ;;
            2) fail2ban_apply; pause ;;
            3) sysctl_apply; pause ;;
            4) limits_apply; pause ;;
            5) fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' || warn "fail2ban not available."
               pause ;;
            0|q|"") return ;;
            *) bad "Unknown option."; sleep 1 ;;
        esac
    done
}
