#!/usr/bin/env python3
"""The config page's server (release/zero-config/server.py) run against a fake home: the cross-site refusal,
input validation, and what it writes to zero-config.log. Nothing answers as Moonraker, so Klipper reads as
down and every change that needs it is refused."""
import http.client, json, os, socket, subprocess, sys, tempfile, time

ZC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "release", "zero-config")
home = tempfile.TemporaryDirectory()
LOG = os.path.join(home.name, "printer_data", "logs", "zero-config.log")
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
SAME = {"Origin": "http://127.0.0.1:%d" % port, "Content-Type": "application/json"}   # the page itself


def req(method, path, body=None, headers=SAME):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    c.request(method, path, body=body, headers=headers)
    r = c.getresponse()
    return r.status, r.read()


def log():
    with open(LOG) as f:
        return f.read()


def check(name, got, want):
    assert got == want, "%s: got %r, want %r" % (name, got, want)
    print("ok", name)


srv = subprocess.Popen([sys.executable, "-B", "server.py", str(port)], cwd=ZC,
                       env=dict(os.environ, HOME=home.name), stderr=subprocess.DEVNULL)
try:
    for _ in range(100):
        try:
            status, page = req("GET", "/")
            break
        except OSError:
            time.sleep(0.1)
    check("page served", (status, page.startswith(b"<!doctype html>")), (200, True))
    check("started logged", "started on port %d" % port in log(), True)

    quiet = json.dumps({"value": "quiet"})
    status, _ = req("POST", "/api/settings/motor-current", quiet, dict(SAME, Origin="http://evil.example"))
    check("cross-site POST refused", status, 403)
    status, _ = req("POST", "/api/update/install", "{}", dict(SAME, Origin="http://evil.example"))
    check("cross-site install refused", status, 403)
    check("refusals change nothing", "setting" in log() or "install:" in log(), False)

    check("unknown value", req("POST", "/api/settings/motor-current", json.dumps({"value": "turbo"}))[0], 400)
    check("not JSON", req("POST", "/api/settings/motor-current", "x")[0], 400)
    check("bad PID target", req("POST", "/api/calibration/pid-bed", json.dumps({"target": 300}))[0], 400)
    check("empty upload", req("POST", "/api/update/upload", b"")[0], 411)
    check("unknown path", req("POST", "/api/nope", "{}")[0], 404)

    status, body = req("POST", "/api/settings/motor-current", quiet)
    check("setting refused while Klipper is down", (status, json.loads(body)["error"]), (500, "not now: Klipper is not ready"))
    check("setting change logged", "INFO setting motor-current: stock -> quiet" in log(), True)
    check("failure logged with traceback", "ERROR setting motor-current: failed\nTraceback" in log(), True)
    check("tuning left alone", os.path.exists(os.path.join(home.name, "zero-extended", "tuning.json")), False)
finally:
    srv.terminate()
    srv.wait()
print("server-test ok")
