# Fade-Monitors-enhanced-dimming

Shebang! I'm told this is really close to pushing bash scripiting to its limits. **Experimental** 

## Mouse-aware auto-monitor dimming with idle dimming (dims down all monitors when user has not touched pc for a set time.)(X11)



This does not aim to replace password protected screen saver but to act as a quality of life addition to the computer experience. 


**This script will auto dim whatever monitor your mouse is not on as well as idle dim to user's preferred settings** 
	
-Mouse-based dimming can be toggled off with a hotkey.

(This version does not have time-based brightness or gamma control but has been updated so user can set an inactivity time between their already set screen saver and/or sleep time.)

**This is the updated stable and optimized version of the mouse-based auto-dim stand-alone script



### Requirements:

-x11 session

-xrandr - controls montior brightness/gamma

-xdotool - reads mouse position

-xprintidle

### Install requirements (copy, paste(ctrl + shift + v) commands into terminal)
Open menu and search for terminal.

Copy/paste then hit enter

	sudo apt-get update
	
Then install

	sudo apt-get install xprintidle bc xdotool x11-xserver-utils

(xrandr will be installed if not already)


Optional (for hotkey support):

	sudo apt install xbindkeys


### Installation:

1. Download the script
	(click on fade-monitors-enhanced-dimming script and to the right of where it says RAW click download raw file)

2. Move it to ~/.local/bin 

3. Make the script executable (open up a terminal and copy/paste commands then hit enter)

		chmod +x ~/.local/bin/fade-monitors-enhanced-dimming.sh

Run the script
	
	~/.local/bin/fade-monitors-enhanced-dimming.sh

How to stop the script

1. ctrl + c in terminal you started script or

2. close the terminal you started script in or

3. Open a new terminal, copy/paste then hit enter

		pkill -f fade-monitors-enhanced-dimming.sh

### Using xbindkeys (recommended) (copy/paste commands into terminal)

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

6. Press the F10 (or designated key) to toggle mouse-based fading.



### Run script at start up

Open Start up applications> click + then custom command>browse and select the script you downloaded

Do the same for xbindkeys (click + then custom command and search for .xbindkeys)



*Reset brightness command for xrandr if needed
	
	xrandr --output <output-name> --brightness 1.0

### Important Information

-Warning Blackout Monitor Warning **If you change the minimum values to zero it will blackout monitors and you will need to ctrl + alt + F2, put in your username, put in your password, then pkill -f fade-monitors-auto-2d-stable.sh, then (ctrl + alt + F1) or sometimes (ctrl + alt + F7).** 


-The mouse polling interval is intentionally tuned for low CPU usage. Advanced users may adjust MOUSE_INTERVAL in the script if they prefer even less cpu usage at cost of monitor dim lag. 0.2 will work. 0.3 is still functional but fast mouse movements may not trigger monitor dim.


-Earlier versions sometimes caused brief flashes if multiple instances of Fade Monitors script ran simultaneously. This has been mitigated with single-instance locking however it is still possible if ran alongside a script without single-instance locking.
