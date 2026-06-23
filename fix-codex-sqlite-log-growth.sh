#!/usr/bin/env bash
set -euo pipefail

# Mitigate Codex SQLite log growth on macOS.
#
# Actions:
#   1. Persist a lower app-server log level with launchctl.
#   2. Disable Codex analytics in ~/.codex/config.toml, preserving a backup.
#   3. Quit Codex and stop app-server processes.
#   4. Archive SQLite log databases instead of deleting them.
#   5. Restart Codex and sample log DB growth.
#
# Usage:
#   bash fix-codex-sqlite-log-growth.sh
#   RUST_LOG_LEVEL=error bash fix-codex-sqlite-log-growth.sh
#   ACTION=check bash fix-codex-sqlite-log-growth.sh
#   ACTION=ramdisk RAMDISK_SIZE_GB=2 bash fix-codex-sqlite-log-growth.sh
#   ACTION=external SQLITE_TARGET=/Volumes/MyDisk/CodexSQLite bash fix-codex-sqlite-log-growth.sh
#   RESTART_CODEX=0 bash fix-codex-sqlite-log-growth.sh
#   SAMPLE_SECONDS=0 bash fix-codex-sqlite-log-growth.sh

ACTION="${ACTION:-fix}"
RUST_LOG_LEVEL="${RUST_LOG_LEVEL:-warn}"
RESTART_CODEX="${RESTART_CODEX:-1}"
FORCE_QUIT_CODEX="${FORCE_QUIT_CODEX:-1}"
MIGRATE_EXISTING_SQLITE="${MIGRATE_EXISTING_SQLITE:-1}"
OVERWRITE_SQLITE_TARGET="${OVERWRITE_SQLITE_TARGET:-0}"
PERSIST_SQLITE_HOME="${PERSIST_SQLITE_HOME:-}"
SQLITE_TARGET="${SQLITE_TARGET:-}"
RAMDISK_NAME="${RAMDISK_NAME:-CodexSQLiteRAM}"
RAMDISK_SIZE_GB="${RAMDISK_SIZE_GB:-2}"
SAMPLE_SECONDS="${SAMPLE_SECONDS:-600}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-60}"
CHECK_SECONDS="${CHECK_SECONDS:-120}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
CHURN_SEQ_WARN_PER_MIN="${CHURN_SEQ_WARN_PER_MIN:-1000}"
SIZE_WARN_BYTES_PER_MIN="${SIZE_WARN_BYTES_PER_MIN:-10485760}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
APP_BUNDLE="${APP_BUNDLE:-/Applications/Codex.app}"
STOP_TIMEOUT_SECONDS="${STOP_TIMEOUT_SECONDS:-20}"
RESTART_TIMEOUT_SECONDS="${RESTART_TIMEOUT_SECONDS:-30}"
CONFIG_FILE="$CODEX_HOME/config.toml"
LOG_DB="$CODEX_HOME/logs_2.sqlite"
LOG_WAL="$CODEX_HOME/logs_2.sqlite-wal"
ARCHIVE_ROOT="$CODEX_HOME/log-db-archive"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_DIR="$ARCHIVE_ROOT/$STAMP"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

