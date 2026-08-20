#!/usr/bin/env bash

system_user_exists() { id "$1" >/dev/null 2>&1; }

user_sessions() {
    pgrep -x sshd -u "$1" 2>/dev/null | wc -l | tr -d ' '
}

kill_sessions() {
    pkill -KILL -u "$1" 2>/dev/null || true
}

user_status_label() {
    local user="$1" state expires
    state=$(db_state "$user")
    expires=$(db_expires "$user")
    if [ "$state" = "locked" ]; then
        printf '%slocked%s' "$C_RED" "$C_RESET"
    elif is_expired "$expires"; then
        printf '%sexpired%s' "$C_YELLOW" "$C_RESET"
    else
        printf '%sactive%s' "$C_GREEN" "$C_RESET"
    fi
}

user_create() {
    local user="$1" pass="$2" days="$3" maxconn="$4" quota_gb="$5"
    local expires quota_bytes

    if [ "$days" = "0" ] || [ "$days" = "never" ]; then
        expires="never"
    else
        expires=$(date_plus_days "$days")
    fi
    quota_bytes=$(awk -v g="$quota_gb" 'BEGIN {printf "%.0f", g * 1073741824}')

    getent group "$TUNNEL_GROUP" >/dev/null 2>&1 || groupadd "$TUNNEL_GROUP"

    useradd -m -s /bin/bash -g "$TUNNEL_GROUP" "$user" >/dev/null 2>&1 || return 1
    printf '%s:%s\n' "$user" "$pass" | chpasswd || return 1
    chmod 750 "/home/$user" 2>/dev/null || true

    if [ "$expires" = "never" ]; then
        chage -E -1 "$user" 2>/dev/null || true
    else
        chage -E "$expires" "$user" 2>/dev/null || true
    fi
    chage -m 0 -M 99999 -I -1 "$user" 2>/dev/null || true

    db_insert "$user" "$(date -u +%Y-%m-%d)" "$expires" "$maxconn" "$quota_bytes" "0" "active"
    acct_add "$user"
    log_event "created user $user expires=$expires maxconn=$maxconn quota=${quota_gb}GB"
    return 0
}

user_delete() {
    local user="$1"
    kill_sessions "$user"
    acct_del "$user"
    userdel -r "$user" >/dev/null 2>&1 || userdel "$user" >/dev/null 2>&1 || true
    db_remove "$user"
    log_event "deleted user $user"
}

user_lock() {
    local user="$1"
    usermod -L "$user" 2>/dev/null || true
    chage -E 1 "$user" 2>/dev/null || true
    kill_sessions "$user"
    db_update "$user" 7 "locked"
    log_event "locked user $user"
}

user_unlock() {
    local user="$1" expires
    expires=$(db_expires "$user")
    usermod -U "$user" 2>/dev/null || true
    if [ "$expires" = "never" ]; then
        chage -E -1 "$user" 2>/dev/null || true
    else
        chage -E "$expires" "$user" 2>/dev/null || true
    fi
    db_update "$user" 7 "active"
    log_event "unlocked user $user"
}

user_extend() {
    local user="$1" days="$2" current base expires
    current=$(db_expires "$user")
    if [ "$days" = "0" ] || [ "$days" = "never" ]; then
        expires="never"
    else
        if [ "$current" = "never" ] || is_expired "$current"; then
            base=$(date -u +%Y-%m-%d)
        else
            base="$current"
        fi
        expires=$(date -u -d "$base +$days days" +%Y-%m-%d)
    fi
    db_update "$user" 3 "$expires"
    if [ "$expires" = "never" ]; then
        chage -E -1 "$user" 2>/dev/null || true
    else
        chage -E "$expires" "$user" 2>/dev/null || true
    fi
    usermod -U "$user" 2>/dev/null || true
    db_update "$user" 7 "active"
    log_event "extended user $user to $expires"
    printf '%s' "$expires"
}

user_set_password() {
    printf '%s:%s\n' "$1" "$2" | chpasswd
    log_event "password changed for $1"
}

user_card() {
    local user="$1" pass="$2"
    local expires maxconn quota used

    expires=$(db_expires "$user")
    maxconn=$(db_maxconn "$user")
    quota=$(db_quota "$user")
    used=$(db_used "$user")

    heading "Account $user"
    field "Server" "$SERVER_HOST"
    field "Username" "$user"
    [ -n "$pass" ] && field "Password" "$pass"
    field "SSH port" "$SSH_PORT${SSH_EXTRA_PORT:+, $SSH_EXTRA_PORT}"
    [ "$ENABLE_TLS" = "yes" ] && field "SSL / TLS port" "$TLS_PORT"
    [ "$ENABLE_WS" = "yes" ] && field "WebSocket port" "$WS_PORT"
    [ "$ENABLE_TLS" = "yes" ] && [ "$ENABLE_WS" = "yes" ] && field "WebSocket over TLS" "$WSTLS_PORT"
    field "Expires" "$expires ($(days_left "$expires") days left)"
    field "Max connections" "$maxconn"
    if [ "$quota" = "0" ]; then
        field "Traffic quota" "unlimited"
    else
        field "Traffic quota" "$(human_bytes "$used") of $(human_bytes "$quota")"
    fi
    rule
    plain "${C_GREY}Payload for HTTP injector style clients${C_RESET}"
    plain "GET / HTTP/1.1[crlf]Host: $SERVER_HOST[crlf]Upgrade: websocket[crlf][crlf]"
    blank
    plain "${C_GREY}Command line client${C_RESET}"
    plain "ssh -N -D 1080 -p $SSH_PORT $user@$SERVER_HOST"
    blank
}

