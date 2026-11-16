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



def status():
    try:
        manifest = json.load(open(os.path.join(STATE, "manifest.json")))
    except OSError:
        manifest = {}
    return {"version": manifest.get("version", "unknown"),
            "boards": {b: v.get("version") for b, v in manifest.get("boards", {}).items()}}
