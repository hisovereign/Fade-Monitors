#!/bin/bash
# -----------------------------
# Professional Enhanced Dimming
# -----------------------------
# Requires: xrandr, xdotool, xprintidle, bc
# -----------------------------

# -----------------------------
# USER CONFIG
# -----------------------------

# Brightness levels
ACTIVE_BRIGHTNESS=0.7      # Monitor with mouse
DIM_BRIGHTNESS=0.5         # Other monitors (when toggle ON)
IDLE_BRIGHTNESS=0.1        # All monitors when idle

# Idle settings
IDLE_TIMEOUT=60            # Seconds of inactivity before idle dim
IDLE_ENABLED=true          # Set to false to disable idle dimming

# Smooth dimming settings
SMOOTH_DIM_STEPS=10        # Number of steps for smooth transitions TO dim/idle
SMOOTH_DIM_INTERVAL=0.02   # Seconds between steps (0.05 × 20 = 1 second total)
SMOOTH_WAKE_STEPS=10       # Number of steps for smooth wake-up FROM idle
SMOOTH_WAKE_INTERVAL=0.01  # Seconds between steps (0.02 × 10 = 0.2 seconds total)

# Instant override options
INSTANT_DIM=false          # Override smooth dimming with instant (going TO dim/idle)
INSTANT_WAKE=true          # Override smooth waking with instant (coming FROM idle)

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
declare -A START_BRIGHTNESS STEP_SIZES
MONITORS=()

CURRENT_STATE="active"
LAST_ACTIVE_MON=""
LAST_ACTIVITY_TIME=0
TOGGLE_STATE=false

