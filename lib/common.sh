#!/usr/bin/env bash

export LC_ALL=C

TUNNELCTL_VERSION="1.1.2"
APP_NAME="TunnelCTL"
APP_DIR="/usr/local/lib/tunnelctl"
LIBEXEC_DIR="$APP_DIR/libexec"
CONF_DIR="/etc/tunnelctl"
CONF_FILE="$CONF_DIR/tunnelctl.conf"
DB_FILE="$CONF_DIR/users.db"
CERT_DIR="$CONF_DIR/certs"
CERT_FILE="$CERT_DIR/stunnel.pem"
STUNNEL_CERT="/etc/stunnel/tunnelctl.pem"
LOG_FILE="/var/log/tunnelctl.log"
BACKUP_DIR="/var/backups/tunnelctl"
LOCK_FILE="/run/tunnelctl.lock"
TUNNEL_GROUP="tunnel"
ACCT_TABLE="tnl_acct"
SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DROPIN="/etc/ssh/sshd_config.d/10-tunnelctl.conf"
STUNNEL_CONF="/etc/stunnel/tunnelctl.conf"
SSHD_PROC="sshd|sshd-session"
UI_WIDTH=64

SERVER_HOST=""
SSH_PORT="22"
SSH_EXTRA_PORT=""
TLS_PORT="443"
WS_PORT="80"
WSTLS_PORT="8443"
ENABLE_TLS="yes"
ENABLE_WS="yes"
DEFAULT_DAYS="30"
DEFAULT_MAXCONN="2"
DEFAULT_QUOTA_GB="0"
FAIL2BAN_ENABLED="no"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
    C_GREY=$'\033[90m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""
    C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_GREY=""
fi

ok()   { printf '  %s%s%s %s\n' "$C_GREEN" "+" "$C_RESET" "$*"; }
bad()  { printf '  %s%s%s %s\n' "$C_RED" "x" "$C_RESET" "$*" >&2; }
warn() { printf '  %s%s%s %s\n' "$C_YELLOW" "!" "$C_RESET" "$*"; }
note() { printf '  %s%s%s %s\n' "$C_CYAN" "-" "$C_RESET" "$*"; }
plain(){ printf '  %s\n' "$*"; }
blank(){ printf '\n'; }

strip_ansi() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'; }

