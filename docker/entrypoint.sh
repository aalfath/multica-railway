#!/bin/sh
set -eu

# The migrator and API server are separate processes, but startup retry time is
# one container-level budget. Both binaries derive their remaining time from
# this entrypoint timestamp. Always overwrite inherited values to avoid reusing
# a stale timestamp after a container restart.
export MULTICA_INTERNAL_DATABASE_STARTUP_STARTED_AT_UNIX="$(date +%s)"

# These directories live on the Railway backend volume. Creating them at
# startup is necessary because volumes are mounted after the image is built.
data_root="${MULTICA_DATA_ROOT:-/app/data}"
mkdir -p "$HOME" "$MULTICA_WORKSPACES_ROOT" "$data_root/uploads"

migrate_pid=""
server_pid=""
daemon_supervisor_pid=""
daemon_auto_start="${MULTICA_DAEMON_AUTO_START:-false}"

case "$daemon_auto_start" in
    1|true|TRUE|yes|YES) daemon_auto_start=true ;;
    *) daemon_auto_start=false ;;
esac

stop_migration() {
  signal="$1"
  exit_code="$2"
  trap - TERM INT
  if [ -n "$migrate_pid" ]; then
    kill "-$signal" "$migrate_pid" 2>/dev/null || true
    wait "$migrate_pid" 2>/dev/null || true
  fi
  exit "$exit_code"
}

stop_running_children() {
  signal="$1"

  if [ -n "$daemon_supervisor_pid" ]; then
    kill "$daemon_supervisor_pid" 2>/dev/null || true
    wait "$daemon_supervisor_pid" 2>/dev/null || true
    daemon_supervisor_pid=""
  fi

  # Stop a daemon that was started automatically or manually in this
  # container. `daemon stop` is local-only and does not require authentication.
  if [ "$daemon_auto_start" = "true" ] && [ -x ./multica ]; then
    ./multica daemon stop >/dev/null 2>&1 || true
  fi

  if [ -n "$server_pid" ]; then
    kill "-$signal" "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
}

stop_server() {
  signal="$1"
  exit_code="$2"
  trap - TERM INT
  stop_running_children "$signal"
  exit "$exit_code"
}

daemon_autostart_loop() {
  interval="${MULTICA_DAEMON_AUTO_START_INTERVAL:-30}"
  daemon_token="${MULTICA_DAEMON_TOKEN:-}"
  daemon_server_url="${MULTICA_DAEMON_SERVER_URL:-${MULTICA_SERVER_URL:-}}"
  daemon_app_url="${MULTICA_DAEMON_APP_URL:-${MULTICA_APP_URL:-}}"

  while :; do
    # Keep the persistent CLI profile pointed at this deployment even when no
    # unattended token is configured. This prevents a manual `multica setup`
    # from leaving the Railway container pointed at Multica Cloud.
    if [ -n "$daemon_server_url" ]; then
      ./multica config set server_url "$daemon_server_url" >/dev/null 2>&1 || true
    fi
    if [ -n "$daemon_app_url" ]; then
      ./multica config set app_url "$daemon_app_url" >/dev/null 2>&1 || true
    fi

    # A token supplied as a Railway secret can complete the same setup sequence
    # the UI prints: persist the server/app URLs, log in, and then start the
    # daemon. The token is piped to the CLI prompt instead of placed in argv.
    if [ -n "$daemon_token" ]; then
      daemon_auth_status="$(./multica auth status 2>&1 || true)"
      if ! printf '%s\n' "$daemon_auth_status" | grep -q 'User:'; then
        if printf '%s\n' "$daemon_token" | ./multica login --token= >/dev/null 2>&1; then
          echo "Multica CLI authenticated automatically from MULTICA_DAEMON_TOKEN."
        else
          echo "Automatic Multica login deferred; verify MULTICA_DAEMON_TOKEN and the configured server URL."
          sleep "$interval"
          continue
        fi
      fi
    fi

    # `daemon start` requires a stored Multica login token. Before the user
    # completes setup, keep the server healthy and retry quietly. Once the
    # token is supplied or the user authenticates over Railway SSH, the next
    # iteration starts the daemon without another restart command.
    daemon_status="$(./multica daemon status --output json 2>/dev/null || true)"
    if printf '%s\n' "$daemon_status" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"running"'; then
      sleep "$interval"
      continue
    fi

    if daemon_start_output="$(./multica daemon start --no-auto-update --no-auto-reload 2>&1)"; then
      echo "Multica daemon started automatically."
    else
      case "$daemon_start_output" in
        *"not logged in"*)
          echo "Multica daemon is waiting for authentication; run 'multica setup self-host' via Railway SSH."
          ;;
        *"already running"*)
          ;;
        *)
          echo "Automatic Multica daemon start deferred: $daemon_start_output"
          ;;
      esac
    fi

    sleep "$interval"
  done
}

trap 'stop_migration TERM 143' TERM
trap 'stop_migration INT 130' INT

echo "Running database migrations..."
./migrate up &
migrate_pid=$!
if wait "$migrate_pid"; then
  migrate_status=0
else
  migrate_status=$?
fi
migrate_pid=""
trap - TERM INT
if [ "$migrate_status" -ne 0 ]; then
  exit "$migrate_status"
fi

echo "Starting server..."
trap 'stop_server TERM 143' TERM
trap 'stop_server INT 130' INT

./server &
server_pid=$!

if [ "$daemon_auto_start" = "true" ]; then
  echo "Multica daemon auto-start enabled; waiting for CLI authentication."
  daemon_autostart_loop &
  daemon_supervisor_pid=$!
fi

if wait "$server_pid"; then
  server_status=0
else
  server_status=$?
fi
server_pid=""
stop_running_children TERM
exit "$server_status"
