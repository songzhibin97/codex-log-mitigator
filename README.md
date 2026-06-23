# codex-log-mitigator

Mitigate excessive local SQLite log growth from the Codex macOS app.

This script is for cases where `~/.codex/logs_2.sqlite` or its WAL file grows quickly and keeps receiving trace or transport logs during normal Codex use. It can either reduce the volume of local logging, rotate bloated log databases, or move Codex SQLite state away from the internal SSD.

## What it does

- Sets a lower Codex app-server log level with `launchctl setenv RUST_LOG`.
- Sets `[analytics].enabled = false` in `~/.codex/config.toml`.
- Sets `[otel].exporter`, `[otel].trace_exporter`, and `[otel].metrics_exporter` to `none`, and sets `[otel].log_user_prompt = false`.
- Backs up the original config before editing it.
- Quits Codex and stops remaining `codex app-server` processes.
- Archives `logs_2.sqlite`, `logs_2.sqlite-wal`, and `logs_2.sqlite-shm` instead of deleting them.
- Reopens Codex and, for `ACTION=fix`, samples the new default log database size.
- Can relocate Codex SQLite state to an external drive or a RAM disk.

The archive is written under:

```text
~/.codex/log-db-archive/<timestamp>/
```

## Requirements

- macOS
- Codex app installed as `Codex.app`
- `bash`, `python3`, `launchctl`, `osascript`, `stat`, `pgrep`, and `pkill`
- `sqlite3` for `ACTION=check`
- `hdiutil` and `diskutil` for `ACTION=ramdisk`
- `lsof` for active-file verification

## Usage

Run from Terminal:

```bash
bash fix-codex-sqlite-log-growth.sh
```

Use a stricter log level:

```bash
RUST_LOG_LEVEL=error bash fix-codex-sqlite-log-growth.sh
```

Skip reopening Codex:

```bash
RESTART_CODEX=0 bash fix-codex-sqlite-log-growth.sh
```

Use a custom app path:

```bash
APP_BUNDLE=/Applications/Codex.app bash fix-codex-sqlite-log-growth.sh
```

Skip post-run sampling:

```bash
SAMPLE_SECONDS=0 bash fix-codex-sqlite-log-growth.sh
```

Check for high-frequency SQLite churn without changing config, restarting Codex, or archiving files:

```bash
ACTION=check bash fix-codex-sqlite-log-growth.sh
```

The check mode watches both file-size growth and `sqlite_sequence` growth. The sequence counter catches insert/delete churn that may not show up as a growing database file. Because it opens a live SQLite database in read-only mode, SQLite sidecar metadata such as `-shm` timestamps may still change.

Tune check thresholds:

```bash
ACTION=check CHECK_SECONDS=180 CHURN_SEQ_WARN_PER_MIN=1000 SIZE_WARN_BYTES_PER_MIN=10485760 bash fix-codex-sqlite-log-growth.sh
```

Move SQLite state to an external drive:

```bash
ACTION=external SQLITE_TARGET=/Volumes/MyDisk/CodexSQLite RUST_LOG_LEVEL=error SAMPLE_SECONDS=0 bash fix-codex-sqlite-log-growth.sh
```

This mode writes `sqlite_home` to `~/.codex/config.toml`, so it is persistent. Make sure the external drive is mounted before starting Codex.

Move SQLite state to a 2GB RAM disk:

```bash
ACTION=ramdisk RAMDISK_SIZE_GB=2 RUST_LOG_LEVEL=error SAMPLE_SECONDS=0 bash fix-codex-sqlite-log-growth.sh
```

This mode creates or reuses `/Volumes/CodexSQLiteRAM`, sets `CODEX_SQLITE_HOME` through `launchctl`, and does not write `sqlite_home` to config by default. RAM disk contents are lost after reboot, eject, or power loss.

If `~/.codex/config.toml` already has a top-level `sqlite_home`, `ACTION=ramdisk` refuses to continue because that config value would override `CODEX_SQLITE_HOME`. Remove the setting or rerun with `PERSIST_SQLITE_HOME=1` if you intentionally want to persist the RAM disk path.

Use a different Codex home:

```bash
CODEX_HOME=/path/to/.codex bash fix-codex-sqlite-log-growth.sh
```