user_list_table() {
    local user expires state used quota online left
    heading "Accounts"
    printf '  %-16s %-9s %-12s %-6s %-8s %s\n' \
        "USER" "STATUS" "EXPIRES" "LEFT" "ONLINE" "TRAFFIC"
    rule
    if [ "$(db_count)" = "0" ]; then
        plain "${C_GREY}No accounts yet.${C_RESET}"
        blank
        return
    fi
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        expires=$(db_expires "$user")
        used=$(db_used "$user")
        quota=$(db_quota "$user")
        online=$(user_sessions "$user")
        left=$(days_left "$expires")
        [ "$left" = "unlimited" ] && left="inf"
        state=$(user_status_label "$user")
        if [ "$quota" = "0" ]; then
            printf '  %-16s %-18b %-12s %-6s %-8s %s\n' \
                "$user" "$state" "$expires" "$left" "$online/$(db_maxconn "$user")" \
                "$(human_bytes "$used")"
        else
            printf '  %-16s %-18b %-12s %-6s %-8s %s\n' \
                "$user" "$state" "$expires" "$left" "$online/$(db_maxconn "$user")" \
                "$(human_bytes "$used") / $(human_bytes "$quota")"
        fi
    done < <(db_names)
    blank
}

menu_user_add() {
    local user pass days maxconn quota generated

    heading "New account"
    while :; do
        user=$(ask "Username" "")
        if [ -z "$user" ]; then return; fi
        if ! valid_username "$user"; then
            bad "Use 3 to 30 characters: lowercase letters, digits, dash, underscore."
            continue
        fi
        if system_user_exists "$user"; then
            bad "That name is already taken on this system."
            continue
        fi
        break
    done

    generated=$(random_secret 12)
    pass=$(ask "Password" "$generated")
    days=$(ask "Valid for how many days (0 = never expires)" "$DEFAULT_DAYS")
    is_number "$days" || days="$DEFAULT_DAYS"
    maxconn=$(ask "Max simultaneous connections" "$DEFAULT_MAXCONN")
    is_number "$maxconn" || maxconn="$DEFAULT_MAXCONN"
    quota=$(ask "Traffic quota in GB (0 = unlimited)" "$DEFAULT_QUOTA_GB")
    is_number "$quota" || quota="$DEFAULT_QUOTA_GB"

    if user_create "$user" "$pass" "$days" "$maxconn" "$quota"; then
        ok "Account created."
        user_card "$user" "$pass"
    else
        bad "Could not create the account."
    fi
    pause
}

pick_user() {
    local user
    user=$(ask "Username" "")
    [ -n "$user" ] || return 1
    if ! db_has "$user"; then
        bad "No such account."
        return 1
    fi
    printf '%s' "$user"
}

menu_user_delete() {
    local user
    user_list_table
    user=$(pick_user) || { pause; return; }
    if ask_yes "Delete $user and all of its data?" "n"; then
        user_delete "$user"
        ok "Account removed."
    else
        note "Cancelled."
    fi
    pause
}

menu_user_toggle() {
    local user state
    user_list_table
    user=$(pick_user) || { pause; return; }
    state=$(db_state "$user")
    if [ "$state" = "locked" ]; then
        user_unlock "$user"
        ok "$user is active again."
    else
        user_lock "$user"
        ok "$user is now locked and disconnected."
    fi
    pause
}

menu_user_extend() {
    local user days result
    user_list_table
    user=$(pick_user) || { pause; return; }
    days=$(ask "Add how many days (0 = never expires)" "30")
    is_number "$days" || days="30"
    result=$(user_extend "$user" "$days")
    ok "$user now expires on $result."
    pause
}

menu_user_password() {
    local user pass
    user_list_table
    user=$(pick_user) || { pause; return; }
    pass=$(ask "New password" "$(random_secret 12)")
    user_set_password "$user" "$pass"
    ok "Password updated."
    user_card "$user" "$pass"
    pause
}

menu_user_limits() {
    local user maxconn quota
    user_list_table
    user=$(pick_user) || { pause; return; }
    maxconn=$(ask "Max simultaneous connections" "$(db_maxconn "$user")")
    is_number "$maxconn" || maxconn=$(db_maxconn "$user")
    quota=$(ask "Traffic quota in GB (0 = unlimited)" "$(awk -v b="$(db_quota "$user")" 'BEGIN {printf "%.0f", b / 1073741824}')")
    is_number "$quota" || quota=0
    db_update "$user" 4 "$maxconn"
    db_update "$user" 5 "$(awk -v g="$quota" 'BEGIN {printf "%.0f", g * 1073741824}')"
    ok "Limits updated."
    pause
}

menu_user_show() {
    local user
    user_list_table
    user=$(pick_user) || { pause; return; }
    user_card "$user" ""
    pause
}

menu_users() {
    local choice
    while :; do
        banner
        user_list_table
        plain "1) Create account        5) Change password"
        plain "2) Delete account        6) Connection and traffic limits"
        plain "3) Lock or unlock        7) Show connection details"
        plain "4) Extend expiry         0) Back"
        blank
        choice=$(ask "Select" "")
        case "$choice" in
            1) menu_user_add ;;
            2) menu_user_delete ;;
            3) menu_user_toggle ;;
            4) menu_user_extend ;;
            5) menu_user_password ;;
            6) menu_user_limits ;;
            7) menu_user_show ;;
            0|q|"") return ;;
            *) bad "Unknown option." ; sleep 1 ;;
        esac
    done
}
