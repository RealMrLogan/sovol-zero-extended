#!/usr/bin/env python3
"""The config page's server (release/zero-config/server.py) run against a fake home: the cross-site refusal,
input validation, refusing changes while an install runs, and what it writes to zero-config.log. Nothing
answers as Moonraker, so Klipper reads as down and every change that needs it is refused. A fake systemctl
reports an install as running while the file INSTALLING exists."""
import http.client, json, os, socket, subprocess, sys, tempfile, time

ZC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "release", "zero-config")
home = tempfile.TemporaryDirectory()
LOG = os.path.join(home.name, "printer_data", "logs", "zero-config.log")
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
SAME = {"Origin": "http://127.0.0.1:%d" % port, "Content-Type": "application/json"}   # the page itself
BIN, INSTALLING = os.path.join(home.name, "bin"), os.path.join(home.name, "installing")
os.makedirs(BIN)
with open(os.path.join(BIN, "systemctl"), "w") as f:
    f.write("#!/bin/sh\n[ -e %s ] && echo ActiveState=active || echo ActiveState=inactive\n" % INSTALLING)
os.chmod(os.path.join(BIN, "systemctl"), 0o755)


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
                       env=dict(os.environ, HOME=home.name, PATH=BIN + os.pathsep + os.environ["PATH"]), stderr=subprocess.DEVNULL)
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

    open(INSTALLING, "w").close()
    status, body = req("POST", "/api/settings/motor-current", quiet)
    check("setting refused during an install", (status, json.loads(body)["error"]), (409, "not now: an install is running"))
    check("refusal not logged as a change", "setting motor-current" in log(), False)
    os.remove(INSTALLING)

    status, body = req("POST", "/api/settings/motor-current", quiet)
    check("setting refused while Klipper is down", (status, json.loads(body)["error"]), (500, "not now: Klipper is not ready"))
    check("setting change logged", "INFO setting motor-current: stock -> quiet" in log(), True)
    check("failure logged with traceback", "ERROR setting motor-current: failed\nTraceback" in log(), True)
    check("tuning left alone", os.path.exists(os.path.join(home.name, "zero-extended", "tuning.json")), False)
finally:
    srv.terminate()
    srv.wait()
print("server-test ok")
