#!/bin/bash
# -----------------------------
# Enhanced Per-Monitor Dimming
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
IDLE_TIMEOUT=5            # Seconds of inactivity before idle dim (1 minute)
IDLE_ENABLED=true          # Set to false to disable idle dimming

# Smooth dimming settings
INSTANT_DIM=false          # true = instant changes, false = smooth transitions
SMOOTH_STEPS=10            # Number of steps for smooth transitions
SMOOTH_INTERVAL=0.05       # Seconds between steps (0.05 × 20 = 1 second total)

# Toggle file
TOGGLE_FILE="$HOME/.fade_mouse_enabled"

# Stop file
STOP_FILE="$HOME/.fade_mouse_stopped"

# Poll intervals (seconds)
MOUSE_INTERVAL=0.1         # Mouse position polling
GEOM_INTERVAL=5            # Monitor configuration checks
IDLE_CHECK_INTERVAL=1      # Idle state checks (less frequent)

# Logging (set to true for debugging)
ENABLE_LOGGING=false
LOG_FILE="/tmp/fade_monitors.log"

# -----------------------------
# LOGGING FUNCTION
# -----------------------------
log_message() {
    if [ "$ENABLE_LOGGING" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    fi
}

# -----------------------------
# SINGLE-INSTANCE LOCK
# -----------------------------
LOCKFILE="$HOME/.fade_mouse.lock"
exec 9>"$LOCKFILE" || { echo "Failed to create lock file" >&2; exit 1; }
flock -n 9 || { echo "Another instance is already running" >&2; exit 0; }

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
        echo "ERROR: xrandr not found. Required for monitor control." >&2
        echo "Install with: sudo apt-get install x11-xserver-utils" >&2
    fi
    
    # Check xdotool
    if ! command -v xdotool &> /dev/null; then
        missing+=("xdotool")
        echo "ERROR: xdotool not found. Required for mouse tracking." >&2
        echo "Install with: sudo apt-get install xdotool" >&2
    fi
    
    # Check bc for floating point math
    if ! command -v bc &> /dev/null; then
        missing+=("bc")
        echo "ERROR: bc not found. Required for brightness calculations." >&2
        echo "Install with: sudo apt-get install bc" >&2
    fi
    
    # Check xprintidle (for idle detection)
    if [ "$IDLE_ENABLED" = true ]; then
        if ! command -v xprintidle &> /dev/null; then
            echo "WARNING: xprintidle not found. Install with: sudo apt-get install xprintidle" >&2
            echo "Idle dimming will be disabled. Continuing with mouse-only dimming." >&2
            IDLE_ENABLED=false
        fi
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "FATAL: Missing required dependencies. Please install them and try again." >&2
        exit 1
    fi
    
    # Optional dependencies warnings
    if [ "$IDLE_ENABLED" = false ] && [ -n "$(command -v xprintidle)" ]; then
        echo "INFO: xprintidle is installed but idle dimming is disabled in config." >&2
    fi
}

check_dependencies

# -----------------------------
# CLEANUP & SIGNAL HANDLING
# -----------------------------
restore_defaults() {
    log_message "Restoring defaults"
    # Restore all monitors to normal brightness
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --brightness 1.0 --gamma 1.0:1.0:1.0 2>/dev/null && \
            log_message "Restored monitor $MON to 1.0 brightness" || \
            log_message "Warning: Failed to restore monitor $MON"
    done
}

