# Settings shown on the config page. Each one: label, help, choices (value -> label), get(), set(value);
# a new option is a new entry in SETTINGS.
import os, re, subprocess, time

XORG = "/etc/X11/xorg.conf.d/01-dbbian-defaults.conf"   # Sovol's X config: fbdev rotation + touch matrix
KS_LOG = os.path.expanduser("~/printer_data/logs/KlipperScreen.log")

# orientation as seen by someone facing the screen; Sovol ships "UD" as its landscape
ORIENTATIONS = {
    "landscape":         ("UD",     "-1 0 1 0 -1 1 0 0 1"),
    "portrait":          ("CCW",    "0 -1 1 1 0 0 0 0 1"),
    "landscape-flipped": ("normal", "1 0 0 0 1 0 0 0 1"),   # fbdev has no "normal": unknown = unrotated
    "portrait-flipped":  ("CW",     "0 1 0 -1 0 1 0 0 1"),
}
ROTATE_RE = re.compile(r'(Option\s+"Rotate"\s+")([^"]*)(")')
MATRIX_RE = re.compile(r'("CalibrationMatrix"\s+")([^"]*)(")')


def get_orientation():
    m = ROTATE_RE.search(open(XORG).read())
    rotate = m.group(2) if m else "normal"
    return next((k for k, (r, _) in ORIENTATIONS.items() if r == rotate), "landscape-flipped")


def set_orientation(value):
    rotate, matrix = ORIENTATIONS[value]
    src = open(XORG).read()
    if not ROTATE_RE.search(src) or not MATRIX_RE.search(src):
        raise RuntimeError("%s has no Rotate/CalibrationMatrix lines to change" % XORG)
    src = ROTATE_RE.sub(lambda m: m.group(1) + rotate + m.group(3), src)
    src = MATRIX_RE.sub(lambda m: m.group(1) + matrix + m.group(3), src)
    subprocess.run(["sudo", "-n", "tee", XORG], input=src.encode(), stdout=subprocess.DEVNULL, check=True)
    try:
        start = os.path.getsize(KS_LOG)
    except OSError:
        start = 0
    subprocess.run(["sudo", "-n", "systemctl", "restart", "KlipperScreen"], check=True)  # restarts X too
    w, h = wait_for_screen(start)
    if (h > w) != value.startswith("portrait"):
        raise RuntimeError("the screen came back at %dx%d" % (w, h))


def wait_for_screen(start, timeout=45):
    """Wait for KlipperScreen to log its screen size after a restart: the UI is up from then on."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(1)
        try:
            with open(KS_LOG, "rb") as f:
                f.seek(start if os.path.getsize(KS_LOG) >= start else 0)   # log rotated: read it all
                m = re.findall(rb"Screen resolution: (\d+)x(\d+)", f.read())
        except OSError:
            continue
        if m:
            return int(m[-1][0]), int(m[-1][1])
    raise RuntimeError("the screen did not come back within %d s" % timeout)


SETTINGS = {
    "orientation": {
        "label": "Screen orientation",
        "help": "Rotates the touchscreen and its touch input. The screen restarts to apply it.",
        "choices": {"landscape": "Landscape", "portrait": "Portrait",
                    "landscape-flipped": "Landscape (flipped)", "portrait-flipped": "Portrait (flipped)"},
        "get": get_orientation,
        "set": set_orientation,
    },
}


