"""Job queue and the rclone worker that actually moves the bytes.

The whole point of this module is that it runs on the NAS: the Mac's FileZilla
only ever issues the FTP control command that lands a row in this queue.
"""

import json
import os
import queue
import shlex
import sqlite3
import shutil
import subprocess

import seedbox
import threading
import time

DB_PATH = os.environ.get("RELAY_DB", "/data/jobs.db")
LOG_DIR = os.environ.get("RELAY_LOG_DIR", "/data/logs")
# A FIXED pool of worker threads is started once; how many may run AT THE SAME TIME
# is a separate, live-adjustable number. That split is what lets the setting change
# without recreating the container -- spawning/killing threads to match would be a
# lot more machinery for the same effect.
MAX_WORKERS = int(os.environ.get("RELAY_MAX_WORKERS", "8"))
MAX_JOBS = int(os.environ.get("RELAY_MAX_JOBS", "1"))     # the DEFAULT limit only
LIMIT_FILE = os.path.join(os.path.dirname(DB_PATH), "max_concurrent")


def _read_limit() -> int:
    """The persisted concurrency limit, falling back to RELAY_MAX_JOBS."""
    try:
        with open(LIMIT_FILE) as f:
            return max(1, min(MAX_WORKERS, int(f.read().strip())))
    except (OSError, ValueError):
        return max(1, min(MAX_WORKERS, MAX_JOBS))

TREE = "/srv/tree"
# The path whose contents ARE the remote's root. The FTP login is chrooted to the
# seedbox's downloads dir, so `seedbox:` root == .../seedbox/downloads. Keeping the
# distinction here (rather than in to_remote) preserves the plain prefix swap.
SEEDBOX_MOUNT = TREE + "/seedbox/downloads"
RCLONE_REMOTE = os.environ.get("RELAY_REMOTE", "seedbox:")
# NOT a `combine` remote. rclone 1.74.4's combine backend silently DROPS files when
# listing a subdirectory of an FTP upstream ("Bad object: file not under root",
# combine/combine.go:1106) and still exits 0 with errors=0 -- a directory copy reports
# success having moved 1 of 3 files. The `downloads` level is a real nested mountpoint
# instead; see SEEDBOX_MOUNT above.

_SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  src_real   TEXT NOT NULL,
  src_remote TEXT NOT NULL,
  dest_dir   TEXT NOT NULL,
  dest_name  TEXT NOT NULL,
  is_dir     INTEGER NOT NULL DEFAULT 0,
  state      TEXT NOT NULL DEFAULT 'queued',
  bytes_done INTEGER DEFAULT 0,
  bytes_total INTEGER DEFAULT 0,
  speed      REAL DEFAULT 0,
  eta        INTEGER DEFAULT 0,
  files_done INTEGER DEFAULT 0,
  files_total INTEGER DEFAULT 0,
  error      TEXT,
  dest_preexisted INTEGER DEFAULT 0,
  rename_to  TEXT,
  replace_path TEXT,
  on_conflict TEXT DEFAULT 'overwrite',
  created_at REAL, updated_at REAL, finished_at REAL
);
"""


# FileZilla's "Target file already exists" actions, mapped onto the rclone flags
# that reproduce them. rclone's DEFAULT (no flags) transfers when size or modtime
# differ in EITHER direction, which is why every policy below names a flag.
#
#   --ignore-times     always rewrite, even if identical
#   --update           skip when the destination is newer  -> "or source is newer"
#   --size-only        compare size alone
#   --ignore-size      compare modtime alone
#   --ignore-existing  never touch a file that is already there
#
# FileZilla's "Resume file transfer" is deliberately absent: rclone restarts an
# interrupted file from zero rather than resuming (see _cleanup_partial), so the
# option would be a button that lies.
CONFLICT_FLAGS = {
    "overwrite":               ["--ignore-times"],
    "overwrite_newer":         ["--update", "--ignore-size"],
    "overwrite_size":          ["--size-only"],
    "overwrite_size_or_newer": ["--update"],
    "skip":                    ["--ignore-existing"],
}
CONFLICT_POLICIES = set(CONFLICT_FLAGS) | {"ask", "rename"}

CONFLICT_SCAN_LIMIT = 200
CONFLICT_SCAN_SECONDS = 6.0


def _src_rel(src_real):
    """Real path -> path relative to the remote root, or None if it is not a seedbox path."""
    if not src_real.startswith(SEEDBOX_MOUNT):
        return None
    return src_real[len(SEEDBOX_MOUNT):].strip("/")


def scan_conflicts(src_real, dest_dir, dest_name, limit=CONFLICT_SCAN_LIMIT):
    """Destination files that already exist under the same relative path.

    Walks the SOURCE and probes the destination, so the cost is bounded by the
    thing being sent rather than by the size of the volume. Both a count limit and
    a wall-clock budget apply: a cold listing on the FUSE mount costs ~1.2s, and an
    enqueue must not block the single-threaded HTTP handler for longer than that.
    Returns (conflicts, truncated).
    """
    target_root = os.path.join(dest_dir, dest_name)
    out, deadline = [], time.time() + CONFLICT_SCAN_SECONDS

    def note_remote(src_size, dst, rel):
        try:
            st = os.stat(dst)
            ds, dm = st.st_size, st.st_mtime
        except OSError:
            ds, dm = 0, 0
        # No source mtime: rclone's per-file modtime over FTP costs an extra round
        # trip each, and the sheet compares sizes plus the destination's date.
        out.append({"path": rel, "src_size": src_size, "src_mtime": 0,
                    "dest_size": ds, "dest_mtime": dm})

    # The SOURCE side is read from the seedbox over rclone; only the DESTINATION is
    # a real local filesystem. Walking the FUSE mirror would work today but breaks
    # the moment there is no mirror, which is the whole point of this relay now.
    rel_src = _src_rel(src_real)
    if rel_src is None:
        return out, False                      # not a seedbox source; nothing to scan

    info = seedbox.stat(rel_src)
    if not info["exists"]:
        return out, False
    if not info["is_dir"]:
        if os.path.exists(target_root):
            note_remote(info["size"], target_root, os.path.basename(dest_name))
        return out, False
    if not os.path.isdir(target_root):
        return out, False                      # nothing there at all
    for f in seedbox.walk_files(rel_src):
        if len(out) >= limit or time.time() > deadline:
            return out, True
        dst = os.path.join(target_root, f["path"])
        if os.path.exists(dst):
            note_remote(f["size"], dst, f["path"])
    return out, False


class JobError(Exception):
    """Raised at enqueue time so the failure surfaces in FileZilla immediately."""


def _count_tree(path):
    """(files, bytes) under a path. Mirrors api._walk_count, duplicated here rather
    than imported because api imports jobs and the cycle is not worth creating for
    ten lines."""
    files = 0
    size = 0
    if os.path.isfile(path):
        try:
            return 1, os.path.getsize(path)
        except OSError:
            return 0, 0
    for root, _dirs, names in os.walk(path):
        for n in names:
            try:
                size += os.path.getsize(os.path.join(root, n))
                files += 1
            except OSError:
                pass
    return files, size


def _connect():
    con = sqlite3.connect(DB_PATH, timeout=15)
    con.row_factory = sqlite3.Row
    # WAL because the FTP handler threads read while the worker writes.
    con.execute("PRAGMA journal_mode=WAL")
    return con


class Jobs:
    def __init__(self, log=print):
        self.log = log
        os.makedirs(LOG_DIR, exist_ok=True)
        con = _connect()
        con.executescript(_SCHEMA)
        # Additive migration for databases created before cancel existed.
        cols = {r[1] for r in con.execute("PRAGMA table_info(jobs)")}
        if "dest_preexisted" not in cols:
            con.execute("ALTER TABLE jobs ADD COLUMN dest_preexisted INTEGER DEFAULT 0")
        if "rename_to" not in cols:
            con.execute("ALTER TABLE jobs ADD COLUMN rename_to TEXT")
        if "on_conflict" not in cols:
            con.execute("ALTER TABLE jobs ADD COLUMN on_conflict TEXT DEFAULT 'overwrite'")
        if "replace_path" not in cols:
            con.execute("ALTER TABLE jobs ADD COLUMN replace_path TEXT")
        # Anything left 'running' died with a previous container. Be honest that
        # rclone restarts an interrupted file from zero rather than resuming.
        n = con.execute(
            "UPDATE jobs SET state='queued', error='requeued after restart' "
            "WHERE state='running'").rowcount
        con.commit()
        con.close()
        if n:
            self.log(f"requeued {n} job(s) interrupted by a restart")

        self._q = queue.Queue()
        self._active_lock = threading.Lock()
        self._active = 0
        # Cancellation state. `_procs` maps job id -> live rclone Popen so another
        # thread can signal it; `_cancelled` is the authority for an in-flight
        # cancel, because a DB state write can be raced by _run's own
        # state='running' update (see the checks in _run).
        self._proc_lock = threading.Lock()
        self._procs = {}
        self._cancelled = set()
        # Concurrency gate. Workers wait here rather than being created/destroyed.
        self._gate = threading.Condition()
        self._limit = _read_limit()
        self._running = 0
        for row in self.snapshot("queued"):
            self._q.put(row["id"])
        for i in range(MAX_WORKERS):
            threading.Thread(target=self._worker, name=f"worker{i}", daemon=True).start()

    # ---------- path mapping ----------

    @staticmethod
    def to_remote(real_path: str) -> str:
        """/srv/tree/seedbox/downloads/X -> seedbox:/X

        A plain prefix swap from SEEDBOX_MOUNT -- the path whose contents ARE the
        remote's root -- to RCLONE_REMOTE. The `downloads` level is a real nested
        mountpoint, and the FTPES login is chrooted to that same directory, so the
        swap drops the component rather than preserving it. Keep all layout
        knowledge in the SEEDBOX_MOUNT constant, never in this function.
        """
        if not real_path.startswith(SEEDBOX_MOUNT):
            raise JobError("source is not on the seedbox")
        rel = real_path[len(SEEDBOX_MOUNT):].lstrip("/")
        return RCLONE_REMOTE + "/" + rel

    # ---------- queue ----------

    def enqueue(self, src_real: str, dest_dir: str, dest_name: str,
                on_conflict: str = "overwrite", replace_path: str = None) -> tuple:
        """Returns (job_id, created). `created` is False when this exact copy was
        already queued or running, in which case the EXISTING job's id comes back
        and nothing new is added.

        Identity is (source, destination folder, destination name). Deliberately
        not the source alone: the same release copied into two different volumes,
        or copied twice under different names, is two real jobs.

        Only 'queued' and 'running' count as already-present. A finished, failed or
        cancelled job is not in the queue, and re-adding it is a legitimate way to
        copy it again -- which is exactly what /retry does.
        """
        # Checked BEFORE the seedbox stat below, which costs ~13s on a cold
        # connection: adding something twice should be cheap, not slower than
        # adding it once.
        existing = self._active_duplicate(src_real, dest_dir, dest_name)
        if existing is not None:
            # A replace carries an instruction the duplicate does not have. Job
            # identity is (src, dest_dir, dest_name), so folding this into the
            # existing job would silently drop the "and delete that" half of what
            # was asked for -- worse than refusing.
            if replace_path:
                raise JobError(f"that copy is already queued as job {existing}; "
                               "wait for it or cancel it before replacing with it")
            self.log(f"already queued as job {existing}: {dest_name} -> {dest_dir}")
            return existing, False

        rel_src = _src_rel(src_real)
        if rel_src is not None:
            # Ask the seedbox, not the filesystem: there may not be a mount at all.
            try:
                info = seedbox.stat(rel_src)
            except seedbox.SeedboxError as exc:
                raise JobError(str(exc))
            if not info["exists"]:
                raise JobError("source does not exist")
            is_dir = info["is_dir"]
            size = info["size"]
            # `size <= 0`, not `not size`: rclone's lsjson reports a DIRECTORY's
            # size as -1, which is truthy, so the walk below was skipped and -1 was
            # stored as the job's byte total. That is why a queued directory could
            # read "0.0 of -0.0 GB" at a negative percentage, and it also denies the
            # progress calculation the one figure that does not grow mid-copy.
            if is_dir and size <= 0:
                try:
                    size = sum(f["size"] for f in seedbox.walk_files(rel_src))
                except seedbox.SeedboxError:
                    size = 0
            # Never let a sentinel reach the database.
            size = max(0, size)
        else:
            if not os.path.exists(src_real):
                raise JobError("source does not exist")
            is_dir = os.path.isdir(src_real)
            size = self._source_size(src_real, is_dir)
        # Fail the enqueue SYNCHRONOUSLY on insufficient space: the user then
        # sees it in FileZilla's message log straight away instead of finding a
        # failure in _done five minutes later. /volume2 runs at 94%.
        try:
            st = os.statvfs(dest_dir)
            free = st.f_bavail * st.f_frsize
            if size and size > free * 0.98:
                raise JobError(
                    f"not enough space: need {size // 2**30}GiB, "
                    f"{free // 2**30}GiB free on {os.path.basename(dest_dir)}")
        except OSError:
            pass

        # Whether the destination already existed decides whether a cancel may
        # delete it. Without this, cancelling a copy into an existing release
        # directory would remove content this job never wrote.
        dest_preexisted = int(os.path.exists(os.path.join(dest_dir, dest_name)))

        now = time.time()
        con = _connect()
        try:
            # The check at the top of this function ran BEFORE a stat that can take
            # seconds, which is plenty of time for a second add of the same thing to
            # get past it. BEGIN IMMEDIATE takes the write lock, so the re-check and
            # the insert are one atomic step and two racing adds cannot both land.
            con.execute("BEGIN IMMEDIATE")
            row = con.execute(
                "SELECT id FROM jobs WHERE src_real=? AND dest_dir=? AND dest_name=? "
                "AND state IN ('queued','running') ORDER BY id LIMIT 1",
                (src_real, dest_dir, dest_name)).fetchone()
            if row:
                con.commit()
                if replace_path:
                    raise JobError(f"that copy is already queued as job {row['id']}; "
                                   "wait for it or cancel it before replacing with it")
                self.log(f"already queued as job {row['id']}: {dest_name} -> {dest_dir}")
                return row["id"], False
            cur = con.execute(
                "INSERT INTO jobs (src_real,src_remote,dest_dir,dest_name,is_dir,"
                "bytes_total,dest_preexisted,on_conflict,replace_path,created_at,"
                "updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (src_real, self.to_remote(src_real), dest_dir, dest_name,
                 int(is_dir), size, dest_preexisted,
                 on_conflict if on_conflict in CONFLICT_FLAGS else "overwrite",
                 replace_path or None, now, now))
            jid = cur.lastrowid
            con.commit()
        finally:
            con.close()
        self._q.put(jid)
        # Workers now wait on the gate rather than on the queue, so poke it: without
        # this the job would not start until some worker's next one-second timeout.
        with self._gate:
            self._gate.notify()
        self.log(f"enqueued job {jid}: {dest_name} -> {dest_dir}")
        return jid, True

    @staticmethod
    def _active_duplicate(src_real: str, dest_dir: str, dest_name: str):
        """The id of an identical job that is already queued or running, else None."""
        con = _connect()
        try:
            row = con.execute(
                "SELECT id FROM jobs WHERE src_real=? AND dest_dir=? AND dest_name=? "
                "AND state IN ('queued','running') ORDER BY id LIMIT 1",
                (src_real, dest_dir, dest_name)).fetchone()
        finally:
            con.close()
        return row["id"] if row else None

    @staticmethod
    def _source_size(path: str, is_dir: bool) -> int:
        if not is_dir:
            try:
                return os.path.getsize(path)
            except OSError:
                return 0
        total = 0
        for root, _dirs, files in os.walk(path):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
        return total

    def snapshot(self, *states):
        con = _connect()
        if states:
            marks = ",".join("?" * len(states))
            rows = con.execute(
                f"SELECT * FROM jobs WHERE state IN ({marks}) ORDER BY id", states).fetchall()
        else:
            rows = con.execute("SELECT * FROM jobs ORDER BY id").fetchall()
        con.close()
        return [dict(r) for r in rows]

    def recent_finished(self, limit=50):
        con = _connect()
        rows = con.execute(
            "SELECT * FROM jobs WHERE state IN ('done','failed','cancelled') "
            "ORDER BY finished_at DESC LIMIT ?", (limit,)).fetchall()
        con.close()
        return [dict(r) for r in rows]

    def busy(self) -> bool:
        with self._active_lock:
            return self._active > 0

    # ---------- cancel ----------

    def cancel(self, jid: int) -> str:
        """Stop a queued or running job. Returns a short human description.

        Ordering matters: the in-memory flag is set FIRST, because _run writes
        state='running' of its own accord and could otherwise clobber a DB-only
        cancel and start the copy anyway.
        """
        con = _connect()
        job = con.execute("SELECT * FROM jobs WHERE id=?", (jid,)).fetchone()
        con.close()
        if job is None:
            raise JobError(f"no such job j{jid}")
        if job["state"] in ("done", "failed", "cancelled", "dismissed"):
            raise JobError(f"j{jid} already finished ({job['state']})")

        with self._proc_lock:
            self._cancelled.add(jid)
            proc = self._procs.get(jid)

        was_running = proc is not None
        if proc is not None:
            # SIGTERM lets rclone close its files; escalate if it ignores us.
            try:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.log(f"job {jid} ignored SIGTERM; killing")
                    proc.kill()
            except Exception as exc:
                self.log(f"job {jid} terminate failed: {exc!r}")

        # replace_path cleared here on purpose: `_run` returns before the rc check
        # on a cancel, so nothing else would ever clear it, and a stale "delete
        # that" instruction sitting on a cancelled job is not something to leave
        # lying around. (rename_to has that exact bug today; it is merely harmless.)
        self._update(jid, state="cancelled", error="cancelled", speed=0, eta=0,
                     replace_path=None, finished_at=time.time())
        removed = self._cleanup_partial(job)
        self.log(f"job {jid} cancelled ({'running' if was_running else 'queued'})"
                 + (f"; removed partial {removed}" if removed else ""))
        return ("stopped mid-transfer" if was_running else "removed from the queue") + \
               (f", partial destination deleted" if removed else "")

    def dismiss(self, jid: int) -> str:
        """Clear a finished job out of the _done listing."""
        con = _connect()
        job = con.execute("SELECT state FROM jobs WHERE id=?", (jid,)).fetchone()
        con.close()
        if job is None:
            raise JobError(f"no such job j{jid}")
        if job["state"] not in ("done", "failed", "cancelled"):
            raise JobError(f"j{jid} is not finished ({job['state']})")
        self._update(jid, state="dismissed")
        return "dismissed"

    def defer_rename(self, jid: int, new_name: str) -> None:
        """Record a rename to apply once this job stops writing.

        Renaming a directory while rclone is writing into it would break the
        transfer -- the process holds the old path -- so a rename aimed at an
        in-flight destination is stored and applied at the terminal branch instead
        of being refused.
        """
        self._update(jid, rename_to=new_name)

    def _apply_replace(self, jid: int) -> None:
        """Delete the item this job was sent to replace -- but only once the new
        copy is proven to have landed.

        Runs ONLY in the success branch, and re-reads the row rather than trusting
        the one captured when the job started, exactly as the deferred rename does.

        The two checks in here are the whole point of the feature being safe:

        1. If the replacement landed on the item it replaces -- same name on both
           sides -- then the copy already overwrote it and there is nothing to
           delete. Skipping that check would delete the file just written.

        2. rclone exiting 0 is NOT proof. A directory copy once moved 1 of 3 files
           with errors=0 and exit 0, which is the entire reason /verify exists. The
           old item is about to be removed irreversibly, so the counts have to
           agree first. On a mismatch NOTHING is deleted and `replace_path` is left
           set -- a still-set replace_path on a done job IS the "the old item was
           kept" signal, and needs no extra column.

        Idempotent, because a relay restart re-runs the whole job and this fires
        again on the second success: an already-deleted target is a no-op.
        """
        con = _connect()
        job = con.execute("SELECT * FROM jobs WHERE id=?", (jid,)).fetchone()
        con.close()
        if job is None or not job["replace_path"]:
            return
        old_path = job["replace_path"]
        dest = os.path.join(job["dest_dir"], job["dest_name"])

        if os.path.normpath(old_path) == os.path.normpath(dest):
            self._update(jid, replace_path=None)
            self.log(f"job {jid} replaced {old_path} in place; nothing to delete")
            return

        if not os.path.exists(old_path):
            self._update(jid, replace_path=None)
            self.log(f"job {jid} replace target already gone: {old_path}")
            return

        src_files, src_bytes = _count_tree(job["src_real"])
        new_files, new_bytes = _count_tree(dest)
        if not new_files or src_files != new_files or src_bytes != new_bytes:
            self.log(f"job {jid} replace SKIPPED: copy did not verify "
                     f"(source {src_files} files/{src_bytes}B, "
                     f"copy {new_files} files/{new_bytes}B); {old_path} kept")
            return                      # replace_path stays set: the old item lives

        try:
            if os.path.isdir(old_path):
                shutil.rmtree(old_path)
            else:
                os.remove(old_path)
            self._update(jid, replace_path=None)
            self.log(f"job {jid} replaced: deleted {old_path}")
        except OSError as exc:
            self.log(f"job {jid} replace delete failed: {exc!r}; {old_path} kept")

    def _apply_pending_rename(self, jid: int) -> None:
        """Apply a deferred rename. Only on success: after a failure or a cancel the
        destination is partial or already deleted, so renaming it would just leave a
        confusingly-named remnant."""
        con = _connect()
        job = con.execute("SELECT * FROM jobs WHERE id=?", (jid,)).fetchone()
        con.close()
        if job is None or not job["rename_to"]:
            return
        src = os.path.join(job["dest_dir"], job["dest_name"])
        dest = os.path.join(job["dest_dir"], job["rename_to"])
        try:
            if os.path.exists(src) and not os.path.exists(dest):
                os.rename(src, dest)
                self._update(jid, dest_name=job["rename_to"], rename_to=None)
                self.log(f"job {jid} deferred rename applied: {job['rename_to']}")
                return
            reason = "target already exists" if os.path.exists(dest) else "source is gone"
            self.log(f"job {jid} deferred rename skipped: {reason}")
        except OSError as exc:
            self.log(f"job {jid} deferred rename failed: {exc!r}")
        self._update(jid, rename_to=None)

    def _cleanup_partial(self, job) -> str:
        """Delete what this job wrote, but never what it did not.

        dest_preexisted is recorded at enqueue precisely so a cancel cannot remove
        a destination that was already there.
        """
        if job["dest_preexisted"]:
            return ""
        dest = os.path.join(job["dest_dir"], job["dest_name"])
        removed = ""
        try:
            if job["is_dir"] and os.path.isdir(dest):
                shutil.rmtree(dest)
                removed = dest
            elif os.path.isfile(dest):
                os.remove(dest)
                removed = dest
            # rclone may leave a sidecar while a transfer is in flight.
            for extra in (dest + ".partial",):
                if os.path.isfile(extra):
                    os.remove(extra)
        except OSError as exc:
            self.log(f"partial cleanup failed for {dest}: {exc!r}")
        self._remove_breadcrumb(job)
        return removed

    @staticmethod
    def _remove_breadcrumb(job) -> None:
        """Drop the FTP front end's `<name>.QUEUED-j<id>` marker.

        The FTP path writes it so a refresh shows something real despite the phantom
        move (vfs.RelayFS._enqueue). It used to be removed ONLY by _cleanup_partial,
        i.e. only on cancel -- so every job that SUCCEEDED left its breadcrumb in the
        destination folder permanently. Called from every terminal branch now.
        The HTTP front end never writes one, so this is a harmless no-op there.
        """
        crumb = os.path.join(job["dest_dir"], f"{job['dest_name']}.QUEUED-j{job['id']}")
        try:
            os.remove(crumb)
        except OSError:
            pass

    def _update(self, jid, **fields):
        fields["updated_at"] = time.time()
        sets = ",".join(f"{k}=?" for k in fields)
        con = _connect()
        con.execute(f"UPDATE jobs SET {sets} WHERE id=?", (*fields.values(), jid))
        con.commit()
        con.close()

    # ---------- worker ----------

    @property
    def limit(self) -> int:
        with self._gate:
            return self._limit

    def set_limit(self, n: int) -> int:
        """Change how many transfers may run at once, live."""
        n = max(1, min(MAX_WORKERS, int(n)))
        with self._gate:
            self._limit = n
            self._gate.notify_all()          # let waiters through if it went up
        try:
            with open(LIMIT_FILE, "w") as f:
                f.write(str(n))
        except OSError as exc:
            self.log(f"could not persist concurrency limit: {exc!r}")
        self.log(f"concurrency limit set to {n}")
        return n

    def _worker(self):
        while True:
            with self._gate:
                # Wait for a free slot AND a job, then take the job while still
                # holding the gate.
                #
                # This used to dequeue FIRST and wait for a slot afterwards. That let
                # all eight workers grab eight job ids and then race for the one
                # slot, and Condition.notify() wakes an ARBITRARY waiter -- so the
                # order jobs actually started in was thread-wakeup order, not the
                # order they were queued. Measured against a standalone reproduction
                # of the old shape: 10 of 12 runs started out of order. Taking the
                # job under the gate makes it 12 of 12, because only one worker is
                # ever inside here at a time.
                #
                # Waiting for the job HERE, rather than parking on a blocking get()
                # while holding a slot, is what keeps a lowered limit honest: an idle
                # worker holding a slot let four jobs run at once under a limit of
                # one (also measured).
                #
                # Lowering the limit still takes effect as running jobs finish -- it
                # never interrupts one mid-copy.
                while self._running >= self._limit or self._q.empty():
                    self._gate.wait(timeout=1.0)
                try:
                    jid = self._q.get_nowait()
                except queue.Empty:
                    # Cannot happen while every consumer holds the gate, but a
                    # raise here would kill the worker thread for good.
                    continue
                self._running += 1
            with self._active_lock:
                self._active += 1
            try:
                self._run(jid)
            except Exception as exc:                     # never kill the worker
                self.log(f"job {jid} crashed: {exc!r}")
                self._update(jid, state="failed", error=str(exc)[:300],
                             finished_at=time.time())
            finally:
                with self._active_lock:
                    self._active -= 1
                with self._gate:
                    self._running -= 1
                    self._gate.notify()
                self._q.task_done()

    def _run(self, jid):
        con = _connect()
        job = con.execute("SELECT * FROM jobs WHERE id=?", (jid,)).fetchone()
        con.close()
        if job is None or job["state"] not in ("queued",):
            return

        dest = os.path.join(job["dest_dir"], job["dest_name"])
        # `rclone copy SRCDIR DSTDIR` copies SRCDIR's *contents* into DSTDIR, so
        # for a directory the basename must be repeated on the destination or a
        # torrent folder dumps loose files straight into the volume root.
        verb = "copy" if job["is_dir"] else "copyto"
        cmd = [
            "rclone", verb, job["src_remote"], dest,
            "--use-json-log", "--stats", "1s",
            # MANDATORY: rclone emits stats at INFO but defaults to NOTICE, so
            # without this the parser below sees zero progress records.
            "--stats-log-level", "NOTICE",
            "--transfers", "2", "--checkers", "4",
            "--buffer-size", "16M",
            "--multi-thread-streams", "4", "--multi-thread-cutoff", "512M",
            "--retries", "3", "--low-level-retries", "10",
        ]
        # What to do about files already at the destination. Chosen by the user in
        # the conflict sheet; "overwrite" is the default and matches the behaviour
        # this relay had before the sheet existed.
        policy = (job["on_conflict"] if "on_conflict" in job.keys() else None) or "overwrite"
        cmd += CONFLICT_FLAGS.get(policy, CONFLICT_FLAGS["overwrite"])
        with self._proc_lock:
            if jid in self._cancelled:
                self.log(f"job {jid} cancelled before it started")
                return
        self._update(jid, state="running", error=None)
        self.log(f"job {jid} start: {shlex.join(cmd)}")

        logpath = os.path.join(LOG_DIR, f"{jid}.log")
        # The size measured at enqueue, which walked the WHOLE source. Captured
        # before the loop because the stats updates below overwrite the column.
        planned_total = job["bytes_total"] or 0
        peak_done = 0
        with open(logpath, "w") as logf:
            logf.write(shlex.join(cmd) + "\n")
            logf.flush()
            with self._proc_lock:
                # Re-check under the lock: a cancel could have landed between the
                # check above and here, and it would have found no proc to signal.
                if jid in self._cancelled:
                    self.log(f"job {jid} cancelled before rclone spawned")
                    return
                # RCLONE_CONFIG_SEEDBOX_* rather than an rclone.conf, so a fresh
                # clone needs no file on disk to reach the seedbox.
                proc = subprocess.Popen(cmd, env=seedbox.env(), stdout=subprocess.DEVNULL,
                                        stderr=subprocess.PIPE, text=True,
                                        bufsize=1)
                self._procs[jid] = proc
            for line in proc.stderr:
                logf.write(line)
                logf.flush()
                rec = None
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                stats = rec.get("stats")
                if not stats:
                    continue
                done = stats.get("bytes") or 0
                total = stats.get("totalBytes") or 0
                speed = stats.get("speed") or 0
                eta = stats.get("eta") or 0
                files_done = stats.get("transfers") or 0
                files_total = stats.get("totalTransfers") or 0
                # A single-file job reads better from transferring[0]; the FINAL
                # record has no transferring array at all, which means
                # "finishing", not an error.
                tr = stats.get("transferring") or []
                if tr and not job["is_dir"]:
                    t = tr[0]
                    done = t.get("bytes") or done
                    total = t.get("size") or total
                    speed = t.get("speedAvg") or t.get("speed") or speed
                    eta = t.get("eta") or eta
                # rclone's totalBytes counts only what it has WALKED so far, so
                # early in a directory copy it equals what has already been
                # transferred. The previous fix clamped the PERCENTAGE monotonic,
                # which it achieved by writing bytes_done back as
                # `peak_pct * total` -- inventing a number rclone never reported.
                # The moment those two figures momentarily agreed, peak_pct stuck
                # at 100 and every later sample was rewritten to the full total, so
                # a 20-file release sat at "100.0% - 117.6G of 117.6G" while
                # reporting "file 14 of 20" and an ETA of 512s.
                #
                # Prefer the enqueue-time size: it walked the entire source and
                # does not grow, so the percentage cannot reach 100 early and needs
                # no clamp. max() covers a planned figure that turned out short,
                # and the fallback covers a source that could not be walked.
                if planned_total:
                    total = max(planned_total, total)
                # Clamp the REPORTED byte count instead, so a retry that restarts a
                # file cannot walk the bar backwards. Never exceeds something rclone
                # actually said.
                done = max(done, peak_done)
                peak_done = done
                self._update(jid, bytes_done=done, bytes_total=total,
                             speed=speed, eta=int(eta),
                             files_done=files_done, files_total=files_total)
            rc = proc.wait()
            with self._proc_lock:
                self._procs.pop(jid, None)
                cancelled = jid in self._cancelled
                self._cancelled.discard(jid)

        if cancelled:
            # cancel() already wrote state and cleaned up; do not overwrite it
            # with 'failed' just because rclone exited non-zero after SIGTERM.
            self.log(f"job {jid} exited after cancel (rc={rc})")
            return

        self._remove_breadcrumb(job)

        if rc == 0:
            # rclone has exited, so nothing holds the path any more.
            self._apply_pending_rename(jid)
            # After the rename, so a replace compares against the final name.
            self._apply_replace(jid)
            final = self._source_size(job["src_real"], bool(job["is_dir"]))
            self._update(jid, state="done", bytes_done=final or job["bytes_total"],
                         speed=0, eta=0, finished_at=time.time())
            self.log(f"job {jid} done")
        else:
            reason = self._last_error(logpath) or f"rclone exit {rc}"
            self._update(jid, state="failed", error=reason[:300],
                         rename_to=None, replace_path=None, finished_at=time.time())
            self.log(f"job {jid} failed: {reason}")

    @staticmethod
    def _last_error(logpath) -> str:
        try:
            with open(logpath) as f:
                tail = f.readlines()[-200:]
        except OSError:
            return ""
        for line in reversed(tail):
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("level") in ("error", "critical") and rec.get("msg"):
                return rec["msg"].strip()
        return ""
