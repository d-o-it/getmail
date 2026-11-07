#!/usr/bin/env bash
#
# Follows MariaDB's binlog and reruns generate_config.sh after every
# transaction that touched Mailcow's sync jobs; getmail is restarted when the
# config changed. Needs log-bin with binlog_format=ROW in Mailcow's MariaDB.

set -o pipefail
cd "$(dirname "$0")" || exit 1

MAILCOW_PATH=/opt/mailcow-dockerized
MAILCOW_CONFIG_FILE="$MAILCOW_PATH/mailcow.conf"
DOCKER_MYSQL_EXEC="/usr/bin/docker compose --project-directory $MAILCOW_PATH exec -T -e MYSQL_PWD mysql-mailcow"
DATABASE="mailcow"
# Sync jobs, and the source servers they point to (host1/port1)
TABLES="imapsync|imapsync_source"
# Binlog file and position after the last transaction that was handled
POS_FILE="./binlog.pos"

[ ! -f $MAILCOW_CONFIG_FILE ] && echo "Mailcow config not found. " && exit 1
source $MAILCOW_CONFIG_FILE
# Passed to the container by name, so the password stays out of ps
export MYSQL_PWD="$DBROOT"

log() {
    echo "$*"
}

cleanup() {
    log "Stopping watcher (caught signal)"
    [[ -n "$BINLOG_PID" ]] && kill "$BINLOG_PID" 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM

binlogs() {
    $DOCKER_MYSQL_EXEC mysql -u root -Nse "SHOW BINARY LOGS;" | cut -f1
}

sync_config() {
    cp ./conf/settings.ini ./conf/settings.ini.bck
    ./generate_config.sh
    if diff <(tail -n +2 ./conf/settings.ini) <(tail -n +2 ./conf/settings.ini.bck) > /dev/null; then
        log "[-] Settings did not change"
    else
        log "[+] Settings changed, restarting container"
        docker compose restart
        echo "Subject: GetMail neu gestartet" | sendmail darkmax@tweedy.no-ip.org
    fi
}

# Only these lines of the decoded binlog matter. Each row event is preceded by
# a Table_map line naming its table, each transaction ends with an Xid line
# (end_log_pos = where the next one starts), and Rotate marks the next file.
# Filtering with grep keeps the loop below fast; reading every line in bash
# made it fall behind until the server dropped the connection.
FILTER="Table_map: |Xid = |Rotate to "
WATCHED="Table_map: \`$DATABASE\`\.\`($TABLES)\` "

# Catch up on changes made while the watcher was down
sync_config

while true; do
    BINLOG_FILE= BINLOG_POS=
    [[ -f "$POS_FILE" ]] && read -r BINLOG_FILE BINLOG_POS < "$POS_FILE"

    # No position yet, or its binlog was already purged (binlog_expire_logs_seconds):
    # start at the newest binlog and regenerate once to cover the gap.
    if [[ -z "$BINLOG_FILE" ]] || ! binlogs | grep -qxF "$BINLOG_FILE"; then
        BINLOG_FILE=$(binlogs | tail -n1)
        if [[ -z "$BINLOG_FILE" ]]; then
            log "No binlog found (MariaDB down?), retrying"
            sleep 10
            continue
        fi
        BINLOG_POS=4
        echo "$BINLOG_FILE $BINLOG_POS" > "$POS_FILE"
        sync_config
    fi

    log "Starting binlog watcher at $BINLOG_FILE:$BINLOG_POS"
    $DOCKER_MYSQL_EXEC mysqlbinlog \
        --no-defaults \
        --read-from-remote-server \
        --host=localhost \
        --user=root \
        --base64-output=DECODE-ROWS \
        --stop-never \
        --start-position="$BINLOG_POS" \
        "$BINLOG_FILE" |
    grep --line-buffered -E "$FILTER" |
    {
        changed=
        while read -r line; do
            if [[ "$line" =~ Rotate\ to\ ([^ ]+) ]]; then
                BINLOG_FILE="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ $WATCHED ]]; then
                changed=1
            elif [[ "$line" =~ end_log_pos\ ([0-9]+).*Xid\ = ]]; then
                if [[ -n "$changed" ]]; then
                    log "[+] Detected change to $DATABASE.($TABLES)"
                    sync_config
                    changed=
                fi
                echo "$BINLOG_FILE ${BASH_REMATCH[1]}" > "$POS_FILE"
            fi
        done
    } &

    BINLOG_PID=$!
    wait "$BINLOG_PID"
    log "mysqlbinlog exited. Restarting watcher..."
    sleep 2
done
