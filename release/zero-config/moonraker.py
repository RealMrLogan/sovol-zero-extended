# Moonraker client for the config page: Klipper status, G-code and restarts over its local HTTP API
# (localhost is a trusted client, so no API key).
import json, time, urllib.error, urllib.parse, urllib.request

URL = "http://127.0.0.1:7125"


def _call(path, body=None, timeout=10):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(URL + path, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)["result"]
    except urllib.error.HTTPError as e:   # Klipper's error message, e.g. "Must home axis first"
        try:
            msg = json.load(e)["error"]["message"]
        except (ValueError, KeyError, TypeError):
            msg = str(e)
        raise RuntimeError(msg) from None
    except urllib.error.URLError as e:
        raise RuntimeError("Moonraker unreachable: %s" % e.reason) from None


def query(*objects):
    """Status of Klipper objects; "name=field1,field2" limits a large object to some fields."""
    return _call("/printer/objects/query?" + "&".join(urllib.parse.quote(o, safe="=,") for o in objects))["status"]


def gcode(script, timeout=1800):
    """Run G-code and wait for it to finish (a calibration can take many minutes)."""
    _call("/printer/gcode/script", {"script": script}, timeout)


def responses_since(t):
    """Klipper's console replies since time t, oldest first."""
    store = _call("/server/gcode_store?count=1000")["gcode_store"]
    return [e["message"] for e in store if e["time"] >= t and e["type"] == "response"]


def ready():
    try:
        return query("webhooks")["webhooks"]["state"] == "ready"
    except RuntimeError:
        return False


def busy():
    """Why Klipper can't be used for a calibration or restart right now, or None."""
    if not ready():
        return "Klipper is not ready"
    if query("print_stats")["print_stats"]["state"] in ("printing", "paused"):
        return "a print is running"
    return None


def wait_ready(timeout=90):
    deadline = time.time() + timeout
    time.sleep(2)   # let a requested restart begin first
    while time.time() < deadline:
        if ready():
            return
        time.sleep(1)
    raise RuntimeError("Klipper did not come back within %d s" % timeout)


def restart():
    try:
        _call("/printer/restart", {})
    except RuntimeError:
        pass   # the connection can drop as Klipper restarts
    wait_ready()


def pending_saves():
    """Sections a SAVE_CONFIG would write now (calibration results not yet saved)."""
    return set(query("configfile=save_config_pending_items")["configfile"].get("save_config_pending_items") or {})


def save_config():
    try:
        gcode("SAVE_CONFIG", timeout=30)
    except RuntimeError as e:
        if "restart" not in str(e).lower() and "disconnect" not in str(e).lower():
            raise
    wait_ready()
