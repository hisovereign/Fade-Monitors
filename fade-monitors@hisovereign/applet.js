const Applet = imports.ui.applet;
const PopupMenu = imports.ui.popupMenu;
const GLib = imports.gi.GLib;
const Gio = imports.gi.Gio;
const St = imports.gi.St;
const Main = imports.ui.main;

let UUID = "fade-monitors@hisovereign";

const HOME = GLib.get_home_dir();
const MOUSE_TOGGLE_FILE = HOME + "/.fade_mouse_enabled";
const IDLE_TOGGLE_FILE = HOME + "/.idle_dim_enabled";
const STOP_FILE = HOME + "/.fade_mouse_stopped";
const SCRIPT_NAME = "fade-monitors";
const SCRIPT_PATH = HOME + "/.local/bin/" + SCRIPT_NAME;
const CONFIG_PATH = HOME + "/.config/fade-monitors/config";
const GITHUB_URL = "https://github.com/hisovereign/Fade-Monitors";

class FadeMonitorsApplet extends Applet.IconApplet {
    constructor(metadata, orientation, panelHeight, instanceId) {
        super(orientation, panelHeight, instanceId);

        this.set_applet_icon_symbolic_name("video-display-symbolic");
        this.set_applet_tooltip("Fade Monitors");

        this.menu = new Applet.AppletPopupMenu(this, orientation);
        this.menuManager = new PopupMenu.PopupMenuManager(this);
        this.menuManager.addMenu(this.menu);

        this._mouseDimmingEnabled = this._isMouseDimmingEnabled();
        this._idleDimmingEnabled = this._isIdleDimmingEnabled();
        this._gammaEnabled = false;

        this.settingsSubmenu = null;

        // Local config values
        this._newDayActiveBrightness   = 0.7;
        this._newDayDimBrightness      = 0.3;
        this._newNightActiveBrightness = 0.4;
        this._newNightDimBrightness    = 0.1;
        this._newIdleBrightness        = 0.1;
        this._newEnableGamma           = false;
        this._newDayGamma              = "1.0:1.0:1.0";
        this._newNightGamma            = "1.0:0.85:0.1";
        this._newIdleTimeout           = "90";
        this._newDayStart              = "0730";
        this._newNightStart            = "1700";

        // Widget references
        this._dayGammaEntry   = null;
        this._nightGammaEntry = null;
        this._idleTimeoutEntry = null;
        this._dayStartEntry   = null;
        this._nightStartEntry = null;

        this._buildMenu();
    }

    /* ---------------- Cinnamon lifecycle ---------------- */

    on_applet_added_to_panel() {
        this._startScript();
    }

    on_applet_removed_from_panel() {
        this._stopScript();
    }

    on_applet_clicked() {
        this._mouseDimmingEnabled = this._isMouseDimmingEnabled();
        this._idleDimmingEnabled = this._isIdleDimmingEnabled();
        this._refreshMenuLabels();
        this._refreshSettings();
        this.menu.toggle();
    }

    /* ---------------- Menu structure ---------------- */

