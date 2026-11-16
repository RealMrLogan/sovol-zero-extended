# The installed release, and updates: upload a release zip, then run its install.sh as a transient systemd
# unit, so the install survives this server being restarted by the release it installs.
import json, os, pwd, re, shutil, subprocess, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.dirname(HERE)                     # ~/zero-extended
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


def read_json(path):
    with open(path) as f:
        return json.load(f)


def update_status():
    running, result = install_state()
    log = ""
    if os.path.exists(LOG_START) and os.path.exists(INSTALL_LOG):
        with open(LOG_START) as f:
            start = int(f.read())
        with open(INSTALL_LOG, "rb") as f:
            f.seek(start)
            log = f.read().decode(errors="replace")
    pending = read_json(PENDING) if os.path.exists(PENDING) else None
    # A finished transient unit is unloaded, so its Result is "" after a success but also after it was
    # killed (power loss, reboot); only install.sh's last line tells them apart.
    finished = re.search(r"^==> installed sovol-zero-extended ", log, re.M)
    return {"pending": pending, "running": running, "log": log,
            "result": None if running or not log else
                      ("success" if finished and result in ("success", "") else "failed")}


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
    with open(PENDING, "w") as f:
        json.dump(pending, f)
    return pending


def install_args(args):
    """install.sh options a client may pass; anything else is refused (trust boundary)."""
    out, rest = [], iter(args)
    for a in rest:
        if a == "--no-flash":
            out.append(a)
        elif a == "--force-flash":
            board = next(rest, None)
            if board not in ("toolhead", "mainboard"):
                raise ValueError("--force-flash takes toolhead or mainboard, not %r" % (board,))
            out += [a, board]
        else:
            raise ValueError("unsupported install option: %r" % (a,))
    return out


def start_install(args):
    if install_state()[0]:
        raise RuntimeError("an install is already running")
    if not os.path.exists(PENDING):
        raise RuntimeError("upload a release first")
    top = read_json(PENDING)["folder"]
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


def status():
    try:
        manifest = read_json(os.path.join(STATE, "manifest.json"))
    except OSError:
        manifest = {}
    return {"version": manifest.get("version", "unknown"),
            "boards": {b: v.get("version") for b, v in manifest.get("boards", {}).items()}}


if __name__ == "__main__":   # self-check of the trust-boundary parsers: python3 updates.py
    import tempfile
    tmp = tempfile.TemporaryDirectory()
    assert install_args([]) == []
    assert install_args(["--force-flash", "toolhead", "--no-flash"]) == ["--force-flash", "toolhead", "--no-flash"]
    for bad in (["--force-flash"], ["--force-flash", "x"], ["--rm"], [1], ["--no-flash", ";reboot"]):
        try:
            install_args(bad)
            raise AssertionError("accepted %r" % bad)
        except ValueError:
            pass

    def zip_of(files):
        path = os.path.join(tmp.name, "%d.zip" % len(os.listdir(tmp.name)))
        with zipfile.ZipFile(path, "w") as z:
            for name, data in files.items():
                z.writestr(name, data)
        return path
    top = "sovol-zero-extended-v1.2.3/"
    good = {top + "install.sh": "", top + "SHA256SUMS": "", top + "manifest.json": '{"name": "sovol-zero-extended"}'}
    assert check_release(zip_of(good))[0] == top.rstrip("/")
    for bad in ({**good, top + "../evil": ""}, {**good, "other/x": ""},
                {k: v for k, v in good.items() if not k.endswith("install.sh")},
                {**good, top + "manifest.json": '{"name": "other"}'}):
        try:
            check_release(zip_of(bad))
            raise AssertionError("accepted %r" % sorted(bad))
        except ValueError:
            pass
    tmp.cleanup()
    print("updates.py self-check ok")
