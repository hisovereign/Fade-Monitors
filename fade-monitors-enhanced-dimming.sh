#!/bin/bash
# -----------------------------
# Enhanced Per-Monitor Dimming EXPERIMENTAL
# Features:
# - Per-monitor mouse-based dimming
# - Idle timeout dimming (all monitors)
# - Configurable smooth transitions
# - Keyboard + mouse activity detection
# -----------------------------
# Requires: xrandr, xdotool, xprintidle
# -----------------------------

# -----------------------------
# USER CONFIG
# -----------------------------

# Brightness levels
ACTIVE_BRIGHTNESS=0.7      # Monitor with mouse (normal use)
DIM_BRIGHTNESS=0.2         # Other monitors (when toggle ON)
IDLE_BRIGHTNESS=0.1        # All monitors when idle

# Idle settings
IDLE_TIMEOUT=60            # Seconds of inactivity before idle dim (1 minute)
IDLE_ENABLED=true          # Set to false to disable idle dimming

# Smooth dimming settings
INSTANT_DIM=false          # true = instant changes, false = smooth transitions
SMOOTH_STEPS=20            # Number of steps for smooth transitions
SMOOTH_INTERVAL=0.05       # Seconds between steps (0.05 × 20 = 1 second total)

# Toggle file
TOGGLE_FILE="$HOME/.fade_mouse_enabled"

# Stop file
STOP_FILE="$HOME/.fade_mouse_stopped"

# Poll intervals (seconds)
MOUSE_INTERVAL=0.1         # Mouse position polling
GEOM_INTERVAL=5            # Monitor configuration checks
IDLE_CHECK_INTERVAL=1      # Idle state checks (less frequent)

# -----------------------------
# SINGLE-INSTANCE LOCK
# -----------------------------
LOCKFILE="$HOME/.fade_mouse.lock"
exec 9>"$LOCKFILE" || exit 1
flock -n 9 || exit 0

# -----------------------------
# Internal state variables
# -----------------------------
declare -A MON_X1 MON_X2 MON_Y1 MON_Y2
declare -A MON_TARGET_BRIGHT MON_CURRENT_BRIGHT
MONITORS=()

# Tracking variables
GEOM_HASH=""
LAST_GEOM_CHECK=0
LAST_IDLE_CHECK=0
GEOM_DIRTY=0

# State management
CURRENT_STATE="active"     # active, idle, restoring
LAST_ACTIVE_MON=""
LAST_ACTIVITY_TIME=0
TOGGLE_STATE=false

# Mouse position cache (for movement detection)
LAST_X=-1
LAST_Y=-1

# -----------------------------
# INITIAL DEPENDENCY CHECK
# -----------------------------
check_dependencies() {
    local missing=()
    
    # Check xrandr
    if ! command -v xrandr &> /dev/null; then
        missing+=("xrandr")
    fi
    
    # Check xdotool
    if ! command -v xdotool &> /dev/null; then
        missing+=("xdotool")
    fi
    
    # Check xprintidle (for idle detection)
    if [ "$IDLE_ENABLED" = true ] && ! command -v xprintidle &> /dev/null; then
        echo "WARNING: xprintidle not found. Install with: sudo apt-get install x11-utils" >&2
        echo "Idle dimming will be disabled." >&2
        IDLE_ENABLED=false
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: Missing required dependencies:" >&2
        for dep in "${missing[@]}"; do
            echo "  - $dep" >&2
        done
        echo "Install with: sudo apt-get install ${missing[*]}" >&2
        exit 1
    fi
}

check_dependencies

# -----------------------------
# CLEANUP & SIGNAL HANDLING
# -----------------------------
restore_defaults() {
    # Restore all monitors to normal brightness
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --brightness 1.0 --gamma 1.0:1.0:1.0 2>/dev/null
    done
}

cleanup() {
    restore_defaults
    flock -u 9  # Release lock
    exit 0
}

trap cleanup EXIT SIGINT SIGTERM

# -----------------------------
# MONITOR GEOMETRY FUNCTIONS
# -----------------------------
read_monitors() {
    MONITORS=()
    MON_X1=()
    MON_X2=()
    MON_Y1=()
    MON_Y2=()

    # Get monitor information from xrandr
    mapfile -t lines < <(xrandr --listmonitors | tail -n +2)

    for line in "${lines[@]}"; do
        if [[ $line =~ ([0-9]+:[[:space:]]+[\+\*]*)\
([A-Za-z0-9-]+)[[:space:]]+([0-9]+)\/[0-9]+x([0-9]+)\/[0-9]+\+([0-9]+)\+([0-9]+) ]]; then
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
            MON_CURRENT_BRIGHT["$NAME"]=1.0  # Start at full brightness
            MON_TARGET_BRIGHT["$NAME"]=1.0   # Target is full brightness initially
        fi
    done
}

