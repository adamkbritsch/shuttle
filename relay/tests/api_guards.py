#!/usr/bin/env python3
"""Every one of these was reachable before guards.py existed.

Each must be refused AND leave nothing behind -- proof by absence, not by status
code alone. Run from the NAS.
"""
import os
import json, os, subprocess, urllib.error, urllib.request

BASE = os.environ.get("RELAY_BASE", "http://127.0.0.1:8789")
TOKEN = os.environ["RELAY_API_TOKEN"]
SRC = "/seedbox/downloads/OpenVPN"


def call(method, path, body=None, token=TOKEN, ctype="application/json"):
    req = urllib.request.Request(BASE + path, method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, data, timeout=20) as r:
            return r.status, r.read().decode()[:200]
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]
    except Exception as e:
        return 0, f"{type(e).__name__}: {e}"


def say(label, want, got, extra=""):
    ok = "PASS" if got == want else "**FAIL**"
    print(f"  {ok}  {label:<46} want {want} got {got} {extra}")


print("== auth ==")
say("/healthz with no token", 200, call("GET", "/healthz", token=None)[0])
say("/v1/jobs with no token", 401, call("GET", "/v1/jobs", token=None)[0])
say("/v1/jobs with wrong token", 401, call("GET", "/v1/jobs", token="nope")[0])

print("== destination guards (proof by absence) ==")
for dest, label in [("/data", "dest /data"),
                    ("/queue/_active", "dest /queue/_active"),
                    ("/queue/_scratch/Movis", "dest nonexistent subfolder"),
                    ("/queue/../../data", "dest traversal"),
                    ("/seedbox/downloads", "dest on the seedbox")]:
    code, body = call("POST", "/v1/jobs", {"src": SRC, "dest_dir": dest})
    say(label, 400, code, body.strip()[:80])

print("== source guards ==")
for src, label in [("/seedbox", "src /seedbox (whole tree)"),
                   ("/seedbox/downloads", "src /seedbox/downloads (whole lib)"),
                   ("/queue/Media/x", "src not on the seedbox"),
                   ("/../../etc/passwd", "src traversal")]:
    code, body = call("POST", "/v1/jobs", {"src": src, "dest_dir": "/queue/_scratch"})
    say(label, 400, code, body.strip()[:80])

print("== dest_name guards ==")
for nm, label in [("../evil", "dest_name ../evil"), ("a/b", "dest_name a/b"),
                  ("..", "dest_name .."), ("", "dest_name empty -> defaults, allowed")]:
    code, body = call("POST", "/v1/jobs",
                      {"src": SRC, "dest_dir": "/queue/_scratch", "dest_name": nm})
    want = 201 if nm == "" else 400
    say(label, want, code, body.strip()[:60])

print("== browse guards ==")
for pth, label, want in [("/../../etc", "browse traversal", 400),
                         ("/seedbox/../../data", "browse escape via seedbox", 400),
                         ("etc", "browse relative path", 400),
                         # A virtual /data means /srv/tree/data, which does not
                         # exist -- so 404, not 400, and the container's real /data
                         # (jobs.db) was never addressable. Verified separately.
                         ("/data", "browse /data (in-tree, absent)", 404)]:
    code, body = call("GET", "/v1/browse?path=" + pth)
    say(label, want, code, body.strip()[:70])

print("== nothing was created ==")
for chk in ["/srv/tree/queue/_scratch/Movis", "/srv/tree/queue/_active/OpenVPN"]:
    r = subprocess.run(["docker", "exec", "seedbox-ftp-relay", "test", "-e", chk])
    print(f"  {'**FAIL** exists' if r.returncode == 0 else 'PASS  absent'}  {chk}")

print("== binding ==")
r = subprocess.run(["ss", "-tln"], capture_output=True, text=True)
lines = [l for l in r.stdout.splitlines() if ":8789" in l]
print("  " + ("PASS" if all(BASE.split("//")[-1].split(":")[0] in l for l in lines) and lines else "**FAIL**")
      + f"  8789 bound tailnet-only: {[l.split()[3] for l in lines]}")
