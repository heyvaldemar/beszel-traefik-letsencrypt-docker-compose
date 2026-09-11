#!/bin/bash

# Restore Beszel's data directory from one of the archives the `backups`
# container has taken.
#
# That directory is everything the hub knows: the systems it monitors, every
# alert rule and threshold you set, the users, and the metric history. The
# history rides along and nobody restores a CPU graph from March; the alert
# rules are the part that is genuinely irreplaceable.
#
#     chmod +x beszel-restore-config.sh
#     ./beszel-restore-config.sh
#
# The agent's own directory is not in the archive and is not touched here. It
# is local state and is rebuilt on start.
#
# The agent keeps running throughout. It buffers nothing, so the gap in the
# charts is exactly as long as the hub is down.
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-beszel-traefik-letsencrypt-docker-compose.yml}"
PROJECT="${COMPOSE_PROJECT_NAME:-beszel}"
BACKUP_PATH="${DATA_BACKUPS_PATH:-/srv/beszel-data/backups}"
RESTORE_PATH="${DATA_PATH:-/beszel_data}"

dc() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

APP_CONTAINER="$(dc ps -aq beszel | head -n 1)"
BACKUPS_CONTAINER="$(dc ps -aq backups | head -n 1)"
[ -n "$APP_CONTAINER" ] || { echo "the beszel container was not found — is the stack up?" >&2; exit 1; }
[ -n "$BACKUPS_CONTAINER" ] || { echo "the backups container was not found — is the stack up?" >&2; exit 1; }

echo "--> All available config backups:"
docker exec "$BACKUPS_CONTAINER" sh -c "ls -1 $BACKUP_PATH" || true

echo "--> Copy and paste the backup name from the list above and press [ENTER]
--> Example: beszel-data-backup-YYYY-MM-DD_hh-mm.tar.gz"
echo -n "--> "
read -r SELECTED
[ -n "$SELECTED" ] || { echo "nothing selected, nothing restored" >&2; exit 1; }

if ! docker exec "$BACKUPS_CONTAINER" sh -c "tar -tzf '${BACKUP_PATH}/${SELECTED}' > /dev/null"; then
  echo "that file is not a readable tar archive — nothing has been stopped or deleted" >&2
  exit 1
fi
echo "--> $SELECTED was selected and reads as a valid archive"

echo "--> Stopping Beszel..."
docker stop "$APP_CONTAINER" > /dev/null

echo "--> Restoring the data directory..."
# The archive stores paths relative to /, so it extracts there. The directory
# is emptied first: a restore that merges leaves rows in the old library
# database that the archive never had.
docker exec "$BACKUPS_CONTAINER" sh -c "rm -rf '${RESTORE_PATH:?}'/* && tar -zxpf '${BACKUP_PATH}/${SELECTED}' -C /"
echo "--> Config recovery completed."

echo "--> Starting Beszel..."
docker start "$APP_CONTAINER" > /dev/null
echo "--> The hub answers once it has opened the restored database."
echo "--> Check Systems afterwards: anything the archive predates is gone, and re-adding it issues a new token."
