#!/usr/bin/env python3
# sovol-zero-extended config page backend. Runs on the printer as the sovol user, on localhost only;
# nginx serves it at /extended/ after Moonraker's /access/user check (same trust as Mainsail).
import json, os, pwd, re, shutil, subprocess, sys, time, zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.dirname(HERE)                     # ~/zero-extended
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


# Each setting: label, choices (value -> label), get(), set(value). New options are new entries here.
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


def status():
    try:
        manifest = json.load(open(os.path.join(STATE, "manifest.json")))
    except OSError:
        manifest = {}
    return {"version": manifest.get("version", "unknown"),
            "boards": {b: v.get("version") for b, v in manifest.get("boards", {}).items()}}


# --- updates: upload a release zip, then run its install.sh as a transient systemd unit, so the install
# survives this server being restarted by the release it installs
INCOMING = os.path.join(STATE, "incoming")
UPLOAD = os.path.join(INCOMING, "upload.zip")
PENDING = os.path.join(INCOMING, "pending.json")        # what's in upload.zip, once checked
LOG_START = os.path.join(INCOMING, "install.logstart")  # install.log size when the last install started
INSTALL_LOG = os.path.join(STATE, "install.log")
UNIT = "zero-install"
MAX_UPLOAD = 256 << 20


def check_release(path):
    """(folder, manifest) of a release zip; raises ValueError if it doesn't look like one."""
    try:
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            tops = {n.split("/", 1)[0] for n in names}
            top = tops.pop() if len(tops) == 1 else ""
            if not re.fullmatch(r"sovol-zero-extended-v[0-9A-Za-z.-]+", top):
                raise ValueError("not a sovol-zero-extended release zip")
            if any(n.startswith("/") or ".." in n.split("/") for n in names):
                raise ValueError("the zip contains unsafe paths")
            for f in ("install.sh", "manifest.json", "SHA256SUMS"):
                if "%s/%s" % (top, f) not in names:
                    raise ValueError("the release has no %s" % f)
            manifest = json.loads(z.read(top + "/manifest.json"))
    except (zipfile.BadZipFile, KeyError, json.JSONDecodeError) as e:
        raise ValueError("not a valid release zip (%s)" % e)
    if manifest.get("name") != "sovol-zero-extended":
        raise ValueError("not a sovol-zero-extended release")
    return top, manifest


def install_state():
    out = subprocess.run(["systemctl", "show", UNIT, "-p", "ActiveState", "-p", "Result"],
                         capture_output=True, text=True).stdout
    props = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)   # --value ignores -p order
    return props.get("ActiveState") in ("active", "activating", "deactivating"), props.get("Result", "")


def update_status():
    running, result = install_state()
    log = ""
    if os.path.exists(LOG_START):
        with open(INSTALL_LOG, "rb") as f:
            f.seek(int(open(LOG_START).read()))
            log = f.read().decode(errors="replace")
    pending = json.load(open(PENDING)) if os.path.exists(PENDING) else None
    # a finished, successful transient unit is unloaded, so "success" also covers "never ran"
    return {"pending": pending, "running": running, "log": log,
            "result": None if running or not log else ("success" if result in ("success", "") else "failed")}


def save_upload(rfile, length):
    if install_state()[0]:
        raise RuntimeError("an install is running")
    os.makedirs(INCOMING, exist_ok=True)
    part = UPLOAD + ".part"
    with open(part, "wb") as f:
        while length > 0:
            chunk = rfile.read(min(length, 1 << 20))
            if not chunk:
                raise ValueError("upload interrupted")
            f.write(chunk)
            length -= len(chunk)
    try:
        top, manifest = check_release(part)
    except ValueError:
        os.remove(part)
        raise
    os.replace(part, UPLOAD)
    pending = {"folder": top, "version": manifest.get("version"), "commit": manifest.get("commit", "")[:7]}
    json.dump(pending, open(PENDING, "w"))
    return pending


def install_args(args):
    """install.sh options a client may pass; anything else is refused (trust boundary)."""
    out = []
    while args:
        a = args.pop(0)
        if a == "--no-flash":
            out.append(a)
        elif a == "--force-flash" and args and args[0] in ("toolhead", "mainboard"):
            out += [a, args.pop(0)]
        else:
            raise ValueError("unsupported install option: %r" % a)
    return out


def start_install(args=()):
    if install_state()[0]:
        raise RuntimeError("an install is already running")
    if not os.path.exists(PENDING):
        raise RuntimeError("upload a release first")
    top = json.load(open(PENDING))["folder"]
    for name in os.listdir(INCOMING):          # unpacked releases from earlier installs
        if os.path.isdir(os.path.join(INCOMING, name)):
            shutil.rmtree(os.path.join(INCOMING, name))
    subprocess.run(["unzip", "-q", UPLOAD, "-d", INCOMING], check=True)   # unzip keeps the scripts executable
    with open(LOG_START, "w") as f:
        f.write(str(os.path.getsize(INSTALL_LOG) if os.path.exists(INSTALL_LOG) else 0))
    subprocess.run(["sudo", "-n", "systemctl", "reset-failed", UNIT], stderr=subprocess.DEVNULL)
    subprocess.run(["sudo", "-n", "systemd-run", "--quiet", "--unit", UNIT,
                    "--uid", pwd.getpwuid(os.getuid()).pw_name,
                    os.path.join(INCOMING, top, "install.sh"), *args], check=True)
    os.remove(PENDING)


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self.send(200, open(os.path.join(HERE, "index.html"), "rb").read(), "text/html; charset=utf-8")
        elif self.path == "/api/settings":
            out = {}
            for key, s in SETTINGS.items():
                try:
                    value, error = s["get"](), None
                except Exception as e:
                    value, error = None, str(e)
                out[key] = {"label": s["label"], "help": s["help"], "choices": s["choices"],
                            "value": value, "error": error}
            self.send(200, {"status": status(), "settings": out})
        elif self.path == "/api/update":
            self.send(200, update_status())
        else:
            self.send(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/api/update/upload":
            length = int(self.headers.get("Content-Length") or 0)
            if not 0 < length <= MAX_UPLOAD:
                return self.send(413 if length else 411, {"error": "upload a release zip (max 256 MB)"})
            try:
                return self.send(200, save_upload(self.rfile, length))
            except ValueError as e:
                return self.send(400, {"error": str(e)})
            except RuntimeError as e:
                return self.send(409, {"error": str(e)})
        if self.path == "/api/update/install":
            try:
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                args = json.loads(body).get("args", []) if body else []
                if not isinstance(args, list):
                    raise ValueError("args must be a list")
                start_install(install_args(list(args)))
            except (ValueError, AttributeError) as e:
                return self.send(400, {"error": str(e)})
            except RuntimeError as e:
                return self.send(409, {"error": str(e)})
            except (OSError, subprocess.CalledProcessError) as e:
                return self.send(500, {"error": str(e)})
            return self.send(200, update_status())
        m = re.fullmatch(r"/api/settings/([a-z-]+)", self.path)
        s = SETTINGS.get(m.group(1)) if m else None
        if not s:
            return self.send(404, {"error": "no such setting"})
        try:
            value = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))["value"]
        except (ValueError, KeyError, TypeError):
            return self.send(400, {"error": "expected {\"value\": ...}"})
        if value not in s["choices"]:            # trust boundary: only known values reach set()
            return self.send(400, {"error": "invalid value"})
        try:
            s["set"](value)
        except Exception as e:
            return self.send(500, {"error": str(e)})
        self.send(200, {"value": s["get"]()})

    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 7130
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
