"""HTTP front end for the relay, driven by the Shuttle Mac app.

A SECOND CALLER of the same choke point, never a second implementation: every
enqueue goes through guards.validate_request, exactly as the FTP path does. If you
add an endpoint that starts a job, it routes through there too.

Stdlib only (http.server + json + sqlite via jobs) so the image needs no new pip
deps and app/ stays bind-mounted -- a change here is `docker compose restart`.

Two deliberate differences from the sibling daemon this is modelled on
(spotidal-sync/app/downloader_daemon.py): the bearer token is MANDATORY, and the
listener binds the tailnet address rather than 0.0.0.0. This API can write into
/volume1/Media; neither is negotiable.

Paths on the wire are VIRTUAL (/seedbox/..., /queue/...), never container paths.
That keeps one vocabulary shared with the README, the FTP 550 messages and the
FileZilla site, and makes guards.to_real the single audited entry point.
"""

import datetime
import hashlib
import heapq
import hmac
import json
import os
import shutil
import re
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import guards
import jobs
import seedbox
from jobs import JobError

PORT = int(os.environ.get("RELAY_API_PORT", "8789"))
# Default to the FTP bind so the API can never accidentally end up on 0.0.0.0
# unless FTP already is.
BIND = os.environ.get("RELAY_API_BIND") or os.environ.get("FTP_BIND_ADDR", "127.0.0.1")
LOG_DIR = os.environ.get("RELAY_LOG_DIR", "/data/logs")

MAX_BODY = 64 * 1024
BROWSE_LIMIT_DEFAULT = 1000
BROWSE_LIMIT_MAX = 5000
LOG_TAIL_DEFAULT = 262144

# Search caps. The limit is about PAYLOAD, not speed: a query for "a" matches
# 87,229 of the 270,516 entries under /queue, and 1000 rows already serialises to
# ~294KB. 500 is far more than anyone scans and weighs ~146KB.
SEARCH_LIMIT_DEFAULT = 500
SEARCH_LIMIT_MAX = 2000
SEARCH_MIN_QUERY = 2
# A backstop, not a budget. Measured on this NAS: a COLD walk of the whole tree
# is 7.44s (MediaVolume3 alone, 251k entries, is 7.32s of it) and a warm one is
# 0.44s -- but a genuinely cold walk inside the relay process was MEASURED
# exceeding 30s once, so this is a stop-and-report threshold, not a promise. When
# it fires the response says `timed_out`, which is NOT the same as "no matches";
# conflating those two made a timeout look like an empty library.
SEARCH_SECONDS = 25.0
# The remote side is a different animal: one rclone recursive listing over FTP,
# measured at 18.9s with no warm case. Its own budget, because forcing it under the
# local walk's 25s would fail a search that was working perfectly.
SEEDBOX_SEARCH_TIMEOUT = 120

# A cold FUSE listing blocks ~1.2s. ThreadingHTTPServer would otherwise spawn a
# thread per request without bound, and a client hammering browse during a stale
# mount would pile up threads all stuck in a syscall.
_browse_slots = threading.BoundedSemaphore(8)

# Search gets its OWN budget rather than sharing the browse one. The comment above
# is about cold FUSE listings piling up; a search is an all-local walk with a
# completely different cost profile, and there is no client-side retry for a browse
# 503 -- so a user typing in the search field must not be able to make the
# directory tree fail. 2, because the only real concurrency is an abandoned search
# still draining while its replacement starts.
_search_slots = threading.BoundedSemaphore(2)
# Downloads to a Mac. Capped low for the same reason as searches: each seedbox
# fetch holds an FTP connection open for the whole transfer, and the seedbox has
# far fewer of those than this relay has threads.
_fetch_slots = threading.BoundedSemaphore(4)

_JOB_RE = re.compile(r"^/v1/jobs/(\d+)(?:/(cancel|dismiss|log|verify|retry))?$")

# Columns never sent to a client: src_remote leaks the rclone remote name and the
# client has no use for it.
_DROP_FIELDS = ("src_real", "src_remote")


def _job_json(row):
    j = {k: v for k, v in row.items() if k not in _DROP_FIELDS}
    j["src"] = guards.to_virtual(row["src_real"])
    j["dest_dir"] = guards.to_virtual(row["dest_dir"])
    j["is_dir"] = bool(row["is_dir"])
    j["dest_preexisted"] = bool(row["dest_preexisted"])
    # Virtual, never the container path. Still set on a DONE job means the old item
    # was deliberately kept because the copy did not verify.
    j["replace_path"] = (guards.to_virtual(row["replace_path"])
                         if "replace_path" in row.keys() and row["replace_path"]
                         else None)
    # Computed here, not client-side, so the two front ends cannot disagree --
    # and because rclone's own transferring[].percentage is an int that FLOORS
    # (see render.py: it reads 0 while 34MB of 86GB is done).
    total = row["bytes_total"] or 0
    done = row["bytes_done"] or 0
    j["percent"] = round(100.0 * done / total, 2) if total else 0.0
    return j


class _SeedboxListed(Exception):
    """Internal: the seedbox branch already produced `rows`."""


def _parse_rfc3339(v):
    """rclone emits RFC3339 with fractional seconds; the wire format here is epoch."""
    if not v:
        return None
    try:
        from datetime import datetime
        return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        return None


