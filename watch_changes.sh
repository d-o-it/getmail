#!/usr/bin/env bash

set -o pipefail

MAILCOW_PATH=/opt/mailcow-dockerized
MAILCOW_CONFIG_FILE="$MAILCOW_PATH/mailcow.conf"
DOCKER_MYSQL_EXEC="/usr/bin/docker compose --project-directory $MAILCOW_PATH exec -T mysql-mailcow"
DATABASE="mailcow"
TABLE="imapsync"
POS_FILE="./binlog.pos"

[ ! -f $MAILCOW_CONFIG_FILE ] && echo "Mailcow config not found. " && exit 1
source $MAILCOW_CONFIG_FILE

# Graceful shutdown handler
cleanup() {
    log "Stopping watcher (caught signal)"
    [[ -n "$BINLOG_PID" ]] && kill "$BINLOG_PID" 2>/dev/null
    exit 0
}

# Trap common termination signals
trap cleanup SIGINT SIGTERM

# Log function
log() {
    echo "$*"
}

# Ensure POS_FILE exists
if [[ -f "$POS_FILE" ]]; then
    read BINLOG_FILE BINLOG_POS < "$POS_FILE"
else
    BINLOG_FILE=$($DOCKER_MYSQL_EXEC mysql -u "root" -p"$DBROOT" -Nse "SHOW BINARY LOGS;" | tail -n1 | awk '{print $1}')
    BINLOG_POS=4
    echo "$BINLOG_FILE $BINLOG_POS" > "$POS_FILE"
fi

while true; do
  log "Starting binlog watcher at $BINLOG_FILE:$BINLOG_POS"

  # Tail the binlog and look for table changes
  $DOCKER_MYSQL_EXEC mysqlbinlog \
	--no-defaults \
	--read-from-remote-server \
    	--host=localhost \
	--user="root" \
	--password="$DBROOT" \
	--verbose \
	--base64-output=DECODE-ROWS \
	--stop-never \
	--start-position="$BINLOG_POS" \
	"$BINLOG_FILE" | \
  while read -r line; do
    if echo "$line" | grep -q "UPDATE \`$DATABASE\`.\`$TABLE\`"; then
      log "[+] Detected update to $DATABASE.$TABLE"
      cp ./conf/settings.ini ./conf/settings.ini.bck
      ./generate_config.sh
      if diff <(tail -n +2 ./conf/settings.ini) <(tail -n +2 ./conf/settings.ini.bck) > /dev/null; then
        log "[-] Settings did not change"
      else
        log "[+] Settings changed, restarting container"
        docker compose restart
        echo "Subject: GetMail neu gestartet" | sendmail darkmax@tweedy.no-ip.org
      fi
    fi

    # Save last seen position
    if [[ "$line" =~ ^#\ at\ ([0-9]+) ]]; then
      BINLOG_POS="${BASH_REMATCH[1]}"
      echo "$BINLOG_FILE $BINLOG_POS" > "$POS_FILE"
    fi
  done &

  BINLOG_PID=$!
  wait "$BINLOG_PID" || log "mysqlbinlog exited. Restarting watcher..."

  BINLOG_FILE=$($DOCKER_MYSQL_EXEC mysql -u "root" -p"$DBROOT" -Nse "SHOW BINARY LOGS;" | tail -n1 | awk '{print $1}')
  BINLOG_POS=4
  echo "$BINLOG_FILE $BINLOG_POS" > "$POS_FILE"

  sleep 2
done