validate_settings() {
  case "$ACTION" in
    fix|check|ramdisk|external) ;;
    *) die "ACTION must be fix, check, ramdisk, or external" ;;
  esac

  case "$RUST_LOG_LEVEL" in
    error|warn|info|debug|trace) ;;
    *) die "RUST_LOG_LEVEL must be one of: error, warn, info, debug, trace" ;;
  esac

  case "$RESTART_CODEX" in
    0|1) ;;
    *) die "RESTART_CODEX must be 0 or 1" ;;
  esac

  case "$FORCE_QUIT_CODEX" in
    0|1) ;;
    *) die "FORCE_QUIT_CODEX must be 0 or 1" ;;
  esac

  case "$MIGRATE_EXISTING_SQLITE" in
    0|1) ;;
    *) die "MIGRATE_EXISTING_SQLITE must be 0 or 1" ;;
  esac

  case "$OVERWRITE_SQLITE_TARGET" in
    0|1) ;;
    *) die "OVERWRITE_SQLITE_TARGET must be 0 or 1" ;;
  esac

  if [ -n "$PERSIST_SQLITE_HOME" ]; then
    case "$PERSIST_SQLITE_HOME" in
      0|1) ;;
      *) die "PERSIST_SQLITE_HOME must be 0 or 1 when set" ;;
    esac
  fi

  case "$SAMPLE_SECONDS" in
    ''|*[!0-9]*) die "SAMPLE_SECONDS must be a non-negative integer" ;;
  esac

  case "$SAMPLE_INTERVAL" in
    ''|*[!0-9]*) die "SAMPLE_INTERVAL must be a positive integer" ;;
  esac

  if [ "$SAMPLE_INTERVAL" -le 0 ]; then
    die "SAMPLE_INTERVAL must be greater than 0"
  fi

  case "$CHECK_SECONDS" in
    ''|*[!0-9]*) die "CHECK_SECONDS must be a non-negative integer" ;;
  esac

  case "$CHECK_INTERVAL" in
    ''|*[!0-9]*) die "CHECK_INTERVAL must be a positive integer" ;;
  esac

  if [ "$CHECK_INTERVAL" -le 0 ]; then
    die "CHECK_INTERVAL must be greater than 0"
  fi

  case "$CHURN_SEQ_WARN_PER_MIN" in
    ''|*[!0-9]*) die "CHURN_SEQ_WARN_PER_MIN must be a non-negative integer" ;;
  esac

  case "$SIZE_WARN_BYTES_PER_MIN" in
    ''|*[!0-9]*) die "SIZE_WARN_BYTES_PER_MIN must be a non-negative integer" ;;
  esac

  case "$STOP_TIMEOUT_SECONDS" in
    ''|*[!0-9]*) die "STOP_TIMEOUT_SECONDS must be a positive integer" ;;
  esac

  if [ "$STOP_TIMEOUT_SECONDS" -le 0 ]; then
    die "STOP_TIMEOUT_SECONDS must be greater than 0"
  fi

  case "$RESTART_TIMEOUT_SECONDS" in
    ''|*[!0-9]*) die "RESTART_TIMEOUT_SECONDS must be a positive integer" ;;
  esac

  if [ "$RESTART_TIMEOUT_SECONDS" -le 0 ]; then
    die "RESTART_TIMEOUT_SECONDS must be greater than 0"
  fi

  if [ ! -d "$CODEX_HOME" ]; then
    die "CODEX_HOME does not exist: $CODEX_HOME"
  fi

  if [ "$ACTION" = "fix" ] && [ "$RESTART_CODEX" = "1" ] && [ ! -d "$APP_BUNDLE" ]; then
    die "APP_BUNDLE does not exist: $APP_BUNDLE"
  fi

  if [ "$ACTION" = "external" ] && [ -z "$SQLITE_TARGET" ]; then
    die "SQLITE_TARGET is required for ACTION=external"
  fi

  if [ "$ACTION" = "ramdisk" ]; then
    case "$RAMDISK_SIZE_GB" in
      ''|*[!0-9]*) die "RAMDISK_SIZE_GB must be a positive integer" ;;
    esac
    if [ "$RAMDISK_SIZE_GB" -le 0 ]; then
      die "RAMDISK_SIZE_GB must be greater than 0"
    fi
  fi
}

prepare_archive_dir() {
  local base="$ARCHIVE_DIR"
  local suffix=1

  while [ -e "$ARCHIVE_DIR" ]; do
    ARCHIVE_DIR="${base}-$suffix"
    suffix=$((suffix + 1))
  done
}

backup_and_patch_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    log "config not found: $CONFIG_FILE; skipping config patch"
    return
  fi

  local backup="$CONFIG_FILE.bak-$STAMP"
  cp -p "$CONFIG_FILE" "$backup"
  log "backed up config to $backup"

  python3 - "$CONFIG_FILE" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()

