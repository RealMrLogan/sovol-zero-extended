# Calibrations run from the config page, one at a time, in a background thread: input shaping, a CoreXY
# belt comparison and heater PID tuning. Results are saved with Klipper's own SAVE_CONFIG; Klipper is
# restarted first so nothing else that's pending (Sovol's per-print eddy calibration) gets saved with them.
import csv, json, logging, math, os, re, threading, time
import moonraker, tuning
from updates import install_state

RESULTS = os.path.expanduser("~/zero-extended/calibration.json")
log = logging.getLogger("zero-config")   # server.py writes it to zero-config.log
PART_FAN = "fan0"            # Sovol's part cooling fan ([fan_generic fan0])
SOVOL_BED_KP = 53.071        # Sovol's factory bed PID, still in printer.cfg until it's tuned
BELT_FILES = {"a": "/tmp/resonances_axis=1.000,1.000_zx_belt_a.csv", "b": "/tmp/resonances_axis=1.000,-1.000_zx_belt_b.csv"}
PID_LIMITS = {"heater_bed": (40, 110), "extruder": (170, 280)}

_lock = threading.Lock()
_job = {"name": None, "running": False, "start": 0, "error": None}


def load_results():
    try:
        with open(RESULTS) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save_result(name, result):
    results = load_results()
    results[name] = dict(result, time=int(time.time()))
    with open(RESULTS + ".tmp", "w") as f:
        json.dump(results, f)
    os.replace(RESULTS + ".tmp", RESULTS)


def _home():
    if moonraker.query("toolhead")["toolhead"]["homed_axes"] != "xyz":
        moonraker.gcode("G28")


def _clean_start():
    """Restart Klipper if something is waiting to be saved, so our SAVE_CONFIG only writes our result."""
    if moonraker.pending_saves():
        moonraker.restart()


def _save(sections):
    pending = moonraker.pending_saves()
    if not pending or not pending <= set(sections):
        raise RuntimeError("not saved: expected %s pending, found %s" % (sorted(sections), sorted(pending)))
    moonraker.save_config()


# --- input shaping ---------------------------------------------------------------------------------------

def parse_shaper(lines):
    """Klipper's SHAPER_CALIBRATE replies -> {axis: {type, freq, max_accel}}."""
    out, axis, accels = {}, None, {}
    for line in lines:
        m = re.search(r"parameters for (x|y) axis", line)
        if m:
            axis, accels = m.group(1), {}
        m = re.search(r"smoothing with '(\w+)', suggested max_accel <= (\d+)", line)
        if m:
            accels[m.group(1)] = int(m.group(2))
        m = re.search(r"Recommended shaper_type_(x|y) = (\w+), shaper_freq_\1 = ([\d.]+) Hz", line)
        if m and m.group(1) == axis:
            out[axis] = {"type": m.group(2), "freq": float(m.group(3)), "max_accel": accels.get(m.group(2))}
    return out


def run_shaper():
    _clean_start()
    _home()
    start = time.time()
    moonraker.gcode("SHAPER_CALIBRATE")
    result = parse_shaper(moonraker.responses_since(start))
    if set(result) != {"x", "y"}:
        raise RuntimeError("could not read the recommendation from Klipper's output")
    accels = [a["max_accel"] for a in result.values() if a["max_accel"]]
    if accels:   # the "From input shaping" acceleration limit
        t = tuning.load()
        t["auto_accel"] = min(accels) // 100 * 100
        tuning.save(t)
        tuning.write(t)   # used from the restart SAVE_CONFIG does
    _save(["input_shaper"])
    return result


# --- belts -----------------------------------------------------------------------------------------------

def read_psd(path):
    with open(path) as f:
        rows = [(float(r["freq"]), float(r["psd_xyz"])) for r in csv.DictReader(f)]
    return [(fr, p) for fr, p in rows if 10 <= fr <= tuning.RESONANCE_MAX_FREQ]


def peak_indexes(values, floor=0.15):
    top = max(values)
    return [i for i in range(1, len(values) - 1)
            if values[i] > values[i - 1] and values[i] >= values[i + 1] and values[i] > floor * top]


