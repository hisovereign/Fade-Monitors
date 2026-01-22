# Fade-Monitors
Mouse-aware and time-based monitor dimming with optional gamma control for (X11)




This script will auto dim whatever monitor your mouse is not on as well as auto dim at specified times with optional gamma changes

-Mouse-based dimming can be toggled off with a hotkey and defaults changed near top of script



**This is the updated, stable version of the stand-alone release with added time-based auto-dim and optional gammma controls similar to the original fade-monitors-night-gamma script


Requirements:

-x11 session 
-xrandr - controls montior brightness/gamma
-xdotool - reads mouse position



Install requirements (copy/paste commands into terminal)

	sudo apt install x11-xserver-utils xdotool

(xrandr will be installed if not already)


Optional (for hotkey support):

	sudo apt install xbindkeys



Installation:

1. Download the script
	(click on the fade-monitors-2d-time-based script then to the right of where it says RAW click download raw file)

2. Move it to ~/.local/bin

3. Make the script executable (open up a terminal and copy/paste commands then hit enter)

		chmod +x ~/.local/bin/fade-monitors-2d-time-based.sh

Run script manually

	~/.local/bin/fade-monitors-2d-time-based.sh

Stop

	pkill -f fade-monitors-2d-time-based.sh



	
Using xbindkeys (recommended) (copy/paste commands into terminal)

1. Install bindkeys

		sudo apt install xbindkeys

2. Create (or open) the xbindkeys config file

		nano ~/.xbindkeysrc

3.Add this block (copy/paste)

	"if [ -f ~/.fade_mouse_enabled ]; then rm ~/.fade_mouse_enabled; else touch ~/.fade_mouse_enabled; fi"
   	F10

4. Save and exit
	crtl + o, enter. crtl + x

5. Start or restart xbindkeys 

		killall xbindkeys
	
   		xbindkeys

5. Press F10 (or designated key) to toggle mouse-based fading.

   (Time based-based brightness will continue working normally)




Run script at start up

1. Open Start up applications> click + then custom command>browse and select the script you downloaded

2. Do the same for xbindkeys (click + then custom command and search for .xbindkeys)





Configuratuion: (can all be changed in script)

-You only need to change the actual values e.g. 0.8 for day brightness or 1630 for night start.

-Gamma is set to off (false) by default; to change make it (=true)

# Day / Night brightness
	DAY_BRIGHTNESS=0.7
	NIGHT_BRIGHTNESS=0.5
	DIM_BRIGHTNESS=0.2

# Time window (24h, HHMM)
	NIGHT_START=1630   # 16:30
	DAY_START=0600     # 06:00

# Gamma control (optional)
	ENABLE_GAMMA=false
	DAY_GAMMA="1.0:1.0:1.0"
	NIGHT_GAMMA="1.0:0.85:0.7"

**Important Information**

-Earlier versions sometimes casued brief flashes if multiple instances of Fade Monitors script ran simultaneously. This has been mitigated with single-instance locking however it is still possible if ran alongside a script without single-instance locking.

-Having gamma on will conflict with other programs that alter gamma.

-The mouse polling interval is intentionally tuned for low CPU usage. Advanced users may adjust MOUSE_INTERVAL in the script if they prefer more aggresive responsives at the cost of higher CPU activity.
