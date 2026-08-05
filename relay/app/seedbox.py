"""Direct connection to the seedbox — no FUSE mount involved.

The relay used to browse the seedbox through an rclone FUSE mount bind-mounted at
/srv/tree/seedbox. That mount existed for FileZilla's benefit: FileZilla needs a
POSIX filesystem to list, so the seedbox had to be mirrored onto the NAS first.
Shuttle talks to this API instead, so the mirror is dead weight for browsing —
transfers never used it (jobs.py has always run `rclone copy seedbox:<path> ...`
straight against the remote).

So listings now come from `rclone lsjson` against the remote directly. The mount is
left alone: the filebrowser stack shares it.

Credentials live in DATA_DIR/seedbox.json (0600), never in the repo, and reach
rclone as RCLONE_CONFIG_SEEDBOX_* environment variables so no rclone.conf is
needed at all. That is what makes a fresh clone configurable purely from the app.
"""
import json
import os
import subprocess
import threading

DATA_DIR = os.environ.get("RELAY_DATA_DIR", "/data")
CONFIG_PATH = os.path.join(DATA_DIR, "seedbox.json")
REMOTE = "seedbox"

# The remote's root is presented to clients as /seedbox/downloads.
#
# This is not cosmetic. The FUSE mount was `rclone mount seedbox:/ .../seedbox/downloads`,
# so the seedbox's FTP root has always appeared one level down as "downloads" --
# there is no directory of that name on the seedbox itself. Keeping the alias means
# saved client paths (browse.path.source = /seedbox/downloads) still resolve, and
# guards.MIN_SRC_DEPTH=2 still rejects a whole-library copy.
ROOT_ALIAS = "downloads"

# rclone's own backend names. "ftps" is not a backend: it is the ftp backend with
# explicit_tls, which is what virtually every seedbox actually serves.
# Every key is stated explicitly, including the false ones. Setting only the keys
# that matter is not enough: if the host happens to have an rclone.conf with its own
# [seedbox] section, rclone MERGES it with the environment, and any key the
# environment does not name is taken from the file. A leftover `explicit_tls = true`
# there makes a plain-FTP connection send AUTH and fail with
# `500 Command "AUTH" not understood`, which looks like a broken server rather than
# a config collision. Observed, not theoretical.
PROTOCOLS = {
    "ftp":  {"type": "ftp",  "explicit_tls": "false", "implicit_tls": "false"},
    "ftps": {"type": "ftp",  "explicit_tls": "true",  "implicit_tls": "false"},
    "sftp": {"type": "sftp"},
}
DEFAULT_PORTS = {"ftp": 21, "ftps": 21, "sftp": 22}

_lock = threading.Lock()


class SeedboxError(Exception):
    pass


def _obscure(plain: str) -> str:
    """rclone stores passwords obscured, and refuses a plain one via env."""
    if not plain:
        return ""
    p = subprocess.run(["rclone", "obscure", plain],
                       capture_output=True, text=True, timeout=15)
    if p.returncode != 0:
        raise SeedboxError("rclone obscure failed: " + (p.stderr or "").strip())
    return p.stdout.strip()


def load() -> dict:
    try:
        with open(CONFIG_PATH) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def configured() -> bool:
    c = load()
    return bool(c.get("host") and c.get("user"))


def public() -> dict:
    """Config for the client. The password is never returned, only whether it is set."""
    c = load()
    return {
        "protocol": c.get("protocol", "ftps"),
        "host": c.get("host", ""),
        "port": c.get("port") or DEFAULT_PORTS.get(c.get("protocol", "ftps"), 21),
        "user": c.get("user", ""),
        "has_password": bool(c.get("pass_obscured")),
        "root": c.get("root", "/"),
        "configured": configured(),
    }


