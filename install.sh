#!/usr/bin/env bash

set -uo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/usr/local/lib/tunnelctl"
BIN_LINK="/usr/local/bin/tunnelctl"

. "$SOURCE_DIR/lib/common.sh"

need_root

detect_platform() {
    local id=""
    [ -f /etc/os-release ] && id=$(. /etc/os-release && printf '%s' "${ID:-}")
    printf '%s' "$id"
}

package_manager() {
    if have apt-get; then printf 'apt'
    elif have dnf; then printf 'dnf'
    elif have yum; then printf 'yum'
    else printf 'none'
    fi
}

install_dependencies() {
    local pm
    pm=$(package_manager)
    heading "Dependencies"
    case "$pm" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq openssh-server stunnel4 python3 openssl curl \
                iproute2 nftables ufw fail2ban procps coreutils >/dev/null 2>&1
            ;;
        dnf|yum)
            "$pm" install -y openssh-server stunnel python3 openssl curl \
                iproute nftables firewalld fail2ban procps-ng >/dev/null 2>&1
            ;;
        *)
            warn "Unknown package manager, install the dependencies manually."
            ;;
    esac

    local missing=""
    for tool in sshd python3 openssl ss chage useradd; do
        have "$tool" || missing="$missing $tool"
    done
    if [ -n "$missing" ]; then
        bad "Missing tools:$missing"
        return 1
    fi
    ok "All required packages are present."
    return 0
}

deploy_files() {
    heading "Installing files"
    rm -rf "$TARGET_DIR"
    mkdir -p "$TARGET_DIR"
    cp -a "$SOURCE_DIR/lib" "$TARGET_DIR/lib"
    cp -a "$SOURCE_DIR/libexec" "$TARGET_DIR/libexec"
    cp -a "$SOURCE_DIR/bin" "$TARGET_DIR/bin"
    chmod 755 "$TARGET_DIR/bin/tunnelctl" "$TARGET_DIR/libexec/hold" \
        "$TARGET_DIR/libexec/ws-proxy.py" "$TARGET_DIR/libexec/watchdog.sh"
    ln -sf "$TARGET_DIR/bin/tunnelctl" "$BIN_LINK"

    mkdir -p "$CONF_DIR" "$CERT_DIR" "$BACKUP_DIR"
    chmod 700 "$CONF_DIR" "$CERT_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
    db_init
    getent group "$TUNNEL_GROUP" >/dev/null 2>&1 || groupadd "$TUNNEL_GROUP"
    ok "Installed to $TARGET_DIR"
    ok "Command available as tunnelctl"
}

current_ssh_port() {
    local port
    port=$(ss -lntp 2>/dev/null | awk '/sshd/ {split($4, a, ":"); print a[length(a)]; exit}')
    [ -n "$port" ] || port=22
    printf '%s' "$port"
}

wizard() {
    local detected value

    heading "Setup"
    detected=$(detect_public_ip)
    value=$(ask "Public IP or domain of this server" "${SERVER_HOST:-$detected}")
    SERVER_HOST="$value"

    value=$(ask "SSH port for tunnel clients" "${SSH_PORT:-$(current_ssh_port)}")
    valid_port "$value" && SSH_PORT="$value"

    if ask_yes "Listen on a second SSH port as a fallback?" "y"; then
        value=$(ask "Second SSH port" "${SSH_EXTRA_PORT:-2222}")
        valid_port "$value" && SSH_EXTRA_PORT="$value"
    else
        SSH_EXTRA_PORT=""
    fi

    if ask_yes "Enable the TLS transport (stunnel)?" "y"; then
        ENABLE_TLS="yes"
        value=$(ask "TLS port" "${TLS_PORT:-443}")
        valid_port "$value" && TLS_PORT="$value"
    else
        ENABLE_TLS="no"
    fi

    if ask_yes "Enable the WebSocket transport?" "y"; then
        ENABLE_WS="yes"
        value=$(ask "WebSocket port" "${WS_PORT:-80}")
        valid_port "$value" && WS_PORT="$value"
        if [ "$ENABLE_TLS" = "yes" ]; then
            value=$(ask "WebSocket over TLS port" "${WSTLS_PORT:-8443}")
            valid_port "$value" && WSTLS_PORT="$value"
        fi
    else
        ENABLE_WS="no"
    fi

    value=$(ask "Default account validity in days" "${DEFAULT_DAYS:-30}")
    is_number "$value" && DEFAULT_DAYS="$value"
    value=$(ask "Default simultaneous connections per account" "${DEFAULT_MAXCONN:-2}")
    is_number "$value" && DEFAULT_MAXCONN="$value"
    value=$(ask "Default traffic quota in GB (0 = unlimited)" "${DEFAULT_QUOTA_GB:-0}")
    is_number "$value" && DEFAULT_QUOTA_GB="$value"

    write_config
    ok "Configuration written to $CONF_FILE"
}

port_conflicts() {
    local port busy=""
    for port in $(managed_ports); do
        if [ "$port" != "$SSH_PORT" ] && [ "$port" != "$SSH_EXTRA_PORT" ] && port_open "$port"; then
            busy="$busy $port"
        fi
    done
    if [ -n "$busy" ]; then
        warn "These ports are already in use:$busy"
        warn "Free them or pick different ports, otherwise those transports will not start."
    fi
}

summary() {
    banner
    heading "Ready"
    field "Server" "$SERVER_HOST"
    field "SSH" "$SSH_PORT${SSH_EXTRA_PORT:+ and $SSH_EXTRA_PORT}"
    [ "$ENABLE_TLS" = "yes" ] && field "TLS" "$TLS_PORT"
    [ "$ENABLE_WS" = "yes" ] && field "WebSocket" "$WS_PORT"
    [ "$ENABLE_TLS" = "yes" ] && [ "$ENABLE_WS" = "yes" ] && field "WebSocket over TLS" "$WSTLS_PORT"
    rule
    plain "Open the console with:  ${C_BOLD}tunnelctl${C_RESET}"
    plain "Create an account with: ${C_BOLD}tunnelctl add myuser 30 2 0${C_RESET}"
    blank
    plain "${C_GREY}Keep your current SSH session open until you have verified"
    plain "that you can log in again on the configured port.${C_RESET}"
    blank
}

main() {
    banner
    plain "This installer prepares an SSH tunnelling server with"
    plain "direct, TLS and WebSocket transports."
    blank
    field "Platform" "$(detect_platform) ($(package_manager))"
    field "Kernel" "$(uname -r)"
    blank

    install_dependencies || die "Dependency installation failed."
    deploy_files

    . "$TARGET_DIR/lib/common.sh"
    . "$TARGET_DIR/lib/users.sh"
    . "$TARGET_DIR/lib/services.sh"
    . "$TARGET_DIR/lib/security.sh"
    . "$TARGET_DIR/lib/monitor.sh"
    . "$TARGET_DIR/lib/backup.sh"

    load_config
    wizard
    port_conflicts

    heading "Transports"
    sshd_apply || die "SSH configuration failed."
    if [ "$ENABLE_TLS" = "yes" ]; then
        cert_generate && ok "Self signed certificate created."
        stunnel_apply
    fi
    [ "$ENABLE_WS" = "yes" ] && ws_apply
    watchdog_apply
    acct_bootstrap && ok "Traffic accounting enabled."

    firewall_apply

    heading "Hardening"
    sysctl_apply
    limits_apply
    if ask_yes "Enable fail2ban for the SSH ports?" "y"; then
        fail2ban_apply
    fi

    log_event "installation completed version $TUNNELCTL_VERSION"
    summary
}

main "$@"
