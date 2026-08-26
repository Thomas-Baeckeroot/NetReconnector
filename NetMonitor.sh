#!/bin/bash
#
# NetMonitor.sh — logs ping latency/loss to a set of targets into a local
# SQLite DB, over time.
#
# Complements NetReconnector.sh: this script only observes and logs, it
# never touches the interface (no ifdown/ifup). Meant to run via cron every
# 1-5 minutes on a Synology NAS to build a history of connection quality
# (e.g. to correlate ping spikes / brief outages with time of day).
#
# Deployment: copy this file per-site, edit the "per-host configuration"
# block below for that site's targets, chmod +x, add to crontab.
# Requires sqlite3 (confirmed present on StBenoit, Deimos and the dev Mac).

set -u

### --- Per-host configuration : edit for each site --------------------------

# Site label, only used in the DB filename. One deployed copy of this
# script per NAS, each with its own SiteName + Targets.
SiteName="Bottens"

# Optional: bind pings to a specific interface (leave empty to let the OS
# pick the default route). Rarely needed on a single-homed NAS — set only
# if the NAS has multiple interfaces/routes and you need to test a specific
# one, the way NetReconnector.sh's NetCard does on the multi-homed Pi.
NetCard=""

# Targets to probe on every run: "Label:IP-or-host"
#   - the LAN gateway/box, to isolate "internet down" from "LAN down"
#   - the first ISP-side hop from `traceroute` (see investigation notes),
#     to catch access-line issues (retrains, bufferbloat) close to home
#   - one or two well-known stable public resolvers, as an internet-reachability baseline
# Bottens (current): local box + first Swisscom-side hop seen in traceroute + public DNS.
Targets=(
  "Fritzbox:192.168.178.1"
  "SwisscomBRAS:138.187.22.32"
  "Cloudflare:1.1.1.1"
  "Quad9:9.9.9.9"
)

# StBenoit (NAS "StBenoit", ISP Free/Proxad — traceroute run 2026-08-26 came
# back clean, no bottleneck hop like Bottens' Swisscom BRAS; kept anyway as
# a baseline and in case a similar spike ever shows up here). To deploy on
# that NAS, replace SiteName and Targets above with:
#   SiteName="StBenoit"
#   Targets=(
#     "Freebox:192.168.1.254"
#     "ProxadEdge1:194.149.162.6"
#     "ProxadEdge2:194.149.162.16"
#     "Cloudflare:1.1.1.1"
#     "Quad9:9.9.9.9"
#   )
# Both Proxad routers are pinged directly (as the packet's actual destination,
# not as an intermediate traceroute hop) so ECMP load-balancing on the path to
# some third-party destination doesn't apply — a direct ping to .6 always
# reaches .6. Keeping both means one being ICMP-rate-limited under load
# doesn't blank out the "closest to the fiber" signal entirely.

### --- Fixed parameters -------------------------------------------------------

PingCount=5      # packets sent per target per run
PingTimeout=2    # seconds to wait per reply (ping -W)
DbFile="$HOME/NetMonitor-${SiteName}.db"

### --- Privilege check ------------------------------------------------------------

# Some systems (this Synology DSM among them) refuse raw ICMP sockets for
# non-root users — `ping` exits immediately with "socket: Operation not
# permitted" and never prints a "packets transmitted" line. Left unchecked,
# probe_target would parse that the same as a real 100% packet loss and
# silently fill the DB with fake outage rows. Ping loopback once as a
# privilege check (always reachable when ping actually works, so a failure
# here is unambiguously a permissions problem, not a network one) and stop
# before writing anything if it fails.
preflight_out=$(ping -c 1 -W "$PingTimeout" 127.0.0.1 2>&1)
if printf '%s' "$preflight_out" | grep -qi 'not permitted'; then
  echo "NetMonitor.sh: ping is not permitted for user '$(id -un)'. On Synology, schedule this script to run as the 'root' user in Task Scheduler (Control Panel > Task Scheduler) rather than adding sudo here — sudo would prompt for a password under cron and just hang." >&2
  exit 1
fi

### --- DB setup -----------------------------------------------------------------

