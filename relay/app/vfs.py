"""The FTP-visible filesystem.

Everything lives under one real root (/srv/tree) on purpose: that lets
pyftpdlib's stock ftp2fs / fs2ftp / ftpnorm / validpath / realpath / chdir work
completely unmodified. A hand-written mount table would have been the most
path-traversal-prone part of this design, so it is avoided entirely.

Only two things are overridden: the write-side hooks that intercept a transfer
request, and listdir + lstat/stat so the two status folders can be synthetic.
"""

import errno
import io
import os
import re
import stat as statmod
import time

from pyftpdlib.filesystems import AbstractedFS, FilesystemError

import render

# Tree constants and the shared validation live in guards.py so both front ends
# (FTP here, HTTP in api.py) pass through one gate. Imported under their original
# private names so every existing call site in this file is unchanged.
import guards
from guards import (TREE, SEEDBOX, QUEUE, ACTIVE, DONE, STATUS_DIRS,
                    MIN_SRC_DEPTH,
                    under as _under,
                    drop_targets as _drop_targets,
                    to_virtual as fs2ftp_hint)

_JOB_ID_RE = re.compile(r"^\[j(\d+)\]")



def _job_id_from_name(name: str):
    """The job id out of a rendered status entry, or None.

    Cancel keys off THIS rather than an exact match on the rendered name, because
    a running job's name embeds live progress and changes every second: an entry
    listed a moment ago no longer matches, so name-based lookup fails exactly when
    a user is trying to stop something. The id prefix is stable.
    """
    m = _JOB_ID_RE.match(name)
    return int(m.group(1)) if m else None