def upsert_section_values(doc, section, values):
    section_match = re.search(rf'(?m)^\[{re.escape(section)}\]\s*$', doc)
    if section_match:
        start = section_match.end()
        next_section = re.search(r'(?m)^\[[^\n]+\]\s*$', doc[start:])
        end = start + next_section.start() if next_section else len(doc)
        body = doc[start:end]
        for key, value in values.items():
            pattern = rf'(?m)^(\s*{re.escape(key)}\s*=\s*).*$'
            if re.search(pattern, body):
                body = re.sub(pattern, rf'\g<1>{value}', body, count=1)
            else:
                if body and not body.startswith('\n'):
                    body = '\n' + body
                body = f'\n{key} = {value}' + body
        return doc[:start] + body + doc[end:]
    else:
        if doc and not doc.endswith('\n'):
            doc += '\n'
        lines = [f'[{section}]']
        lines.extend(f'{key} = {value}' for key, value in values.items())
        return doc + '\n' + '\n'.join(lines) + '\n'

text = upsert_section_values(text, 'analytics', {
    'enabled': 'false',
})
text = upsert_section_values(text, 'otel', {
    'exporter': '"none"',
    'trace_exporter': '"none"',
    'metrics_exporter': '"none"',
    'log_user_prompt': 'false',
})

path.write_text(text)
PY
  log "set [analytics].enabled=false and disabled [otel] exporters in $CONFIG_FILE"
}

backup_and_set_sqlite_home_config() {
  local target="$1"

  if [ ! -f "$CONFIG_FILE" ]; then
    log "config not found: $CONFIG_FILE; creating config with sqlite_home"
    printf 'sqlite_home = "%s"\n' "$target" >"$CONFIG_FILE"
    return
  fi

  local backup="$CONFIG_FILE.bak-sqlite-home-$STAMP"
  cp -p "$CONFIG_FILE" "$backup"
  log "backed up config to $backup"

  python3 - "$CONFIG_FILE" "$target" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
target = sys.argv[2]
text = path.read_text()
line = f'sqlite_home = "{target}"\n'

if re.search(r'(?m)^sqlite_home\s*=', text):
    text = re.sub(r'(?m)^sqlite_home\s*=.*$', line.rstrip('\n'), text, count=1)
else:
    first_section = re.search(r'(?m)^\[[^\n]+\]\s*$', text)
    if first_section:
        insert_at = first_section.start()
        prefix = text[:insert_at]
        suffix = text[insert_at:]
        if prefix and not prefix.endswith('\n'):
            prefix += '\n'
        text = prefix + line + suffix
    else:
        if text and not text.endswith('\n'):
            text += '\n'
        text += line

path.write_text(text)
PY
  log "set sqlite_home=$target in $CONFIG_FILE"
}

config_has_sqlite_home() {
  [ -f "$CONFIG_FILE" ] && awk '/^sqlite_home[[:space:]]*=/{found=1} END{exit found ? 0 : 1}' "$CONFIG_FILE"
}

stop_codex() {
  log "asking Codex.app to quit"
  osascript -e 'quit app "Codex"' >/dev/null 2>&1 || true

  local waited=0
  while [ "$waited" -lt "$STOP_TIMEOUT_SECONDS" ]; do
    if ! pgrep -x Codex >/dev/null 2>&1 && ! pgrep -f 'codex app-server' >/dev/null 2>&1; then
      log "Codex.app and app-server stopped"
      return
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if pgrep -f 'codex app-server' >/dev/null 2>&1; then
    log "stopping remaining codex app-server processes"
    pkill -TERM -f 'codex app-server' >/dev/null 2>&1 || true
    sleep 3
  fi

  if [ "$FORCE_QUIT_CODEX" = "1" ] && pgrep -x Codex >/dev/null 2>&1; then
    log "stopping remaining Codex.app processes"
    pkill -TERM -x Codex >/dev/null 2>&1 || true
    sleep 3
  fi

  if pgrep -f 'codex app-server' >/dev/null 2>&1; then
    log "force-stopping remaining codex app-server processes"
    pkill -KILL -f 'codex app-server' >/dev/null 2>&1 || true
    sleep 1
  fi

  if [ "$FORCE_QUIT_CODEX" = "1" ] && pgrep -x Codex >/dev/null 2>&1; then
    log "force-stopping remaining Codex.app processes"
    pkill -KILL -x Codex >/dev/null 2>&1 || true
    sleep 1
  fi

  if pgrep -f 'codex app-server' >/dev/null 2>&1; then
    die "codex app-server is still running; refusing to archive live SQLite logs"
  fi
}