    _buildMenu() {
        // Mouse dimming toggle
        this.mouseToggleSwitch = new PopupMenu.PopupSwitchMenuItem("Mouse Dim", this._mouseDimmingEnabled);
        this.mouseToggleSwitch.connect("toggled", (item, state) => { this._toggleMouseDimming(state); });
        this.menu.addMenuItem(this.mouseToggleSwitch);

        // Idle dimming toggle
        this.idleToggleSwitch = new PopupMenu.PopupSwitchMenuItem("Idle Dim", this._idleDimmingEnabled);
        this.idleToggleSwitch.connect("toggled", (item, state) => { this._toggleIdleDimming(state); });
        this.menu.addMenuItem(this.idleToggleSwitch);

        // Gamma toggle (immediate)
        this.gammaToggleSwitch = new PopupMenu.PopupSwitchMenuItem("Gamma", this._gammaEnabled);
        this.gammaToggleSwitch.connect("toggled", (item, state) => { this._toggleGamma(state); });
        this.menu.addMenuItem(this.gammaToggleSwitch);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Status
        this.statusItem = new PopupMenu.PopupMenuItem("");
        this.statusItem.setSensitive(false);
        this.menu.addMenuItem(this.statusItem);

        // Script control
        let startItem = new PopupMenu.PopupMenuItem("Start");
        startItem.connect("activate", () => { this._startScript(); });
        this.menu.addMenuItem(startItem);

        let stopItem = new PopupMenu.PopupMenuItem("Stop");
        stopItem.connect("activate", () => { this._stopScript(); });
        this.menu.addMenuItem(stopItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Settings submenu
        this.settingsSubmenu = new PopupMenu.PopupSubMenuMenuItem("Settings");
        this.menu.addMenuItem(this.settingsSubmenu);

        this._refreshMenuLabels();
    }

    /* ---------------- Settings population ---------------- */

    _refreshSettings() {
        this._readFadeConfig((config) => {
            this._newDayActiveBrightness   = parseFloat(config.DAY_ACTIVE_BRIGHTNESS)   || 0.7;
            this._newDayDimBrightness      = parseFloat(config.DAY_DIM_BRIGHTNESS)      || 0.3;
            this._newNightActiveBrightness = parseFloat(config.NIGHT_ACTIVE_BRIGHTNESS) || 0.4;
            this._newNightDimBrightness    = parseFloat(config.NIGHT_DIM_BRIGHTNESS)    || 0.1;
            this._newIdleBrightness        = parseFloat(config.IDLE_BRIGHTNESS)        || 0.1;
            this._newEnableGamma           = config.ENABLE_GAMMA === "false";
            this._newDayGamma              = config.DAY_GAMMA   || "1.0:1.0:1.0";
            this._newNightGamma            = config.NIGHT_GAMMA || "1.0:0.85:0.1";
            this._newIdleTimeout           = config.IDLE_TIMEOUT || "90";
            this._newDayStart              = config.DAY_START    || "0730";
            this._newNightStart            = config.NIGHT_START  || "1700";

            this.gammaToggleSwitch.setToggleState(this._newEnableGamma);
            this._gammaEnabled = this._newEnableGamma;

            this._populateSettingsSubmenu();
        });
    }

    _populateSettingsSubmenu() {
        this.settingsSubmenu.menu.removeAll();

        // --- Day brightness ---
        let dayHeader = new PopupMenu.PopupMenuItem("Day Brightness");
        dayHeader.setSensitive(false);
        this.settingsSubmenu.menu.addMenuItem(dayHeader);

        this.settingsSubmenu.menu.addMenuItem(
            this._addBrightnessSlider("Active", this._newDayActiveBrightness, (v) => { this._newDayActiveBrightness = v; })
        );
        this.settingsSubmenu.menu.addMenuItem(
            this._addBrightnessSlider("Dim", this._newDayDimBrightness, (v) => { this._newDayDimBrightness = v; })
        );

        // --- Night brightness ---
        let nightHeader = new PopupMenu.PopupMenuItem("Night Brightness");
        nightHeader.setSensitive(false);
        this.settingsSubmenu.menu.addMenuItem(nightHeader);

        this.settingsSubmenu.menu.addMenuItem(
            this._addBrightnessSlider("Active", this._newNightActiveBrightness, (v) => { this._newNightActiveBrightness = v; })
        );
        this.settingsSubmenu.menu.addMenuItem(
            this._addBrightnessSlider("Dim", this._newNightDimBrightness, (v) => { this._newNightDimBrightness = v; })
        );

        // --- Idle timeout & brightness ---
        this._idleTimeoutEntry = this._addTextEntryRow(this.settingsSubmenu.menu, "Idle Timeout (s)", this._newIdleTimeout,
            (v) => { this._newIdleTimeout = v; });
        this.settingsSubmenu.menu.addMenuItem(
            this._addBrightnessSlider("Idle Brightness", this._newIdleBrightness, (v) => { this._newIdleBrightness = v; })
        );

        this.settingsSubmenu.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // --- Day/Night start times ---
        this._dayStartEntry = this._addTextEntryRow(this.settingsSubmenu.menu, "Day Start (HHMM)", this._newDayStart,
            (v) => { this._newDayStart = v; });
        this._nightStartEntry = this._addTextEntryRow(this.settingsSubmenu.menu, "Night Start (HHMM)", this._newNightStart,
            (v) => { this._newNightStart = v; });

        this.settingsSubmenu.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // --- Day & Night gamma values ---
        this._dayGammaEntry = this._addTextEntryRow(this.settingsSubmenu.menu, "Day Gamma", this._newDayGamma,
            (v) => { this._newDayGamma = v; });
        this._nightGammaEntry = this._addTextEntryRow(this.settingsSubmenu.menu, "Night Gamma", this._newNightGamma,
            (v) => { this._newNightGamma = v; });

        this.settingsSubmenu.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // --- Apply button ---
        let applyItem = new PopupMenu.PopupMenuItem("Apply Settings");
        applyItem.connect("activate", () => { this._applySettings(); });
        this.settingsSubmenu.menu.addMenuItem(applyItem);
    }

    /* ---------------- Helpers ---------------- */

    _addBrightnessSlider(label, initialValue, onChange) {
        let slider = new PopupMenu.PopupSliderMenuItem(initialValue);
        let sliderLabel = slider.actor.get_children()[0];
        sliderLabel.text = label + ": " + initialValue.toFixed(2);
        slider.connect("value-changed", (item) => {
            let val = Math.round(item._value * 100) / 100;
            sliderLabel.text = label + ": " + val.toFixed(2);
            onChange(val);
        });
        return slider;
    }

    _addTextEntryRow(menu, label, initialValue, onChange) {
        let item = new PopupMenu.PopupBaseMenuItem({ reactive: false });
        let box = new St.BoxLayout({ vertical: false });
        let lbl = new St.Label({ text: label + ": " });
        box.add(lbl);
        let entry = new St.Entry({ text: initialValue, style_class: "popup-menu-item", can_focus: true, reactive: true });
        entry.clutter_text.set_single_line_mode(true);
        box.add(entry);
        item.addActor(box);
        menu.addMenuItem(item);
        entry.clutter_text.connect("activate", () => { onChange(entry.text); });
        return entry;
    }

    /* ---------------- Apply Settings ---------------- */

    _applySettings() {
        if (this._dayGammaEntry)   this._newDayGamma   = this._dayGammaEntry.text;
        if (this._nightGammaEntry) this._newNightGamma = this._nightGammaEntry.text;
        if (this._idleTimeoutEntry) this._newIdleTimeout = this._idleTimeoutEntry.text;
        if (this._dayStartEntry)    this._newDayStart   = this._dayStartEntry.text;
        if (this._nightStartEntry)  this._newNightStart = this._nightStartEntry.text;

        let commands = [
            ["set", "DAY_ACTIVE_BRIGHTNESS",   this._newDayActiveBrightness.toString()],
            ["set", "DAY_DIM_BRIGHTNESS",      this._newDayDimBrightness.toString()],
            ["set", "NIGHT_ACTIVE_BRIGHTNESS", this._newNightActiveBrightness.toString()],
            ["set", "NIGHT_DIM_BRIGHTNESS",    this._newNightDimBrightness.toString()],
            ["set", "IDLE_BRIGHTNESS",        this._newIdleBrightness.toString()],
            ["set", "DAY_GAMMA",              this._newDayGamma],
            ["set", "NIGHT_GAMMA",            this._newNightGamma],
            ["set", "IDLE_TIMEOUT",           this._newIdleTimeout],
            ["set", "DAY_START",              this._newDayStart],
            ["set", "NIGHT_START",            this._newNightStart]
        ];

        for (let i = 0; i < commands.length; i++) {
            GLib.spawn_sync(null, [SCRIPT_PATH].concat(commands[i]), null, GLib.SpawnFlags.SEARCH_PATH, null);
        }
        GLib.spawn_sync(null, [SCRIPT_PATH, "reload"], null, GLib.SpawnFlags.SEARCH_PATH, null);

        Main.notify("Fade Monitors", "Settings applied and reloaded.");
    }

    /* ---------------- Immediate toggles ---------------- */

    _toggleMouseDimming(state) {
        try {
            if (state) GLib.file_set_contents(MOUSE_TOGGLE_FILE, "");
            else GLib.unlink(MOUSE_TOGGLE_FILE);
            this._mouseDimmingEnabled = state;
            this._refreshMenuLabels();
        } catch (e) { this._showError("Failed to toggle mouse dimming: " + e.message); }
    }

    _toggleIdleDimming(state) {
        try {
            if (state) GLib.unlink(IDLE_TOGGLE_FILE);
            else GLib.file_set_contents(IDLE_TOGGLE_FILE, "");
            this._idleDimmingEnabled = state;
            this._refreshMenuLabels();
        } catch (e) { this._showError("Failed to toggle idle dimming: " + e.message); }
    }

    _toggleGamma(state) {
        try {
            GLib.spawn_sync(null, [SCRIPT_PATH, "set", "ENABLE_GAMMA", state ? "true" : "false"], null, GLib.SpawnFlags.SEARCH_PATH, null);
            GLib.spawn_sync(null, [SCRIPT_PATH, "reload"], null, GLib.SpawnFlags.SEARCH_PATH, null);
            this._gammaEnabled = state;
            this._newEnableGamma = state;
            this.gammaToggleSwitch.setToggleState(state);
        } catch (e) { this._showError("Failed to toggle gamma: " + e.message); }
    }

    /* ---------------- Config reading ---------------- */

    _readFadeConfig(callback) {
        let configFile = Gio.File.new_for_path(CONFIG_PATH);
        if (!configFile.query_exists(null)) { callback({}); return; }
        configFile.load_contents_async(null, (obj, res) => {
            let result = {};
            try {
                let [success, contents] = obj.load_contents_finish(res);
                if (success) {
                    let lines = contents.toString().split('\n');
                    for (let i = 0; i < lines.length; i++) {
                        let line = lines[i].trim();
                        if (line === "" || line.startsWith("#")) continue;
                        let [key, ...valueParts] = line.split('=');
                        key = key.trim();
                        let value = valueParts.join('=').trim();
                        if (key) result[key] = value;
                    }
                }
            } catch (e) { global.logError("Error reading fade-monitors config: " + e); }
            callback(result);
        });
    }

    /* ---------------- Helpers ---------------- */

    _refreshMenuLabels() {
        this.mouseToggleSwitch.setToggleState(this._mouseDimmingEnabled);
        this.idleToggleSwitch.setToggleState(this._idleDimmingEnabled);
        let running = this._isScriptRunning();
        this.statusItem.label.text = running ? "Status: Running" : "Status: Stopped";
    }

    _isScriptRunning() {
        try {
            let [ok, stdout] = GLib.spawn_sync(null, ["pgrep", "-f", SCRIPT_NAME + "$"], null, GLib.SpawnFlags.SEARCH_PATH, null);
            return ok && stdout.toString().trim().length > 0;
        } catch (e) { return false; }
    }

    _showError(message) { Main.notifyError("Fade Monitors Error", message); }

    _isMouseDimmingEnabled() { return GLib.file_test(MOUSE_TOGGLE_FILE, GLib.FileTest.EXISTS); }
    _isIdleDimmingEnabled()  { return !GLib.file_test(IDLE_TOGGLE_FILE, GLib.FileTest.EXISTS); }

    _startScript() {
        try { GLib.unlink(STOP_FILE); } catch (e) {}
        if (!GLib.file_test(SCRIPT_PATH, GLib.FileTest.EXISTS)) { this._showMissingScriptMessage(); return; }
        try {
            GLib.spawn_async(HOME, ["bash", SCRIPT_PATH], null, GLib.SpawnFlags.SEARCH_PATH | GLib.SpawnFlags.DO_NOT_REAP_CHILD, null);
        } catch (e) { this._showError("Failed to start script: " + e.message); }
    }

    _stopScript() {
        try { GLib.file_set_contents(STOP_FILE, ""); } catch (e) {}
        try { GLib.spawn_async(null, ["pkill", "-f", SCRIPT_NAME + "$"], null, GLib.SpawnFlags.SEARCH_PATH, null); } catch (e) {}
    }

    _showMissingScriptMessage() {
        let message = "Missing Fade Monitors script\n\nGet it from:\n" + GITHUB_URL;
        Main.notify("Script Not Found", message);
        try {
            let Clipboard = St.Clipboard.get_default();
            Clipboard.set_text(St.ClipboardType.CLIPBOARD, GITHUB_URL);
        } catch (e) {}
    }
}

function main(metadata, orientation, panelHeight, instanceId) {
    return new FadeMonitorsApplet(metadata, orientation, panelHeight, instanceId);
}