class RelayFS(AbstractedFS):
    """Adds transfer interception and synthetic status listings."""

    jobs = None          # set by server.py
    log = staticmethod(print)

    def __init__(self, root, cmd_channel):
        super().__init__(root, cmd_channel)
        # Names rendered during the current LIST, so the lstat() calls that
        # follow listdir() see a consistent snapshot even though progress moves.
        self._synth_cache = {}

    # ------------------------------------------------------------------
    # Triggers
    # ------------------------------------------------------------------

    def rename(self, src, dst):
        """Primary trigger. FileZilla renders a same-server drag as RNFR+RNTO.

        pyftpdlib's ftp_RNTO calls straight through to here, so this is the
        cleanest seam. It must return FAST: FileZilla's timeout is 20s, so the
        copy is queued and performed asynchronously rather than inline.
        """
        dst_parent = os.path.dirname(os.path.normpath(dst))
        targets = _drop_targets()

        # 1. seedbox -> anywhere inside a queue drop target: the transfer request.
        #    Accepting SUBDIRECTORIES matters: a media library wants
        #    /queue/MediaVolume3/Movies, not the volume root. Requiring the parent
        #    to exist keeps a typo ("Movis") from silently creating a junk folder,
        #    since rclone would happily make it.
        if _under(src, SEEDBOX):
            if guards.resolve_drop_target(dst_parent, targets) is not None:
                # dest-exists, whole-library and name checks all happen in
                # guards.validate_request, called from _enqueue.
                self._enqueue(src, dst_parent, os.path.basename(dst))
                return

        # 2. Fallback A: rename in place to "Name@Volume".
        if _under(src, SEEDBOX):
            # Take the destination relative to the SOURCE's folder, not just its
            # basename: a rename to "Name@Vol/Sub" arrives as a path, so basename()
            # would yield "Sub" and lose the "@" entirely.
            src_parent = os.path.dirname(os.path.normpath(src))
            norm_dst = os.path.normpath(dst)
            base = (norm_dst[len(src_parent):].strip("/")
                    if norm_dst.startswith(src_parent) else os.path.basename(norm_dst))
            if "@" in base:
                # "Name@MediaVolume3" or "Name@MediaVolume3/Movies" -- a subpath is
                # allowed so this route is as capable as the drag. normpath plus the
                # under-a-drop-target check together block "@../.." traversal.
                name, _, rel = base.rpartition("@")
                target = os.path.normpath(os.path.join(QUEUE, rel))
                if guards.resolve_drop_target(target, targets) is not None:
                    self._enqueue(src, target, name or os.path.basename(src))
                    return
            raise FilesystemError(
                "seedbox is read-only; drag into /queue/<Volume> (or any folder inside it) "
                "to copy it to the NAS")

        # 3. A genuine local rename inside one drop target (same filesystem).
        for t in targets:
            if _under(src, t) and _under(dst, t):
                return os.rename(src, dst)

        # 4. Never os.rename across the volumes or off the FUSE mount: those are
        #    separate filesystems, so it would fail with EXDEV. That is the whole
        #    reason this relay exists.
        raise FilesystemError("cross-volume moves are not supported here")

    def mkdir(self, path):
        """Fallback B: MKD under /queue/<Volume> naming a seedbox path.

        Chosen over a zero-byte job file because FileZilla's 'Create directory'
        dialog accepts arbitrary text including slashes, so the source path is
        expressible in one dialog with no local file and no encoding scheme.

        Note MKD's semantics: 'a/b/c' means "create c inside a/b", so pyftpdlib
        hands over a fully resolved path. Everything AFTER the drop target is
        therefore treated as the source path, not just the basename.
        """
        norm = os.path.normpath(path)
        for target in _drop_targets():
            if norm != target and _under(norm, target):
                rel = norm[len(target):].strip("/")
                candidate = os.path.normpath(os.path.join(SEEDBOX, rel))
                if _under(candidate, SEEDBOX) and os.path.exists(candidate):
                    self._enqueue(candidate, target, os.path.basename(candidate))
                    return
                # A real subdirectory inside a drop target is still legitimate.
                break
        if _under(path, SEEDBOX):
            raise FilesystemError("seedbox is read-only")
        return os.mkdir(path)

    def _enqueue(self, src, dest_dir, dest_name):
        from jobs import JobError
        try:
            src, dest_dir, dest_name = guards.validate_request(src, dest_dir, dest_name)
            jid, _ = self.jobs.enqueue(src, dest_dir, dest_name)
        except JobError as exc:
            # guards and jobs both speak JobError; 550 is this front end's dialect.
            raise FilesystemError(str(exc))
        # Breadcrumb so refreshing the destination shows something real
        # immediately -- FileZilla will otherwise show a file that does not
        # exist yet (see "the phantom move" in the plan).
        try:
            with open(os.path.join(dest_dir, f"{dest_name}.QUEUED-j{jid}"), "w") as f:
                f.write(f"queued {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        except OSError:
            pass

    # ------------------------------------------------------------------
    # Protect the seedbox (and therefore seeding)
    # ------------------------------------------------------------------

    def remove(self, path):
        """DELE. On a status entry this is the cancel gesture.

        Deleting the job out of /queue/_active reads naturally as "stop this", and
        it is the only cancel FileZilla can express without a custom command --
        right-click -> Delete on the running job. On a finished entry it just
        clears the row out of the _done listing.
        """
        norm = os.path.normpath(path)
        parent = os.path.dirname(norm)
        if parent in STATUS_DIRS and self.jobs is not None:
            from jobs import JobError
            jid = _job_id_from_name(os.path.basename(norm))
            if jid is None:
                raise FilesystemError("not a job entry")
            try:
                # _active cancels; _done just clears the row from the listing.
                msg = (self.jobs.cancel(jid) if parent == ACTIVE
                       else self.jobs.dismiss(jid))
            except JobError as exc:
                raise FilesystemError(str(exc))
            # The rendered name embeds live progress, so any cached entry for this
            # job is now stale and would otherwise resolve to the old row.
            self._synth_cache.clear()
            self.log_info(f"j{jid}: {msg}")
            return

        self._deny_seedbox(path)
        if os.path.normpath(path) in STATUS_DIRS:
            raise FilesystemError("that is a status folder, not a file")
        return os.remove(path)

    def rmdir(self, path):
        self._deny_seedbox(path)
        if os.path.normpath(path) in STATUS_DIRS:
            raise FilesystemError("_active and _done are status folders and cannot be removed")
        return os.rmdir(path)

    def log_info(self, msg):
        """Best-effort note into the relay log; never break a command over it."""
        try:
            print(msg, flush=True)
        except Exception:
            pass

    def open(self, filename, mode):
        synth = self._synth(filename)
        if synth is not None and "r" in mode and "+" not in mode:
            # Downloading a status entry hands back that job's rclone log, which
            # is the cheapest possible failure diagnosis.
            return self._log_stream(synth)
        if any(m in mode for m in ("w", "a", "+", "x")):
            self._deny_seedbox(filename)
        return super().open(filename, mode)

    @staticmethod
    def _deny_seedbox(path):
        if _under(path, SEEDBOX):
            # The bind is read-only so the kernel would refuse anyway, but this
            # returns a clean 550 instead of an EROFS traceback -- and it is the
            # belt-and-braces guard that keeps the torrent seeding.
            raise FilesystemError("seedbox is mounted read-only")

    @staticmethod
    def _log_stream(job):
        path = os.path.join("/data/logs", f"{job['id']}.log")
        try:
            with open(path, "rb") as f:
                data = f.read()[-262144:]
        except OSError:
            data = b"(no log yet)\n"
        return io.BytesIO(data)

    # ------------------------------------------------------------------
    # Synthetic status listings
    # ------------------------------------------------------------------

    def _rows_for(self, directory):
        if self.jobs is None:
            return []
        if directory == ACTIVE:
            return self.jobs.snapshot("queued", "running")
        return self.jobs.recent_finished()

    def _synth(self, path):
        """The job behind a synthetic entry, or None."""
        path = os.path.normpath(path)
        parent = os.path.dirname(path)
        if parent not in STATUS_DIRS:
            return None
        name = os.path.basename(path)
        hit = self._synth_cache.get(path)
        if hit is not None:
            return hit
        for row in self._rows_for(parent):
            if render.render(row) == name:
                job = dict(row)
                self._synth_cache[path] = job
                return job
        return None

    def listdir(self, path):
        p = os.path.normpath(path)
        if p in STATUS_DIRS:
            names = []
            for row in self._rows_for(p):
                name = render.render(row)
                names.append(name)
                self._synth_cache[os.path.join(p, name)] = dict(row)
            return names
        return super().listdir(path)

    def _synth_stat(self, job):
        # A real os.stat_result built from a 10-tuple, so stat.filemode() and
        # st_nlink behave and the formatters need no special-casing.
        # st_size = bytes done so FileZilla's own Filesize column tracks
        # progress too, and st_mtime ticks so does Last-modified.
        size = int(job.get("bytes_done") or 0)
        mtime = int(job.get("updated_at") or time.time())
        return os.stat_result((
            statmod.S_IFREG | 0o444,        # mode
            0x7000_0000 + int(job["id"]),   # stable synthetic inode
            0, 1, 1000, 10, size, mtime, mtime, mtime))

    def lstat(self, path):
        job = self._synth(path)
        if job is not None:
            # format_list/format_mlsx default to ignore_err=True, which SILENTLY
            # swallows an exception here and just drops the entry -- the symptom
            # is an empty _active with no error anywhere. So log our own.
            try:
                return self._synth_stat(job)
            except Exception as exc:
                self.log(f"synthetic lstat failed for {path}: {exc!r}")
                raise OSError(errno.EIO, "synthetic stat failed")
        return super().lstat(path)

    def stat(self, path):
        job = self._synth(path)
        if job is not None:
            return self.lstat(path)
        return super().stat(path)

    def isdir(self, path):
        return False if self._synth(path) is not None else super().isdir(path)

    def isfile(self, path):
        return True if self._synth(path) is not None else super().isfile(path)

    def islink(self, path):
        # Critical: format_list calls readlink() on anything claiming to be a
        # link and appends " -> target", which would mangle every entry.
        return False if self._synth(path) is not None else super().islink(path)

    def lexists(self, path):
        return True if self._synth(path) is not None else super().lexists(path)

    def getsize(self, path):
        job = self._synth(path)
        return int(job.get("bytes_done") or 0) if job else super().getsize(path)

    def getmtime(self, path):
        job = self._synth(path)
        return float(job.get("updated_at") or time.time()) if job else super().getmtime(path)