cleanup() {
    log_message "Cleanup initiated"
    restore_defaults
    flock -u 9  # Release lock
    log_message "Script exited cleanly"
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
    local xrandr_output
    xrandr_output=$(xrandr --listmonitors 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to get monitor information from xrandr" >&2
        return 1
    fi
    
    mapfile -t lines < <(echo "$xrandr_output" | tail -n +2)

    log_message "Reading monitor configuration"
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
            
            log_message "Found monitor: $NAME at ${X_OFF}x${Y_OFF}, size ${WIDTH}x${HEIGHT}"
        else
            log_message "Warning: Could not parse monitor line: $line"
        fi
    done
    
    if [ ${#MONITORS[@]} -eq 0 ]; then
        echo "ERROR: No monitors found!" >&2
        return 1
    fi
    
    log_message "Total monitors found: ${#MONITORS[@]}"
    return 0
}

# -----------------------------
# BRIGHTNESS CONTROL FUNCTIONS
# -----------------------------
set_brightness_instant() {
    local monitor="$1"
    local brightness="$2"
    
    # Use bc for accurate floating point comparison
    local current="${MON_CURRENT_BRIGHT[$monitor]:-1.0}"
    local diff
    diff=$(echo "scale=3; $current - $brightness" | bc | awk '{if ($1<0) print -$1; else print $1}')
    
    # Only update if the brightness actually changed by more than 0.001
    if [ "$(echo "$diff > 0.001" | bc -l)" -eq 1 ]; then
        if xrandr --output "$monitor" --brightness "$brightness" 2>/dev/null; then
            MON_CURRENT_BRIGHT["$monitor"]="$brightness"
            log_message "Set $monitor to brightness $brightness (instant)"
        else
            log_message "Error: Failed to set $monitor to brightness $brightness"
        fi
    fi
}

set_brightness_smooth() {
    local monitor="$1"
    local target="$2"
    local current="${MON_CURRENT_BRIGHT[$monitor]:-1.0}"
    
    # If instant dimming is enabled, or if the change is very small, do it instantly
    local diff
    diff=$(echo "scale=3; $current - $target" | bc | awk '{if ($1<0) print -$1; else print $1}')
    
    if [ "$INSTANT_DIM" = true ] || [ "$(echo "$diff < 0.01" | bc -l)" -eq 1 ]; then
        set_brightness_instant "$monitor" "$target"
        return
    fi
    
    log_message "Smooth transition for $monitor: $current -> $target ($SMOOTH_STEPS steps)"
    
    # Calculate step size
    local step
    step=$(echo "scale=4; ($target - $current) / $SMOOTH_STEPS" | bc)
    
    # Perform smooth transition
    for ((i=1; i<=SMOOTH_STEPS; i++)); do
        # Check for stop file during long transitions
        if [ -f "$STOP_FILE" ]; then
            log_message "Stop file detected during smooth transition"
            break
        fi
        
        current=$(echo "scale=4; $current + $step" | bc)
        
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
    log_message "Completed smooth transition for $monitor to $target"
}

# -----------------------------
# ACTIVITY & IDLE DETECTION
# -----------------------------
get_idle_time() {
    # Returns idle time in seconds (0 if xprintidle fails or not available)
    if [ "$IDLE_ENABLED" = false ]; then
        echo "0"
        return 0
    fi
    
    local idle_ms
    if idle_ms=$(xprintidle 2>/dev/null); then
        echo "$((idle_ms / 1000))"
    else
        log_message "Warning: xprintidle command failed"
        echo "0"
    fi
}

check_mouse_movement() {
    # Check if mouse has moved since last check
    local mouse_output
    if mouse_output=$(xdotool getmouselocation --shell 2>/dev/null); then
        eval "$mouse_output"
        
        if [ "$X" != "$LAST_X" ] || [ "$Y" != "$LAST_Y" ]; then
            LAST_X="$X"
            LAST_Y="$Y"
            LAST_ACTIVITY_TIME=$(date +%s)
            return 0  # Mouse moved
        fi
    else
        log_message "Warning: Failed to get mouse location"
    fi
    return 1  # Mouse stationary or error
}

update_activity() {
    # Update last activity time
    LAST_ACTIVITY_TIME=$(date +%s)
}

check_state_transition() {
    # Check and update the current state based on activity
    if [ "$IDLE_ENABLED" = false ]; then
        # If idle is disabled, always stay in active state
        if [ "$CURRENT_STATE" != "active" ]; then
            log_message "Idle disabled, returning to active state"
            CURRENT_STATE="active"
            return 2
        fi
        return 0
    fi
    
    local idle_time
    idle_time=$(get_idle_time)
    
    case "$CURRENT_STATE" in
        "active")
            if [ "$idle_time" -ge "$IDLE_TIMEOUT" ]; then
                log_message "Entering idle state (idle for ${idle_time}s)"
                CURRENT_STATE="idle"
                return 1  # State changed to idle
            fi
            ;;
        "idle")
            if [ "$idle_time" -lt "$IDLE_TIMEOUT" ]; then
                log_message "Activity detected, restoring brightness (idle for ${idle_time}s)"
                CURRENT_STATE="restoring"
                return 2  # State changed to restoring
            fi
            ;;
        "restoring")
            # Once we start restoring, we should quickly transition to active
            CURRENT_STATE="active"
            log_message "Restoration complete, returning to active state"
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
    log_message "Applying idle brightness ($IDLE_BRIGHTNESS) to all monitors"
    for MON in "${MONITORS[@]}"; do
        local current="${MON_CURRENT_BRIGHT[$MON]:-1.0}"
        if [ "$(echo "$current != $IDLE_BRIGHTNESS" | bc -l)" -eq 1 ]; then
            MON_TARGET_BRIGHT["$MON"]="$IDLE_BRIGHTNESS"
            set_brightness_smooth "$MON" "$IDLE_BRIGHTNESS"
        fi
    done
}

