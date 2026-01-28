# Fade-Monitors
## Mouse-aware and time-based monitor dimming with optional gamma control for (X11)


-This script will auto dim whatever monitor your mouse is not on as well as auto dim at specified times with optional gamma changes

-Mouse-based dimming can be toggled off with a hotkey and defaults changed near top of script



**This is the updated, stable version of the stand-alone release with added time-based auto-dim and optional gammma controls similar to the original fade-monitors-night-gamma script


## Requirements:

-x11 session 

-xrandr - controls montior brightness/gamma

-xdotool - reads mouse position



## Install requirements (copy, paste(ctrl + shift + v) commands into terminal)

Open menu and search for terminal.

Copy/paste then hit enter
	
	sudo apt-get update

Then install

	sudo apt install x11-xserver-utils xdotool

(xrandr will be installed if not already)


Optional (for hotkey support):

	sudo apt install xbindkeys



## Installation:

1. Download the script
	(click on the fade-monitors-2d-time-based script then to the right of where it says RAW click download raw file)

2. Move it to ~/.local/bin  (if you don't see it in your home folder right click>show hidden files)

3. Make the script executable (open up a terminal and copy/paste commands then hit enter)

		chmod +x ~/.local/bin/fade-monitors-2d-time-based.sh

Run the script

	~/.local/bin/fade-monitors-2d-time-based.sh



## How to stop the script

1. Close the terminal you ran the script in or

2. Copy/paste in new terminal
   
		pkill -f fade-monitors-2d-time-based.sh


## Using xbindkeys (recommended) 
(copy/paste commands into terminal)

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




## Run script at start up

**WARNING** Running script at start up and changing brightness values to zero will blackout monitors and you need to do recovery option in important information at bottom.

1. Open Start up applications> click + then custom command>browse and select the script you downloaded

2. Do the same for xbindkeys (click + then custom command and search for .xbindkeys)





## Configuratuion: (can all be changed in script)

-You only need to change the actual values e.g. 0.8 for day brightness or 1630 for night start.

-Gamma is set to off (false) by default; to change make it (=true)

  Day / Night brightness
    
	DAY_BRIGHTNESS=0.7
	NIGHT_BRIGHTNESS=0.5
	DIM_BRIGHTNESS=0.2

Time window (24h, HHMM)**
	
	NIGHT_START=1630   # 16:30
	DAY_START=0600     # 06:00

Gamma control (optional)**
    
	ENABLE_GAMMA=false
	DAY_GAMMA="1.0:1.0:1.0"
	NIGHT_GAMMA="1.0:0.85:0.7"

## Important Information

![WARNING] Minimum brightness logic has been implemented. However, you can just delete it. Previous version of this script can also still set brightness values to zero. Doing so will blackout monitors and you will need **boot into a live USB session, mount system drive, nagivate to .local/bin and change the script**
 
 or
 
**Blind** enter ctrl + alt + F2, put in your username, put in your password, then pkill -f fade-monitors-2d-time-based.sh, then (ctrl + alt + F1) or sometimes (ctrl + alt + F7). This will kill the script and you will need to change values before restart.

-Earlier versions sometimes caused brief flashes if multiple instances of Fade Monitors script ran simultaneously. This has been mitigated with single-instance locking however it is still possible if ran alongside a script without single-instance locking.

-Having gamma on will conflict with other programs that alter gamma.

-The mouse polling interval is intentionally tuned for low CPU usage. Advanced users may adjust MOUSE_INTERVAL in the script if they prefer even lower cpu usage. 0.2 works, 0.3 is functional but mouse-based dimming may not trigger with fast mouse movements
