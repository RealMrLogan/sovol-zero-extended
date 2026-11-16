#!/usr/bin/env python3
# sovol-zero-extended config page backend. Runs on the printer as the sovol user, on localhost only;
# nginx serves it at /extended/ after Moonraker's /access/user check (same trust as Mainsail).
import json, os, re, subprocess, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from settings import SETTINGS
from updates import MAX_UPLOAD, install_args, save_upload, start_install, status, update_status

HERE = os.path.dirname(os.path.abspath(__file__))


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