def compare_belts(a, b):
    """Two belts' resonance spectra -> peaks, similarity and a plain verdict."""
    freqs = [fr for fr, _ in a]
    pa = [p for _, p in a]
    pb = [p for _, p in b][:len(pa)]
    ma, mb = sum(pa) / len(pa), sum(pb) / len(pb)
    cov = sum((x - ma) * (y - mb) for x, y in zip(pa, pb))
    sim = cov / math.sqrt(sum((x - ma) ** 2 for x in pa) * sum((y - mb) ** 2 for y in pb))
    top = max(max(pa), max(pb))
    na, nb = [p / top for p in pa], [p / top for p in pb]
    main_a, main_b = freqs[na.index(max(na))], freqs[nb.index(max(nb))]
    # a peak much stronger on one belt (or only on it) points at that belt's path, not its tension
    uneven = [("A", freqs[i]) for i in peak_indexes(na) if na[i] > 0.3 and nb[i] < 0.5 * na[i]]
    uneven += [("B", freqs[i]) for i in peak_indexes(nb) if nb[i] > 0.3 and na[i] < 0.5 * nb[i]]
    if abs(main_a - main_b) > 3:
        looser = "A" if main_a < main_b else "B"
        verdict = "Belt tension differs: belt %s's main peak is lower (%.0f vs %.0f Hz), so it's looser." % (
            looser, min(main_a, main_b), max(main_a, main_b))
    else:
        verdict = "Belt tension is matched (main peaks %.0f and %.0f Hz)." % (main_a, main_b)
    if uneven:
        verdict += " A peak much stronger on one belt (%s) usually means something mechanical in that " \
                   "belt's path: an idler, pulley, loose screw or rough bearing." % ", ".join(
                       "belt %s at %.0f Hz" % u for u in uneven)
    return {"verdict": verdict, "similarity": round(sim, 2),
            "freq": freqs, "a": [round(p, 3) for p in na], "b": [round(p, 3) for p in nb]}


def run_belts():
    for path in BELT_FILES.values():   # an earlier run's files must not be read as this one's
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
    _home()
    for belt, axis in (("a", "1,1"), ("b", "1,-1")):
        moonraker.gcode("TEST_RESONANCES AXIS=%s NAME=zx_belt_%s" % (axis, belt))
    return compare_belts(read_psd(BELT_FILES["a"]), read_psd(BELT_FILES["b"]))


# --- heaters ---------------------------------------------------------------------------------------------

def parse_pid(lines):
    for line in lines:
        m = re.search(r"pid_Kp=([\d.]+) pid_Ki=([\d.]+) pid_Kd=([\d.]+)", line)
        if m:
            return {"kp": float(m.group(1)), "ki": float(m.group(2)), "kd": float(m.group(3))}
    raise RuntimeError("could not read the PID result from Klipper's output")


def run_pid(heater, target):
    _clean_start()
    start = time.time()
    fan = heater == "extruder"   # tune the nozzle the way it prints: with the part fan on
    try:
        if fan:
            moonraker.gcode("SET_FAN_SPEED FAN=%s SPEED=0.6" % PART_FAN)
        moonraker.gcode("PID_CALIBRATE HEATER=%s TARGET=%d" % (heater, target))
    finally:
        if fan:
            moonraker.gcode("SET_FAN_SPEED FAN=%s SPEED=0" % PART_FAN)
        moonraker.gcode("TURN_OFF_HEATERS")
    result = dict(parse_pid(moonraker.responses_since(start)), target=target)
    _save([heater])
    return result


JOBS = {   # name: (label, function, heater for a PID job)
    "shaper": ("Input shaping", run_shaper, None),
    "belts": ("Belt check", run_belts, None),
    "pid-bed": ("Bed heater PID tuning", None, "heater_bed"),
    "pid-nozzle": ("Nozzle heater PID tuning", None, "extruder"),
}


def start(name, target=None):
    label, fn, heater = JOBS[name]
    if heater:
        lo, hi = PID_LIMITS[heater]
        if not isinstance(target, int) or not lo <= target <= hi:   # trust boundary: it heats things
            raise ValueError("target must be a whole number from %d to %d" % (lo, hi))
    with _lock:
        if _job["running"]:
            raise RuntimeError("%s is already running" % JOBS[_job["name"]][0])
        if install_state()[0]:
            raise RuntimeError("an install is running")
        reason = moonraker.busy()
        if reason:
            raise RuntimeError(reason)
        _job.update(name=name, running=True, start=time.time(), error=None)
    log.info("calibration %s: started%s", name, " at %d C" % target if heater else "")
    threading.Thread(target=_run, args=(name, fn, heater, target), daemon=True).start()


def running():
    """The running calibration's label, or None."""
    return JOBS[_job["name"]][0] if _job["running"] else None


def _run(name, fn, heater, target):
    try:
        result = run_pid(heater, target) if heater else fn()
        _save_result(name, result)
        log.info("calibration %s: done, %s", name, {k: v for k, v in result.items() if not isinstance(v, list)})
    except Exception as e:   # shown on the page; the thread must always clear "running"
        _job["error"] = str(e)
        log.exception("calibration %s: failed", name)
    finally:
        _job["running"] = False


