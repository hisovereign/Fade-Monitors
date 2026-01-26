#!/bin/bash
# -----------------------------
# Enhanced Per-Monitor Dimming
# Features:
# - Simultaneous smooth transitions for all monitors
# - Separate controls for idle dimming vs wake-up
# - Configurable smooth/instant dimming
# - Keyboard + mouse activity detection
# -----------------------------
# Requires: xrandr, xdotool, xprintidle, bc
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

# Dimming transitions (going TO idle/dim)
INSTANT_DIM=false          # true = instant changes, false = smooth transitions
SMOOTH_DIM_STEPS=10        # Number of steps for smooth transitions TO dim/idle
SMOOTH_DIM_INTERVAL=0.02   # Seconds between steps (0.05 × 20 = 1 second total)

# Wake-up transitions (coming FROM idle/dim)
INSTANT_WAKE=true         # true = instant wake, false = smooth wake
SMOOTH_WAKE_STEPS=10       # Number of steps for smooth wake-up (usually faster)
SMOOTH_WAKE_INTERVAL=0.01  # Seconds between steps (0.02 × 10 = 0.2 seconds total)

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

# Transition tracking
TRANSITION_IN_PROGRESS=false
TRANSITION_START_TIME=0

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
}

check_dependencies

# -----------------------------
# CLEANUP & SIGNAL HANDLING
# -----------------------------
restore_defaults() {
    log_message "Restoring defaults"
    # Restore all monitors to normal brightness
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --brightness 1.0 --gamma 1.0:1.0:1.0 2>/dev/null
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
        fi
    done
    
    if [ ${#MONITORS[@]} -eq 0 ]; then
        echo "ERROR: No monitors found!" >&2
        return 1
    fi
    
    return 0
}

# -----------------------------
# SIMULTANEOUS BRIGHTNESS CONTROL FUNCTIONS
# -----------------------------
set_all_brightness_instant() {
    # Set all monitors to their target brightness instantly
    for MON in "${MONITORS[@]}"; do
        local target="${MON_TARGET_BRIGHT[$MON]:-1.0}"
        local current="${MON_CURRENT_BRIGHT[$MON]:-1.0}"
        
        # Only update if changed
        if [ "$(echo "$current != $target" | bc -l)" -eq 1 ]; then
            xrandr --output "$MON" --brightness "$target" 2>/dev/null
            MON_CURRENT_BRIGHT["$MON"]="$target"
        fi
    done
}

transition_all_monitors() {
    # Simultaneous smooth transition for ALL monitors
    # Arguments: $1 = "dim" or "wake" (determines which settings to use)
    local mode="$1"
    local steps interval instant
    
    if [ "$mode" = "dim" ]; then
        steps="$SMOOTH_DIM_STEPS"
        interval="$SMOOTH_DIM_INTERVAL"
        instant="$INSTANT_DIM"
    elif [ "$mode" = "wake" ]; then
        steps="$SMOOTH_WAKE_STEPS"
        interval="$SMOOTH_WAKE_INTERVAL"
        instant="$INSTANT_WAKE"
    else
        echo "ERROR: Invalid transition mode: $mode" >&2
        return 1
    fi
    
    # Check if we should do instant transition
    if [ "$instant" = true ]; then
        set_all_brightness_instant
        log_message "Instant $mode transition"
        return 0
    fi
    
    log_message "Starting simultaneous smooth $mode transition ($steps steps)"
    TRANSITION_IN_PROGRESS=true
    TRANSITION_START_TIME=$(date +%s)
    
    # Calculate starting brightness for each monitor
    declare -A start_brightness
    declare -A target_brightness
    declare -A step_sizes
    
    for MON in "${MONITORS[@]}"; do
        start_brightness["$MON"]="${MON_CURRENT_BRIGHT[$MON]:-1.0}"
        target_brightness["$MON"]="${MON_TARGET_BRIGHT[$MON]:-1.0}"
        
        # Calculate step size for this monitor
        step_sizes["$MON"]=$(echo "scale=4; (${target_brightness[$MON]} - ${start_brightness[$MON]}) / $steps" | bc)
    done
    
    # Perform smooth transition simultaneously
    for ((step=1; step<=steps; step++)); do
        # Check for stop file
        if [ -f "$STOP_FILE" ]; then
            log_message "Stop file detected during transition"
            TRANSITION_IN_PROGRESS=false
            return 1
        fi
        
        # Calculate current brightness for each monitor and apply
        for MON in "${MONITORS[@]}"; do
            local current_bright
            current_bright=$(echo "scale=4; ${start_brightness[$MON]} + (${step_sizes[$MON]} * $step)" | bc)
            
            # Clamp between 0 and 1
            if [ "$(echo "$current_bright < 0" | bc -l)" -eq 1 ]; then
                current_bright=0
            elif [ "$(echo "$current_bright > 1" | bc -l)" -eq 1 ]; then
                current_bright=1
            fi
            
            xrandr --output "$MON" --brightness "$current_bright" 2>/dev/null
            MON_CURRENT_BRIGHT["$MON"]="$current_bright"
        done
        
        sleep "$interval"
    done
    
    # Ensure final targets are set exactly
    for MON in "${MONITORS[@]}"; do
        local target="${target_brightness[$MON]}"
        xrandr --output "$MON" --brightness "$target" 2>/dev/null
        MON_CURRENT_BRIGHT["$MON"]="$target"
    done
    
    TRANSITION_IN_PROGRESS=false
    local duration=$(( $(date +%s) - TRANSITION_START_TIME ))
    log_message "Completed simultaneous $mode transition in ${duration}s"
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
    fi
    return 1  # Mouse stationary or error
}

check_state_transition() {
    # Check and update the current state based on activity
    if [ "$IDLE_ENABLED" = false ]; then
        # If idle is disabled, always stay in active state
        if [ "$CURRENT_STATE" != "active" ]; then
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
            return 0  # State changed to active
            ;;
    esac
    return 0  # No state change
}

# -----------------------------
# BRIGHTNESS LOGIC FUNCTIONS
# -----------------------------
apply_idle_brightness() {
    # Set target brightness for idle state (all monitors same)
    for MON in "${MONITORS[@]}"; do
        MON_TARGET_BRIGHT["$MON"]="$IDLE_BRIGHTNESS"
    done
    
    # Apply the transition
    transition_all_monitors "dim"
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
    
    # Set target brightness for each monitor
    local needs_transition=false
    for MON in "${MONITORS[@]}"; do
        local target="$ACTIVE_BRIGHTNESS"
        
        if [ "$toggle_state" = true ] && [ "$MON" != "$active_mon" ]; then
            target="$DIM_BRIGHTNESS"
        fi
        
        # Check if target changed
        local current_target="${MON_TARGET_BRIGHT[$MON]:-1.0}"
        if [ "$(echo "$current_target != $target" | bc -l)" -eq 1 ]; then
            MON_TARGET_BRIGHT["$MON"]="$target"
            needs_transition=true
        fi
    done
    
    # Apply transition if needed (but not if we're already in a transition)
    if [ "$needs_transition" = true ] && [ "$TRANSITION_IN_PROGRESS" = false ]; then
        if [ "$CURRENT_STATE" = "restoring" ]; then
            # Use wake settings for restoring from idle
            transition_all_monitors "wake"
        else
            # Use dim settings for normal active changes
            transition_all_monitors "dim"
        fi
    elif [ "$needs_transition" = false ] && [ "$TRANSITION_IN_PROGRESS" = false ]; then
        # Just ensure current brightness matches target
        set_all_brightness_instant
    fi
    
    # Store last active monitor for state tracking
    LAST_ACTIVE_MON="$active_mon"
    TOGGLE_STATE="$toggle_state"
}

# -----------------------------
# GEOMETRY CHECK FUNCTION
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
    fi
}

# -----------------------------
# INITIAL SETUP
# -----------------------------
echo "Enhanced Per-Monitor Dimming Script" >&2
echo "==================================" >&2
echo "Active brightness: $ACTIVE_BRIGHTNESS" >&2
echo "Dim brightness: $DIM_BRIGHTNESS" >&2
echo "Idle brightness: $IDLE_BRIGHTNESS" >&2
echo "Idle timeout: ${IDLE_TIMEOUT}s" >&2
echo "Idle detection: $IDLE_ENABLED" >&2
echo "" >&2
echo "Dimming transitions:" >&2
echo "  Instant dim: $INSTANT_DIM" >&2
echo "  Smooth steps: $SMOOTH_DIM_STEPS" >&2
echo "  Step interval: ${SMOOTH_DIM_INTERVAL}s" >&2
echo "  Total time: $(echo "$SMOOTH_DIM_STEPS * $SMOOTH_DIM_INTERVAL" | bc)s" >&2
echo "" >&2
echo "Wake-up transitions:" >&2
echo "  Instant wake: $INSTANT_WAKE" >&2
echo "  Smooth steps: $SMOOTH_WAKE_STEPS" >&2
echo "  Step interval: ${SMOOTH_WAKE_INTERVAL}s" >&2
echo "  Total time: $(echo "$SMOOTH_WAKE_STEPS * $SMOOTH_WAKE_INTERVAL" | bc)s" >&2
echo "" >&2

if [ "$ENABLE_LOGGING" = true ]; then
    echo "Log file: $LOG_FILE" >&2
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
        check_mouse_movement
        
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
            ;;
    esac
    
    # -------- Sleep for next iteration --------
    sleep "$MOUSE_INTERVAL"
done
