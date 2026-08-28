#!/usr/bin/env python3
#
# fritz_dsl_stats.py — polls the Fritzbox's own DSL line stats over TR-064
# (sync rate, noise margin, attenuation, cumulative retrain/error counters)
# and logs one row into the same SQLite DB as NetMonitor.sh, so line-quality
# telemetry and ping results can be correlated by timestamp.
#
# Bottens-only: this talks to the Fritzbox's TR-064/DSL API, which only
# exists on the ADSL/VDSL line here. St-Benoit's Freebox (fiber) has no
# equivalent DSL service and uses a completely different local API
# (Freebox OS), so there's no "St-Benoit variant" of this script to fill in.
#
# Why TR-064 needs `requests`/fritzconnection instead of curl: this Fritzbox
# never answers a clean 401 challenge to an empty probe body the way
# `curl --digest` sends it (confirmed 2026-08-28) — it needs the real SOAP
# body present on the very first (unauthenticated) request to respond
# correctly, which only fritzconnection (via `requests`) does out of the box.
#
# Deployment: run inside a dedicated venv (keeps this off DSM's shared
# system Python3, used by other packages/projects on the NAS):
#   python3 -m venv venv
#   venv/bin/pip install -r requirements.txt
# Task Scheduler "user-defined script" (as root): the venv's own
# interpreter, no activation needed:
#   /volume1/homes/Deimos-admin/NetReconnector/venv/bin/python3 \
#     /volume1/homes/Deimos-admin/NetReconnector/fritz_dsl_stats.py
#
# Credentials: read from ConfigFile below (KEY=value, one per line) — see
# fritzbox.env.example for the format. That file must live OUTSIDE this git
# checkout and be chmod 600; it is never committed.

import glob
import os
import sqlite3
import sys

from fritzconnection import FritzConnection
from fritzconnection.core.exceptions import FritzConnectionException

### --- Per-host configuration -------------------------------------------------

DbFile = "/volume1/homes/Deimos-admin/NetMonitor-Bottens.db"
ConfigFile = "/volume1/homes/Deimos-admin/.config/NetReconnector/fritzbox.env"
FritzboxHost = "192.168.178.1"

### --- Load credentials --------------------------------------------------------


def load_env(path):
    values = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip()
    except OSError as e:
        sys.exit(f"fritz_dsl_stats.py: cannot read {path}: {e}")
    for required in ("FRITZ_USER", "FRITZ_PASSWORD"):
        if required not in values:
            sys.exit(f"fritz_dsl_stats.py: {path} is missing {required}")
    return values["FRITZ_USER"], values["FRITZ_PASSWORD"]


### --- DB setup -----------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS dsl_stats (
  id                          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts                          TEXT    NOT NULL,
  link_status                 TEXT,
  uptime_s                    INTEGER,
  upstream_curr_kbps          INTEGER,
  downstream_curr_kbps        INTEGER,
  upstream_max_kbps           INTEGER,
  downstream_max_kbps         INTEGER,
  upstream_noise_margin_db    REAL,
  downstream_noise_margin_db  REAL,
  upstream_attenuation_db     REAL,
  downstream_attenuation_db   REAL,
  link_retrain_total          INTEGER,
  crc_errors_total            INTEGER,
  fec_errors_total            INTEGER,
  errored_secs_total          INTEGER,
  severely_errored_secs_total INTEGER
);
"""


def main():
    user, password = load_env(ConfigFile)

    try:
        fc = FritzConnection(address=FritzboxHost, user=user, password=password)
        device_info = fc.call_action("DeviceInfo1", "GetInfo")
        dsl_info = fc.call_action("WANDSLInterfaceConfig1", "GetInfo")
        dsl_stats = fc.call_action("WANDSLInterfaceConfig1", "GetStatisticsTotal")
    except FritzConnectionException as e:
        sys.exit(f"fritz_dsl_stats.py: TR-064 call failed: {e}")

    row = (
        dsl_info["NewStatus"],
        device_info["NewUpTime"],
        dsl_info["NewUpstreamCurrRate"],
        dsl_info["NewDownstreamCurrRate"],
        dsl_info["NewUpstreamMaxRate"],
        dsl_info["NewDownstreamMaxRate"],
        dsl_info["NewUpstreamNoiseMargin"] / 10.0,
        dsl_info["NewDownstreamNoiseMargin"] / 10.0,
        dsl_info["NewUpstreamAttenuation"] / 10.0,
        dsl_info["NewDownstreamAttenuation"] / 10.0,
        dsl_stats["NewLinkRetrain"],
        dsl_stats["NewCRCErrors"],
        dsl_stats["NewFECErrors"],
        dsl_stats["NewErroredSecs"],
        dsl_stats["NewSeverelyErroredSecs"],
    )

    conn = sqlite3.connect(DbFile)
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.execute(SCHEMA)
    conn.execute(
        """
        INSERT INTO dsl_stats (
          ts, link_status, uptime_s,
          upstream_curr_kbps, downstream_curr_kbps,
          upstream_max_kbps, downstream_max_kbps,
          upstream_noise_margin_db, downstream_noise_margin_db,
          upstream_attenuation_db, downstream_attenuation_db,
          link_retrain_total, crc_errors_total, fec_errors_total,
          errored_secs_total, severely_errored_secs_total
        ) VALUES (datetime('now', 'localtime'), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        row,
    )
    conn.commit()
    conn.close()

    # Runs as root (see Task Scheduler note above) — keep the DB (and its
    # WAL/SHM sidecars) world-readable, same rationale as NetMonitor.sh.
    for path in glob.glob(DbFile + "*"):
        os.chmod(path, 0o644)


if __name__ == "__main__":
    main()
