#!/usr/bin/env bash

set -uo pipefail

APP_ROOT="/usr/local/lib/tunnelctl"

. "$APP_ROOT/lib/common.sh"
. "$APP_ROOT/lib/users.sh"
. "$APP_ROOT/lib/services.sh"
. "$APP_ROOT/lib/monitor.sh"

[ "$(id -u)" -eq 0 ] || exit 0

db_init
load_config

acct_sync
enforce_expiry
enforce_quota
enforce_connections

exit 0
