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


def body_full(path):
    """call() truncates to 200 chars, which is right for error text and useless for
    a result set."""
    req = urllib.request.Request(BASE + path, method="GET")
    req.add_header("Authorization", "Bearer " + TOKEN)
    with urllib.request.urlopen(req, timeout=90) as r:
        return r.read().decode()


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

print("== search ==")
# Ground truth measured directly on the volumes; these are the numbers that catch a
# walk that silently stops early or starts skipping a root.
for term, want_total in [("ted lasso", 2), ("reacher", 26), ("1080p", 7008)]:
    code, body = call("GET", "/v1/search?q=" + urllib.parse.quote(term))
    try:
        got = json.loads(body_full("/v1/search?q=" + urllib.parse.quote(term)))["total"]
    except Exception as exc:
        got = f"error {exc}"
    say(f"search {term!r} total", want_total, got, f"http {code}")

# The cap must not come from whichever volume sorts first. Before this was fixed a
# 500-row search returned 500 rows from Media and none at all from MediaVolume3.
d = json.loads(body_full("/v1/search?q=1080p&limit=500"))
vols = {e["path"].split("/")[2] for e in d["entries"]}
say("search spans >1 volume", True, len(vols) > 1, str(sorted(vols)))
say("search reports true total", True, d["total"] > len(d["entries"]), f"{len(d['entries'])} of {d['total']}")

# Scope: the guard's own view of the drop targets, never os.listdir(QUEUE).
say("no _active/_done in results", 0,
    sum(1 for e in d["entries"] if "/_active" in e["path"] or "/_done" in e["path"]))
say("every path is virtual", True, all(e["path"].startswith("/queue/") for e in d["entries"]))
say("no '..' path component", True,
    all(".." not in e["path"].split("/") for e in d["entries"]))
say("no hidden names by default", True,
    all(not e["name"].startswith(".") for e in d["entries"]))

# Input handling.
for qs, label, want in [("q=a", "search 1 char refused", 400),
                        ("q=", "search empty refused", 400),
                        ("", "search missing q refused", 400),
                        ("q=%20%20", "search whitespace refused", 400),
                        ("q=reacher&side=bogus", "search bad side refused", 400)]:
    code, body = call("GET", "/v1/search?" + qs)
    say(label, want, code, body.strip()[:50])
say("search limit clamped", 2000,
    json.loads(body_full("/v1/search?q=ep&limit=99999"))["limit"])

# Two identical calls must agree, or the top-N window is nondeterministic and no
# assertion above is trustworthy.
a = json.loads(body_full("/v1/search?q=mkv&limit=100"))["entries"]
b = json.loads(body_full("/v1/search?q=mkv&limit=100"))["entries"]
say("search order deterministic", True, a == b)

# The remote side is a different implementation (one rclone recursive listing) and
# is slow enough that it gets its own budget -- so it needs its own assertion.
sb = json.loads(body_full("/v1/search?q=zootopia&side=seedbox"))
say("seedbox search scoped", True,
    all(e["path"].startswith("/seedbox/") for e in sb["entries"]),
    f"{len(sb['entries'])} results")

print("== nothing was created ==")
for chk in ["/srv/tree/queue/_scratch/Movis", "/srv/tree/queue/_active/OpenVPN"]:
    r = subprocess.run(["docker", "exec", "seedbox-ftp-relay", "test", "-e", chk])
    print(f"  {'**FAIL** exists' if r.returncode == 0 else 'PASS  absent'}  {chk}")

print("== binding ==")
r = subprocess.run(["ss", "-tln"], capture_output=True, text=True)
lines = [l for l in r.stdout.splitlines() if ":8789" in l]
print("  " + ("PASS" if all(BASE.split("//")[-1].split(":")[0] in l for l in lines) and lines else "**FAIL**")
      + f"  8789 bound tailnet-only: {[l.split()[3] for l in lines]}")
