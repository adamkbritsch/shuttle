"""Validation shared by every front end.

These checks used to live only in vfs.py, i.e. only on the FTP path. That was fine
while FileZilla was the only client. An HTTP caller reaching jobs.enqueue() directly
would bypass all of them -- and jobs.enqueue() is deliberately dumb: its ONLY touch
of dest_dir is an os.statvfs() wrapped in `except OSError: pass`, so a nonexistent
destination silently skips the free-space check AND lets rclone create the folder.

Every guard here exists because something would otherwise be written somewhere it
should not be. They raise JobError; each front end translates it (vfs -> a 550
FilesystemError, api -> HTTP 400).

This module owns the tree constants so there is no import cycle: vfs.py re-imports
them from here, which keeps `vfs.TREE` / `vfs.SEEDBOX` resolving for server.py.
"""

import os

from jobs import JobError

TREE = "/srv/tree"
SEEDBOX = TREE + "/seedbox"
QUEUE = TREE + "/queue"
ACTIVE = QUEUE + "/_active"
DONE = QUEUE + "/_done"
STATUS_DIRS = (ACTIVE, DONE)

# A real release sits at <SEEDBOX>/downloads/<Release>, i.e. depth 2. Anything
# shallower is a whole level of the library rather than one item, so it is refused
# as a source. This became load-bearing when the `downloads` level was restored:
# before that, a stray `MKD downloads` inside a drop target resolved to a path that
# did NOT exist and merely made a junk directory, whereas now it names a real
# directory and would enqueue a recursive copy of everything.
# Directories only -- a single file is never the whole library.
MIN_SRC_DEPTH = int(os.environ.get("RELAY_MIN_SRC_DEPTH", "2"))

_BAD_NAME = {"", ".", ".."}


def under(path: str, root: str) -> bool:
    return path == root or path.startswith(root.rstrip("/") + "/")


def to_virtual(real: str) -> str:
    """Container path -> the path the user actually typed, for error messages."""
    if real == TREE:
        return "/"
    return real[len(TREE):] if real.startswith(TREE) else real


def to_real(virtual: str) -> str:
    """A client-supplied /seedbox|/queue path -> a container path inside TREE.

    normpath BEFORE the prefix check is the whole trick: it collapses '..' first, so
    "/queue/../../data" becomes "/data" and then fails under(). Checking the prefix
    on the raw string and normalising afterwards is the classic inversion that makes
    traversal work.
    """
    if not isinstance(virtual, str) or not virtual.startswith("/"):
        raise JobError("path must be absolute, e.g. /seedbox/downloads/<Release>")
    if "\0" in virtual:
        # os.* raises ValueError, not OSError, on an embedded NUL -- that would
        # surface as a 500 instead of a 400.
        raise JobError("path contains a null byte")
    real = os.path.normpath(os.path.join(TREE, virtual.lstrip("/")))
    if not under(real, TREE):
        raise JobError("path escapes the tree")
    return real


def drop_targets():
    """Real drop targets, i.e. every /queue/<name> that is not a status folder.

    Kept verbatim from the original in vfs.py, including the behaviour of returning
    an empty set (and so dropping _scratch) on OSError. A refactor and a behaviour
    change in the same step would be unfalsifiable.
    """
    try:
        return {
            os.path.join(QUEUE, d) for d in os.listdir(QUEUE)
            if os.path.isdir(os.path.join(QUEUE, d)) and not d.startswith("_")
        } | {os.path.join(QUEUE, "_scratch")}
    except OSError:
        return set()


def resolve_drop_target(path: str, targets=None):
    """The drop-target root `path` sits in (or is), else None.

    Subdirectories count: a media library wants /queue/MediaVolume3/Movies, not the
    volume root. `targets` may be passed so one FTP command can reuse a single
    os.listdir(QUEUE) snapshot.
    """
    if targets is None:
        targets = drop_targets()
    return next((t for t in targets if path == t or under(path, t)), None)


