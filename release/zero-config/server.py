#!/usr/bin/env python3
# sovol-zero-extended config page backend. Runs on the printer as the sovol user, on localhost only;
# nginx serves it at /extended/ after Moonraker's /access/user check (same trust as Mainsail).
import json, logging, logging.handlers, os, re, subprocess, sys
from urllib.parse import urlsplit
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import calibration
from settings import SETTINGS, choices
from updates import MAX_UPLOAD, install_args, install_state, installed_release, save_upload, start_install, update_status

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.expanduser("~/printer_data/logs/zero-config.log")   # next to Klipper's, so Mainsail lists it
log = logging.getLogger("zero-config")


def busy():
    """Why the printer can't take a change now, or None: installs, calibrations and settings each restart
    Klipper, so only one runs at a time."""
    if install_state()[0]:
        return "an install is running"
    job = calibration.running()
    return "%s is running" % job if job else None


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
                out[key] = {"label": s["label"], "help": s["help"], "choices": choices(s),
                            "applying": s["applying"], "value": value, "error": error}
            self.send(200, {"status": installed_release(), "settings": out})
        elif self.path == "/api/update":
            self.send(200, update_status())
        elif self.path == "/api/calibration":
            self.send(200, calibration.status())
        else:
            self.send(404, {"error": "not found"})

    def body_length(self):
        try:
            return int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return -1

    def cross_site(self):
        """True for a browser request from another site. Moonraker trusts every LAN address, so without
        this any web page open on the LAN could post a release here and run its install.sh."""
        origin = self.headers.get("Origin")
        return origin is not None and urlsplit(origin).netloc != self.headers.get("Host")

    def do_POST(self):
        if self.cross_site():
            return self.send(403, {"error": "cross-site request refused"})
        if self.path == "/api/update/upload":
            return self.post_upload()
        if self.path == "/api/update/install":
            return self.post_install()
        m = re.fullmatch(r"/api/calibration/([a-z-]+)", self.path)
        if m and m.group(1) in calibration.JOBS:
            return self.post_calibration(m.group(1))
        m = re.fullmatch(r"/api/settings/([a-z-]+)", self.path)
        if m and m.group(1) in SETTINGS:
            return self.post_setting(m.group(1), SETTINGS[m.group(1)])
        self.send(404, {"error": "not found"})

    def post_upload(self):
        length = self.body_length()
        if length < 0:
            return self.send(400, {"error": "bad Content-Length"})
        if not 0 < length <= MAX_UPLOAD:
            return self.send(413 if length else 411, {"error": "upload a release zip (max %d MB)" % (MAX_UPLOAD >> 20)})
        try:
            self.send(200, save_upload(self.rfile, length))
        except ValueError as e:
            self.send(400, {"error": str(e)})
        except RuntimeError as e:
            self.send(409, {"error": str(e)})

    def post_install(self):
        try:
            body = self.rfile.read(max(self.body_length(), 0))
            args = json.loads(body).get("args", []) if body else []
            if not isinstance(args, list):
                raise ValueError("args must be a list")
            pending = update_status()["pending"] or {}
            reason = busy()
            if reason:
                raise RuntimeError(reason)
            start_install(install_args(args))
        except (ValueError, AttributeError) as e:
            return self.send(400, {"error": str(e)})
        except RuntimeError as e:
            return self.send(409, {"error": str(e)})
        except (OSError, subprocess.CalledProcessError) as e:
            log.exception("install: could not start")
            return self.send(500, {"error": str(e)})
        log.info("install: started %s %s (its log: ~/zero-extended/install.log)", pending.get("version"), " ".join(args))
        self.send(200, update_status())

    def post_calibration(self, name):
        try:
            body = self.rfile.read(max(self.body_length(), 0))
            target = json.loads(body).get("target") if body else None
            calibration.start(name, target)
        except (ValueError, AttributeError) as e:
            return self.send(400, {"error": str(e)})
        except RuntimeError as e:
            return self.send(409, {"error": str(e)})
        self.send(200, calibration.status())

    def post_setting(self, key, s):
        try:
            value = json.loads(self.rfile.read(max(self.body_length(), 0)))["value"]
        except (ValueError, KeyError, TypeError):
            return self.send(400, {"error": "expected {\"value\": ...}"})
        if not isinstance(value, str) or value not in choices(s):   # trust boundary: only known values reach set()
            return self.send(400, {"error": "invalid value"})
        reason = busy()
        if reason:
            return self.send(409, {"error": "not now: %s" % reason})
        try:
            old = s["get"]()
        except Exception:
            old = "unknown"
        log.info("setting %s: %s -> %s", key, old, value)
        try:
            s["set"](value)
            self.send(200, {"value": s["get"]()})
        except Exception as e:
            log.exception("setting %s: failed", key)
            self.send(500, {"error": str(e)})

    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 7130
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(LOG, maxBytes=1 << 20, backupCount=2)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logging.basicConfig(level=logging.INFO, handlers=[handler])
    log.info("started on port %d", port)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
