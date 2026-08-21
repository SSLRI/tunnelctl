#!/usr/bin/env bash

set -uo pipefail

TARGET_DIR="/usr/local/lib/tunnelctl"
BIN_LINK="/usr/local/bin/tunnelctl"

if [ -f "$TARGET_DIR/lib/common.sh" ]; then
    . "$TARGET_DIR/lib/common.sh"
else
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
fi
. "$TARGET_DIR/lib/users.sh" 2>/dev/null || true
. "$TARGET_DIR/lib/monitor.sh" 2>/dev/null || true

need_root
load_config

banner
heading "Uninstall"
plain "This removes the services, the configuration and optionally"
plain "every tunnel account created by this tool."
blank

if ! ask_yes "Continue?" "n"; then
    note "Nothing was changed."
    exit 0
fi

for unit in tunnelctl-ws.service tunnelctl-tls.service tunnelctl-watchdog.timer tunnelctl-watchdog.service; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$unit"
done
systemctl daemon-reload >/dev/null 2>&1
ok "Services removed."

if ask_yes "Delete every tunnel account as well?" "n"; then
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        pkill -KILL -u "$user" 2>/dev/null || true
        acct_del "$user" 2>/dev/null || true
        userdel -r "$user" >/dev/null 2>&1 || userdel "$user" >/dev/null 2>&1 || true
    done < <(db_names)
    groupdel "$TUNNEL_GROUP" >/dev/null 2>&1 || true
    ok "Accounts removed."
else
    note "Accounts were kept."
fi

nft delete table inet "$ACCT_TABLE" >/dev/null 2>&1 || true
nft delete table inet tunnelctl_fw >/dev/null 2>&1 || true

rm -f "$SSHD_DROPIN" "$STUNNEL_CONF" "$STUNNEL_CERT" /etc/fail2ban/jail.d/tunnelctl.conf \
      /etc/sysctl.d/99-tunnelctl.conf /etc/nftables.d/tunnelctl.nft

if [ -f "$SSHD_MAIN.tunnelctl.bak" ]; then
    cp -a "$SSHD_MAIN.tunnelctl.bak" "$SSHD_MAIN"
    ok "Original sshd_config restored."
fi
sshd -t 2>/dev/null && systemctl restart "$(sshd_service_name)" 2>/dev/null

if ask_yes "Delete configuration, database and backups?" "n"; then
    rm -rf "$CONF_DIR" "$BACKUP_DIR"
    ok "Data removed."
else
    note "Configuration kept in $CONF_DIR"
fi

rm -rf "$TARGET_DIR"
rm -f "$BIN_LINK"
sed -i '/tunnelctl/d' /etc/security/limits.conf 2>/dev/null || true

blank
ok "Uninstall finished."
blank