def save(protocol: str, host: str, port, user: str, password, root: str) -> dict:
    protocol = (protocol or "ftps").strip().lower()
    if protocol not in PROTOCOLS:
        raise SeedboxError("protocol must be one of: " + ", ".join(sorted(PROTOCOLS)))
    host = (host or "").strip()
    user = (user or "").strip()
    root = (root or "/").strip() or "/"
    if not host:
        raise SeedboxError("host is required")
    if not user:
        raise SeedboxError("username is required")
    try:
        port = int(port) if port else DEFAULT_PORTS[protocol]
    except (TypeError, ValueError):
        raise SeedboxError("port must be a number")
    if not (1 <= port <= 65535):
        raise SeedboxError("port must be between 1 and 65535")

    with _lock:
        current = load()
        # An empty password on an existing config means "leave it alone", so the
        # client can edit the host without having to re-enter the secret.
        if password:
            obscured = _obscure(password)
        elif current.get("pass_obscured"):
            obscured = current["pass_obscured"]
        else:
            raise SeedboxError("password is required")

        cfg = {"protocol": protocol, "host": host, "port": port,
               "user": user, "pass_obscured": obscured, "root": root}
        os.makedirs(DATA_DIR, exist_ok=True)
        tmp = CONFIG_PATH + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(cfg, fh, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, CONFIG_PATH)
    return public()


def env(base=None) -> dict:
    """RCLONE_CONFIG_SEEDBOX_* for a subprocess, so no rclone.conf is required."""
    e = dict(base or os.environ)
    c = load()
    if not c:
        return e
    # Belt and braces alongside the explicit keys above: point rclone at an empty
    # config so the remote is defined ENTIRELY by this environment and no stray
    # rclone.conf can contribute anything.
    empty = os.path.join(DATA_DIR, "rclone-empty.conf")
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        if not os.path.exists(empty):
            with open(empty, "w"):
                pass
        e["RCLONE_CONFIG"] = empty
    except OSError:
        pass
    spec = PROTOCOLS.get(c.get("protocol", "ftps"), PROTOCOLS["ftps"])
    up = REMOTE.upper()
    for k, v in spec.items():
        e[f"RCLONE_CONFIG_{up}_{k.upper()}"] = v
    e[f"RCLONE_CONFIG_{up}_HOST"] = c["host"]
    e[f"RCLONE_CONFIG_{up}_PORT"] = str(c["port"])
    e[f"RCLONE_CONFIG_{up}_USER"] = c["user"]
    e[f"RCLONE_CONFIG_{up}_PASS"] = c["pass_obscured"]
    return e


def remote_path(rel: str) -> str:
    """Virtual '/seedbox/<rel>' -> 'seedbox:<root>/<rel>'."""
    root = (load().get("root") or "/").strip("/")
    rel = (rel or "").strip("/")
    joined = "/".join(p for p in (root, rel) if p)
    return f"{REMOTE}:{joined}"


def lsjson(rel: str, timeout: int = 45) -> list:
    """One directory listing, straight from the seedbox.

    Not recursive and no --fast-list: a seedbox release directory can be huge and
    the caller only ever renders one level.
    """
    if not configured():
        raise SeedboxError("seedbox is not configured yet — set it in Settings")
    cmd = ["rclone", "lsjson", remote_path(rel)]
    p = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=timeout, env=env())
    if p.returncode != 0:
        msg = (p.stderr or "").strip().splitlines()
        raise SeedboxError(msg[-1] if msg else f"rclone exit {p.returncode}")
    try:
        return json.loads(p.stdout or "[]")
    except ValueError:
        raise SeedboxError("could not parse the seedbox listing")


def test(timeout: int = 30) -> dict:
    """Prove the settings actually work before they are trusted."""
    entries = lsjson("", timeout=timeout)
    dirs = sum(1 for e in entries if e.get("IsDir"))
    return {"ok": True, "entries": len(entries), "directories": dirs,
            "files": len(entries) - dirs}


