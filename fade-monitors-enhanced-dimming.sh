#!/bin/bash
# -----------------------------
# Enhanced Per-Monitor Dimming
# Features: Mouse-based dimming + Toggle file + Idle dimming
# -----------------------------
# Requires: xrandr, xdotool, xprintidle, bc
# -----------------------------

# -----------------------------
# USER CONFIG
# -----------------------------

# Brightness levels
ACTIVE_BRIGHTNESS=0.7      # Monitor with mouse
DIM_BRIGHTNESS=0.2         # Other monitors (when toggle ON)
IDLE_BRIGHTNESS=0.0        # All monitors when idle

# Idle settings
IDLE_TIMEOUT=5            # Seconds of inactivity before idle dim
IDLE_ENABLED=true          # Set to false to disable idle dimming

# Dimming transitions
INSTANT_DIM=false          # Smooth dimming to idle
INSTANT_WAKE=true          # Instant wake from idle (recommended)

# Toggle file (enable/disable per-monitor dimming)
TOGGLE_FILE="$HOME/.fade_mouse_enabled"

# Stop file
STOP_FILE="$HOME/.fade_mouse_stopped"

# Poll intervals
MOUSE_INTERVAL=0.1         # Mouse polling (10 times/sec)
GEOM_INTERVAL=5            # Monitor check (every 5 seconds)

# -----------------------------
# INTERNAL STATE
# -----------------------------
declare -A MON_X1 MON_X2 MON_Y1 MON_Y2
declare -A MON_TARGET_BRIGHT MON_CURRENT_BRIGHT
MONITORS=()

CURRENT_STATE="active"
LAST_ACTIVE_MON=""
TOGGLE_STATE=false

# -----------------------------
# SINGLE-INSTANCE LOCK
# -----------------------------
LOCKFILE="$HOME/.fade_mouse.lock"
exec 9>"$LOCKFILE" || exit 1
flock -n 9 || exit 0

# -----------------------------
# CLEANUP
# -----------------------------
cleanup() {
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --brightness 1.0 2>/dev/null
    done
    flock -u 9
    exit 0
}
trap cleanup EXIT SIGINT SIGTERM

# -----------------------------
# READ MONITOR GEOMETRY
# -----------------------------
read_monitors() {
    MONITORS=()
    
    while IFS= read -r line; do
        if [[ $line =~ ([0-9]+:[[:space:]]+[\+\*]*)([A-Za-z0-9-]+)[[:space:]]+([0-9]+)/[0-9]+x([0-9]+)/[0-9]+\+([0-9]+)\+([0-9]+) ]]; then
            name="${BASH_REMATCH[2]}"
            width="${BASH_REMATCH[3]}"
            height="${BASH_REMATCH[4]}"
            x_off="${BASH_REMATCH[5]}"
            y_off="${BASH_REMATCH[6]}"
            
            MONITORS+=("$name")
            MON_X1["$name"]=$x_off
            MON_Y1["$name"]=$y_off
            MON_X2["$name"]=$((x_off + width))
            MON_Y2["$name"]=$((y_off + height))
        fi
    done < <(xrandr --listmonitors 2>/dev/null | tail -n +2)
}

# -----------------------------
# MOUSE POSITION
# -----------------------------
get_mouse_position() {
    mouse_output=$(xdotool getmouselocation --shell 2>/dev/null || echo "X=0;Y=0")
    eval "$mouse_output" 2>/dev/null
}

# -----------------------------
# IDLE DETECTION
# -----------------------------
get_idle_time() {
    if [ "$IDLE_ENABLED" = false ]; then
        echo "0"
        return 0
    fi
    idle_ms=$(xprintidle 2>/dev/null || echo "0")
    echo "$((idle_ms / 1000))"
}

# -----------------------------
# BRIGHTNESS FUNCTIONS
# -----------------------------
apply_idle_brightness() {
    # All monitors to idle brightness
    for MON in "${MONITORS[@]}"; do
        MON_TARGET_BRIGHT["$MON"]="$IDLE_BRIGHTNESS"
        xrandr --output "$MON" --brightness "$IDLE_BRIGHTNESS" 2>/dev/null
        MON_CURRENT_BRIGHT["$MON"]="$IDLE_BRIGHTNESS"
    done
}

apply_active_brightness() {
    # Get mouse position
    get_mouse_position
    
    # Find active monitor
    active_mon=""
    for MON in "${MONITORS[@]}"; do
        if [ "$X" -ge "${MON_X1[$MON]}" ] && [ "$X" -lt "${MON_X2[$MON]}" ] &&
           [ "$Y" -ge "${MON_Y1[$MON]}" ] && [ "$Y" -lt "${MON_Y2[$MON]}" ]; then
            active_mon="$MON"
            break
        fi
    done
    
    # Check toggle state
    toggle_state=false
    if [ -f "$TOGGLE_FILE" ]; then
        toggle_state=true
    fi
    
    # Apply brightness to each monitor
    for MON in "${MONITORS[@]}"; do
        if [ "$toggle_state" = true ] && [ "$MON" != "$active_mon" ]; then
            target="$DIM_BRIGHTNESS"
        else
            target="$ACTIVE_BRIGHTNESS"
        fi
        
        # Only update if changed
        current="${MON_CURRENT_BRIGHT[$MON]:-1.0}"
        if [ "$(echo "$current != $target" | bc -l 2>/dev/null)" -eq 1 ]; then
            xrandr --output "$MON" --brightness "$target" 2>/dev/null
            MON_CURRENT_BRIGHT["$MON"]="$target"
        fi
    done
    
    # Store for tracking
    LAST_ACTIVE_MON="$active_mon"
    TOGGLE_STATE="$toggle_state"
}

# -----------------------------
# MAIN LOOP
# -----------------------------
read_monitors

# Initialize brightness
for MON in "${MONITORS[@]}"; do
    MON_CURRENT_BRIGHT["$MON"]=1.0
done

LAST_ACTIVITY_TIME=$(date +%s)

echo "Enhanced Dimming Active" >&2
echo "Toggle file: $TOGGLE_FILE" >&2
echo "Active brightness: $ACTIVE_BRIGHTNESS" >&2
echo "Dim brightness: $DIM_BRIGHTNESS" >&2
echo "Idle brightness: $IDLE_BRIGHTNESS" >&2
echo "Idle timeout: ${IDLE_TIMEOUT}s" >&2

while true; do
    # Check stop file
    [ -f "$STOP_FILE" ] && { rm -f "$STOP_FILE"; exit 0; }
    
    NOW=$(date +%s)
    
    # Check idle state
    if [ "$IDLE_ENABLED" = true ]; then
        idle_time=$(get_idle_time)
        
        if [ "$idle_time" -ge "$IDLE_TIMEOUT" ]; then
            CURRENT_STATE="idle"
        else
            CURRENT_STATE="active"
        fi
    else
        CURRENT_STATE="active"
    fi
    
    # Apply brightness based on state
    case "$CURRENT_STATE" in
        "active")
            apply_active_brightness
            ;;
        "idle")
            apply_idle_brightness
            ;;
    esac
    
    sleep "$MOUSE_INTERVAL"
done