# -----------------------------
# BRIGHTNESS CONTROL FUNCTIONS
# -----------------------------
set_brightness_instant() {
    local monitor="$1"
    local brightness="$2"
    
    # Only update if the brightness actually changed
    if [ "$(echo "${MON_CURRENT_BRIGHT[$monitor]} != $brightness" | bc -l)" -eq 1 ]; then
        xrandr --output "$monitor" --brightness "$brightness" 2>/dev/null
        MON_CURRENT_BRIGHT["$monitor"]="$brightness"
    fi
}

set_brightness_smooth() {
    local monitor="$1"
    local target="$2"
    local current="${MON_CURRENT_BRIGHT[$monitor]:-1.0}"
    
    # If instant dimming is enabled, or if the change is very small, do it instantly
    if [ "$INSTANT_DIM" = true ] || \
       [ "$(echo "scale=3; $target - $current" | bc | awk '{if ($1<0) print -$1; else print $1}')" = "0" ]; then
        set_brightness_instant "$monitor" "$target"
        return
    fi
    
    # Calculate step size
    local step
    step=$(echo "scale=3; ($target - $current) / $SMOOTH_STEPS" | bc)
    
    # Perform smooth transition
    for ((i=1; i<=SMOOTH_STEPS; i++)); do
        # Break if we get activity during transition (quick restoration)
        if [ "$i" -gt 1 ] && [ $((i % 4)) -eq 0 ] && [ "$CURRENT_STATE" = "restoring" ]; then
            # Quick check for activity during restore
            if [ "$(get_idle_time)" -lt "$IDLE_TIMEOUT" ]; then
                break  # Activity detected, exit early
            fi
        fi
        
        current=$(echo "scale=3; $current + $step" | bc)
        
        # Clamp value between 0 and 1
        if [ "$(echo "$current < 0" | bc -l)" -eq 1 ]; then
            current=0
        elif [ "$(echo "$current > 1" | bc -l)" -eq 1 ]; then
            current=1
        fi
        
        xrandr --output "$monitor" --brightness "$current" 2>/dev/null
        sleep "$SMOOTH_INTERVAL"
    done
    
    # Ensure final target is set
    xrandr --output "$monitor" --brightness "$target" 2>/dev/null
    MON_CURRENT_BRIGHT["$monitor"]="$target"
}

# -----------------------------
# ACTIVITY & IDLE DETECTION
# -----------------------------
get_idle_time() {
    # Returns idle time in seconds (0 if xprintidle fails or not available)
    if [ "$IDLE_ENABLED" = false ] || ! command -v xprintidle &> /dev/null; then
        echo "0"
        return
    fi
    
    local idle_ms
    idle_ms=$(xprintidle 2>/dev/null || echo "0")
    echo "$((idle_ms / 1000))"
}

check_mouse_movement() {
    # Check if mouse has moved since last check
    eval "$(xdotool getmouselocation --shell 2>/dev/null || echo "X=0;Y=0")"
    
    if [ "$X" != "$LAST_X" ] || [ "$Y" != "$LAST_Y" ]; then
        LAST_X="$X"
        LAST_Y="$Y"
        return 0  # Mouse moved
    fi
    return 1  # Mouse stationary
}

update_activity() {
    # Update last activity time based on mouse/keyboard activity
    local idle_time
    idle_time=$(get_idle_time)
    
    if [ "$idle_time" -lt "$IDLE_TIMEOUT" ]; then
        LAST_ACTIVITY_TIME=$(date +%s)
        return 0  # Activity detected
    fi
    return 1  # Idle
}

check_state_transition() {
    # Check and update the current state based on activity
    local idle_time
    idle_time=$(get_idle_time)
    
    case "$CURRENT_STATE" in
        "active")
            if [ "$IDLE_ENABLED" = true ] && [ "$idle_time" -ge "$IDLE_TIMEOUT" ]; then
                CURRENT_STATE="idle"
                echo "[$(date '+%H:%M:%S')] Entering idle state" >&2
                return 1  # State changed to idle
            fi
            ;;
        "idle")
            if [ "$idle_time" -lt "$IDLE_TIMEOUT" ]; then
                CURRENT_STATE="restoring"
                echo "[$(date '+%H:%M:%S')] Activity detected, restoring brightness" >&2
                return 2  # State changed to restoring
            fi
            ;;
        "restoring")
            # Once we start restoring, we should quickly transition to active
            CURRENT_STATE="active"
            return 0  # State changed to active
            ;;
    esac
    return 0  # No state change
}

# -----------------------------
# BRIGHTNESS LOGIC FUNCTIONS
# -----------------------------
apply_idle_brightness() {
    # Set all monitors to idle brightness
    for MON in "${MONITORS[@]}"; do
        if [ "$(echo "${MON_CURRENT_BRIGHT[$monitor]} != $IDLE_BRIGHTNESS" | bc -l)" -eq 1 ]; then
            MON_TARGET_BRIGHT["$MON"]="$IDLE_BRIGHTNESS"
            set_brightness_smooth "$MON" "$IDLE_BRIGHTNESS"
        fi
    done
}

