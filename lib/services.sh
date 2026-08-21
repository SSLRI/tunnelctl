#!/usr/bin/env bash

WS_UNIT="tunnelctl-ws.service"
STUNNEL_UNIT="tunnelctl-tls.service"
WATCHDOG_UNIT="tunnelctl-watchdog.service"
WATCHDOG_TIMER="tunnelctl-watchdog.timer"

sshd_supports_dropin() {
    grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$SSHD_MAIN" 2>/dev/null
}

sshd_backup_once() {
    [ -f "$SSHD_MAIN.tunnelctl.bak" ] || cp -a "$SSHD_MAIN" "$SSHD_MAIN.tunnelctl.bak"
}

sshd_neutralize_ports() {
    sed -i -E 's/^([[:space:]]*Port[[:space:]]+[0-9]+)/#tunnelctl \1/' "$SSHD_MAIN"
}

sshd_render() {
    local target="$1"
    {
        printf 'Port %s\n' "$SSH_PORT"
        [ -n "$SSH_EXTRA_PORT" ] && printf 'Port %s\n' "$SSH_EXTRA_PORT"
        cat <<'EOF'
AddressFamily any
Protocol 2
PermitRootLogin prohibit-password
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
MaxAuthTries 3
MaxSessions 10
MaxStartups 20:40:100
LoginGraceTime 20
ClientAliveInterval 30
ClientAliveCountMax 4
TCPKeepAlive yes
UseDNS no
Compression no
AllowAgentForwarding no
X11Forwarding no
PrintMotd no
PrintLastLog no
Banner none
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,rsa-sha2-512,rsa-sha2-256
EOF
        printf '\n'
        printf 'Match Group %s\n' "$TUNNEL_GROUP"
        printf '    AllowTcpForwarding yes\n'
        printf '    AllowAgentForwarding no\n'
        printf '    GatewayPorts no\n'
        printf '    PermitTunnel no\n'
        printf '    PermitTTY yes\n'
        printf '    PermitUserRC no\n'
        printf '    X11Forwarding no\n'
        printf '    MaxSessions 4\n'
        printf '    ForceCommand %s/hold\n' "$LIBEXEC_DIR"
        printf 'Match all\n'
    } > "$target"
    chmod 644 "$target"
}

sshd_root_has_keys() {
    [ -s /root/.ssh/authorized_keys ]
}

sshd_apply() {
    local tmp
    sshd_backup_once

    if ! sshd_supports_dropin; then
        mkdir -p /etc/ssh/sshd_config.d
        if ! grep -q 'tunnelctl-include' "$SSHD_MAIN"; then
            sed -i '1i Include /etc/ssh/sshd_config.d/*.conf #tunnelctl-include' "$SSHD_MAIN"
        fi
    fi

    mkdir -p /etc/ssh/sshd_config.d
    sshd_neutralize_ports

    tmp=$(mktemp)
    sshd_render "$tmp"

    if ! sshd_root_has_keys; then
        sed -i 's/^PermitRootLogin prohibit-password/PermitRootLogin yes/' "$tmp"
    fi

    cp "$tmp" "$SSHD_DROPIN"
    rm -f "$tmp"

    if sshd -t 2>/dev/null; then
        systemctl restart "$(sshd_service_name)" 2>/dev/null
        ok "SSH daemon configured on port $SSH_PORT."
        sshd_root_has_keys || warn "Root has no SSH key, password login for root left enabled."
        return 0
    fi

    rm -f "$SSHD_DROPIN"
    cp -a "$SSHD_MAIN.tunnelctl.bak" "$SSHD_MAIN"
    bad "SSH config test failed, previous configuration restored."
    return 1
}

cert_generate() {
    local cn="${SERVER_HOST:-tunnel.local}"
    mkdir -p "$CERT_DIR"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$CERT_DIR/stunnel.key" \
        -out "$CERT_DIR/stunnel.crt" \
        -subj "/C=US/ST=Cloud/L=Edge/O=TunnelCTL/CN=$cn" >/dev/null 2>&1 || return 1
    cat "$CERT_DIR/stunnel.key" "$CERT_DIR/stunnel.crt" > "$CERT_FILE"
    chmod 600 "$CERT_FILE" "$CERT_DIR/stunnel.key"
    cert_publish
    return 0
}