LAST_X=-1
LAST_Y=-1
TRANSITION_IN_PROGRESS=false

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
    
    if [ ${#MONITORS[@]} -eq 0 ]; then
        echo "No monitors found" >&2
        return 1
    fi
    return 0
}

# -----------------------------
# PARALLEL XRANDR FUNCTIONS
# -----------------------------
parallel_xrandr_same() {
    # Set all monitors to the same brightness
    local brightness="$1"
    local pids=()
    
    for MON in "${MONITORS[@]}"; do
        xrandr --output "$MON" --brightness "$brightness" 2>/dev/null &
        pids+=($!)
    done
    
    wait "${pids[@]}" 2>/dev/null
}

parallel_xrandr_different() {
    # Set each monitor to its own brightness (parallel)
    local -A brightness_map=()
    while [ $# -ge 2 ]; do
        brightness_map["$1"]="$2"
        shift 2
    done
    
    local pids=()
    for MON in "${MONITORS[@]}"; do
        if [ -n "${brightness_map[$MON]}" ]; then
            xrandr --output "$MON" --brightness "${brightness_map[$MON]}" 2>/dev/null &
            pids+=($!)
        fi
    done
    
    wait "${pids[@]}" 2>/dev/null
}

# -----------------------------
# SIMULTANEOUS SMOOTH TRANSITIONS
# -----------------------------
simultaneous_smooth_transition() {
    local mode="$1"  # "dim" or "wake"
    local steps interval instant
    
    case "$mode" in
        "dim")
            steps="$SMOOTH_DIM_STEPS"
            interval="$SMOOTH_DIM_INTERVAL"
            instant="$INSTANT_DIM"
            ;;
        "wake")
            steps="$SMOOTH_WAKE_STEPS"
            interval="$SMOOTH_WAKE_INTERVAL"
            instant="$INSTANT_WAKE"
            ;;
        *)
            return 1
            ;;
    esac
    
    # Instant mode
    if [ "$instant" = true ]; then
        for MON in "${MONITORS[@]}"; do
            MON_CURRENT_BRIGHT["$MON"]="${MON_TARGET_BRIGHT[$MON]}"
        done
        
        # Use parallel update with different brightness per monitor
        local brightness_args=()
        for MON in "${MONITORS[@]}"; do
            brightness_args+=("$MON" "${MON_TARGET_BRIGHT[$MON]}")
        done
        parallel_xrandr_different "${brightness_args[@]}"
        return 0
    fi
    
    # Smooth transition
    TRANSITION_IN_PROGRESS=true
    
    # Calculate start values and step sizes for each monitor
    for MON in "${MONITORS[@]}"; do
        START_BRIGHTNESS["$MON"]="${MON_CURRENT_BRIGHT[$MON]:-1.0}"
        STEP_SIZES["$MON"]=$(echo "scale=6; (${MON_TARGET_BRIGHT[$MON]} - ${START_BRIGHTNESS[$MON]}) / $steps" | bc 2>/dev/null || echo "0")
    done
    
    # Perform smooth transition with parallel updates
    for ((step=1; step<=steps; step++)); do
        # Calculate current brightness for this step for each monitor
        local brightness_args=()
        
        for MON in "${MONITORS[@]}"; do
            local current
            current=$(echo "scale=6; ${START_BRIGHTNESS[$MON]} + ${STEP_SIZES[$MON]} * $step" | bc 2>/dev/null || echo "${MON_TARGET_BRIGHT[$MON]}")
            
            # Clamp between 0 and 1
            if [ "$(echo "$current < 0" | bc -l 2>/dev/null)" -eq 1 ]; then
                current=0
            elif [ "$(echo "$current > 1" | bc -l 2>/dev/null)" -eq 1 ]; then
                current=1
            fi
            
            # Store current brightness
            MON_CURRENT_BRIGHT["$MON"]="$current"
            brightness_args+=("$MON" "$current")
        done
        
        # Update all monitors in parallel with their individual brightness
        parallel_xrandr_different "${brightness_args[@]}"
        
        # Sleep for interval
        sleep "$interval"
    done
    
    # Ensure final exact targets are set
    for MON in "${MONITORS[@]}"; do
        MON_CURRENT_BRIGHT["$MON"]="${MON_TARGET_BRIGHT[$MON]}"
    done
    
    # Final parallel update with exact targets
    local final_brightness_args=()
    for MON in "${MONITORS[@]}"; do
        final_brightness_args+=("$MON" "${MON_TARGET_BRIGHT[$MON]}")
    done
    parallel_xrandr_different "${final_brightness_args[@]}"
    
    TRANSITION_IN_PROGRESS=false
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
# BRIGHTNESS FUNCTIONS - BUG FIXED
# -----------------------------
apply_idle_brightness() {
    # Set target brightness for idle state (all monitors same)
    for MON in "${MONITORS[@]}"; do
        MON_TARGET_BRIGHT["$MON"]="$IDLE_BRIGHTNESS"
    done
    
    # Apply simultaneous transition
    simultaneous_smooth_transition "dim"
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
    
    # If no active monitor found, default to first monitor
    if [ -z "$active_mon" ] && [ ${#MONITORS[@]} -gt 0 ]; then
        active_mon="${MONITORS[0]}"
    fi
    
    # Check toggle state
    toggle_state=false
    if [ -f "$TOGGLE_FILE" ]; then
        toggle_state=true
    fi
    
    # Set targets for each monitor
    needs_update=false
    for MON in "${MONITORS[@]}"; do
        # FIXED BUG: Logic was reversed
        # If toggle is OFF, all monitors should be ACTIVE_BRIGHTNESS
        # If toggle is ON, only active monitor should be ACTIVE_BRIGHTNESS, others DIM_BRIGHTNESS
        if [ "$toggle_state" = true ]; then
            if [ "$MON" = "$active_mon" ]; then
                target="$ACTIVE_BRIGHTNESS"
            else
                target="$DIM_BRIGHTNESS"
            fi
        else
            # Toggle is OFF - all monitors get ACTIVE_BRIGHTNESS
            target="$ACTIVE_BRIGHTNESS"
        fi
        
        # Check if target changed
        current_target="${MON_TARGET_BRIGHT[$MON]:-1.0}"
        if [ "$(echo "$current_target != $target" | bc -l 2>/dev/null)" -eq 1 ]; then
            MON_TARGET_BRIGHT["$MON"]="$target"
            needs_update=true
        fi
    done
    
    # Apply transition if needed (but not if already in transition)
    if [ "$needs_update" = true ] && [ "$TRANSITION_IN_PROGRESS" = false ]; then
        local mode="dim"
        if [ "$CURRENT_STATE" = "waking" ]; then
            mode="wake"
        fi
        simultaneous_smooth_transition "$mode"
    elif [ "$needs_update" = false ] && [ "$TRANSITION_IN_PROGRESS" = false ]; then
        # Just ensure current brightness matches target
        for MON in "${MONITORS[@]}"; do
            current="${MON_CURRENT_BRIGHT[$MON]:-1.0}"
            target="${MON_TARGET_BRIGHT[$MON]:-1.0}"
            if [ "$(echo "$current != $target" | bc -l 2>/dev/null)" -eq 1 ]; then
                xrandr --output "$MON" --brightness "$target" 2>/dev/null
                MON_CURRENT_BRIGHT["$MON"]="$target"
            fi
        done
    fi
    
    # Store for tracking
    LAST_ACTIVE_MON="$active_mon"
    TOGGLE_STATE="$toggle_state"
}

# -----------------------------
# MAIN LOOP
# -----------------------------
read_monitors

# Initialize brightness tracking
for MON in "${MONITORS[@]}"; do
    MON_CURRENT_BRIGHT["$MON"]=1.0
    MON_TARGET_BRIGHT["$MON"]=1.0
done

LAST_ACTIVITY_TIME=$(date +%s)

echo "Enhanced Dimming Active - BUG FIXED VERSION" >&2
echo "==================================" >&2
echo "Active brightness: $ACTIVE_BRIGHTNESS" >&2
echo "Dim brightness: $DIM_BRIGHTNESS" >&2
echo "Idle brightness: $IDLE_BRIGHTNESS" >&2
echo "Idle timeout: ${IDLE_TIMEOUT}s" >&2
echo "" >&2
echo "Smooth dimming settings:" >&2
echo "  Dim steps: $SMOOTH_DIM_STEPS (total: $(echo "$SMOOTH_DIM_STEPS * $SMOOTH_DIM_INTERVAL" | bc)s)" >&2
echo "  Wake steps: $SMOOTH_WAKE_STEPS (total: $(echo "$SMOOTH_WAKE_STEPS * $SMOOTH_WAKE_INTERVAL" | bc)s)" >&2
echo "" >&2
echo "Instant overrides:" >&2
echo "  Instant dim: $INSTANT_DIM" >&2
echo "  Instant wake: $INSTANT_WAKE" >&2
echo "" >&2
echo "Toggle file: $TOGGLE_FILE" >&2
echo "  ON: Per-monitor dimming enabled" >&2
echo "  OFF: All monitors at active brightness" >&2
echo "" >&2
echo "Parallel updates: ENABLED with per-monitor brightness" >&2
echo "" >&2

while true; do
    # Check stop file
    [ -f "$STOP_FILE" ] && { rm -f "$STOP_FILE"; exit 0; }
    
    NOW=$(date +%s)
    
    # Check idle state
    if [ "$IDLE_ENABLED" = true ]; then
        idle_time=$(get_idle_time)
        
        case "$CURRENT_STATE" in
            "active")
                if [ "$idle_time" -ge "$IDLE_TIMEOUT" ]; then
                    echo "Entering idle state (idle for ${idle_time}s)" >&2
                    CURRENT_STATE="idle"
                fi
                ;;
            "idle")
                if [ "$idle_time" -lt "$IDLE_TIMEOUT" ]; then
                    echo "Waking from idle (idle for ${idle_time}s)" >&2
                    CURRENT_STATE="waking"
                fi
                ;;
            "waking")
                # Transition handled in apply_active_brightness
                CURRENT_STATE="active"
                ;;
        esac
    fi
    
    # Apply brightness based on state
    case "$CURRENT_STATE" in
        "active")
            apply_active_brightness
            ;;
        "idle")
            apply_idle_brightness
            ;;
        "waking")
            apply_active_brightness
            ;;
    esac
    
    sleep "$MOUSE_INTERVAL"
done