archive_log_dbs() {
  mkdir -p "$ARCHIVE_DIR/root" "$ARCHIVE_DIR/sqlite"

  local moved=0
  local file

  for file in \
    "$CODEX_HOME/logs_2.sqlite" \
    "$CODEX_HOME/logs_2.sqlite-wal" \
    "$CODEX_HOME/logs_2.sqlite-shm"; do
    if [ -e "$file" ]; then
      log "archiving $file"
      mv "$file" "$ARCHIVE_DIR/root/"
      moved=1
    fi
  done

  for file in \
    "$CODEX_HOME/sqlite/logs_2.sqlite" \
    "$CODEX_HOME/sqlite/logs_2.sqlite-wal" \
    "$CODEX_HOME/sqlite/logs_2.sqlite-shm"; do
    if [ -e "$file" ]; then
      log "archiving $file"
      mv "$file" "$ARCHIVE_DIR/sqlite/"
      moved=1
    fi
  done

  if [ "$moved" -eq 0 ]; then
    log "no logs_2 SQLite files found to archive"
    rmdir "$ARCHIVE_DIR/root" "$ARCHIVE_DIR/sqlite" "$ARCHIVE_DIR" 2>/dev/null || true
  else
    log "archived SQLite log files under $ARCHIVE_DIR"
  fi
}

restart_codex() {
  if [ "$RESTART_CODEX" = "1" ]; then
    log "reopening Codex.app from $APP_BUNDLE"
    open "$APP_BUNDLE"
    osascript -e 'tell application "Codex" to activate' >/dev/null 2>&1 || true

    local waited=0
    while [ "$waited" -lt "$RESTART_TIMEOUT_SECONDS" ]; do
      if pgrep -x Codex >/dev/null 2>&1; then
        log "Codex.app is running"
        break
      fi
      sleep 1
      waited=$((waited + 1))
    done

    if ! pgrep -x Codex >/dev/null 2>&1; then
      die "Codex.app did not start within ${RESTART_TIMEOUT_SECONDS}s"
    fi

    waited=0
    while [ "$waited" -lt "$RESTART_TIMEOUT_SECONDS" ]; do
      if pgrep -f 'codex app-server' >/dev/null 2>&1; then
        log "codex app-server is running"
        return
      fi
      sleep 1
      waited=$((waited + 1))
    done

    log "warning: Codex.app started, but app-server was not observed within ${RESTART_TIMEOUT_SECONDS}s"
  else
    log "RESTART_CODEX=0; leaving Codex stopped"
  fi
}

sample_growth() {
  if [ "$SAMPLE_SECONDS" = "0" ]; then
    log "SAMPLE_SECONDS=0; skipping growth sampling"
    return
  fi

  local iterations=$((SAMPLE_SECONDS / SAMPLE_INTERVAL))
  if [ "$iterations" -lt 1 ]; then
    iterations=1
  fi

  log "sampling SQLite log sizes for about $((iterations * SAMPLE_INTERVAL)) seconds"
  for ((i = 1; i <= iterations; i++)); do
    printf '\n[%s] sample %d/%d\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$i" "$iterations"
    stat -f '%z bytes  %N' \
      "$CODEX_HOME/logs_2.sqlite" \
      "$CODEX_HOME/logs_2.sqlite-wal" \
      "$CODEX_HOME/sqlite/logs_2.sqlite" \
      "$CODEX_HOME/sqlite/logs_2.sqlite-wal" 2>/dev/null || true
    sleep "$SAMPLE_INTERVAL"
  done
}