def checks():
    """Problems worth fixing, as (level, text): what Sovol's defaults leave behind."""
    try:
        config = moonraker.query("configfile=settings")["configfile"]["settings"]
    except RuntimeError as e:
        return [("err", "Can't read Klipper's settings: %s" % e)]
    out = []
    shaper = config.get("input_shaper", {})
    if not shaper.get("shaper_freq_x") or not shaper.get("shaper_freq_y"):
        out.append(("err", "Input shaping is off: printing at high acceleration rings and is loud. Run Input shaping."))
    if config.get("resonance_tester", {}).get("max_freq", tuning.RESONANCE_MAX_FREQ) < 100:
        out.append(("warn", "The resonance test is limited to %g Hz; reinstall this release to fix it."
                    % config["resonance_tester"]["max_freq"]))
    if config.get("heater_bed", {}).get("pid_kp") == SOVOL_BED_KP:
        out.append(("warn", "The bed heater still uses Sovol's factory tuning. Run Bed heater PID tuning."))
    if not out:
        out.append(("ok", "No problems found."))
    return out


def status():
    job = dict(_job, label=JOBS[_job["name"]][0] if _job["name"] else None)
    try:
        console = moonraker.responses_since(_job["start"])[-12:] if _job["running"] else []
    except RuntimeError:   # Klipper restarting mid-job
        console = []
    return {"job": job, "log": console, "results": load_results(), "checks": checks()}


