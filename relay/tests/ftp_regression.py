#!/usr/bin/env python3
"""FTP regression suite for the relay.

Run this against UNMODIFIED code first and keep the output: that transcript is the
baseline. The guards refactor moves validation out of vfs.py into guards.py, and the
only thing that proves it did not change behaviour is a byte-for-byte diff of the
550 strings a client actually receives.

Driven from the NAS on purpose, so the Mac is structurally uninvolved.
Read-only apart from writes into /queue/_scratch, which is the stack's own data/test.
"""
import os
import ftplib, os, sqlite3, sys, time

HOST = os.environ.get("RELAY_HOST", "127.0.0.1")
PORT = int(os.environ.get("FTP_PORT", "2121"))
DB = os.environ.get("RELAY_DB", "./data/jobs.db")
SCRATCH = "/queue/_scratch"
META = "8033FEA0AC5A584CEB10163FB2475D9ECC132F7E.meta"
SRC = f"/seedbox/downloads/{META}"


def connect():
    f = ftplib.FTP()
    f.connect(HOST, PORT, timeout=25)
    f.login(os.environ["FTP_USER"], os.environ["FTP_PASS"])
    f.set_pasv(True)
    return f


def say(label, outcome):
    print(f"  {label:<44} {outcome}")


def expect(label, fn):
    """Run fn; report either the 2xx/3xx reply or the verbatim error text."""
    t0 = time.time()
    try:
        r = fn()
        say(label, f"OK {(r or '').strip()[:64]}  [{time.time()-t0:.2f}s]")
    except ftplib.error_perm as e:
        say(label, f"REFUSED {str(e).strip()[:96]}")
    except Exception as e:
        say(label, f"ERROR {type(e).__name__}: {str(e)[:70]}")


def last_job():
    c = sqlite3.connect(DB); c.row_factory = sqlite3.Row
    return c.execute("select id,state,dest_dir,error from jobs order by id desc limit 1").fetchone()


def wait_idle(limit=60):
    for _ in range(limit):
        time.sleep(1)
        c = sqlite3.connect(DB)
        if not c.execute("select 1 from jobs where state in ('queued','running')").fetchone():
            return True
    return False


def main():
    f = connect()
    print("== browse ==")
    say("NLST /seedbox/downloads", f"{len(f.nlst('/seedbox/downloads'))} entries")
    say("NLST /queue", sorted(x for x in f.nlst("/queue")))

    print("== primary trigger ==")
    expect("RNTO -> volume root", lambda: f.rename(SRC, f"{SCRATCH}/base_root.meta"))
    wait_idle(); say("  job", dict(last_job()))
    try: f.mkd(f"{SCRATCH}/Movies")
    except ftplib.error_perm: pass
    expect("RNTO -> existing subfolder", lambda: f.rename(SRC, f"{SCRATCH}/Movies/base_sub.meta"))
    wait_idle(); say("  job", dict(last_job()))

    print("== fallback A (rename with @) ==")
    expect("X@_scratch", lambda: f.rename(SRC, f"/seedbox/downloads/{META}@_scratch"))
    wait_idle()
    expect("X@_scratch/Movies", lambda: f.rename(SRC, f"/seedbox/downloads/{META}@_scratch/Movies"))
    wait_idle()

    print("== fallback B (MKD) ==")
    expect("MKD naming a real release", lambda: f.mkd(f"{SCRATCH}/OpenVPN"))
    wait_idle()
    # THE branch that must survive the refactor: a name that is NOT a release must
    # still create a genuine directory (vfs.py:168 is a branch, not a guard).
    expect("MKD NotAReleaseName (must CREATE)", lambda: f.mkd(f"{SCRATCH}/NotAReleaseName"))

    print("== guards: every one of these must be refused, with stable text ==")
    expect("RNTO into nonexistent folder", lambda: f.rename(SRC, f"{SCRATCH}/Movis/x.meta"))
    expect("rename @../../etc", lambda: f.rename(SRC, f"/seedbox/downloads/{META}@../../etc"))
    expect("src /seedbox (whole tree)", lambda: f.rename("/seedbox", f"{SCRATCH}/EVIL"))
    expect("src /seedbox/downloads (whole lib)", lambda: f.rename("/seedbox/downloads", f"{SCRATCH}/EVIL"))
    expect("MKD downloads inside a target", lambda: f.mkd(f"{SCRATCH}/downloads"))
    expect("DELE under /seedbox", lambda: f.delete(SRC))
    expect("RNTO to a non-target (/seedbox)", lambda: f.rename(SRC, "/seedbox/downloads/x.meta"))

    print("== status folders ==")
    say("NLST /queue/_done", f"{len(f.nlst('/queue/_done'))} entries")
    done = f.nlst("/queue/_done")
    if done:
        buf = []
        f.retrbinary(f"RETR /queue/_done/{done[0]}", buf.append)
        say("RETR a _done entry (its log)", f"{sum(len(b) for b in buf)} bytes")
    expect("RMD /queue/_active (must refuse)", lambda: f.rmd("/queue/_active"))
    f.quit()
    print("== done ==")


if __name__ == "__main__":
    main()