def _search_tree(roots, needle, limit, hidden, deadline):
    """-> (entries, total, timed_out). Recursive name match over local volumes.

    `heapq.nsmallest` over a generator rather than "collect the first `limit`
    hits". That is not a micro-optimisation, it is correctness: the roots are
    walked in order, so taking the first 500 returns 500 rows from whichever
    volume sorts first and NONE from the others. Measured before this fix -- a
    500-row search for "1080p" came back 500/500 from `Media`, with nothing at all
    from MediaVolume3, which holds most of the library.

    The generator yields cheap tuples and stats nothing; only the survivors are
    stat'd, so a 7,000-hit query pays 500 stats rather than 7,000.
    """
    counted = [0]
    timed_out = [False]

    def candidates():
        for root in sorted(roots):
            if timed_out[0]:
                return
            if not os.path.isdir(root):
                continue          # drop_targets() adds _scratch unconditionally
            stack = [root]
            while stack:
                if time.monotonic() > deadline:
                    timed_out[0] = True
                    return        # return, not break: break only leaves ONE root
                current = stack.pop()
                try:
                    with os.scandir(current) as it:
                        for e in it:
                            if not hidden and e.name.startswith("."):
                                continue
                            try:
                                # follow_symlinks=False: guards.under() is a string
                                # prefix test, not realpath, so descending a link
                                # could walk clean out of the tree.
                                is_dir = e.is_dir(follow_symlinks=False)
                            except OSError:
                                is_dir = False
                            if is_dir:
                                stack.append(e.path)
                            if needle not in e.name.casefold():
                                continue
                            counted[0] += 1
                            # Path is the tiebreak, and it is load-bearing: plenty of
                            # files share a name across folders, and without it the
                            # top-N window differs between two identical calls.
                            yield (not is_dir, e.name.casefold(),
                                   e.path.casefold(), e.name, e.path, is_dir)
                except OSError:
                    continue      # unreadable directory: skip, keep searching

    best = heapq.nsmallest(limit, candidates())

    entries = []
    for _, _, _, name, real, is_dir in best:
        size = mtime = None
        try:
            st = os.stat(real, follow_symlinks=False)
            mtime = st.st_mtime
            if not is_dir:
                size = st.st_size
        except OSError:
            pass
        entries.append({"name": name, "path": guards.to_virtual(real),
                        "is_dir": is_dir, "size": size, "mtime": mtime})
    return entries, counted[0], timed_out[0]


def _search_seedbox(needle, limit, hidden):
    """-> (entries, total, timed_out). Name search over the remote side.

    A completely different shape from the NAS walk and deliberately so. The NAS is
    a local disk, so it is walked directly. The seedbox is reached over FTP, where
    walking it ourselves would be a round trip per directory -- so rclone does the
    whole recursive listing in ONE call and the filtering happens here.

    Measured: 737 entries in 18.9s, the same on a repeat. There is no warm case to
    optimise for, which is why the app shows a spinner and searches on submit.
    """
    items = seedbox.walk_all(timeout=SEEDBOX_SEARCH_TIMEOUT)
    rows = []
    total = 0
    for it in items:
        name = it.get("Name") or ""
        rel = it.get("Path") or ""
        if not name:
            continue
        # Hidden applies to any component, so a file inside a dot-directory stays
        # hidden -- the same rule the local walk gets by never descending.
        if not hidden and any(part.startswith(".") for part in rel.split("/")):
            continue
        if needle not in name.casefold():
            continue
        total += 1
        is_dir = bool(it.get("IsDir"))
        real = os.path.join(jobs.SEEDBOX_MOUNT, rel)
        rows.append((not is_dir, name.casefold(), real.casefold(),
                     {"name": name, "path": guards.to_virtual(real),
                      "is_dir": is_dir,
                      "size": None if is_dir else it.get("Size"),
                      "mtime": _rclone_mtime(it.get("ModTime"))}))
    rows.sort(key=lambda r: (r[0], r[1], r[2]))
    return [r[3] for r in rows[:limit]], total, False