apply_active_brightness() {
    # Apply per-monitor dimming based on mouse position
    local active_mon=""
    
    # Get current mouse position
    local mouse_output
    if mouse_output=$(xdotool getmouselocation --shell 2>/dev/null); then
        eval "$mouse_output"
    else
        # Default to monitor 0 if we can't get mouse position
        X=0
        Y=0
        if [ ${#MONITORS[@]} -gt 0 ]; then
            active_mon="${MONITORS[0]}"
        fi
    fi
    
    # Find which monitor contains the mouse
    if [ -z "$active_mon" ]; then
        for MON in "${MONITORS[@]}"; do
            if [ "$X" -ge "${MON_X1[$MON]}" ] && [ "$X" -lt "${MON_X2[$MON]}" ] &&
               [ "$Y" -ge "${MON_Y1[$MON]}" ] && [ "$Y" -lt "${MON_Y2[$MON]}" ]; then
                active_mon="$MON"
                break
            fi
        done
    fi
    
    # Check toggle state
    local toggle_state=false
    if [ -f "$TOGGLE_FILE" ]; then
        toggle_state=true
    fi
    
    # Apply brightness to each monitor
    for MON in "${MONITORS[@]}"; do
        local target="$ACTIVE_BRIGHTNESS"
        
        if [ "$toggle_state" = true ] && [ "$MON" != "$active_mon" ]; then
            target="$DIM_BRIGHTNESS"
        fi
        
        # Only update if target changed
        local current_target="${MON_TARGET_BRIGHT[$MON]:-1.0}"
        if [ "$(echo "$current_target != $target" | bc -l)" -eq 1 ]; then
            MON_TARGET_BRIGHT["$MON"]="$target"
            set_brightness_smooth "$MON" "$target"
        fi
    done
    
    # Store last active monitor for state tracking
    LAST_ACTIVE_MON="$active_mon"
    TOGGLE_STATE="$toggle_state"
}

# -----------------------------
# GEOMETRY CHECK FUNCTION (NEW)
# -----------------------------
check_geometry() {
    # This function checks if monitor configuration has changed
    local new_xrandr_list
    if new_xrandr_list=$(xrandr --listmonitors 2>/dev/null); then
        local new_hash
        new_hash="$(echo "$new_xrandr_list" | sha1sum | awk '{print $1}')"
        
        if [ "$new_hash" != "$GEOM_HASH" ]; then
            log_message "Monitor configuration changed, updating geometry"
            echo "Monitor configuration changed. Updating..." >&2
            GEOM_HASH="$new_hash"
            GEOM_DIRTY=1
            if ! read_monitors; then
                echo "Warning: Failed to update monitor geometry" >&2
            fi
        fi
    else
        log_message "Warning: Failed to check monitor configuration"
    fi
}

# -----------------------------
# INITIAL SETUP
# -----------------------------
echo "Enhanced Per-Monitor Dimming Script" >&2
echo "==================================" >&2
echo "Active brightness: $ACTIVE_BRIGHTNESS" >&2
echo "Dim brightness: $DIM_BRIGHTNESS" >&2
echo "Idle timeout: ${IDLE_TIMEOUT}s" >&2
echo "Idle brightness: $IDLE_BRIGHTNESS" >&2
echo "Instant dimming: $INSTANT_DIM" >&2
echo "Smooth steps: $SMOOTH_STEPS" >&2
echo "Idle detection: $IDLE_ENABLED" >&2
echo "Logging: $ENABLE_LOGGING" >&2
echo "" >&2

if [ "$ENABLE_LOGGING" = true ]; then
    echo "Log file: $LOG_FILE" >&2
    echo "Starting logging..." >&2
    echo "==================================" >> "$LOG_FILE"
    echo "Script started at $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
fi

log_message "Script starting"
log_message "Configuration: ACTIVE=$ACTIVE_BRIGHTNESS, DIM=$DIM_BRIGHTNESS, IDLE=$IDLE_BRIGHTNESS"
log_message "Idle timeout: ${IDLE_TIMEOUT}s, Enabled: $IDLE_ENABLED"

# Read initial monitor configuration
if ! read_monitors; then
    echo "FATAL: Failed to read monitor configuration. Exiting." >&2
    exit 1
fi

XRANDR_LIST=$(xrandr --listmonitors 2>/dev/null)
if [ $? -eq 0 ]; then
    GEOM_HASH="$(echo "$XRANDR_LIST" | sha1sum | awk '{print $1}')"
else
    echo "Warning: Could not get initial monitor hash" >&2
    GEOM_HASH=""
fi

# Initialize brightness tracking
for MON in "${MONITORS[@]}"; do
    MON_CURRENT_BRIGHT["$MON"]=1.0
    MON_TARGET_BRIGHT["$MON"]=1.0
done

# Initial mouse position
if mouse_output=$(xdotool getmouselocation --shell 2>/dev/null); then
    eval "$mouse_output"
    LAST_X="$X"
    LAST_Y="$Y"
else
    LAST_X=0
    LAST_Y=0
    echo "Warning: Could not get initial mouse position" >&2
fi
LAST_ACTIVITY_TIME=$(date +%s)

echo "Found ${#MONITORS[@]} monitor(s): ${MONITORS[*]}" >&2
echo "Script initialized successfully. Press Ctrl+C to stop." >&2
echo "" >&2

# -----------------------------
# MAIN LOOP
# -----------------------------
while true; do
    # Check for stop file
    if [ -f "$STOP_FILE" ]; then
        log_message "Stop file detected, exiting"
        echo "Stop file detected. Exiting..." >&2
        rm -f "$STOP_FILE" 2>/dev/null
        exit 0
    fi
    
    NOW=$(date +%s)
    
    # -------- Monitor Configuration Check --------
    if (( NOW - LAST_GEOM_CHECK >= GEOM_INTERVAL )); then
        LAST_GEOM_CHECK=$NOW
        check_geometry
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
        
        # Check mouse movement
        if check_mouse_movement; then
            log_message "Mouse movement detected at ($X, $Y)"
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
            log_message "Restoring from idle state"
            apply_active_brightness
            CURRENT_STATE="active"
            ;;
    esac
    
    # -------- Sleep for next iteration --------
    sleep "$MOUSE_INTERVAL"
done
