#!/usr/bin/env bash

backup_create() {
    local stamp dir archive user
    stamp=$(date +%Y%m%d-%H%M%S)
    dir=$(mktemp -d)
    archive="$BACKUP_DIR/tunnelctl-$stamp.tar.gz"

    mkdir -p "$BACKUP_DIR" "$dir/etc"
    cp -a "$CONF_DIR" "$dir/etc/tunnelctl" 2>/dev/null || true
    [ -f "$SSHD_DROPIN" ] && cp -a "$SSHD_DROPIN" "$dir/sshd-tunnelctl.conf"
    [ -f "$STUNNEL_CONF" ] && cp -a "$STUNNEL_CONF" "$dir/stunnel-tunnelctl.conf"

    : > "$dir/accounts.txt"
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        printf '%s:%s\n' "$user" "$(getent shadow "$user" | cut -d: -f2)" >> "$dir/accounts.txt"
    done < <(db_names)
    chmod 600 "$dir/accounts.txt"

    printf '%s\n' "$TUNNELCTL_VERSION" > "$dir/version"

    tar -czf "$archive" -C "$dir" . 2>/dev/null
    chmod 600 "$archive"
    rm -rf "$dir"
    printf '%s' "$archive"
}

backup_restore() {
    local archive="$1" dir user hash expires maxconn quota used state
    [ -f "$archive" ] || { bad "Archive not found."; return 1; }
    dir=$(mktemp -d)
    tar -xzf "$archive" -C "$dir" 2>/dev/null || { bad "Archive is unreadable."; rm -rf "$dir"; return 1; }

    [ -d "$dir/etc/tunnelctl" ] || { bad "Archive does not contain a configuration."; rm -rf "$dir"; return 1; }

    cp -a "$dir/etc/tunnelctl/." "$CONF_DIR/" 2>/dev/null
    chmod 600 "$CONF_FILE" "$DB_FILE" 2>/dev/null || true
    load_config

    getent group "$TUNNEL_GROUP" >/dev/null 2>&1 || groupadd "$TUNNEL_GROUP"

    while IFS= read -r user; do
        [ -n "$user" ] || continue
        expires=$(db_expires "$user")
        hash=$(awk -F: -v u="$user" '$1 == u {print $2}' "$dir/accounts.txt" 2>/dev/null)
        if ! system_user_exists "$user"; then
            useradd -m -s /bin/bash -g "$TUNNEL_GROUP" "$user" >/dev/null 2>&1 || continue
        else
            usermod -g "$TUNNEL_GROUP" "$user" >/dev/null 2>&1 || true
        fi
        if [ -n "$hash" ]; then
            usermod -p "$hash" "$user" >/dev/null 2>&1 || true
        fi
        if [ "$expires" = "never" ]; then
            chage -E -1 "$user" 2>/dev/null || true
        else
            chage -E "$expires" "$user" 2>/dev/null || true
        fi
        acct_add "$user"
    done < <(db_names)

    rm -rf "$dir"
    ok "Configuration and $(db_count) accounts restored."
    log_event "restored backup $archive"
}

backup_list() {
    heading "Stored backups"
    if ! ls -1 "$BACKUP_DIR"/tunnelctl-*.tar.gz >/dev/null 2>&1; then
        plain "${C_GREY}No backups yet.${C_RESET}"
        blank
        return
    fi
    ls -1t "$BACKUP_DIR"/tunnelctl-*.tar.gz | head -n 15 | while IFS= read -r f; do
        printf '  %-46s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
    done
    blank
}

backup_prune() {
    ls -1t "$BACKUP_DIR"/tunnelctl-*.tar.gz 2>/dev/null | tail -n +15 | xargs -r rm -f
}

menu_backup() {
    local choice archive name
    while :; do
        banner
        backup_list
        plain "1) Create a backup now"
        plain "2) Restore from a backup"
        plain "3) Delete old backups"
        plain "0) Back"
        blank
        choice=$(ask "Select" "")
        case "$choice" in
            1) archive=$(backup_create)
               ok "Saved to $archive"
               backup_prune
               pause ;;
            2) name=$(ask "File name" "")
               [ -n "$name" ] && backup_restore "$BACKUP_DIR/$name"
               pause ;;
            3) backup_prune; ok "Old archives removed."; pause ;;
            0|q|"") return ;;
            *) bad "Unknown option."; sleep 1 ;;
        esac
    done
}
