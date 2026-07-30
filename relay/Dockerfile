# rclone ships a static binary, so it can simply be copied into a slim python
# image rather than installing it — verified by running it there.
FROM rclone/rclone:latest AS rclone

FROM python:3.11-slim
COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
RUN pip install --no-cache-dir "pyftpdlib==2.2.0"

# The whole virtual tree is a REAL single-rooted tree so pyftpdlib's stock
# path handling (ftp2fs / fs2ftp / validpath) works unmodified. Writing a
# custom mount table there would be the most traversal-prone part of this.
# _active/_done are real empty dirs so chdir/isdir/lexists also work stock;
# only listdir + lstat/stat are synthesised.
RUN mkdir -p /srv/tree/seedbox \
             /srv/tree/queue/Media \
             /srv/tree/queue/MediaVolume2 \
             /srv/tree/queue/MediaVolume3 \
             /srv/tree/queue/_scratch \
             /srv/tree/queue/_active \
             /srv/tree/queue/_done

COPY app/ /app/
ENV XDG_CONFIG_HOME=/config PYTHONUNBUFFERED=1
# umask 002 is load-bearing: it is what makes copied files 664 / dirs 775
# instead of 600/700, matching this NAS's existing ownership conventions.
ENTRYPOINT ["/bin/sh","-c","umask 002 && exec python /app/server.py"]
