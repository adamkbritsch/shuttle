#!/bin/bash
# Restart the relay ONLY when nothing is transferring.
#
# A restart requeues every running job (jobs.py flips 'running' back to 'queued'),
# and rclone runs with --ignore-times, so the copy starts again from zero. On a
# 24GB file that is tens of minutes of transfer thrown away.
#
# This exists because knowing that was not enough: a deploy script printed the
# active-job count and then restarted anyway, interrupting a real transfer four
# minutes in. Checking and acting have to be the same step, not two steps with a
# human in between.
#
#   ./safe-restart.sh          refuse if anything is queued or running
#   ./safe-restart.sh --force  restart regardless (say why out loud)
set -euo pipefail
cd "$(dirname "$0")"

active=$(docker exec seedbox-ftp-relay python3 -c "
import sqlite3
c = sqlite3.connect('/data/jobs.db')
print(c.execute(\"SELECT COUNT(*) FROM jobs WHERE state IN ('running','queued')\").fetchone()[0])
" 2>/dev/null || echo "?")

if [[ "$active" == "?" ]]; then
  echo "==> Could not read the job table; refusing to restart blind." >&2
  exit 2
fi

if [[ "$active" != "0" && "${1:-}" != "--force" ]]; then
  echo "==> REFUSING: $active job(s) queued or running." >&2
  docker exec seedbox-ftp-relay python3 -c "
import sqlite3
c = sqlite3.connect('/data/jobs.db'); c.row_factory = sqlite3.Row
for r in c.execute(\"SELECT id,state,bytes_done,bytes_total,dest_name FROM jobs\"
                   \" WHERE state IN ('running','queued') ORDER BY id\"):
    pct = 100.0 * r['bytes_done'] / (r['bytes_total'] or 1)
    print('    j%-4s %-8s %5.1f%%  %s' % (r['id'], r['state'], pct, r['dest_name'][:52]))
" >&2
  echo "==> A restart would send these back to zero. Wait, or pass --force." >&2
  exit 1
fi

docker compose restart