padded() {
    local text="$1" width="$2" bare len pad
    bare=$(strip_ansi "$text")
    len=${#bare}
    pad=$(( width - len ))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s%*s' "$text" "$pad" ""
}

rule() {
    local i out=""
    for (( i = 0; i < UI_WIDTH; i++ )); do out="$out-"; done
    printf '  %s%s%s\n' "$C_GREY" "$out" "$C_RESET"
}

heading() {
    blank
    printf '  %s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
    rule
}

banner() {
    clear 2>/dev/null
    blank
    printf '  %s%s %s%s  %sSSH Tunnel Suite%s\n' \
        "$C_BOLD" "$APP_NAME" "$TUNNELCTL_VERSION" "$C_RESET" "$C_GREY" "$C_RESET"
    rule
}

field() { printf '  %-22s %s\n' "$1" "$2"; }

log_event() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

die() { bad "$1"; exit "${2:-1}"; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "This tool must be run as root. Try: sudo tunnelctl"
}

have() { command -v "$1" >/dev/null 2>&1; }

tty_write() {
    if [ -e /dev/tty ] && [ -w /dev/tty ]; then
        printf '%s' "$1" > /dev/tty
    else
        printf '%s' "$1" >&2
    fi
}

tty_read() {
    local answer=""
    if [ -e /dev/tty ] && [ -r /dev/tty ]; then
        IFS= read -r answer < /dev/tty || true
    else
        IFS= read -r answer || true
    fi
    answer="${answer%$'\r'}"
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    printf '%s' "$answer"
}

pause() {
    blank
    tty_write "  ${C_GREY}Press Enter to continue${C_RESET} "
    tty_read >/dev/null
}

ask() {
    local prompt="$1" default="${2:-}" reply
    if [ -n "$default" ]; then
        tty_write "  $prompt ${C_GREY}[$default]${C_RESET} "
    else
        tty_write "  $prompt "
    fi
    reply=$(tty_read)
    printf '%s' "${reply:-$default}"
}

ask_yes() {
    local prompt="$1" default="${2:-y}" reply hint="Y/n"
    [ "$default" = "n" ] && hint="y/N"
    tty_write "  $prompt ${C_GREY}[$hint]${C_RESET} "
    reply=$(tty_read)
    reply="${reply:-$default}"
    case "$reply" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

valid_port() {
    is_number "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_username() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]{2,29}$ ]]
}

random_secret() {
    local len="${1:-12}" out
    out=$(head -c 512 /dev/urandom 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$len")
    [ -n "$out" ] || out=$(date +%s%N | sha256sum | head -c "$len")
    printf '%s' "$out"
}

human_bytes() {
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN {
        split("B KB MB GB TB PB", u, " ")
        i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]
        else printf "%.2f %s", b, u[i]
    }'
}

today_epoch() { date -u -d "today 00:00" +%s 2>/dev/null || date -u +%s; }

date_plus_days() { date -u -d "+$1 days" +%Y-%m-%d; }

days_left() {
    local expires="$1"
    [ "$expires" = "never" ] && { printf 'unlimited'; return; }
    local target now
    target=$(date -u -d "$expires" +%s 2>/dev/null) || { printf '?'; return; }
    now=$(today_epoch)
    printf '%s' "$(( (target - now) / 86400 ))"
}

is_expired() {
    local expires="$1"
    [ "$expires" = "never" ] && return 1
    local target now
    target=$(date -u -d "$expires" +%s 2>/dev/null) || return 1
    now=$(today_epoch)
    [ "$now" -gt "$target" ]
}

detect_public_ip() {
    local ip="" url
    if have curl; then
        for url in https://api.ipify.org https://ipinfo.io/ip https://api.ip.sb/ip \
                   https://ifconfig.me/ip https://icanhazip.com; do
            ip=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
            [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$ip"; return; }
            ip=""
        done
    fi
    if have ip; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}')
        [ -n "$ip" ] && { printf '%s' "$ip"; return; }
    fi
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s' "$ip"
}

active_ssh_ports() {
    ss -lntH 2>/dev/null | awk '/sshd/ {n = split($4, a, ":"); print a[n]}' | sort -un | tr '\n' ' '
}

load_config() {
    [ -f "$CONF_FILE" ] && . "$CONF_FILE"
    [ -n "$SERVER_HOST" ] || SERVER_HOST=$(detect_public_ip)
}

write_config() {
    mkdir -p "$CONF_DIR"
    cat > "$CONF_FILE" <<EOF
SERVER_HOST="$SERVER_HOST"
SSH_PORT="$SSH_PORT"
SSH_EXTRA_PORT="$SSH_EXTRA_PORT"
TLS_PORT="$TLS_PORT"
WS_PORT="$WS_PORT"
WSTLS_PORT="$WSTLS_PORT"
ENABLE_TLS="$ENABLE_TLS"
ENABLE_WS="$ENABLE_WS"
DEFAULT_DAYS="$DEFAULT_DAYS"
DEFAULT_MAXCONN="$DEFAULT_MAXCONN"
DEFAULT_QUOTA_GB="$DEFAULT_QUOTA_GB"
FAIL2BAN_ENABLED="$FAIL2BAN_ENABLED"
EOF
    chmod 600 "$CONF_FILE"
}

db_init() {
    mkdir -p "$CONF_DIR"
    [ -f "$DB_FILE" ] || : > "$DB_FILE"
    chmod 600 "$DB_FILE"
}

db_lock() {
    exec 9>"$LOCK_FILE"
    flock -w 10 9 2>/dev/null || true
}

db_unlock() { exec 9>&- 2>/dev/null || true; }

db_names() { awk -F'|' 'NF >= 7 {print $1}' "$DB_FILE" 2>/dev/null; }

db_has() { grep -q "^$1|" "$DB_FILE" 2>/dev/null; }

db_field() {
    awk -F'|' -v u="$1" -v n="$2" '$1 == u {print $n; exit}' "$DB_FILE" 2>/dev/null
}

db_created()  { db_field "$1" 2; }
db_expires()  { db_field "$1" 3; }
db_maxconn()  { db_field "$1" 4; }
db_quota()    { db_field "$1" 5; }
db_used()     { db_field "$1" 6; }
db_state()    { db_field "$1" 7; }

db_insert() {
    db_lock
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$DB_FILE"
    db_unlock
}

db_update() {
    local user="$1" col="$2" value="$3" tmp
    tmp=$(mktemp)
    db_lock
    awk -F'|' -v OFS='|' -v u="$user" -v c="$col" -v v="$value" \
        '$1 == u { $c = v } {print}' "$DB_FILE" > "$tmp" 2>/dev/null
    cat "$tmp" > "$DB_FILE"
    db_unlock
    rm -f "$tmp"
}

db_remove() {
    local user="$1" tmp
    tmp=$(mktemp)
    db_lock
    grep -v "^$user|" "$DB_FILE" > "$tmp" 2>/dev/null || true
    cat "$tmp" > "$DB_FILE"
    db_unlock
    rm -f "$tmp"
}

db_count() { db_names | wc -l | tr -d ' '; }

svc_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

svc_badge() {
    if svc_active "$1"; then
        printf '%sactive%s' "$C_GREEN" "$C_RESET"
    elif svc_exists "$1"; then
        printf '%sstopped%s' "$C_RED" "$C_RESET"
    else
        printf '%snot installed%s' "$C_GREY" "$C_RESET"
    fi
}

port_open() {
    ss -lntH 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" {found = 1} END {exit !found}'
}

port_owner() {
    ss -lntpH 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" {print $0; exit}' | \
        sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p'
}

sshd_service_name() {
    if systemctl cat ssh.service >/dev/null 2>&1; then
        printf 'ssh'
    else
        printf 'sshd'
    fi
}

reload_sshd() {
    if sshd -t 2>/dev/null; then
        systemctl reload "$(sshd_service_name)" 2>/dev/null || \
            systemctl restart "$(sshd_service_name)" 2>/dev/null
        return 0
    fi
    return 1
}
