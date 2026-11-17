# zero-extended.cfg: the Klipper settings this firmware owns, written from tuning.json by the config page and
# by install.sh. It's included at the end of printer.cfg, so it overrides Sovol's values, and lives in its own
# folder, so the display's factory reset (which copies ~/patch/config/*.cfg) leaves it alone.
# It must never set an option SAVE_CONFIG writes (input shaper type/freq, PID, eddy calibration): Klipper
# refuses to save over an included value, which would break every calibration.
import json, os, re, sys

CONFIG = os.path.expanduser("~/printer_data/config")
OURS = os.path.join(CONFIG, "zero-extended", "zero-extended.cfg")
INCLUDE = "[include zero-extended/*.cfg]"   # a glob, so a missing file isn't an error
TUNING = os.path.expanduser("~/zero-extended/tuning.json")
AUTOSAVE_HEADER = "#*# <---------------------- SAVE_CONFIG ---------------------->"

REDUCED_CURRENTS = {"quiet": ("Quiet", 2.5), "low": ("Low", 1.5)}   # A, X and Y (Sovol: 3.5 A on the TMC5160s)
FALLBACK_ACCEL = 10000   # "auto" before input shaping has been measured
PRINTER_CFG = os.path.join(CONFIG, "printer.cfg")
RESONANCE_MAX_FREQ = 133   # Hz: the top of the resonance test (Klipper's default)
FIXED_CAPS = {"15k": 15000, "10k": 10000}   # keys aren't numbers: the page's JavaScript sorts those first
DEFAULTS = {"motor_current": "stock", "max_accel": "stock", "auto_accel": None}

BASE = """\
# Managed by Sovol Zero Extended (/extended/ in the browser). Changes here are overwritten.

# Sovol tests 35-45 Hz only, and SHAPER_CALIBRATE can't recommend a frequency it didn't test
[resonance_tester]
min_freq: 5
max_freq: %d

# Sovol: 0.001, an undamped frame; 0.1 is Klipper's default and closer to a real one
[input_shaper]
damping_ratio_x: 0.1
damping_ratio_y: 0.1

# The Zero's eddy sensor reads about 6.03 MHz, over Klipper's 5 MHz default, from which Klipper sets the
# LDC1612's clock divider (Sovol's Klipper had a fixed one)
[probe_eddy_current eddy]
max_sensor_hz: 6500000
""" % RESONANCE_MAX_FREQ

# Klipper takes any acceleration a file asks for; these cap it. The resonance test sets its own
# acceleration directly, not through these commands, so calibration isn't capped.
ACCEL_CAP = """
[printer]
max_accel: {cap}

[gcode_macro SET_VELOCITY_LIMIT]
rename_existing: _ZX_SET_VELOCITY_LIMIT
gcode:
    _ZX_SET_VELOCITY_LIMIT {{% for k, v in params.items() %}} {{k}}={{ [v|float, {cap}]|min if k == "ACCEL" else v }}{{% endfor %}}

[gcode_macro M204]
rename_existing: M204.1
gcode:
    {{% set accel = params.S|default(0)|float %}}
    {{% if not accel and "P" in params and "T" in params %}}{{% set accel = [params.P|float, params.T|float]|min %}}{{% endif %}}
    {{% if accel %}}M204.1 S{{ [accel, {cap}]|min }}{{% endif %}}
"""


def stock_current():
    """X's run_current in printer.cfg itself (what "Stock" leaves in place), or None."""
    try:
        text = open(PRINTER_CFG).read().split(AUTOSAVE_HEADER)[0]
    except OSError:
        return None
    m = re.search(r"^\[tmc\w+ stepper_x\][^\[]*?^run_current\s*[:=]\s*([\d.]+)", text, re.M)
    return float(m.group(1)) if m else None


def current_choices():
    stock = stock_current()
    return {"stock": "Stock (%g A)" % stock if stock else "Stock",
            **{k: "%s (%g A)" % (label, amps) for k, (label, amps) in REDUCED_CURRENTS.items()}}


def accel_choices():
    auto = load()["auto_accel"]
    return {"stock": "No limit",
            "auto": "From input shaping (%s)" % ("{:,} mm/s²".format(auto) if auto else
                                                 "not measured yet: {:,} mm/s²".format(FALLBACK_ACCEL)),
            **{k: "{:,} mm/s²".format(v) for k, v in FIXED_CAPS.items()}}