cert_publish() {
    [ -f "$CERT_FILE" ] || return 1
    mkdir -p /etc/stunnel
    install -m 600 -o root -g root "$CERT_FILE" "$STUNNEL_CERT" 2>/dev/null ||         { cp "$CERT_FILE" "$STUNNEL_CERT" && chmod 600 "$STUNNEL_CERT"; }
    return 0
}

stunnel_binary() {
    if have stunnel; then printf 'stunnel'
    elif have stunnel4; then printf 'stunnel4'
    else printf ''
    fi
}

install_stunnel_package() {
    if have apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq stunnel4 >/dev/null 2>&1 || \
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq stunnel >/dev/null 2>&1
    elif have dnf; then
        dnf install -y stunnel >/dev/null 2>&1
    elif have yum; then
        yum install -y stunnel >/dev/null 2>&1
    fi
}

stunnel_apply() {
    local bin owner
    bin=$(stunnel_binary)
    if [ -z "$bin" ]; then
        note "stunnel is missing, trying to install it."
        install_stunnel_package
        bin=$(stunnel_binary)
    fi
    [ -n "$bin" ] || { bad "stunnel could not be installed, TLS transport skipped."; return 1; }

    if port_open "$TLS_PORT"; then
        owner=$(port_owner "$TLS_PORT")
        if [ "$owner" != "stunnel" ] && [ "$owner" != "stunnel4" ]; then
            bad "Port $TLS_PORT is already used by ${owner:-another process}."
            warn "Stop it, or choose another TLS port in Settings."
            return 1
        fi
    fi

    [ -f "$CERT_FILE" ] || cert_generate || { bad "Certificate generation failed."; return 1; }
    cert_publish || { bad "Certificate could not be published to /etc/stunnel."; return 1; }

    mkdir -p /etc/stunnel
    {
        printf 'foreground = yes\n'
        printf 'debug = 4\n'
        printf 'socket = l:TCP_NODELAY=1\n'
        printf 'socket = r:TCP_NODELAY=1\n'
        printf 'sslVersionMin = TLSv1.2\n'
        printf '\n'
        printf '[ssh-tls]\n'
        printf 'accept = 0.0.0.0:%s\n' "$TLS_PORT"
        printf 'connect = 127.0.0.1:%s\n' "$SSH_PORT"
        printf 'cert = %s\n' "$STUNNEL_CERT"
        printf 'TIMEOUTclose = 0\n'
        if [ "$ENABLE_WS" = "yes" ]; then
            printf '\n'
            printf '[ws-tls]\n'
            printf 'accept = 0.0.0.0:%s\n' "$WSTLS_PORT"
            printf 'connect = 127.0.0.1:%s\n' "$WS_PORT"
            printf 'cert = %s\n' "$STUNNEL_CERT"
            printf 'TIMEOUTclose = 0\n'
        fi
    } > "$STUNNEL_CONF"
    chmod 640 "$STUNNEL_CONF"

    cat > "/etc/systemd/system/$STUNNEL_UNIT" <<EOF
[Unit]
Description=TunnelCTL TLS transport
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v "$bin") $STUNNEL_CONF
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$STUNNEL_UNIT" >/dev/null 2>&1
    systemctl restart "$STUNNEL_UNIT" >/dev/null 2>&1
    sleep 2
    if svc_active "$STUNNEL_UNIT" && port_open "$TLS_PORT"; then
        ok "TLS transport listening on port $TLS_PORT."
        return 0
    fi
    bad "TLS transport failed to start. Last lines from its log:"
    journalctl -u "$STUNNEL_UNIT" -n 8 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
}

ws_apply() {
    local owner
    if port_open "$WS_PORT"; then
        owner=$(port_owner "$WS_PORT")
        if [ "$owner" != "python3" ] && [ "$owner" != "python" ]; then
            bad "Port $WS_PORT is already used by ${owner:-another process}."
            warn "Stop it, or choose another WebSocket port in Settings."
            return 1
        fi
    fi

    cat > "/etc/systemd/system/$WS_UNIT" <<EOF
[Unit]
Description=TunnelCTL WebSocket transport
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v python3) $LIBEXEC_DIR/ws-proxy.py --listen 0.0.0.0:$WS_PORT --target 127.0.0.1:$SSH_PORT
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$WS_UNIT" >/dev/null 2>&1
    systemctl restart "$WS_UNIT" >/dev/null 2>&1
    sleep 2
    if svc_active "$WS_UNIT" && port_open "$WS_PORT"; then
        ok "WebSocket transport listening on port $WS_PORT."
        return 0
    fi
    bad "WebSocket transport failed to start. Last lines from its log:"
    journalctl -u "$WS_UNIT" -n 8 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
}