def stat(rel: str, timeout: int = 30):
    """{"exists", "is_dir", "size"} for one remote path, via `rclone lsjson --stat`."""
    if not configured():
        raise SeedboxError("seedbox is not configured yet — set it in Settings")
    p = subprocess.run(["rclone", "lsjson", "--stat", remote_path(rel)],
                       capture_output=True, text=True, timeout=timeout, env=env())
    if p.returncode != 0:
        err = (p.stderr or "").lower()
        if "not found" in err or "does not exist" in err:
            return {"exists": False, "is_dir": False, "size": 0}
        msg = (p.stderr or "").strip().splitlines()
        raise SeedboxError(msg[-1] if msg else f"rclone exit {p.returncode}")
    try:
        item = json.loads(p.stdout or "null")
    except ValueError:
        raise SeedboxError("could not parse the seedbox stat")
    if not item:
        return {"exists": False, "is_dir": False, "size": 0}
    return {"exists": True, "is_dir": bool(item.get("IsDir")),
            "size": int(item.get("Size") or 0)}


def _run(cmd: list, timeout: int):
    """One rclone invocation against the remote, with rclone's own last line as the
    error text so the app shows what actually went wrong."""
    if not configured():
        raise SeedboxError("seedbox is not configured yet — set it in Settings")
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env())
    if p.returncode != 0:
        msg = (p.stderr or "").strip().splitlines()
        raise SeedboxError(msg[-1] if msg else f"rclone exit {p.returncode}")
    return p.stdout


def delete(rel: str, is_dir: bool, timeout: int = 600) -> None:
    """Remove a file or a whole directory from the seedbox.

    The FTP backend does NOT support Purge, so rclone deletes each file and then
    the directories; a large release is many round trips, hence the long timeout.
    """
    if is_dir:
        _run(["rclone", "purge", remote_path(rel)], timeout)
    else:
        _run(["rclone", "deletefile", remote_path(rel)], timeout)


def walk_all(rel: str = "", timeout: int = 180) -> list:
    """Every entry under a remote path, FILES AND DIRECTORIES, in one call.

    `walk_files` exists for sizing a transfer and passes --files-only; search needs
    the directories too, because a release IS a directory and that is usually the
    thing being looked for.

    One `lsjson --recursive` and not a listing per level: over FTP each level is a
    round trip. Measured on the live seedbox -- 737 entries in 18.9s, and identical
    on a second run, because rclone still walks every directory remotely and there
    is nothing to cache. That is ~40x the local NAS walk, which is why the two sides
    get different budgets rather than one shared number.
    """
    if not configured():
        raise SeedboxError("seedbox is not configured yet — set it in Settings")
    p = subprocess.run(["rclone", "lsjson", "--recursive", remote_path(rel)],
                       capture_output=True, text=True, timeout=timeout, env=env())
    if p.returncode != 0:
        msg = (p.stderr or "").strip().splitlines()
        raise SeedboxError(msg[-1] if msg else f"rclone exit {p.returncode}")
    try:
        return json.loads(p.stdout or "[]")
    except ValueError:
        raise SeedboxError("could not parse the seedbox listing")


def walk_files(rel: str, timeout: int = 300) -> list:
    """Every file under a remote path, as [{"path": relative, "size": int}].

    One recursive rclone call rather than a listing per directory: over FTP each
    listing is a round trip, and a release folder can be several levels deep.
    """
    if not configured():
        raise SeedboxError("seedbox is not configured yet — set it in Settings")
    p = subprocess.run(["rclone", "lsjson", "--recursive", "--files-only",
                        remote_path(rel)],
                       capture_output=True, text=True, timeout=timeout, env=env())
    if p.returncode != 0:
        msg = (p.stderr or "").strip().splitlines()
        raise SeedboxError(msg[-1] if msg else f"rclone exit {p.returncode}")
    try:
        items = json.loads(p.stdout or "[]")
    except ValueError:
        raise SeedboxError("could not parse the seedbox listing")
    return [{"path": i.get("Path") or "", "size": int(i.get("Size") or 0)}
            for i in items]
