# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

The checked-out `main` branch contains only `LICENSE`. The actual project code lives on the `master` branch (upstream from the original fork at github.com/wxlcat/NetReconnector). If asked to work on the script, fetch it from `origin/master`:

```bash
git show origin/master:NetReconnector.sh
git show origin/master:README.md
```

## What the project is

A single bash script (`NetReconnector.sh`) intended to run on a Raspberry Pi via cron. It pings a target through a specific network interface; if 0 packets are received, it bounces the interface with `ifdown` / `ifup`. Logs go to `~/NetReconnector.log`.

Two parameters at the top of the script are meant to be edited per-host: `NetCard` (e.g. `wlan0`) and `PingTarget` (router IP or hostname).

Intended deployment: copy to `~`, `chmod +x`, add a crontab entry like `*/5 8-22 * * * ~/NetReconnector.sh`.

## Things to watch for if modifying the script

- `ifdown` / `ifup` are Debian-family tools and require `sudo`; they don't exist on systems using NetworkManager or systemd-networkd. Don't silently swap them without confirming the target environment.
- The hardcoded `wlan0` in the `ifdown`/`ifup` line ignores the `$NetCard` variable — likely a bug worth flagging if touching that block.
- `ping -I $NetCard` binds to the interface; preserve this when refactoring (a plain `ping` would defeat the point of the script on multi-homed hosts).