# busy_timeout: if a previous cron run is still writing when this one starts,
# wait rather than fail outright with "database is locked".
# WAL: lets a concurrent reader (e.g. an ad-hoc `sqlite3` query) not block writers.
sqlite3 "$DbFile" <<'SQL'
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;
CREATE TABLE IF NOT EXISTS pings (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  ts         TEXT    NOT NULL,
  label      TEXT    NOT NULL,
  target     TEXT    NOT NULL,
  sent       INTEGER NOT NULL,
  received   INTEGER NOT NULL,
  loss_pct   REAL    NOT NULL,
  rtt_min_ms REAL,
  rtt_avg_ms REAL,
  rtt_max_ms REAL
);
SQL

# Doubles embedded single quotes so a value can be dropped into a SQL
# '...' literal safely (labels/hosts come from this script's own config,
# not untrusted input, but this costs nothing and avoids surprises).
sql_escape() {
  printf '%s' "${1//\'/\'\'}"
}

### --- Probe one target, print its INSERT statement to stdout -----------------

probe_target() {
  local label="$1" host="$2"
  local out
  if [ -n "$NetCard" ]; then
    out=$(ping -c "$PingCount" -W "$PingTimeout" -I "$NetCard" "$host" 2>&1)
  else
    out=$(ping -c "$PingCount" -W "$PingTimeout" "$host" 2>&1)
  fi

  # Parses both BusyBox ping ("round-trip min/avg/max = a/b/c ms") and
  # GNU/iputils ping ("rtt min/avg/max/mdev = a/b/c/d ms") output.
  local sent received loss rtt_min rtt_avg rtt_max rtt_line

  sent=$(printf '%s\n' "$out" | grep -oE '[0-9]+ packets transmitted' | grep -oE '^[0-9]+')
  received=$(printf '%s\n' "$out" | grep -oE '[0-9]+ (packets )?received' | head -1 | grep -oE '^[0-9]+')
  loss=$(printf '%s\n' "$out" | grep -oE '[0-9]+(\.[0-9]+)?% packet loss' | grep -oE '^[0-9.]+')

  rtt_line=$(printf '%s\n' "$out" | grep -E '(round-trip|rtt) min/avg/max')
  if [ -n "$rtt_line" ]; then
    rtt_min=$(printf '%s\n' "$rtt_line" | sed -E 's#.*= ?([0-9.]+)/([0-9.]+)/([0-9.]+).*#\1#')
    rtt_avg=$(printf '%s\n' "$rtt_line" | sed -E 's#.*= ?([0-9.]+)/([0-9.]+)/([0-9.]+).*#\2#')
    rtt_max=$(printf '%s\n' "$rtt_line" | sed -E 's#.*= ?([0-9.]+)/([0-9.]+)/([0-9.]+).*#\3#')
  fi

  # 100% loss (or a target that errors out before printing stats) leaves
  # sent/received/loss blank and rtt_* unset upstream; default them so
  # every row is complete (rtt_* become SQL NULL, not the string "NULL").
  sent=${sent:-$PingCount}
  received=${received:-0}
  loss=${loss:-100}

  local esc_label esc_host
  esc_label=$(sql_escape "$label")
  esc_host=$(sql_escape "$host")

  printf "INSERT INTO pings (ts, label, target, sent, received, loss_pct, rtt_min_ms, rtt_avg_ms, rtt_max_ms) VALUES ('%s', '%s', '%s', %s, %s, %s, %s, %s, %s);\n" \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$esc_label" "$esc_host" "$sent" "$received" "$loss" \
    "${rtt_min:-NULL}" "${rtt_avg:-NULL}" "${rtt_max:-NULL}"
}

### --- Main --------------------------------------------------------------------

# All targets are probed first and their INSERTs collected, then written in
# a single transaction — one sqlite3 invocation per run instead of one per
# target, and a smaller lock window.
sql_batch="BEGIN;"$'\n'
for t in "${Targets[@]}"; do
  sql_batch+="$(probe_target "${t%%:*}" "${t#*:}")"$'\n'
done
sql_batch+="COMMIT;"

printf '%s\n' "$sql_batch" | sqlite3 "$DbFile"