copy_existing_sqlite_files() {
  local target="$1"
  local source_dir="$CODEX_HOME"
  local copied=0
  local file
  local dest

  if [ "$MIGRATE_EXISTING_SQLITE" != "1" ]; then
    log "MIGRATE_EXISTING_SQLITE=0; not copying existing SQLite state"
    return
  fi

  mkdir -p "$target"

  for file in "$source_dir"/*.sqlite "$source_dir"/*.sqlite-wal "$source_dir"/*.sqlite-shm; do
    [ -e "$file" ] || continue
    dest="$target/$(basename "$file")"
    if [ -e "$dest" ] && [ "$OVERWRITE_SQLITE_TARGET" != "1" ]; then
      log "keeping existing target file $dest"
      continue
    fi
    log "copying $(basename "$file") to $target"
    cp -p "$file" "$dest"
    copied=1
  done

  if [ "$copied" = "0" ]; then
    log "no root SQLite files copied from $source_dir"
  fi
}

set_runtime_sqlite_home() {
  local target="$1"

  log "setting launchctl CODEX_SQLITE_HOME=$target"
  launchctl setenv CODEX_SQLITE_HOME "$target"
}

create_ramdisk() {
  need_cmd hdiutil
  need_cmd diskutil

  if [ -d "/Volumes/$RAMDISK_NAME" ]; then
    SQLITE_TARGET="/Volumes/$RAMDISK_NAME"
    log "using existing RAM disk at $SQLITE_TARGET"
    return
  fi

  local sectors=$((RAMDISK_SIZE_GB * 1024 * 1024 * 1024 / 512))
  local disk
  log "creating ${RAMDISK_SIZE_GB}GB RAM disk named $RAMDISK_NAME"
  disk="$(hdiutil attach -nomount "ram://$sectors" | awk '/^\/dev\/disk/{print $1; exit}')"
  if [ -z "$disk" ]; then
    die "hdiutil did not return a RAM disk device"
  fi

  if ! diskutil eraseDisk APFS "$RAMDISK_NAME" "$disk" >/dev/null; then
    hdiutil detach "$disk" >/dev/null 2>&1 || true
    die "failed to format RAM disk device $disk"
  fi

  SQLITE_TARGET="/Volumes/$RAMDISK_NAME"
  log "created RAM disk at $SQLITE_TARGET"
}

relocate_sqlite_home() {
  local persist_default="$1"

  need_cmd osascript
  need_cmd launchctl
  need_cmd python3
  need_cmd stat
  need_cmd pgrep
  need_cmd pkill

  if [ "$RESTART_CODEX" = "1" ] && [ ! -d "$APP_BUNDLE" ]; then
    die "APP_BUNDLE does not exist: $APP_BUNDLE"
  fi

  if [ "$ACTION" = "ramdisk" ]; then
    create_ramdisk
  else
    mkdir -p "$SQLITE_TARGET"
  fi

  if [ -z "$PERSIST_SQLITE_HOME" ]; then
    PERSIST_SQLITE_HOME="$persist_default"
  fi

  if [ "$ACTION" = "ramdisk" ] && [ "$PERSIST_SQLITE_HOME" != "1" ] && config_has_sqlite_home; then
    die "config already has sqlite_home; it would override CODEX_SQLITE_HOME. Remove it or rerun with PERSIST_SQLITE_HOME=1"
  fi

  log "CODEX_HOME=$CODEX_HOME"
  log "SQLITE_TARGET=$SQLITE_TARGET"
  log "setting launchctl RUST_LOG=$RUST_LOG_LEVEL"
  launchctl setenv RUST_LOG "$RUST_LOG_LEVEL"

  backup_and_patch_config
  stop_codex
  copy_existing_sqlite_files "$SQLITE_TARGET"
  set_runtime_sqlite_home "$SQLITE_TARGET"

  if [ "$PERSIST_SQLITE_HOME" = "1" ]; then
    backup_and_set_sqlite_home_config "$SQLITE_TARGET"
  else
    log "PERSIST_SQLITE_HOME=0; sqlite_home was not written to config"
  fi

  restart_codex
  sample_growth

  log "done"
  log "SQLite home is $SQLITE_TARGET"
  if [ "$ACTION" = "ramdisk" ]; then
    log "RAM disk data is volatile; recreate it before launching Codex after reboot"
  fi
}

read_log_seq() {
  sqlite3 "file:$LOG_DB?mode=ro" \
    "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='logs'), 0);" \
    2>/dev/null || printf '0\n'
}

read_log_rows() {
  sqlite3 "file:$LOG_DB?mode=ro" "SELECT COUNT(*) FROM logs;" 2>/dev/null || printf '0\n'
}

check_churn() {
  need_cmd sqlite3

  if [ ! -f "$LOG_DB" ]; then
    die "log database not found: $LOG_DB"
  fi

  local iterations=$((CHECK_SECONDS / CHECK_INTERVAL))
  if [ "$iterations" -lt 1 ]; then
    iterations=1
  fi

  local start_ts
  local end_ts
  local start_seq
  local end_seq
  local start_size
  local end_size
  local start_wal_size
  local end_wal_size
  local rows

  start_ts="$(date +%s)"
  start_seq="$(read_log_seq)"
  start_size="$(stat -f '%z' "$LOG_DB" 2>/dev/null || printf '0')"
  start_wal_size="$(stat -f '%z' "$LOG_WAL" 2>/dev/null || printf '0')"

  log "checking SQLite log churn for about $((iterations * CHECK_INTERVAL)) seconds"
  log "start: seq=$start_seq db_bytes=$start_size wal_bytes=$start_wal_size"

  for ((i = 1; i <= iterations; i++)); do
    sleep "$CHECK_INTERVAL"
    rows="$(read_log_rows)"
    end_seq="$(read_log_seq)"
    end_size="$(stat -f '%z' "$LOG_DB" 2>/dev/null || printf '0')"
    end_wal_size="$(stat -f '%z' "$LOG_WAL" 2>/dev/null || printf '0')"
    log "sample $i/$iterations: rows=$rows seq=$end_seq db_bytes=$end_size wal_bytes=$end_wal_size"
  done

  end_ts="$(date +%s)"
  end_seq="$(read_log_seq)"
  end_size="$(stat -f '%z' "$LOG_DB" 2>/dev/null || printf '0')"
  end_wal_size="$(stat -f '%z' "$LOG_WAL" 2>/dev/null || printf '0')"

  local elapsed=$((end_ts - start_ts))
  if [ "$elapsed" -le 0 ]; then
    elapsed=1
  fi

  local seq_delta=$((end_seq - start_seq))
  local size_delta=$((end_size + end_wal_size - start_size - start_wal_size))
  local seq_per_min=$((seq_delta * 60 / elapsed))
  local bytes_per_min=$((size_delta * 60 / elapsed))

  log "result: elapsed=${elapsed}s seq_delta=$seq_delta seq_per_min=$seq_per_min bytes_per_min=$bytes_per_min"

  if [ "$seq_per_min" -gt "$CHURN_SEQ_WARN_PER_MIN" ] || [ "$bytes_per_min" -gt "$SIZE_WARN_BYTES_PER_MIN" ]; then
    die "high churn detected; thresholds seq/min>$CHURN_SEQ_WARN_PER_MIN or bytes/min>$SIZE_WARN_BYTES_PER_MIN"
  fi

  log "no high churn detected"
}

fix_growth() {
  need_cmd osascript
  need_cmd launchctl
  need_cmd python3
  need_cmd stat

  prepare_archive_dir

  log "CODEX_HOME=$CODEX_HOME"
  log "setting launchctl RUST_LOG=$RUST_LOG_LEVEL"
  launchctl setenv RUST_LOG "$RUST_LOG_LEVEL"

  backup_and_patch_config
  stop_codex
  archive_log_dbs
  restart_codex
  sample_growth

  log "done"
  log "restore config with: cp '$CONFIG_FILE.bak-$STAMP' '$CONFIG_FILE'"
  log "restore archived DBs from: $ARCHIVE_DIR"
}

main() {
  need_cmd stat
  validate_settings

  case "$ACTION" in
    fix) fix_growth ;;
    check) check_churn ;;
    ramdisk) relocate_sqlite_home 0 ;;
    external) relocate_sqlite_home 1 ;;
  esac
}

main "$@"