watchdog_apply() {
    cat > "/etc/systemd/system/$WATCHDOG_UNIT" <<EOF
[Unit]
Description=TunnelCTL policy enforcement

[Service]
Type=oneshot
ExecStart=/bin/bash $LIBEXEC_DIR/watchdog.sh
EOF

    cat > "/etc/systemd/system/$WATCHDOG_TIMER" <<EOF
[Unit]
Description=TunnelCTL policy enforcement schedule

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=10

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$WATCHDOG_TIMER" >/dev/null 2>&1
    svc_active "$WATCHDOG_TIMER" && ok "Policy watchdog scheduled every minute."
}

services_restart_all() {
    systemctl restart "$(sshd_service_name)" 2>/dev/null
    [ "$ENABLE_TLS" = "yes" ] && systemctl restart "$STUNNEL_UNIT" 2>/dev/null
    [ "$ENABLE_WS" = "yes" ] && systemctl restart "$WS_UNIT" 2>/dev/null
    ok "All transports restarted."
}

transports_repair() {
    heading "Rebuilding transports"
    sshd_apply || return 1
    if [ "$ENABLE_TLS" = "yes" ]; then
        stunnel_apply || warn "TLS transport is not running."
    fi
    if [ "$ENABLE_WS" = "yes" ]; then
        ws_apply || warn "WebSocket transport is not running."
    fi
    watchdog_apply
    acct_bootstrap >/dev/null 2>&1 && ok "Traffic accounting ready."
    firewall_apply
    blank
    transports_check
}

transports_check() {
    local port state
    heading "Reachability check"
    for port in $(managed_ports); do
        if port_open "$port"; then
            state="${C_GREEN}listening${C_RESET}"
        else
            state="${C_RED}closed${C_RESET}"
        fi
        printf '  %-22s %b %s\n' "tcp/$port" "$state" "$(port_owner "$port")"
    done
    blank
}

services_overview() {
    heading "Transports"
    printf '  %-22s %s %s\n' "SSH direct" \
        "$(padded "$(svc_badge "$(sshd_service_name).service")" 15)" "port $SSH_PORT"
    if [ "$ENABLE_TLS" = "yes" ]; then
        printf '  %-22s %s %s\n' "TLS (stunnel)" \
            "$(padded "$(svc_badge "$STUNNEL_UNIT")" 15)" "port $TLS_PORT"
    fi
    if [ "$ENABLE_WS" = "yes" ]; then
        printf '  %-22s %s %s\n' "WebSocket" \
            "$(padded "$(svc_badge "$WS_UNIT")" 15)" "port $WS_PORT"
    fi
    if [ "$ENABLE_TLS" = "yes" ] && [ "$ENABLE_WS" = "yes" ]; then
        printf '  %-22s %s %s\n' "WebSocket over TLS" \
            "$(padded "$(svc_badge "$STUNNEL_UNIT")" 15)" "port $WSTLS_PORT"
    fi
    printf '  %-22s %s %s\n' "Watchdog" \
        "$(padded "$(svc_badge "$WATCHDOG_TIMER")" 15)" "every 60s"
    blank
    heading "Listening sockets"
    ss -lntp 2>/dev/null | awk 'NR == 1 || /sshd|stunnel|python/ {print "  " $0}' | head -n 15
    blank
}

menu_services() {
    local choice
    while :; do
        banner
        services_overview
        plain "1) Restart every transport      4) Rebuild TLS certificate"
        plain "2) Rebuild SSH configuration    5) Live logs"
        plain "3) Repair everything            0) Back"
        blank
        choice=$(ask "Select" "")
        case "$choice" in
            1) services_restart_all; pause ;;
            2) sshd_apply; pause ;;
            3) transports_repair; pause ;;
            4) if cert_generate; then
                   ok "New certificate generated."
                   systemctl restart "$STUNNEL_UNIT" 2>/dev/null
               else
                   bad "Generation failed."
               fi
               pause ;;
            5) note "Press Ctrl+C to return."
               sleep 1
               journalctl -u "$WS_UNIT" -u "$STUNNEL_UNIT" -u "$(sshd_service_name)" -n 60 -f 2>/dev/null || true
               ;;
            0|q|"") return ;;
            *) bad "Unknown option."; sleep 1 ;;
        esac
    done
}
