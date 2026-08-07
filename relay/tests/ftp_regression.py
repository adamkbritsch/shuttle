#!/usr/bin/env python3
"""FTP regression suite for the relay.

Run this against UNMODIFIED code first and keep the output: that transcript is the
baseline. The guards refactor moves validation out of vfs.py into guards.py, and the
only thing that proves it did not change behaviour is a byte-for-byte diff of the
550 strings a client actually receives.

Driven from the NAS on purpose, so the Mac is structurally uninvolved.
Read-only apart from writes into /queue/_scratch, which is the stack's own data/test.
"""
import ftplib, os, sqlite3, subprocess, sys, time

HOST = os.environ.get("RELAY_HOST", "127.0.0.1")
PORT = int(os.environ.get("FTP_PORT", "2121"))
DB = os.environ.get("RELAY_DB", "./data/jobs.db")
SCRATCH = "/queue/_scratch"
CONTAINER = os.environ.get("RELAY_CONTAINER", "seedbox-ftp-relay")

# The suite used to point at a hardcoded file that simply happened to be on the
# remote server. Those come and go, and when that one was removed every rename
# assertion began failing with "No such file or directory" -- a red suite that said
# nothing whatever about the code, which is the worst kind of test. The fixture is
# created and removed here instead, so the suite depends on nothing but itself.
#
# It must be TINY: several assertions use the `Name@Volume` rename that enqueues a
# real copy, and borrowing an arbitrary release would start a hundred-gigabyte
# transfer as a side effect of running the tests.
META = "shuttle-ftp-regression.txt"
SRC = f"/seedbox/downloads/{META}"


def _rclone(*args):
    """rclone against the remote, using the relay's own stored credentials."""
    code = ("import sys, subprocess; sys.path.insert(0, '/app'); import seedbox; "
            "sys.exit(subprocess.run(['rclone'] + %r, env=seedbox.env()).returncode)"
            % (list(args),))
    return subprocess.run(["docker", "exec", CONTAINER, "python3", "-c", code],
                          capture_output=True, text=True).returncode


def make_fixture():
    subprocess.run(["docker", "exec", CONTAINER, "sh", "-c",
                    f"printf 'shuttle ftp regression fixture' > /tmp/{META}"],
                   check=True, capture_output=True)
    if _rclone("copyto", f"/tmp/{META}", f"seedbox:/{META}") != 0:
        print("  ** could not create the fixture on the remote; aborting")
        sys.exit(1)
    # The relay reads the remote through a FUSE mount with a 30s directory cache, so
    # a file that exists remotely can still be invisible locally. Wait, don't race.
    real = f"/srv/tree/seedbox/downloads/{META}"
    for _ in range(40):
        if subprocess.run(["docker", "exec", CONTAINER, "test", "-e", real]).returncode == 0:
            return
        time.sleep(1)
    print("  ** fixture never appeared on the mount; aborting")
    sys.exit(1)


def drop_fixture():
    _rclone("deletefile", f"seedbox:/{META}")


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
    # Both MKD targets are removed first because this section CREATES them and
    # nothing else does. Without this the suite passes once and then reports
    # "REFUSED 550 File exists" on every subsequent run -- a failure that looks
    # like a regression in the guards and is really just last run's leftovers.
    for leftover in ("OpenVPN", "NotAReleaseName"):
        try:
            f.rmd(f"{SCRATCH}/{leftover}")
        except ftplib.all_errors:
            pass          # absent is the normal case
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
    make_fixture()
    try:
        main()
    finally:
        # Always, even on a failure: leaving it behind would show up in the app as
        # a stray file on the remote.
        drop_fixture()
