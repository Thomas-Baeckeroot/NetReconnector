#!/bin/bash
#
# NetMonitor-event.sh — logs a free-text, timestamped note (rain started,
# box reboot, cable/connector redone, ...) into the same SQLite DB as
# NetMonitor.sh, so pings and real-world events can be correlated later
# (e.g. "was there a spike within 10 minutes of this reboot?").
#
# Usage: NetMonitor-event.sh <note text...>
#   NetMonitor-event.sh reboot box
#   NetMonitor-event.sh "recablage prise salon"
#
# Deployment: same DbFile as the matching NetMonitor.sh on this NAS — edit below.

set -u

# Must match the DbFile of the NetMonitor.sh deployed on this NAS.
DbFile="/volume1/homes/Deimos-admin/NetMonitor-Bottens.db"
# StBenoit: DbFile="/volume1/homes/StBenoit-admin/NetMonitor-StBenoit.db"

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <note text...>" >&2
  exit 1
fi

note="$*"
esc_note="${note//\'/''}"

sqlite3 "$DbFile" <<SQL
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
CREATE TABLE IF NOT EXISTS events (
  id   INTEGER PRIMARY KEY AUTOINCREMENT,
  ts   TEXT NOT NULL,
  note TEXT NOT NULL
);
INSERT INTO events (ts, note) VALUES ('$(date '+%Y-%m-%d %H:%M:%S')', '$esc_note');
SQL

# Same rationale as NetMonitor.sh: keep the DB queryable without sudo.
chmod 644 "$DbFile"* 2>/dev/null || true

echo "Logged: $note"