apply_active_brightness() {
    # Apply per-monitor dimming based on mouse position
    local active_mon=""
    
    # Get current mouse position
    eval "$(xdotool getmouselocation --shell 2>/dev/null || echo "X=0;Y=0")"
    
    # Find which monitor contains the mouse
    for MON in "${MONITORS[@]}"; do
        if [ "$X" -ge "${MON_X1[$MON]}" ] && [ "$X" -lt "${MON_X2[$MON]}" ] &&
           [ "$Y" -ge "${MON_Y1[$MON]}" ] && [ "$Y" -lt "${MON_Y2[$MON]}" ]; then
            active_mon="$MON"
            break
        fi
    done
    
    # Check toggle state
    local toggle_state=false
    [ -f "$TOGGLE_FILE" ] && toggle_state=true
    
    # Apply brightness to each monitor
    for MON in "${MONITORS[@]}"; do
        local target="$ACTIVE_BRIGHTNESS"
        
        if [ "$toggle_state" = true ] && [ "$MON" != "$active_mon" ]; then
            target="$DIM_BRIGHTNESS"
        fi
        
        # Only update if target changed
        if [ "$(echo "${MON_TARGET_BRIGHT[$MON]:-1.0} != $target" | bc -l)" -eq 1 ]; then
            MON_TARGET_BRIGHT["$MON"]="$target"
            set_brightness_smooth "$MON" "$target"
        fi
    done
    
    # Store last active monitor for state tracking
    LAST_ACTIVE_MON="$active_mon"
    TOGGLE_STATE="$toggle_state"
}

# -----------------------------
# INITIAL SETUP
# -----------------------------
echo "[$(date '+%H:%M:%S')] Starting enhanced dimming script" >&2
echo "[$(date '+%H:%M:%S')] Idle timeout: ${IDLE_TIMEOUT}s, Idle brightness: ${IDLE_BRIGHTNESS}" >&2
echo "[$(date '+%H:%M:%S')] Instant dim: $INSTANT_DIM, Smooth steps: $SMOOTH_STEPS" >&2

# Read initial monitor configuration
read_monitors
XRANDR_LIST=$(xrandr --listmonitors)
GEOM_HASH="$(echo "$XRANDR_LIST" | sha1sum | awk '{print $1}')"

# Initialize brightness tracking
for MON in "${MONITORS[@]}"; do
    MON_CURRENT_BRIGHT["$MON"]=1.0
    MON_TARGET_BRIGHT["$MON"]=1.0
done

# Initial mouse position
eval "$(xdotool getmouselocation --shell 2>/dev/null || echo "X=0;Y=0")"
LAST_X="$X"
LAST_Y="$Y"
LAST_ACTIVITY_TIME=$(date +%s)

# -----------------------------
# MAIN LOOP
# -----------------------------
while true; do
    # Check for stop file
    if [ -f "$STOP_FILE" ]; then
        echo "[$(date '+%H:%M:%S')] Stop file detected, exiting" >&2
        rm -f "$STOP_FILE"
        exit 0
    fi
    
    NOW=$(date +%s)
    
    # -------- Monitor Configuration Check --------
    if (( NOW - LAST_GEOM_CHECK >= GEOM_INTERVAL )); then
        LAST_GEOM_CHECK=$NOW
        XRANDR_LIST=$(xrandr --listmonitors)
        NEW_HASH="$(echo "$XRANDR_LIST" | sha1sum | awk '{print $1}')"
        
        if [ "$NEW_HASH" != "$GEOM_HASH" ]; then
            echo "[$(date '+%H:%M:%S')] Monitor configuration changed, updating geometry" >&2
            GEOM_HASH="$NEW_HASH"
            GEOM_DIRTY=1
            read_monitors
            
            # Reinitialize brightness for any new monitors
            for MON in "${MONITORS[@]}"; do
                if [ -z "${MON_CURRENT_BRIGHT[$MON]}" ]; then
                    MON_CURRENT_BRIGHT["$MON"]=1.0
                    MON_TARGET_BRIGHT["$MON"]=1.0
                fi
            done
        fi
    fi
    
    # Skip brightness updates if geometry just changed
    if [ "$GEOM_DIRTY" -eq 1 ]; then
        GEOM_DIRTY=0
        sleep "$MOUSE_INTERVAL"
        continue
    fi
    
    # -------- Idle State Check --------
    if (( NOW - LAST_IDLE_CHECK >= IDLE_CHECK_INTERVAL )); then
        LAST_IDLE_CHECK=$NOW
        
        # Update activity detection
        if check_mouse_movement; then
            LAST_ACTIVITY_TIME=$NOW
        fi
        
        # Check for state transitions
        check_state_transition
        state_change=$?
    fi
    
    # -------- State-Based Brightness Control --------
    case "$CURRENT_STATE" in
        "active")
            apply_active_brightness
            ;;
        "idle")
            apply_idle_brightness
            ;;
        "restoring")
            # Quick restoration to active state
            apply_active_brightness
            CURRENT_STATE="active"
            ;;
    esac
    
    # -------- Sleep for next iteration --------
    sleep "$MOUSE_INTERVAL"
done
