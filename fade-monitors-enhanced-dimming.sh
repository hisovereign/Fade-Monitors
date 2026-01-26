#!/bin/bash
# -----------------------------
# Professional Enhanced Dimming
# Complete Feature Set: Smooth transitions + Instant override
# -----------------------------
# Requires: xrandr, xdotool, xprintidle, bc
# -----------------------------

# -----------------------------
# USER CONFIG
# -----------------------------

# Brightness levels
ACTIVE_BRIGHTNESS=0.5      # Monitor with mouse
DIM_BRIGHTNESS=0.2         # Other monitors (when toggle ON)
IDLE_BRIGHTNESS=0.1        # All monitors when idle

# Idle settings
IDLE_TIMEOUT=5            # Seconds of inactivity before idle dim
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
MONITORS=()

CURRENT_STATE="active"
LAST_ACTIVE_MON=""
LAST_ACTIVITY_TIME=0
TOGGLE_STATE=false

LAST_X=-1
LAST_Y=-1

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
# SMOOTH TRANSITION FUNCTIONS
# -----------------------------
smooth_transition_to_idle() {
    # Transition all monitors to idle brightness
    local current_bright target_bright step_bright
    
    for MON in "${MONITORS[@]}"; do
        MON_TARGET_BRIGHT["$MON"]="$IDLE_BRIGHTNESS"
        current_bright="${MON_CURRENT_BRIGHT[$MON]:-1.0}"
        
        if [ "$INSTANT_DIM" = true ]; then
            # Instant dimming
            xrandr --output "$MON" --brightness "$IDLE_BRIGHTNESS" 2>/dev/null
            MON_CURRENT_BRIGHT["$MON"]="$IDLE_BRIGHTNESS"
        else
            # Smooth dimming
            step_bright=$(echo "scale=4; ($IDLE_BRIGHTNESS - $current_bright) / $SMOOTH_DIM_STEPS" | bc 2>/dev/null || echo "0")
            
            for ((i=1; i<=SMOOTH_DIM_STEPS; i++)); do
                current_bright=$(echo "scale=4; $current_bright + $step_bright" | bc 2>/dev/null || echo "$IDLE_BRIGHTNESS")
                
                # Clamp value
                if [ "$(echo "$current_bright < 0" | bc -l 2>/dev/null)" -eq 1 ]; then
                    current_bright=0
                elif [ "$(echo "$current_bright > 1" | bc -l 2>/dev/null)" -eq 1 ]; then
                    current_bright=1
                fi
                
                xrandr --output "$MON" --brightness "$current_bright" 2>/dev/null
                sleep "$SMOOTH_DIM_INTERVAL"
            done
            
            # Ensure exact target
            xrandr --output "$MON" --brightness "$IDLE_BRIGHTNESS" 2>/dev/null
            MON_CURRENT_BRIGHT["$MON"]="$IDLE_BRIGHTNESS"
        fi
    done
}

smooth_transition_to_active() {
    # Transition from idle to active state
    local target_bright current_bright step_bright
    
    # Calculate targets first
    get_mouse_position
    local active_mon=""
    local toggle_state=false
    [ -f "$TOGGLE_FILE" ] && toggle_state=true
    
    # Find active monitor
    for MON in "${MONITORS[@]}"; do
        if [ "$X" -ge "${MON_X1[$MON]}" ] && [ "$X" -lt "${MON_X2[$MON]}" ] &&
           [ "$Y" -ge "${MON_Y1[$MON]}" ] && [ "$Y" -lt "${MON_Y2[$MON]}" ]; then
            active_mon="$MON"
            break
        fi
    done
    
    # Set targets
    for MON in "${MONITORS[@]}"; do
        if [ "$toggle_state" = true ] && [ "$MON" != "$active_mon" ]; then
            MON_TARGET_BRIGHT["$MON"]="$DIM_BRIGHTNESS"
        else
            MON_TARGET_BRIGHT["$MON"]="$ACTIVE_BRIGHTNESS"
        fi
    done
    
    # Apply transitions
    if [ "$INSTANT_WAKE" = true ]; then
        # Instant wake
        for MON in "${MONITORS[@]}"; do
            target_bright="${MON_TARGET_BRIGHT[$MON]}"
            xrandr --output "$MON" --brightness "$target_bright" 2>/dev/null
            MON_CURRENT_BRIGHT["$MON"]="$target_bright"
        done
    else
        # Smooth wake
        for MON in "${MONITORS[@]}"; do
            target_bright="${MON_TARGET_BRIGHT[$MON]}"
            current_bright="${MON_CURRENT_BRIGHT[$MON]:-$IDLE_BRIGHTNESS}"
            step_bright=$(echo "scale=4; ($target_bright - $current_bright) / $SMOOTH_WAKE_STEPS" | bc 2>/dev/null || echo "0")
            
            for ((i=1; i<=SMOOTH_WAKE_STEPS; i++)); do
                current_bright=$(echo "scale=4; $current_bright + $step_bright" | bc 2>/dev/null || echo "$target_bright")
                
                # Clamp value
                if [ "$(echo "$current_bright < 0" | bc -l 2>/dev/null)" -eq 1 ]; then
                    current_bright=0
                elif [ "$(echo "$current_bright > 1" | bc -l 2>/dev/null)" -eq 1 ]; then
                    current_bright=1
                fi
                
                xrandr --output "$MON" --brightness "$current_bright" 2>/dev/null
                sleep "$SMOOTH_WAKE_INTERVAL"
            done
            
            # Ensure exact target
            xrandr --output "$MON" --brightness "$target_bright" 2>/dev/null
            MON_CURRENT_BRIGHT["$MON"]="$target_bright"
        done
    fi
    
    # Store tracking info
    LAST_ACTIVE_MON="$active_mon"
    TOGGLE_STATE="$toggle_state"
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
    smooth_transition_to_idle
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
    MON_TARGET_BRIGHT["$MON"]=1.0
done

LAST_ACTIVITY_TIME=$(date +%s)

echo "Enhanced Dimming Active" >&2
echo "==================================" >&2
echo "Active brightness: $ACTIVE_BRIGHTNESS" >&2
echo "Dim brightness: $DIM_BRIGHTNESS" >&2
echo "Idle brightness: $IDLE_BRIGHTNESS" >&2
echo "Idle timeout: ${IDLE_TIMEOUT}s" >&2
echo "" >&2
echo "Smooth dimming settings:" >&2
echo "  Dim steps: $SMOOTH_DIM_STEPS" >&2
echo "  Dim interval: ${SMOOTH_DIM_INTERVAL}s" >&2
echo "  Dim total: $(echo "$SMOOTH_DIM_STEPS * $SMOOTH_DIM_INTERVAL" | bc)s" >&2
echo "  Wake steps: $SMOOTH_WAKE_STEPS" >&2
echo "  Wake interval: ${SMOOTH_WAKE_INTERVAL}s" >&2
echo "  Wake total: $(echo "$SMOOTH_WAKE_STEPS * $SMOOTH_WAKE_INTERVAL" | bc)s" >&2
echo "" >&2
echo "Instant overrides:" >&2
echo "  Instant dim: $INSTANT_DIM" >&2
echo "  Instant wake: $INSTANT_WAKE" >&2
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
                smooth_transition_to_active
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
            # Transition handled in state check above
            ;;
    esac
    
    sleep "$MOUSE_INTERVAL"
done