## Restore

The script prints restore paths at the end.

Restore the previous config:

```bash
cp ~/.codex/config.toml.bak-YYYYMMDD-HHMMSS ~/.codex/config.toml
```

Restore archived log databases only if you really need the old local logs:

```bash
cp ~/.codex/log-db-archive/YYYYMMDD-HHMMSS/root/logs_2.sqlite* ~/.codex/
cp ~/.codex/log-db-archive/YYYYMMDD-HHMMSS/sqlite/logs_2.sqlite* ~/.codex/sqlite/
```

Quit Codex before restoring archived database files.

If you used `ACTION=external`, remove or change the top-level `sqlite_home` setting in `~/.codex/config.toml` to move SQLite state back.

If you used `ACTION=ramdisk`, clear the launchctl override and restart Codex:

```bash
launchctl unsetenv CODEX_SQLITE_HOME
```

## Verify

After `ACTION=fix`, watch the new log database:

```bash
for i in {1..10}; do
  date
  stat -f '%z bytes  %N' ~/.codex/logs_2.sqlite ~/.codex/logs_2.sqlite-wal 2>/dev/null
  sleep 60
done
```

Healthy behavior is a small initial database followed by slow or flat growth during normal use.

To detect hidden churn, use:

```bash
ACTION=check bash fix-codex-sqlite-log-growth.sh
```

After `ACTION=external` or `ACTION=ramdisk`, success means Codex writes the SQLite files in the target directory and the original `~/.codex/*.sqlite*` files stop receiving new log rows. High churn may still exist; it should be redirected away from the internal SSD.

```bash
launchctl getenv CODEX_SQLITE_HOME
ls -lh /Volumes/MyDisk/CodexSQLite
ls -lh /Volumes/CodexSQLiteRAM
```

On macOS, `launchctl getenv` may be less informative than the per-user launchd environment. This is a more reliable check:

```bash
launchctl print gui/$(id -u) | grep -E 'CODEX_SQLITE_HOME|RUST_LOG'
lsof /Volumes/CodexSQLiteRAM/logs_2.sqlite /Volumes/CodexSQLiteRAM/logs_2.sqlite-wal
```

For an external drive, replace `/Volumes/CodexSQLiteRAM` with your `SQLITE_TARGET`.

To compare the redirected database with the old default path:

```bash
sqlite3 'file:/Volumes/CodexSQLiteRAM/logs_2.sqlite?mode=ro' \
  "SELECT COUNT(*), (SELECT seq FROM sqlite_sequence WHERE name='logs'), datetime(MAX(ts),'unixepoch','localtime') FROM logs;"

sqlite3 "file:$HOME/.codex/logs_2.sqlite?mode=ro&immutable=1" \
  "SELECT COUNT(*), (SELECT seq FROM sqlite_sequence WHERE name='logs'), datetime(MAX(ts),'unixepoch','localtime') FROM logs;"
```

## Notes

- This is a local mitigation script, not an official Codex fix.
- The script intentionally archives rather than removes log databases.
- It stops all matching `codex app-server` processes. Running Codex threads may be interrupted.
- By default it also terminates leftover `Codex.app` processes if normal quit does not finish within the timeout. Set `FORCE_QUIT_CODEX=0` to disable this.
- `RUST_LOG` set with `launchctl` affects future GUI processes in the current user session. Restart Codex after changing it.
- File size alone is not enough: SQLite can insert and delete many log rows while the DB size stays flat. Use `ACTION=check` to detect that case.
- The script verifies that Codex starts after reopening and warns if the app-server is not observed within the restart timeout.
- `ACTION=external` persists `sqlite_home` in config. `ACTION=ramdisk` does not persist by default because RAM disk paths disappear after reboot.
- `ACTION=ramdisk` is a containment strategy: it protects the internal SSD from Codex SQLite churn, but the RAM disk itself can still receive frequent writes.

## Limits

This tool can reduce local log volume, rotate bloated SQLite log files, move SQLite writes to another volume, and detect hidden insert/delete churn. It cannot guarantee that Codex stops writing local SQLite logs entirely. If `ACTION=check` still reports high churn after running the fix and restarting Codex, treat that as evidence for an upstream Codex logging issue rather than something this script can fully solve with public configuration.
