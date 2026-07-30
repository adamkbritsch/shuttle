"""Rendering job state as FTP listing filenames.

The only channel FTP gives us for pushing status to the client is the directory
listing, so progress is encoded into the *filename* of a synthetic entry. That
puts a few hard constraints on what those names may contain -- see sanitise().
"""

_FORBIDDEN_SUBSTRINGS = (
    # LIST parsers (FileZilla's included) split on this to extract a symlink
    # target, so a name containing it renders as a broken symlink.
    " -> ",
)


def sanitise(name: str) -> str:
    """Make a string safe to appear as a filename in an FTP listing."""
    # A newline injects a whole extra line into the LIST data stream -- that is
    # protocol corruption, not a cosmetic bug. Release names come from torrents,
    # so treat them as untrusted and strip unconditionally.
    for ch in ("\r", "\n", "\0", "\t"):
        name = name.replace(ch, " ")
    # '/' cannot appear in a listing entry at all.
    name = name.replace("/", "∕")
    for bad in _FORBIDDEN_SUBSTRINGS:
        name = name.replace(bad, " to ")
    # MLSD uses "; " between facts and the name, and several clients trim, so a
    # leading or trailing space makes the name ambiguous.
    return name.strip() or "unnamed"


def human(n: float) -> str:
    for unit in ("B", "K", "M", "G", "T"):
        if abs(n) < 1024 or unit == "T":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024.0
    return f"{n:.1f}T"


def _eta(seconds) -> str:
    if not seconds or seconds < 0:
        return "--"
    seconds = int(seconds)
    if seconds < 90:
        return f"{seconds}s"
    if seconds < 5400:
        return f"{seconds // 60}m"
    return f"{seconds // 3600}h{(seconds % 3600) // 60:02d}m"


def _middle_truncate(name: str, keep: int) -> str:
    if len(name) <= keep:
        return name
    head = (keep - 1) * 2 // 3
    tail = keep - 1 - head
    return name[:head] + "…" + name[len(name) - tail:]


MAX_NAME = 180


def render(job: dict) -> str:
    """One listing entry for a job.

    Progress goes FIRST and the (often 100+ char) release name is
    middle-truncated, so the state is readable without widening FileZilla's
    Filename column -- and the default name sort happens to group by progress.
    """
    jid = f"[j{job['id']:02d}]"
    name = sanitise(job["dest_name"])
    state = job["state"]

    if state == "queued":
        prefix = f"{jid} QUEUED"
    elif state == "running":
        done = job.get("bytes_done") or 0
        total = job.get("bytes_total") or 0
        # rclone's own transferring[].percentage is an int that FLOORS -- it
        # reads 0 while 34MB of 86GB is done -- so always compute this here.
        pct = (100.0 * done / total) if total else 0.0
        speed = job.get("speed") or 0
        parts = [f"{pct:5.1f}%", f"{human(done)} of {human(total)}"]
        if speed:
            parts.append(f"{human(speed)}\u2215s")   # U+2215, not ASCII "/"
        parts.append(f"ETA {_eta(job.get('eta'))}")
        if (job.get("files_total") or 0) > 1:
            parts.append(f"file {job.get('files_done') or 0} of {job['files_total']}")
        prefix = f"{jid} " + " · ".join(parts)
    elif state == "done":
        prefix = f"{jid} DONE {human(job.get('bytes_done') or 0)}"
    elif state == "failed":
        prefix = f"{jid} FAILED {sanitise((job.get('error') or 'unknown')[:60])}"
    else:
        prefix = f"{jid} {state.upper()}"

    room = MAX_NAME - len(prefix) - 3
    out = f"{prefix} — {_middle_truncate(name, max(room, 20))}"
    # Belt-and-braces: the name went through sanitise() but the PREFIX is built
    # here, and a '/' anywhere makes the entry unaddressable -- the FTP server
    # parses it as nested directories, so DELE/RETR on the entry return 550. That
    # is exactly how the cancel gesture broke. Guard at the one exit point rather
    # than trusting every future edit to the prefix above.
    return out.replace("/", "\u2215")