def load():
    try:
        with open(TUNING) as f:
            return {**DEFAULTS, **json.load(f)}
    except (OSError, ValueError):
        return dict(DEFAULTS)


def save(tuning):
    os.makedirs(os.path.dirname(TUNING), exist_ok=True)
    with open(TUNING + ".tmp", "w") as f:
        json.dump(tuning, f)
    os.replace(TUNING + ".tmp", TUNING)


def accel_cap(tuning):
    if tuning["max_accel"] == "stock":
        return None
    if tuning["max_accel"] == "auto":
        return tuning["auto_accel"] or FALLBACK_ACCEL
    return FIXED_CAPS[tuning["max_accel"]]


def render(tuning):
    out = BASE
    if tuning["motor_current"] in REDUCED_CURRENTS:
        for axis in "xy":
            out += "\n[tmc5160 stepper_%s]\nrun_current: %.1f\n" % (axis, REDUCED_CURRENTS[tuning["motor_current"]][1])
    cap = accel_cap(tuning)
    if cap:
        out += ACCEL_CAP.format(cap=int(cap))
    return out


def write(tuning):
    """Write zero-extended.cfg; True if it changed (Klipper needs a restart to use it)."""
    text = render(tuning)
    try:
        if open(OURS).read() == text:
            return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(OURS), exist_ok=True)
    with open(OURS + ".tmp", "w") as f:
        f.write(text)
    os.replace(OURS + ".tmp", OURS)
    return True


def add_include(path):
    """Include our file at the end of a printer.cfg's own settings (after Sovol's, before SAVE_CONFIG's
    block) so it wins. True if the file changed."""
    text = open(path, newline="").read()
    if INCLUDE in text:
        return False
    nl = "\r\n" if "\r\n" in text else "\n"
    pos = text.find(AUTOSAVE_HEADER)
    body, rest = (text, "") if pos < 0 else (text[:pos], text[pos:])
    body = body.rstrip() + nl + nl + INCLUDE + nl + (nl if rest else "")
    with open(path, "w", newline="") as f:
        f.write(body + rest)
    return True


if __name__ == "__main__":
    if sys.argv[1:2] == ["install"]:   # install.sh: prints what changed; printer.cfg paths follow
        done = ["zero-extended.cfg written"] if write(load()) else []
        done += ["included from %s" % p for p in sys.argv[2:] if os.path.exists(p) and add_include(p)]
        print(", ".join(done))
        sys.exit()

    # self-check: python3 tuning.py
    import tempfile
    t = dict(DEFAULTS)
    assert "tmc5160" not in render(t) and "max_accel" not in render(t)
    t.update(motor_current="quiet", max_accel="auto", auto_accel=8300)
    r = render(t)
    assert "run_current: 2.5" in r and "max_accel: 8300" in r and "[v|float, 8300]|min" in r
    assert list(accel_choices()) == ["stock", "auto", "15k", "10k"] and "10,000 mm/s²" == accel_choices()["10k"]
    assert accel_cap(dict(t, auto_accel=None)) == FALLBACK_ACCEL and accel_cap(dict(t, max_accel="15k")) == 15000
    assert not re.search(r"shaper_(type|freq)|pid_|calibrate", r), "SAVE_CONFIG would refuse to save"
    with tempfile.TemporaryDirectory() as d:
        PRINTER_CFG = os.path.join(d, "stock.cfg")
        open(PRINTER_CFG, "w").write("[tmc5160 stepper_x]\ncs_pin: PE0\nrun_current: 3.5\n[tmc5160 stepper_y]\nrun_current: 9\n")
        assert stock_current() == 3.5 and current_choices() == {"stock": "Stock (3.5 A)", "quiet": "Quiet (2.5 A)", "low": "Low (1.5 A)"}
        assert "run_current: 1.5" in render(dict(DEFAULTS, motor_current="low"))
        p = os.path.join(d, "printer.cfg")
        open(p, "w", newline="").write("[printer]\r\nmax_accel: 40000\r\n\r\n%s\r\n#*# [input_shaper]\r\n" % AUTOSAVE_HEADER)
        assert add_include(p) and not add_include(p)
        s = open(p, newline="").read()
        assert s.index(INCLUDE) < s.index(AUTOSAVE_HEADER) and "\n" not in s.replace("\r\n", "")
        p2 = os.path.join(d, "plain.cfg")
        open(p2, "w").write("[printer]\n")
        add_include(p2)
        assert open(p2).read() == "[printer]\n\n%s\n" % INCLUDE
    print("ok")