if __name__ == "__main__":   # self-check: python3 calibration.py
    logging.disable()   # the failure cases below log tracebacks on purpose
    out = parse_shaper([
        "Calculating the best input shaper parameters for x axis",
        "Fitted shaper 'mzv' frequency = 72.8 Hz (vibrations = 2.6%, smoothing ~= 0.040)",
        "To avoid too much smoothing with 'mzv', suggested max_accel <= 15600 mm/sec^2",
        "To avoid too much smoothing with 'ei', suggested max_accel <= 11500 mm/sec^2",
        "Recommended shaper_type_x = mzv, shaper_freq_x = 72.8 Hz",
        "Calculating the best input shaper parameters for y axis",
        "To avoid too much smoothing with 'mzv', suggested max_accel <= 8300 mm/sec^2",
        "Recommended shaper_type_y = mzv, shaper_freq_y = 53.2 Hz"])
    assert out == {"x": {"type": "mzv", "freq": 72.8, "max_accel": 15600},
                   "y": {"type": "mzv", "freq": 53.2, "max_accel": 8300}}, out
    assert parse_pid(["PID parameters: pid_Kp=22.2 pid_Ki=1.08 pid_Kd=114\nThe SAVE_CONFIG"]) == {"kp": 22.2, "ki": 1.08, "kd": 114}

    def spectrum(*peaks):   # (centre, width, height) resonance peaks on Klipper's 1.5 Hz grid
        return [(f, sum(h / (1 + ((f - c) / w) ** 2) for c, w, h in peaks)) for f in (i * 1.5 for i in range(7, 89))]
    same = compare_belts(spectrum((52, 2, 1), (71, 3, .5)), spectrum((51, 2, 1), (71, 3, .45)))
    assert same["verdict"].startswith("Belt tension is matched") and "stronger" not in same["verdict"], same["verdict"]
    loose = compare_belts(spectrum((45, 2, 1)), spectrum((55, 2, 1)))
    assert "belt A's main peak is lower" in loose["verdict"], loose["verdict"]
    odd = compare_belts(spectrum((52, 2, 1), (71, 3, .7)), spectrum((52, 2, 1), (71, 3, .2)))
    assert "belt A at 70 Hz" in odd["verdict"] or "belt A at 72 Hz" in odd["verdict"], odd["verdict"]

    # the job flow against a fake Moonraker: what it sends, and what it saves
    import tempfile
    tmp = tempfile.TemporaryDirectory()
    RESULTS = os.path.join(tmp.name, "calibration.json")
    tuning.TUNING, tuning.OURS = os.path.join(tmp.name, "tuning.json"), os.path.join(tmp.name, "zx.cfg")

    class Fake:
        def __init__(self, pending=(), replies=(), fail=None, busy=None, also=()):   # also: sections a calibration adds
            self.sent, self.pending, self.replies, self.fail, self.why = [], set(pending), list(replies), fail, busy
            self.also = set(also)

        def gcode(self, script, timeout=0):
            self.sent.append(script)
            if self.fail and script.startswith(self.fail):
                raise RuntimeError("Klipper says no")
            if script.startswith(("PID_CALIBRATE HEATER=", "SHAPER_CALIBRATE")):
                self.pending |= {script.split("=")[1].split()[0]} if "HEATER" in script else {"input_shaper"}
                self.pending |= self.also

        def restart(self):
            self.sent.append("restart")
            self.pending = set()

        def save_config(self):
            self.sent.append("SAVE_CONFIG")

        def install(self):
            for name in ("gcode", "restart", "save_config"):
                setattr(moonraker, name, getattr(self, name))
            moonraker.pending_saves = lambda: set(self.pending)
            moonraker.responses_since = lambda t: self.replies
            moonraker.query = lambda *o: {"toolhead": {"homed_axes": ""}}
            moonraker.busy = lambda: self.why
            return self

    pid = "PID parameters: pid_Kp=32.678 pid_Ki=3.890 pid_Kd=68.619"
    # an unrelated pending save (Sovol's eddy calibration) is cleared first, so only ours is saved
    m = Fake(pending={"probe_eddy_current"}, replies=[pid]).install()
    assert run_pid("extruder", 220) == {"kp": 32.678, "ki": 3.89, "kd": 68.619, "target": 220}
    assert m.sent == ["restart", "SET_FAN_SPEED FAN=fan0 SPEED=0.6", "PID_CALIBRATE HEATER=extruder TARGET=220",
                      "SET_FAN_SPEED FAN=fan0 SPEED=0", "TURN_OFF_HEATERS", "SAVE_CONFIG"], m.sent
    # a failed calibration still turns the fan and heaters off, and saves nothing
    m = Fake(fail="PID_CALIBRATE").install()
    try:
        run_pid("extruder", 220)
        raise AssertionError("no error")
    except RuntimeError:
        pass
    assert m.sent[-2:] == ["SET_FAN_SPEED FAN=fan0 SPEED=0", "TURN_OFF_HEATERS"] and "SAVE_CONFIG" not in m.sent
    # something else pending at save time: refuse rather than save it too
    m = Fake(replies=[pid], also={"bed_mesh"}).install()
    try:
        run_pid("heater_bed", 60)
        raise AssertionError("saved an unexpected section")
    except RuntimeError as e:
        assert "bed_mesh" in str(e) and "SAVE_CONFIG" not in m.sent, e
    # input shaping: homes, saves, and sets the "From input shaping" acceleration from the softer axis
    m = Fake(replies=["Calculating the best input shaper parameters for x axis",
                      "To avoid too much smoothing with 'mzv', suggested max_accel <= 15400 mm/sec^2",
                      "Recommended shaper_type_x = mzv, shaper_freq_x = 72.4 Hz",
                      "Calculating the best input shaper parameters for y axis",
                      "To avoid too much smoothing with 'mzv', suggested max_accel <= 8345 mm/sec^2",
                      "Recommended shaper_type_y = mzv, shaper_freq_y = 53.0 Hz"]).install()
    run_shaper()
    assert m.sent == ["G28", "SHAPER_CALIBRATE", "SAVE_CONFIG"], m.sent
    assert tuning.load()["auto_accel"] == 8300
    # the belt check never reads an earlier run's files: here Klipper writes none, so it fails
    BELT_FILES = {b: os.path.join(tmp.name, "belt_%s.csv" % b) for b in "ab"}
    for path in BELT_FILES.values():
        open(path, "w").write("freq,psd_xyz\n50,1\n")
    Fake().install()
    try:
        run_belts()
        raise AssertionError("read a stale belt file")
    except FileNotFoundError:
        pass
    # start(): the target is checked before anything heats, one job at a time, never during a print
    install_state = lambda: (False, "")
    for bad in (None, "220", 22.5, 300, 100):
        try:
            start("pid-nozzle", bad)
            raise AssertionError("accepted target %r" % bad)
        except ValueError:
            pass
    Fake(busy="a print is running").install()
    try:
        start("belts")
        raise AssertionError("started during a print")
    except RuntimeError as e:
        assert "print" in str(e)
    # a job that fails reports its error and frees the slot for the next one
    m = Fake(fail="PID_CALIBRATE").install()
    start("pid-bed", 60)
    for _ in range(100):
        if not _job["running"]:
            break
        time.sleep(0.01)
    assert not _job["running"] and _job["error"] == "Klipper says no", _job
    assert running() is None
    _job.update(name="belts", running=True)
    assert running() == "Belt check"
    _job["running"] = False
    tmp.cleanup()
    print("ok")
