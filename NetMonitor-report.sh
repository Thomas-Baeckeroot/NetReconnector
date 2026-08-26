#!/bin/bash
#
# NetMonitor-report.sh — quick-look summary of NetMonitor.sh's ping history:
# per-target best/mean/worst latency and loss, for the last 24h or a given day.
#
# Usage:
#   NetMonitor-report.sh                 # last 24 hours, per target
#   NetMonitor-report.sh 2026-08-26      # a specific calendar day, per target
#   NetMonitor-report.sh --spikes [N]    # last N (default 20) lossy/slow rows, most recent first
#
# Deployment: same DbFile as the matching NetMonitor.sh on this NAS — edit below.

set -u

# Must match the DbFile of the NetMonitor.sh deployed on this NAS.
DbFile="/volume1/homes/Deimos-admin/NetMonitor-Bottens.db"
# StBenoit: DbFile="/volume1/homes/StBenoit-admin/NetMonitor-StBenoit.db"

# ">1000ms" is the "ping explosion" threshold originally reported at Bottens.
SpikeRttThreshold=1000

if [ ! -f "$DbFile" ]; then
  echo "NetMonitor-report.sh: no DB at $DbFile (has NetMonitor.sh run yet?)" >&2
  exit 1
fi

summary_query() {
  # $1: a SQL WHERE clause selecting the period to summarize
  sqlite3 -header -column "$DbFile" "
    SELECT label,
           COUNT(*)                                   AS probes,
           ROUND(AVG(loss_pct), 1)                     AS avg_loss_pct,
           SUM(CASE WHEN loss_pct = 100 THEN 1 ELSE 0 END) AS full_outages,
           ROUND(MIN(rtt_avg_ms), 1)                   AS best_ms,
           ROUND(AVG(rtt_avg_ms), 1)                   AS mean_ms,
           ROUND(MAX(rtt_avg_ms), 1)                   AS worst_ms
    FROM pings
    WHERE $1
    GROUP BY label
    ORDER BY label;
  "
}

mode="${1:-}"

case "$mode" in
  --spikes)
    limit="${2:-20}"
    sqlite3 -header -column "$DbFile" "
      SELECT ts, label, target, loss_pct, rtt_avg_ms
      FROM pings
      WHERE loss_pct > 0 OR rtt_avg_ms > $SpikeRttThreshold
      ORDER BY ts DESC
      LIMIT $limit;
    "
    ;;
  "")
    # ts is stored in local time (see NetMonitor.sh), so compare against
    # sqlite's 'now' converted to local time too, not raw UTC.
    summary_query "ts >= datetime('now', 'localtime', '-24 hours')"
    ;;
  *)
    if ! [[ "$mode" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      echo "Usage: $0 [YYYY-MM-DD | --spikes [N]]" >&2
      exit 1
    fi
    summary_query "date(ts) = '$mode'"
    ;;
esac
