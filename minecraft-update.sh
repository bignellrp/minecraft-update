#!/bin/bash

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"
}

update_server() {
    SERVER_NAME="$1"
    BACKUP_ROOT="/mnt/user/share/backups/minecraft/old"
    TODAY=$(date +%Y-%m-%d)
    BACKUP_DIR="$BACKUP_ROOT/$TODAY"
    MC_DIR="/mnt/user/appdata/$SERVER_NAME/minecraft"
    PLUGINS_DIR="$MC_DIR/plugins"
    LOG_DIR="/var/log/scripts"
    LOG_FILE="$LOG_DIR/update_minecraft.log"
    CHOWN_NAME="nobody:users"
    SHARE_CHOWN_NAME="rbignell:users"
    FAILED=0

    find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*" -mtime +30 -exec rm -rf {} \;
    log "Purged backups older than 1 month from $BACKUP_ROOT"
    mkdir -p "$LOG_DIR"

    backup_file() {
        local file="$1"
        if [ -f "$file" ]; then
            mkdir -p "$BACKUP_DIR"
            cp "$file" "$BACKUP_DIR/"
            log "Backed up $file to $BACKUP_DIR"
        fi
    }

    # PaperMC
    PAPER_API="https://api.papermc.io/v2/projects/paper"
    PAPER_VERSION=$(curl -s "$PAPER_API" | jq -r '.versions[-1]')
    PAPER_BUILD=$(curl -s "$PAPER_API/versions/$PAPER_VERSION" | jq -r '.builds[-1]')
    PAPER_JAR_URL="$PAPER_API/versions/$PAPER_VERSION/builds/$PAPER_BUILD/downloads/paper-$PAPER_VERSION-$PAPER_BUILD.jar"
    PAPER_JAR="$MC_DIR/paper_server.jar"
    backup_file "$PAPER_JAR"
    curl -sL "$PAPER_JAR_URL" -o "$PAPER_JAR"
    if [ $? -eq 0 ]; then
        log "Downloaded latest PaperMC to $PAPER_JAR"
    else
        log "Failed to download PaperMC"
        FAILED=1
    fi

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

    # ViaVersion
    html=$(curl -s 'https://hangar.papermc.io/ViaVersion/ViaVersion/versions?channel=Release&platform=PAPER')
    latest=$(echo "$html" | grep -oP 'ViaVersion/ViaVersion/versions/\K[0-9]+\.[0-9]+\.[0-9]+' | sort -Vr | head -n 1)
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

    # ViaBackwards
    html=$(curl -s 'https://hangar.papermc.io/ViaVersion/ViaBackwards/versions?channel=Release&platform=PAPER')
    latest=$(echo "$html" | grep -oP 'ViaVersion/ViaBackwards/versions/\K[0-9]+\.[0-9]+\.[0-9]+' | sort -Vr | head -n 1)
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
        /usr/local/emhttp/webGui/scripts/notify \
            -e "Minecraft Update Failed" \
            -s "Update failed for $SERVER_NAME." \
            -d "Update failed for $SERVER_NAME. Please check the logs." \
            -i "alert"
    fi

    log "Update complete for $SERVER_NAME."
    /usr/local/emhttp/webGui/scripts/notify \
        -e "Minecraft Update" \
        -s "Update complete for $SERVER_NAME." \
        -d "The Minecraft server $SERVER_NAME has been updated successfully." \
        -i "normal"
}

# List of servers to update
for SERVER in binhex-minecraftserver binhex-minecraftserver2 binhex-minecraftserver3 binhex-minecraftserver4; do
    update_server "$SERVER"
done