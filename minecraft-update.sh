#!/bin/bash

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

FAILED=0

# Input variables
SERVER_NAME="binhex-minecraftserver"
BACKUP_ROOT="/mnt/user/share/backups/minecraft/old"
TODAY=$(date +%Y-%m-%d)
BACKUP_DIR="$BACKUP_ROOT/$TODAY"
MC_DIR="/mnt/user/appdata/$SERVER_NAME/minecraft"
PLUGINS_DIR="$MC_DIR/plugins"
LOG_DIR="/var/log/scripts"
LOG_FILE="$LOG_DIR/update_minecraft.log"
CHOWN_NAME="nobody:users"
SHARE_CHOWN_NAME="rbignell:users"

# Purge backups older than 1 month
find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*" -mtime +30 -exec rm -rf {} \;
log "Purged backups older than 1 month from $BACKUP_ROOT"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        mkdir -p "$BACKUP_DIR"
        cp "$file" "$BACKUP_DIR/"
        log "Backed up $file to $BACKUP_DIR"
    fi
}

download_latest() {
    local url="$1"
    local dest="$2"
    local name="$3"
    curl -sL "$url" -o "$dest"
    if [ $? -eq 0 ]; then
        log "Downloaded latest $name to $dest"
    else
        log "Failed to download $name from $url"
        FAILED=1
    fi
}

# PaperMC
PAPER_API="https://api.papermc.io/v2/projects/paper"
PAPER_VERSION=$(curl -s "$PAPER_API" | jq -r '.versions[-1]')
PAPER_BUILD=$(curl -s "$PAPER_API/versions/$PAPER_VERSION" | jq -r '.builds[-1]')
PAPER_JAR_URL="$PAPER_API/versions/$PAPER_VERSION/builds/$PAPER_BUILD/downloads/paper-$PAPER_VERSION-$PAPER_BUILD.jar"
PAPER_JAR="$MC_DIR/paper_server.jar"
backup_file "$PAPER_JAR"
download_latest "$PAPER_JAR_URL" "$PAPER_JAR" "PaperMC"

# Geyser
GEYSER_JAR="$PLUGINS_DIR/Geyser-Spigot.jar"
backup_file "$GEYSER_JAR"
curl -L -o "$GEYSER_JAR" "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot"
if [ $? -eq 0 ]; then
    log "Downloaded latest Geyser to $GEYSER_JAR"
else
    log "Failed to download Geyser"
    FAILED=1
fi

# Floodgate
FLOODGATE_JAR="$PLUGINS_DIR/floodgate-spigot.jar"
backup_file "$FLOODGATE_JAR"
curl -L -o "$FLOODGATE_JAR" "https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot"
if [ $? -eq 0 ]; then
    log "Downloaded latest Floodgate to $FLOODGATE_JAR"
else
    log "Failed to download Floodgate"
    FAILED=1
fi

# ViaVersion (scrape latest release from Hangar)
html=$(curl -s 'https://hangar.papermc.io/ViaVersion/ViaVersion/versions')
latest=$(echo "$html" | grep -oP '/ViaVersion/ViaVersion/versions/\K[\w.+-]+' | grep -v SNAPSHOT | head -n 1)
VIAVERSION_JAR="$PLUGINS_DIR/ViaVersion.jar"
backup_file "$VIAVERSION_JAR"
url="https://hangarcdn.papermc.io/plugins/ViaVersion/ViaVersion/versions/${latest}/PAPER/ViaVersion-${latest}.jar"
log "Downloading ViaVersion $latest from $url..."
curl -L -o "$VIAVERSION_JAR" "$url"
if [ $? -eq 0 ]; then
    log "Downloaded latest ViaVersion to $VIAVERSION_JAR"
else
    log "Failed to download ViaVersion"
    FAILED=1
fi

# ViaBackwards (scrape latest release from Hangar)
html=$(curl -s 'https://hangar.papermc.io/ViaVersion/ViaBackwards/versions')
latest=$(echo "$html" | grep -oP '/ViaVersion/ViaBackwards/versions/\K[\w.+-]+' | grep -v SNAPSHOT | head -n 1)
VIABACKWARDS_JAR="$PLUGINS_DIR/ViaBackwards.jar"
backup_file "$VIABACKWARDS_JAR"
url="https://hangarcdn.papermc.io/plugins/ViaVersion/ViaBackwards/versions/${latest}/PAPER/ViaBackwards-${latest}.jar"
log "Downloading ViaBackwards $latest from $url..."
curl -L -o "$VIABACKWARDS_JAR" "$url"
if [ $? -eq 0 ]; then
    log "Downloaded latest ViaBackwards to $VIABACKWARDS_JAR"
else
    log "Failed to download ViaBackwards"
    FAILED=1
fi

# Set ownership
chown "$CHOWN_NAME" "$MC_DIR"/*.jar "$PLUGINS_DIR"/*.jar
log "Set ownership to $CHOWN_NAME"
chmod 777 "$BACKUP_ROOT/$TODAY"
chown -R "$SHARE_CHOWN_NAME" "$BACKUP_ROOT/$TODAY"
log "Set permissions to $BACKUP_ROOT/$TODAY"

if [ "$FAILED" -eq 0 ]; then
    docker restart "$SERVER_NAME"
    log "Restarting $SERVER_NAME container"
else
    log "Not restarting container due to failures"
fi

log "Update complete."