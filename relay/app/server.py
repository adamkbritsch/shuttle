"""seedbox-ftp-relay: FileZilla on the Mac as a frontend, transfers on the NAS.

The Mac's FileZilla connects here and only ever sends control commands. Dragging
a file from /seedbox into /queue/<Volume> is a same-server move to FileZilla, so
it arrives as RNFR+RNTO; that is intercepted and turned into an rclone copy that
runs entirely NAS<->seedbox.
"""

import errno
import logging
import os
import sys
import threading
import time

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer

import api
import vfs
from jobs import Jobs

BIND = os.environ.get("FTP_BIND_ADDR", "127.0.0.1")
PORT = int(os.environ.get("FTP_PORT", "2121"))
PASV_LOW = int(os.environ.get("FTP_PASV_LOW", "50400"))
PASV_HIGH = int(os.environ.get("FTP_PASV_HIGH", "50450"))
USER = os.environ.get("FTP_USER") or ""
PASSWORD = os.environ.get("FTP_PASS") or ""

CMD_LOG = "/data/logs/commands.log"


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line, flush=True)
    try:
        with open(CMD_LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


class LoggingFTPHandler(FTPHandler):
    """Logs every verb.

    process_command is the single choke point every FTP command passes through,
    so this catches whatever the client actually does -- which is how the drag
    gesture gets identified rather than guessed at.
    """

    def process_command(self, cmd, *args, **kwargs):
        try:
            shown = args[0] if args else ""
        except Exception:
            shown = ""
        log(f"CMD {cmd} {shown}")
        return super().process_command(cmd, *args, **kwargs)


def seedbox_watchdog(jobs):
    """Recycle the container if the seedbox FUSE bind goes stale.

    If rclone-mount-seedbox restarts, this container's bind still points at the
    dead mount and every access returns ENOTCONN; a bind of the leaf cannot pick
    up the new mount. Exiting lets restart:unless-stopped re-bind.

    A Docker healthcheck would NOT do this -- Docker does not restart unhealthy
    containers. And the exit is deferred while a job runs, because rclone
    restarts an interrupted file from zero.
    """
    # Probe INSIDE the mount and require a non-empty listing, rather than stat()ing
    # the mountpoint. Two reasons, both learned the hard way:
    #
    #  * stat() on the bare mountpoint is nearly a tautology. The dangerous state is
    #    not "gone" but "present and empty": after the mount is recreated, a bind
    #    that missed the new mount can expose an empty-but-valid directory, which
    #    stat() reports as perfectly fine. The relay would then serve an EMPTY
    #    seedbox tree over FTP without ever erroring.
    #  * an earlier comment here claimed a "/downloads" probe would make this
    #    exit-loop forever. That was wrong: a missing path raises ENOENT, which is
    #    not in the errno set below, so it would have gone BLIND, not looped.
    #    Hence checking the listing explicitly instead of relying on the errno.
    probe = vfs.SEEDBOX
    while True:
        time.sleep(30)
        try:
            empty = not os.listdir(probe)
        except OSError as exc:
            if exc.errno in (errno.ENOTCONN, errno.ESTALE):
                if jobs.busy():
                    log("seedbox mount is stale but a job is running; deferring restart")
                    continue
                log("seedbox mount is stale (ENOTCONN) — exiting so Docker re-binds it")
                os._exit(1)
            continue
        except Exception:
            continue
        if empty:
            if jobs.busy():
                log("seedbox tree is empty but a job is running; deferring restart")
                continue
            log("seedbox tree is EMPTY — bind likely missed a remount; exiting so Docker re-binds")
            os._exit(1)


def main():
    if not USER or not PASSWORD:
        sys.exit("FTP_USER and FTP_PASS must be set (see .env)")

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")

    jobs = Jobs(log=log)
    vfs.RelayFS.jobs = jobs
    vfs.RelayFS.log = staticmethod(log)

    authorizer = DummyAuthorizer()
    # e/l/r browse+read, f rename (the primary trigger), m mkdir (fallback B),
    # w upload, a append, d delete inside the queue dirs. The seedbox subtree is
    # protected separately in RelayFS, and by a read-only bind.
    authorizer.add_user(USER, PASSWORD, vfs.TREE, perm="elradfmw")

    handler = LoggingFTPHandler
    handler.authorizer = authorizer
    handler.abstracted_fs = vfs.RelayFS
    handler.banner = "seedbox-ftp-relay ready"
    handler.passive_ports = range(PASV_LOW, PASV_HIGH + 1)
    # Deliberately NOT set: PassiveDTP takes the local address of the control
    # connection, which under host networking is already the tailnet IP. Setting
    # masquerade_address would pin one path and break the other.
    handler.masquerade_address = None
    # Default, but stated explicitly: this is what blocks FXP-bounce abuse of
    # the data channel.
    handler.permit_foreign_addresses = False
    handler.use_sendfile = True

    threading.Thread(target=seedbox_watchdog, args=(jobs,), daemon=True).start()

    # HTTP front end for the Shuttle Mac app. It goes HERE because
    # serve_forever() below never returns -- it is pyftpdlib's single-threaded
    # ioloop on THIS thread, so anything that must coexist with FTP has to be
    # started before it, on its own daemon thread. api.start() binds
    # synchronously and only then hands off, and returns None rather than
    # raising if the port is taken: a broken API must never take FTP down.
    api.start(jobs, log)

    log(f"binding {BIND}:{PORT} passive {PASV_LOW}-{PASV_HIGH} "
        f"max_jobs={os.environ.get('RELAY_MAX_JOBS','1')}")
    server = FTPServer((BIND, PORT), handler)
    server.max_cons = 32
    server.serve_forever()


if __name__ == "__main__":
    main()