def _rclone_mtime(stamp):
    """rclone's RFC3339 timestamp -> epoch seconds, or None."""
    if not stamp:
        return None
    try:
        return datetime.datetime.fromisoformat(
            stamp.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _walk_count(path):
    files = 0
    size = 0
    if os.path.isfile(path):
        return 1, os.path.getsize(path)
    for root, _dirs, names in os.walk(path):
        for n in names:
            try:
                size += os.path.getsize(os.path.join(root, n))
                files += 1
            except OSError:
                pass
    return files, size


class Handler(BaseHTTPRequestHandler):
    jobs = None
    token = ""
    log = staticmethod(print)

    # Keep-alive: the app polls at 1 Hz and would otherwise pay a TCP handshake
    # every second. Requires Content-Length on every response, which _send sets.
    protocol_version = "HTTP/1.1"
    server_version = "seedbox-relay/1"

    # ---------- plumbing ----------

    def log_message(self, fmt, *args):
        pass                                    # quiet the default request spam

    def _send(self, code, obj, ctype="application/json", raw=None):
        body = raw if raw is not None else json.dumps(obj).encode()
        try:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # The app cancels in-flight polls when the window closes; an unhandled
            # one becomes a traceback in the container log on every close.
            pass

    def _fail(self, code, msg, extra=None):
        if code >= 400:
            self.log(f"api {code} {self.command} {self.path} :: {msg}")
        body = {"error": msg}
        # `extra` carries the facts a caller needs to ANSWER a refusal rather
        # than merely report it -- the 409 from a move says which name is taken.
        if extra:
            body.update(extra)
        self._send(code, body)

    def _authed(self):
        # compare_digest so a wrong token cannot be recovered a byte at a time
        # from response timing.
        return hmac.compare_digest(self.headers.get("Authorization", ""),
                                   "Bearer " + self.token)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > MAX_BODY:
            raise JobError("request body too large")
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode() or "{}")
        except (ValueError, UnicodeDecodeError):
            raise JobError("bad json")

    def _q(self):
        return urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)

    def _qi(self, q, key, default, lo=None, hi=None):
        try:
            v = int(q.get(key, [default])[0])
        except (TypeError, ValueError):
            v = default
        if lo is not None:
            v = max(lo, v)
        if hi is not None:
            v = min(hi, v)
        return v

    # ---------- routing ----------

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/healthz":
            return self._health()                # before auth, on purpose
        if not self._authed():
            return self._fail(401, "unauthorized")
        try:
            if path == "/v1/browse":
                return self._browse()
            if path == "/v1/search":
                return self._search()
            if path == "/v1/targets":
                return self._targets()
            if path == "/v1/settings":
                return self._settings()
            if path == "/v1/seedbox":
                return self._send(200, seedbox.public())
            if path == "/v1/stat":
                return self._stat()
            if path == "/v1/manifest":
                return self._manifest()
            if path == "/v1/fetch":
                return self._fetch()
            if path == "/v1/jobs":
                return self._jobs()
            m = _JOB_RE.match(path)
            if m and m.group(2) in (None, "log", "verify"):
                jid, sub = int(m.group(1)), m.group(2)
                if sub == "log":
                    return self._job_log(jid)
                if sub == "verify":
                    return self._verify(jid)
                return self._job(jid)
        except JobError as exc:
            return self._fail(400, str(exc))
        except Exception as exc:                 # never leak a traceback
            self.log(f"api 500 GET {self.path}: {exc!r}")
            return self._fail(500, "internal error")
        self._fail(404, "not found")

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path
        if not self._authed():
            return self._fail(401, "unauthorized")
        try:
            if path == "/v1/jobs":
                return self._enqueue()
            if path == "/v1/rename":
                return self._rename()
            if path == "/v1/delete":
                return self._delete()
            if path == "/v1/move":
                return self._move()
            if path == "/v1/mkdir":
                return self._mkdir()
            if path == "/v1/settings":
                return self._set_settings()
            if path == "/v1/seedbox":
                return self._set_seedbox()
            m = _JOB_RE.match(path)
            if m and m.group(2) == "retry":
                return self._retry(int(m.group(1)))
            if m and m.group(2) in ("cancel", "dismiss"):
                return self._job_action(int(m.group(1)), m.group(2))
        except JobError as exc:
            return self._fail(400, str(exc))
        except Exception as exc:
            self.log(f"api 500 POST {self.path}: {exc!r}")
            return self._fail(500, "internal error")
        self._fail(404, "not found")

    # ---------- endpoints ----------

    def _health(self):
        self._send(200, {"ok": True, "service": "seedbox-ftp-relay", "api": 1,
                         "jobs_active": len(self.jobs.snapshot("queued", "running"))})

    def _browse(self):
        q = self._q()
        virtual = q.get("path", ["/seedbox/downloads"])[0]
        real = guards.to_real(virtual)
        offset = self._qi(q, "offset", 0, lo=0)
        limit = self._qi(q, "limit", BROWSE_LIMIT_DEFAULT, lo=1, hi=BROWSE_LIMIT_MAX)
        want_stat = q.get("stat", ["1"])[0] != "0"
        hidden = q.get("hidden", ["0"])[0] == "1"

        seedbox_stats = None
        if not _browse_slots.acquire(blocking=False):
            return self._fail(503, "busy: too many directory listings in flight")
        try:
            # The /queue root is built from the GUARD's view, not os.listdir, so the
            # browser can only ever show a destination validate_request would accept
            # -- _active and _done are real directories that would otherwise appear.
            if os.path.normpath(real) == guards.QUEUE:
                names = sorted(os.path.basename(t) for t in guards.drop_targets())
                rows = [(n, True) for n in names]
            elif guards.under(real, guards.SEEDBOX):
              try:
                # Straight from the seedbox over rclone -- NOT through the FUSE
                # mirror. The mirror only ever existed so FileZilla had a POSIX
                # filesystem to list; this API does not need one, and transfers
                # never used it either (jobs.py runs `rclone copy seedbox:...`).
                alias_root = os.path.join(guards.SEEDBOX, seedbox.ROOT_ALIAS)
                norm = os.path.normpath(real)
                if norm == guards.SEEDBOX:
                    # /seedbox itself holds exactly one thing: the alias for the
                    # remote root. Synthesised, because the seedbox has no such dir.
                    rows = [(seedbox.ROOT_ALIAS, True)]
                    seedbox_stats = {seedbox.ROOT_ALIAS: (None, None)}
                    raise _SeedboxListed
                if not guards.under(norm, alias_root):
                    return self._fail(404, f"no such folder: {guards.to_virtual(real)}")
                rel = os.path.relpath(norm, alias_root)
                if rel == ".":
                    rel = ""
                try:
                    listing = seedbox.lsjson(rel)
                except seedbox.SeedboxError as exc:
                    return self._fail(502, str(exc))
                rows = []
                stats = {}
                for e in listing:
                    name = e.get("Name") or ""
                    if not name or (not hidden and name.startswith(".")):
                        continue
                    is_dir = bool(e.get("IsDir"))
                    rows.append((name, is_dir))
                    stats[name] = (None if is_dir else e.get("Size"), e.get("ModTime"))
                seedbox_stats = stats
              except _SeedboxListed:
                pass
            else:
                if not os.path.isdir(real):
                    return self._fail(404, f"no such folder: {guards.to_virtual(real)}")
                rows = []
                with os.scandir(real) as it:
                    for e in it:
                        if not hidden and e.name.startswith("."):
                            continue
                        try:
                            rows.append((e.name, e.is_dir()))
                        except OSError:
                            rows.append((e.name, False))
            # Sort BEFORE slicing so paging is stable.
            rows.sort(key=lambda r: (not r[1], r[0].lower()))
            total = len(rows)
            page = rows[offset:offset + limit]

            entries = []
            for name, is_dir in page:
                item = {"name": name,
                        "path": guards.to_virtual(os.path.join(real, name)),
                        "is_dir": is_dir, "size": None, "mtime": None}
                if want_stat and seedbox_stats is not None:
                    size, mod = seedbox_stats.get(name, (None, None))
                    item["size"] = size
                    item["mtime"] = _parse_rfc3339(mod)
                elif want_stat:
                    try:
                        st = os.stat(os.path.join(real, name))
                        item["size"] = None if is_dir else st.st_size
                        item["mtime"] = st.st_mtime
                    except OSError:
                        pass
                entries.append(item)
        except OSError as exc:
            return self._fail(503, f"cannot read that folder: {exc.strerror or exc!r}")
        finally:
            _browse_slots.release()

        parent = guards.to_virtual(os.path.dirname(os.path.normpath(real)))
        self._send(200, {"path": guards.to_virtual(os.path.normpath(real)),
                         "parent": None if os.path.normpath(real) == guards.TREE else parent,
                         "entries": entries, "total": total, "offset": offset,
                         "limit": limit, "truncated": total > offset + limit})

    def _search(self):
        """Recursive name search across the NAS destination volumes.

        Whole-tree and live: every drop target is a LOCAL ext4 bind, so the whole
        library is one walk rather than a round trip per directory. That is what
        makes an index unnecessary -- and it is only true on THIS side. The seedbox
        is rclone over FTP, where the same walk would be thousands of round trips,
        which is why there is no search for it.

        Measured: 0.44-0.52s warm. Cold is far worse and has been seen past 25s,
        so the app searches on submit, not as you type.
        """
        params = self._q()                     # NOT `q`: that is the search term
        needle = (params.get("q", [""])[0] or "").strip()
        if len(needle) < SEARCH_MIN_QUERY:
            raise JobError(f"search needs at least {SEARCH_MIN_QUERY} characters")
        if "\x00" in needle:
            raise JobError("bad search text")
        limit = self._qi(params, "limit", SEARCH_LIMIT_DEFAULT,
                         lo=1, hi=SEARCH_LIMIT_MAX)
        hidden = params.get("hidden", ["0"])[0] == "1"
        side = params.get("side", ["nas"])[0]
        if side not in ("nas", "seedbox"):
            raise JobError("side must be nas or seedbox")

        if not _search_slots.acquire(blocking=False):
            return self._fail(503, "busy: a search is already running")
        began = time.monotonic()
        try:
            if side == "seedbox":
                entries, total, timed_out = _search_seedbox(
                    needle.casefold(), limit, hidden)
            else:
                entries, total, timed_out = _search_tree(
                    guards.drop_targets(), needle.casefold(), limit, hidden,
                    began + SEARCH_SECONDS)
        except seedbox.SeedboxError as exc:
            raise JobError(str(exc))
        finally:
            _search_slots.release()

        ms = int((time.monotonic() - began) * 1000)
        self.log(f"api search[{side}] {needle!r}: {len(entries)} of {total} in {ms}ms"
                 + (" (TIMED OUT)" if timed_out else ""))
        self._send(200, {"query": needle, "side": side,
                         "entries": entries, "total": total,
                         "limit": limit,
                         # Two distinct facts. `truncated` means "more matched than
                         # we returned"; `timed_out` means "we stopped early and the
                         # count itself is incomplete". Collapsing them made a
                         # timeout render as an empty library.
                         "truncated": total > len(entries),
                         "timed_out": timed_out,
                         "elapsed_ms": ms})

    def _targets(self):
        out = []
        for real in sorted(guards.drop_targets()):
            free = None
            try:
                st = os.statvfs(real)
                free = st.f_bavail * st.f_frsize
            except OSError:
                pass
            name = os.path.basename(real)
            out.append({"name": name, "path": guards.to_virtual(real),
                        "free_bytes": free,
                        # _scratch is the stack's own data/test bind, so its free
                        # space is the docker volume's, not a media volume's.
                        "is_test_target": name == "_scratch",
                        "exists": os.path.isdir(real)})
        self._send(200, {"targets": out})

    def _enqueue(self):
        body = self._body()
        src_v = body.get("src")
        dest_v = body.get("dest_dir")
        if not src_v or not dest_v:
            raise JobError("src and dest_dir are required")
        src = guards.to_real(src_v)
        dest_dir = guards.to_real(dest_v)
        dest_name = body.get("dest_name") or os.path.basename(os.path.normpath(src))
        # `replace`: an item to delete once this copy has landed AND verified.
        # Validated HERE, at enqueue, through the same guard a direct delete uses --
        # so a target outside a drop target, a volume root, or a seedbox path is
        # refused before a hundred-gigabyte transfer rather than after it.
        replace_real = None
        if body.get("replace"):
            replace_real = guards.to_real(body["replace"])
            # NAS only, explicitly. validate_delete PERMITS seedbox paths now that
            # the app can delete there, so it would happily accept a replace that
            # removes the source -- which is a move, not a replace, and would break
            # whatever torrent is seeding it. Caught in testing: the only thing that
            # stopped it was the mount being read-only, which is luck, not a design.
            if guards.under(replace_real, guards.SEEDBOX):
                raise JobError("replace removes something on the NAS; "
                               "it cannot target the seedbox")
            replace_real = guards.validate_delete(replace_real)

        # The same gate the FTP path uses. Deliberately no breadcrumb file: that
        # exists only to paper over FileZilla's phantom move, and the app has real
        # job state, so writing one here would just litter the destination.
        src, dest_dir, dest_name = guards.validate_request(src, dest_dir, dest_name)

        # FileZilla's "Target file already exists" gate. Without a policy the
        # enqueue is REFUSED with 409 and the conflict list, so the app can ask
        # rather than silently overwriting -- which is what this relay did before.
        # A policy of "rename" needs no scan: the caller has already changed
        # dest_name, so by definition there is nothing to collide with.
        import jobs as jobsmod
        policy = (body.get("on_conflict") or "ask").strip()
        if policy not in jobsmod.CONFLICT_POLICIES:
            raise JobError("unknown on_conflict: " + policy)
        if policy == "ask":
            conflicts, truncated = jobsmod.scan_conflicts(src, dest_dir, dest_name)
            if conflicts:
                self.log(f"api 409 conflict: {len(conflicts)} file(s) already in "
                         f"{guards.to_virtual(dest_dir)}/{dest_name}")
                return self._send(409, {
                    "error": "target files already exist",
                    "dest_name": dest_name,
                    "conflicts": conflicts,
                    "truncated": truncated,
                })
            policy = "overwrite"
        elif policy == "rename":
            policy = "overwrite"

        jid, created = self.jobs.enqueue(src, dest_dir, dest_name, on_conflict=policy,
                                         replace_path=replace_real)
        if not created:
            # 200, not 201: nothing was created. The app says so rather than
            # implying a second copy was queued.
            self.log(f"api duplicate: {dest_name} -> {guards.to_virtual(dest_dir)} "
                     f"is already job {jid}")
            return self._send(200, {"id": jid, "duplicate": True})
        self.log(f"api enqueued job {jid}: {dest_name} -> {guards.to_virtual(dest_dir)} "
                 f"[on_conflict={policy}]")
        self._send(201, {"id": jid})

    def _set_seedbox(self):
        """Save the seedbox connection, then PROVE it works before answering ok.

        Testing here rather than in the client is deliberate: the NAS is the thing
        that has to reach the seedbox, so a test from the Mac would prove nothing
        about whether transfers will run.
        """
        body = self._body()
        try:
            saved = seedbox.save(
                body.get("protocol"), body.get("host"), body.get("port"),
                body.get("user"), body.get("password"), body.get("root"))
        except seedbox.SeedboxError as exc:
            raise JobError(str(exc))
        try:
            probe = seedbox.test()
        except seedbox.SeedboxError as exc:
            # Keep what was saved -- a typo is easier to fix by editing one field
            # than by retyping the whole form -- but say plainly that it failed.
            return self._send(502, {"error": str(exc), "seedbox": saved, "ok": False})
        self.log(f"seedbox configured: {saved['protocol']}://{saved['host']}:{saved['port']} "
                 f"({probe['entries']} entries at root)")
        self._send(200, {"seedbox": saved, "ok": True, "probe": probe})

    def _stat(self):
        """Size and file count for one path, so the delete sheet can show what is
        at stake before anything is removed."""
        virtual = self._q().get("path", [None])[0]
        if not virtual:
            raise JobError("path is required")
        real = guards.to_real(virtual)
        if not os.path.exists(real):
            return self._fail(404, f"no such item: {guards.to_virtual(real)}")
        files, size = _walk_count(real)
        self._send(200, {"path": guards.to_virtual(real),
                         "is_dir": os.path.isdir(real),
                         "files": files, "bytes": size})

    # ---------- reading bytes out, for a destination this relay cannot write to ----------

    def _seedbox_rel(self, real):
        """The remote-relative path for a /seedbox/... real path, or None if it is
        not one. Mirrors the arithmetic `_browse` does."""
        norm = os.path.normpath(real)
        if not guards.under(norm, guards.SEEDBOX):
            return None
        alias_root = os.path.join(guards.SEEDBOX, seedbox.ROOT_ALIAS)
        if not guards.under(norm, alias_root):
            raise JobError(f"no such folder: {guards.to_virtual(real)}")
        rel = os.path.relpath(norm, alias_root)
        return "" if rel == "." else rel

    def _manifest(self):
        """A path flattened to the files it contains, with sizes.

        The Mac needs this because it fetches one file at a time: a release folder
        has to become a list before any of it can be asked for, and the total is
        what makes a progress bar honest rather than a spinner.
        """
        virtual = self._q().get("path", [None])[0]
        if not virtual:
            raise JobError("path is required")
        real = guards.validate_fetch(guards.to_real(virtual))
        rel = self._seedbox_rel(real)

        if rel is not None:
            base = os.path.basename(real)
            try:
                # `--files-only` on a FILE is an rclone error, not an empty list, so
                # a plain file has to be sized from its parent's listing instead.
                entries = seedbox.walk_files(rel)
            except seedbox.SeedboxError:
                entries = []
            if not entries:
                try:
                    info = seedbox.lsjson(os.path.dirname(rel))
                except seedbox.SeedboxError as exc:
                    return self._fail(502, f"seedbox: {exc}")
                match = next((e for e in info if e.get("Name") == base), None)
                if match is None:
                    return self._fail(404, f"no such item: {virtual}")
                if not match.get("IsDir"):
                    size = int(match.get("Size") or 0)
                    return self._send(200, {"path": virtual, "is_dir": False,
                                            "files": [{"rel": base, "size": size}],
                                            "bytes": size})
            # walk_files normalises to lowercase keys; rclone's own are capitalised.
            files = [{"rel": e["path"], "size": int(e.get("size") or 0)}
                     for e in entries]
            is_dir = True
        elif os.path.isdir(real):
            is_dir = True
            files = []
            for root, _dirs, names in os.walk(real):
                for n in sorted(names):
                    full = os.path.join(root, n)
                    if os.path.islink(full) or not os.path.isfile(full):
                        continue
                    files.append({"rel": os.path.relpath(full, real),
                                  "size": os.path.getsize(full)})
        elif os.path.isfile(real):
            is_dir = False
            files = [{"rel": os.path.basename(real), "size": os.path.getsize(real)}]
        else:
            return self._fail(404, f"no such item: {virtual}")

        self._send(200, {"path": guards.to_virtual(real),
                         "is_dir": is_dir,
                         "files": files,
                         "bytes": sum(f["size"] for f in files)})

    def _fetch(self):
        """One file's bytes.

        Read-only, and the ONLY way anything leaves this relay as content rather
        than metadata. A seedbox path is piped straight from `rclone cat` -- never
        staged on the NAS disk, so a 24 GB pull costs no space here.

        CONTRACT: the path must be a FILE. On the NAS that is checked, because
        `os.path.isfile` is free. On the seedbox it is NOT, because the only way to
        ask is an `lsjson --stat` round trip -- ~0.4s each over FTP, which a
        fifty-file release would pay fifty times for a question the caller has
        already answered. `/v1/manifest` is what turns a directory into file paths,
        and callers are expected to fetch only what it listed. Handing this a remote
        directory concatenates it rather than refusing.
        """
        virtual = self._q().get("path", [None])[0]
        if not virtual:
            raise JobError("path is required")
        real = guards.validate_fetch(guards.to_real(virtual))
        rel = self._seedbox_rel(real)

        if not _fetch_slots.acquire(blocking=False):
            return self._fail(503, "busy: too many downloads in flight")
        try:
            if rel is not None:
                try:
                    self._stream_remote(rel)
                except seedbox.SeedboxError as exc:
                    return self._fail(502, f"seedbox: {exc}")
            else:
                if not os.path.isfile(real):
                    return self._fail(404, f"not a file: {virtual}")
                self._stream_local(real)
        finally:
            _fetch_slots.release()

    def _stream_local(self, real):
        """Content-Length, because the size is free here and it is what gives the
        client a real progress bar."""
        size = os.path.getsize(real)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            if self.command == "HEAD":
                return
            with open(real, "rb") as fh:
                while True:
                    chunk = fh.read(1 << 20)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass   # the client cancelled; nothing to clean up on a read

    def _stream_remote(self, rel):
        """Chunked, because the size is NOT free here.

        Learning it would mean an `lsjson` round trip per file, and over FTP that is
        ~1s each -- fifty files in a release would spend a minute answering a
        question the client already has from the manifest. So the length is omitted
        and the client uses the manifest's size for progress.
        """
        argv = ["rclone", "cat", seedbox.remote_path(rel)]
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=seedbox.env())
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            while True:
                chunk = proc.stdout.read(1 << 20)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            # The client hanging up must not leave an rclone holding an FTP slot.
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
            try:
                proc.stdout.close()
                proc.stderr.close()
            except Exception:
                pass

    def _move(self):
        """Relocate something within one drop target.

        The FTP front end has always been able to do this (vfs.rename step 3);
        the HTTP API could not, because _rename is pinned to the same parent by
        two separate locks. Same guard shape as _delete otherwise: refuse while a
        transfer is touching either end, and answer 409 rather than guessing when
        the destination name is taken.
        """
        body = self._body()
        virtual, dest_virtual = body.get("path"), body.get("dest_dir")
        if not virtual or not dest_virtual:
            raise JobError("path and dest_dir are required")
        new_name = (body.get("new_name") or "").strip()
        src, dest = guards.validate_move(guards.to_real(virtual),
                                         guards.to_real(dest_virtual), new_name)

        # Either end. A job writing INTO the source would lose its progress, and
        # one writing into the destination would be overwritten from under it.
        for row in self.jobs.snapshot("queued", "running"):
            target = os.path.join(row["dest_dir"], row["dest_name"])
            for path in (src, dest):
                if (target == path or guards.under(target, path)
                        or guards.under(path, target)):
                    raise JobError(
                        f"job {row['id']} is still transferring into "
                        f"{guards.to_virtual(target)} -- cancel it first")

        if os.path.exists(dest):
            if not body.get("overwrite"):
                # 409, not 400: this refusal can actually be ANSWERED, so it
                # carries the name and the app asks overwrite-or-rename. Same
                # shape as the enqueue conflict.
                return self._fail(409,
                                  f"{os.path.basename(dest)} already exists there",
                                  extra={"name": os.path.basename(dest),
                                         "existing": guards.to_virtual(dest)})
            # Explicitly asked for, having been shown the clash. os.rename would
            # replace a file silently but REFUSES a non-empty directory, so the
            # destination is removed first either way.
            try:
                if os.path.isdir(dest):
                    shutil.rmtree(dest)
                else:
                    os.remove(dest)
            except OSError as exc:
                raise JobError(f"could not replace {os.path.basename(dest)}: "
                               f"{exc.strerror or exc!r}")
        try:
            os.rename(src, dest)
        except OSError as exc:
            # Same drop target by construction, so EXDEV should be unreachable --
            # report whatever actually happened rather than assuming.
            raise JobError(f"move failed: {exc.strerror or exc!r}")
        self.log(f"moved {guards.to_virtual(src)} -> {guards.to_virtual(dest)}")
        self._send(200, {"moved": guards.to_virtual(dest)})

    def _delete(self):
        """Remove something from the NAS. Irreversible, so the checks come first."""
        body = self._body()
        virtual = body.get("path")
        if not virtual:
            raise JobError("path is required")
        src = guards.validate_delete(guards.to_real(virtual), require_exists=False)

        # The seedbox cannot be written through the filesystem -- that mount is bound
        # read-only at two layers -- so it gets its own implementation over rclone.
        if guards.under(src, guards.SEEDBOX):
            return self._delete_seedbox(src)

        # Never delete out from under a transfer. rclone would keep writing into a
        # directory that no longer exists and the job would fail in a way that looks
        # like a network fault. Overlap in EITHER direction counts: the job may be
        # writing into this path, or into something that contains it.
        for row in self.jobs.snapshot("queued", "running"):
            target = os.path.join(row["dest_dir"], row["dest_name"])
            if target == src or guards.under(target, src) or guards.under(src, target):
                raise JobError(
                    f"job {row['id']} is still transferring into "
                    f"{guards.to_virtual(target)} -- cancel it first")

        # Existence is only now worth asserting: everything above has ruled out the
        # cases where "missing" would have been the wrong thing to say.
        if not os.path.exists(src):
            return self._fail(404, f"no such item: {guards.to_virtual(src)}")

        files, size = _walk_count(src)
        if os.path.isdir(src):
            shutil.rmtree(src)
        else:
            os.remove(src)
        self.log(f"deleted {guards.to_virtual(src)} ({files} files, {size} bytes)")
        self._send(200, {"deleted": guards.to_virtual(src),
                         "files": files, "bytes": size})

    def _mkdir(self):
        body = self._body()
        parent, name = body.get("parent"), (body.get("name") or "").strip()
        if not parent:
            raise JobError("parent is required")
        exist_ok = bool(body.get("exist_ok"))
        dest = guards.validate_mkdir(guards.to_real(parent), name, exist_ok=exist_ok)
        created = not os.path.isdir(dest)
        if created:
            os.mkdir(dest)
            self.log(f"created folder {guards.to_virtual(dest)}")
        # `created` is the honest answer to "did I make this or join it?", which
        # is what lets the app say "using the existing folder" instead of
        # implying it made one.
        self._send(201 if created else 200,
                   {"path": guards.to_virtual(dest), "created": created})

    def _retry(self, jid):
        """Queue a fresh job with the same source and destination as a finished one."""
        row = self._find(jid)
        if row is None:
            return self._fail(404, f"no job {jid}")
        if row["state"] in ("queued", "running"):
            raise JobError(f"job {jid} is still {row['state']}")
        src, dest_dir, dest_name = guards.validate_request(
            row["src_real"], row["dest_dir"], row["dest_name"])
        # The guard above already refused a retry of a queued/running job, so a
        # duplicate here means an identical job was queued by some other route.
        new_id, _ = self.jobs.enqueue(src, dest_dir, dest_name,
                                      on_conflict=row["on_conflict"] or "overwrite")
        self.log(f"retry of job {jid} queued as {new_id}")
        self._send(201, {"id": new_id, "retry_of": jid})

    def _settings(self):
        import jobs as jobsmod
        self._send(200, {"max_concurrent": self.jobs.limit,
                         "max_concurrent_ceiling": jobsmod.MAX_WORKERS})

    def _set_settings(self):
        import jobs as jobsmod
        body = self._body()
        raw = body.get("max_concurrent")
        if raw is None:
            raise JobError("max_concurrent is required")
        try:
            n = int(raw)
        except (TypeError, ValueError):
            raise JobError("max_concurrent must be a whole number")
        if n < 1 or n > jobsmod.MAX_WORKERS:
            raise JobError(f"max_concurrent must be between 1 and {jobsmod.MAX_WORKERS}")
        self._send(200, {"max_concurrent": self.jobs.set_limit(n),
                         "max_concurrent_ceiling": jobsmod.MAX_WORKERS})

    def _rename(self):
        """Rename something already on the NAS. Seedbox paths are refused by the
        guard, not here, so both front ends would get the same answer."""
        body = self._body()
        virtual = body.get("path")
        new_name = body.get("new_name") or ""
        if not virtual:
            raise JobError("path is required")
        # Validate WITHOUT requiring existence first: an in-flight destination is
        # created by rclone as it writes, so it may legitimately not be on disk yet.
        src, dest = guards.validate_rename(guards.to_real(virtual), new_name,
                                           require_exists=False)

        # If a transfer is still writing into this path (or into something under
        # it), renaming now would pull the directory out from under rclone and lose
        # the transfer's progress. Record it against that job instead; the worker
        # applies it the moment rclone exits.
        for row in self.jobs.snapshot("queued", "running"):
            target = os.path.join(row["dest_dir"], row["dest_name"])
            if target == src or guards.under(target, src):
                self.jobs.defer_rename(row["id"], new_name
                                       if target == src
                                       # renaming an ANCESTOR of the destination is
                                       # not expressible as a rename of the job's own
                                       # folder, so only the exact match can defer.
                                       else None)
                if target != src:
                    raise JobError(
                        f"a transfer is writing into {guards.to_virtual(target)}; "
                        "rename that folder itself, or wait for it to finish")
                self.log(f"api rename of {guards.to_virtual(src)} deferred to job {row['id']}")
                return self._send(202, {"deferred": True, "job": row["id"],
                                        "name": new_name,
                                        "message": "will be renamed when the transfer finishes"})

        # Nothing is writing there, so it must actually exist to be renamed.
        if not os.path.exists(src):
            raise JobError(f"no such item: {guards.to_virtual(src)}")
        try:
            os.rename(src, dest)
        except OSError as exc:
            # Same volume by construction (both are under one drop target), so EXDEV
            # should be unreachable -- report whatever really happened.
            raise JobError(f"rename failed: {exc.strerror or exc!r}")
        self.log(f"api renamed {guards.to_virtual(src)} -> {new_name}")
        self._send(200, {"deferred": False, "path": guards.to_virtual(dest),
                         "name": new_name})

    def _seedbox_in_use(self, path):
        """Refuse to disturb something a transfer is still READING.

        The mirror of the destination checks on the NAS side. Pulling a source out
        from under a running rclone fails the copy in a way that reads as a network
        fault, and the partially-written destination is left behind.
        """
        for row in self.jobs.snapshot("queued", "running"):
            s = row["src_real"]
            if s == path or guards.under(s, path) or guards.under(path, s):
                raise JobError(f"job {row['id']} is still copying from "
                               f"{guards.to_virtual(s)} -- cancel it first")

    def _delete_seedbox(self, src):
        """Delete on the seedbox, over rclone rather than the read-only mount.

        This BREAKS whatever torrent is seeding the files; that is the intended
        behaviour and the app says so before asking for confirmation. Nothing here
        touches qBittorrent, so the torrent is left to be cleaned up there.
        """
        import jobs as jobsmod
        self._seedbox_in_use(src)
        # Existence and the file/byte count come from the read-only mount, which is
        # cheap. The listing the APP shows is read live over rclone, so a delete is
        # visible on the next refresh even though this mount caches.
        if not os.path.exists(src):
            return self._fail(404, f"no such item: {guards.to_virtual(src)}")
        is_dir = os.path.isdir(src)
        files, size = _walk_count(src)
        rel = jobsmod._src_rel(src)
        if rel is None:
            raise JobError(f"{guards.to_virtual(src)} is not on the seedbox remote")
        try:
            seedbox.delete(rel, is_dir)
        except seedbox.SeedboxError as exc:
            raise JobError(str(exc))
        self.log(f"deleted on the seedbox: {guards.to_virtual(src)} "
                 f"({files} files, {size} bytes)")
        self._send(200, {"deleted": guards.to_virtual(src),
                         "files": files, "bytes": size, "seedbox": True})

    def _payload(self, limit):
        return {"active": [_job_json(r) for r in self.jobs.snapshot("queued", "running")],
                "recent": [_job_json(r) for r in self.jobs.recent_finished(limit)],
                "server_time": time.time()}

    def _jobs(self):
        limit = self._qi(self._q(), "limit", 50, lo=1, hi=200)
        payload = self._payload(limit)
        # ETag over the payload rather than a rev counter: a counter in memory
        # resets when the watchdog os._exit(1)s (a client holding rev=812 would see
        # rev=3 and reasonably conclude nothing changed), and in the DB it is a
        # schema change. Hashing is exact and costs microseconds for ~60 rows.
        body = dict(payload)
        body.pop("server_time")
        etag = '"%s"' % hashlib.sha1(
            json.dumps(body, sort_keys=True).encode()).hexdigest()[:16]
        if self.headers.get("If-None-Match") == etag:
            try:
                self.send_response(304)
                self.send_header("ETag", etag)
                self.send_header("Content-Length", "0")
                self.send_header("Cache-Control", "no-cache")
                self.end_headers()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        payload["rev"] = etag.strip('"')
        raw = json.dumps(payload).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-cache")
            self.send_header("ETag", etag)
            self.end_headers()
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _find(self, jid):
        for row in self.jobs.snapshot():
            if row["id"] == jid:
                return row
        return None

    def _job(self, jid):
        row = self._find(jid)
        if row is None:
            return self._fail(404, f"no such job j{jid}")
        self._send(200, _job_json(row))

    def _job_action(self, jid, action):
        # Look the job up first so "no such job" is a 404 and everything else is a
        # 400. jobs.cancel raises JobError for both, and telling them apart by
        # string-matching the message is exactly the coupling that breaks silently.
        if self._find(jid) is None:
            return self._fail(404, f"no such job j{jid}")
        msg = (self.jobs.cancel(jid) if action == "cancel" else self.jobs.dismiss(jid))
        self.log(f"api {action} job {jid}: {msg}")
        self._send(200, {"id": jid, "message": msg})

    def _job_log(self, jid):
        if self._find(jid) is None:
            return self._fail(404, f"no such job j{jid}")
        tail = self._qi(self._q(), "tail", LOG_TAIL_DEFAULT, lo=1024, hi=4 * 1024 * 1024)
        try:
            with open(os.path.join(LOG_DIR, f"{jid}.log"), "rb") as f:
                data = f.read()[-tail:]
        except OSError:
            data = b"(no log yet)\n"
        self._send(200, None, ctype="text/plain; charset=utf-8", raw=data)

    def _verify(self, jid):
        """File counts and bytes on both sides.

        This exists because of a real incident: a directory copy transferred 1 of 3
        files, rclone reported errors=0 and exited 0, and the job was marked done.
        files_total came from rclone's stats and lied; walking the tree does not.
        Never automatic -- the source walk is on the FUSE mount and costs real time.
        """
        row = self._find(jid)
        if row is None:
            return self._fail(404, f"no such job j{jid}")
        src = row["src_real"]
        dest = os.path.join(row["dest_dir"], row["dest_name"])
        sf, sb = _walk_count(src) if os.path.exists(src) else (None, None)
        df, db = _walk_count(dest) if os.path.exists(dest) else (None, None)
        self._send(200, {
            "id": jid, "state": row["state"],
            "src": {"path": guards.to_virtual(src), "files": sf, "bytes": sb,
                    "exists": os.path.exists(src)},
            "dest": {"path": guards.to_virtual(dest), "files": df, "bytes": db,
                     "exists": os.path.exists(dest)},
            "files_match": sf is not None and sf == df,
            "bytes_match": sb is not None and sb == db,
        })


def start(jobs, log):
    """Bind, then hand off to a daemon thread. Returns the server, or None.

    Binding SYNCHRONOUSLY matters: a port clash becomes a log line at startup
    rather than a silent failure inside a thread nobody is watching. And a failure
    here must not take FTP down -- moving bytes is the job, and FileZilla is the
    proven front end.
    """
    token = os.environ.get("RELAY_API_TOKEN", "")
    if not token:
        log("HTTP API disabled: RELAY_API_TOKEN is not set. This API can write "
            "into the media volumes, so the token is never optional.")
        return None
    Handler.jobs = jobs
    Handler.token = token
    Handler.log = staticmethod(log)
    try:
        srv = ThreadingHTTPServer((BIND, PORT), Handler)
    except OSError as exc:
        log(f"HTTP API failed to bind {BIND}:{PORT}: {exc!r} — FTP continues")
        return None
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, name="httpapi", daemon=True).start()
    log(f"HTTP API listening on {BIND}:{PORT}")
    return srv
