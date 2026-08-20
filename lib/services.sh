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
    return 0
}

stunnel_binary() {
    if have stunnel; then printf 'stunnel'
    elif have stunnel4; then printf 'stunnel4'
    else printf ''
    fi
}

stunnel_apply() {
    local bin
    bin=$(stunnel_binary)
    [ -n "$bin" ] || { bad "stunnel is not installed."; return 1; }
    [ -f "$CERT_FILE" ] || cert_generate || { bad "Certificate generation failed."; return 1; }

    mkdir -p /etc/stunnel
    {
        printf 'pid = /run/tunnelctl-tls.pid\n'
        printf 'foreground = yes\n'
        printf 'debug = 3\n'
        printf 'socket = l:TCP_NODELAY=1\n'
        printf 'socket = r:TCP_NODELAY=1\n'
        printf 'options = NO_SSLv2\n'
        printf 'options = NO_SSLv3\n'
        printf 'options = NO_TLSv1\n'
        printf 'options = NO_TLSv1.1\n'
        printf 'sslVersion = all\n'
        printf 'ciphers = ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256\n'
        printf '\n'
        printf '[ssh-tls]\n'
        printf 'accept = 0.0.0.0:%s\n' "$TLS_PORT"
        printf 'connect = 127.0.0.1:%s\n' "$SSH_PORT"
        printf 'cert = %s\n' "$CERT_FILE"
        printf 'TIMEOUTclose = 0\n'
        if [ "$ENABLE_WS" = "yes" ]; then
            printf '\n'
            printf '[ws-tls]\n'
            printf 'accept = 0.0.0.0:%s\n' "$WSTLS_PORT"
            printf 'connect = 127.0.0.1:%s\n' "$WS_PORT"
            printf 'cert = %s\n' "$CERT_FILE"
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
    systemctl enable --now "$STUNNEL_UNIT" >/dev/null 2>&1
    if svc_active "$STUNNEL_UNIT"; then
        ok "TLS transport listening on port $TLS_PORT."
        return 0
    fi
    bad "TLS transport failed to start, check: journalctl -u $STUNNEL_UNIT"
    return 1
}

ws_apply() {
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
    systemctl enable --now "$WS_UNIT" >/dev/null 2>&1
    if svc_active "$WS_UNIT"; then
        ok "WebSocket transport listening on port $WS_PORT."
        return 0
    fi
    bad "WebSocket transport failed to start, check: journalctl -u $WS_UNIT"
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

services_overview() {
    heading "Transports"
    printf '  %-22s %-12b %s\n' "SSH direct" "$(svc_badge "$(sshd_service_name).service")" "port $SSH_PORT"
    if [ "$ENABLE_TLS" = "yes" ]; then
        printf '  %-22s %-12b %s\n' "TLS (stunnel)" "$(svc_badge "$STUNNEL_UNIT")" "port $TLS_PORT"
    fi
    if [ "$ENABLE_WS" = "yes" ]; then
        printf '  %-22s %-12b %s\n' "WebSocket" "$(svc_badge "$WS_UNIT")" "port $WS_PORT"
    fi
    if [ "$ENABLE_TLS" = "yes" ] && [ "$ENABLE_WS" = "yes" ]; then
        printf '  %-22s %-12b %s\n' "WebSocket over TLS" "$(svc_badge "$STUNNEL_UNIT")" "port $WSTLS_PORT"
    fi
    printf '  %-22s %-12b %s\n' "Watchdog" "$(svc_badge "$WATCHDOG_TIMER")" "every 60s"
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
        plain "3) Rebuild TLS and WebSocket    0) Back"
        blank
        choice=$(ask "Select" "")
        case "$choice" in
            1) services_restart_all; pause ;;
            2) sshd_apply; pause ;;
            3) [ "$ENABLE_TLS" = "yes" ] && stunnel_apply
               [ "$ENABLE_WS" = "yes" ] && ws_apply
               pause ;;
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