def reject_whole_library(src: str) -> None:
    """Refuse a source shallower than an individual release."""
    norm = os.path.normpath(src)
    if not norm.startswith(SEEDBOX):
        return
    rel = norm[len(SEEDBOX):].strip("/")
    parts = [p for p in rel.split("/") if p]
    # Depth alone, deliberately NOT `os.path.isdir(norm) and ...`. The seedbox is
    # reached over rclone now and may have no local mount to stat, so asking the
    # filesystem here would either raise or -- worse -- silently answer False and
    # wave a whole-library copy straight through. A file this shallow is a loose
    # file at the seedbox root, which is equally not a release.
    if len(parts) < MIN_SRC_DEPTH:
        what = "the seedbox root" if not parts else repr(rel)
        raise JobError(
            f"refusing {what}: that is a whole level of the library, not a "
            f"release -- drag an individual item instead")


def validate_request(src: str, dest_dir: str, dest_name: str):
    """The single gate every enqueue passes through, from either front end.

    The ORDER is load-bearing: it reproduces the order these checks fired in when
    they were spread across rename()/_enqueue(), so the 550 text a FileZilla user
    gets for a given mistake does not change. tests/ftp_regression.py holds the
    baseline those strings are diffed against.
    """
    src = os.path.normpath(src)
    dest_dir = os.path.normpath(dest_dir)

    # (a) source on the seedbox. FTP only reaches here via an under(src, SEEDBOX)
    #     branch, so this is a no-op there; for HTTP it is the whole check.
    if not under(src, SEEDBOX):
        raise JobError("source is not on the seedbox")

    # (b) destination is a real drop target, or a folder inside one.
    if resolve_drop_target(dest_dir) is None:
        raise JobError(f"{to_virtual(dest_dir)} is not a drop target -- use "
                       "/queue/<Volume> or a folder inside it")

    # (c) ...and already exists. THE gap: jobs.enqueue does not check, and rclone
    #     would create it, turning a typo into a silently wrong destination.
    if not os.path.isdir(dest_dir):
        raise JobError(f"no such folder: {to_virtual(dest_dir)} — create it first, "
                       "or drop onto a folder that already exists")

    # (d) not a whole level of the library. Was after (c) on the FTP path; kept there
    #     so a whole-library drag onto a misspelled folder still says "no such folder".
    reject_whole_library(src)

    # (e) a single path component. FTP gets this free from basename(); HTTP does not.
    if (dest_name in _BAD_NAME or "/" in dest_name
            or any(ord(c) < 32 for c in dest_name)):
        raise JobError("destination name must be a single path component")

    return src, dest_dir, dest_name


def validate_rename(path: str, new_name: str, require_exists: bool = True):
    """Gate for renaming something that already landed on the NAS.

    The seedbox side is deliberately NOT renameable: that mount is bound read-only
    and `_deny_seedbox` exists to keep qBittorrent seeding, so a rename there would
    both fail and, if it somehow succeeded, break the torrent.
    """
    src = os.path.normpath(path)

    if under(src, SEEDBOX):
        raise JobError("the seedbox is read-only -- rename it on the NAS side "
                       "after it has been copied")
    if resolve_drop_target(src) is None:
        raise JobError(f"{to_virtual(src)} is not somewhere this can rename")
    # The drop-target ROOTS are the media volumes themselves; renaming one would
    # rename a whole volume mount.
    if src in drop_targets():
        raise JobError("that is a volume, not something inside one")
    # An in-flight destination may not exist on disk yet -- rclone creates it as it
    # writes -- so a deferred rename validates everything EXCEPT existence.
    if require_exists and not os.path.exists(src):
        raise JobError(f"no such item: {to_virtual(src)}")

    if (new_name in _BAD_NAME or "/" in new_name
            or any(ord(c) < 32 for c in new_name)):
        raise JobError("the new name must be a single path component")

    dest = os.path.join(os.path.dirname(src), new_name)
    if os.path.exists(dest):
        raise JobError(f"{new_name} already exists here")
    return src, dest
