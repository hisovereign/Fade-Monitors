#!/bin/bash
# -----------------------------
# Mouse-Based Per-Monitor Dimming
# -----------------------------
# Requires: xrandr, xdotool
# -----------------------------

# Brightness levels
ACTIVE_BRIGHTNESS=0.8
DIM_BRIGHTNESS=0.2

# Toggle file (enable/disable dimming)
TOGGLE_FILE="$HOME/.fade_mouse_enabled"

# Poll interval (seconds)
SLEEP_INTERVAL=0.05

# Declare associative arrays for monitor geometry
declare -A MON_X1 MON_X2 MON_Y1 MON_Y2 MON_LAST_BRIGHT
MONITORS=()
GEOM_HASH=""

# Restore brightness on exit
restore_brightness() {
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --brightness 1.0
    done
    exit
}
trap restore_brightness SIGINT SIGTERM

# Function: read monitor geometry from xrandr
read_monitors() {
    MONITORS=()
    MON_X1=()
    MON_X2=()
    MON_Y1=()
    MON_Y2=()
    MON_LAST_BRIGHT=()

    # Skip first line
    mapfile -t lines < <(xrandr --listmonitors | tail -n +2)

    for line in "${lines[@]}"; do
        # Use regex to reliably extract geometry and name
        # Example line: " 0: +*DP-1 2560/597x1440/336+1920+0  DP-1"
        if [[ $line =~ ([0-9]+:[[:space:]]+[\+\*]*)([A-Za-z0-9-]+)[[:space:]]+([0-9]+)\/[0-9]+x([0-9]+)\/[0-9]+\+([0-9]+)\+([0-9]+) ]]; then
            NAME="${BASH_REMATCH[2]}"
            WIDTH="${BASH_REMATCH[3]}"
            HEIGHT="${BASH_REMATCH[4]}"
            X_OFF="${BASH_REMATCH[5]}"
            Y_OFF="${BASH_REMATCH[6]}"

            MONITORS+=("$NAME")
            MON_X1["$NAME"]=$X_OFF
            MON_Y1["$NAME"]=$Y_OFF
            MON_X2["$NAME"]=$((X_OFF + WIDTH))
            MON_Y2["$NAME"]=$((Y_OFF + HEIGHT))
            MON_LAST_BRIGHT["$NAME"]=""
        fi
    done
}

# Initial read
read_monitors
GEOM_HASH="$(xrandr --listmonitors | sha1sum)"

# Main loop
while true; do
    # Re-read geometry if layout changed (hotplug, rotation, resolution)
    NEW_HASH="$(xrandr --listmonitors | sha1sum)"
    if [ "$NEW_HASH" != "$GEOM_HASH" ]; then
        GEOM_HASH="$NEW_HASH"
        read_monitors
    fi

    # Mouse position
    eval "$(xdotool getmouselocation --shell)"

    ACTIVE_MON=""

    # Determine which monitor the mouse is on
    for MON in "${MONITORS[@]}"; do
        if [ "$X" -ge "${MON_X1[$MON]}" ] && [ "$X" -lt "${MON_X2[$MON]}" ] &&
           [ "$Y" -ge "${MON_Y1[$MON]}" ] && [ "$Y" -lt "${MON_Y2[$MON]}" ]; then
            ACTIVE_MON="$MON"
            break
        fi
    done

    # Apply brightness per monitor
    for MON in "${MONITORS[@]}"; do
        TARGET="$ACTIVE_BRIGHTNESS"

        # Only dim if toggle file exists and monitor is not active
        if [ -f "$TOGGLE_FILE" ] && [ "$MON" != "$ACTIVE_MON" ]; then
            TARGET="$DIM_BRIGHTNESS"
        fi

        # Only apply if brightness changed (reduce flicker / xrandr calls)
        if [ "${MON_LAST_BRIGHT[$MON]}" != "$TARGET" ]; then
            xrandr --output "$MON" --brightness "$TARGET"
            MON_LAST_BRIGHT["$MON"]="$TARGET"
        fi
    done

    sleep "$SLEEP_INTERVAL"
done
