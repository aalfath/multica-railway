#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
ENTRYPOINT_PID=""

export HOME="$TEST_DIR/home"
export MULTICA_DATA_ROOT="$TEST_DIR/data"
export MULTICA_WORKSPACES_ROOT="$TEST_DIR/workspaces"
export MULTICA_DAEMON_AUTO_START=false

cleanup() {
  if [ -n "$ENTRYPOINT_PID" ]; then
    kill -KILL "$ENTRYPOINT_PID" 2>/dev/null || true
  fi
  if [ -s "$TEST_DIR/migrate.pid" ]; then
    kill -KILL "$(cat "$TEST_DIR/migrate.pid")" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

cp "$ROOT_DIR/docker/entrypoint.sh" "$TEST_DIR/entrypoint.sh"

cat >"$TEST_DIR/migrate" <<'SCRIPT'
#!/bin/sh
trap 'printf "TERM\n" >"$MIGRATE_SIGNAL_FILE"; exit 143' TERM
printf '%s\n' "$$" >"$MIGRATE_PID_FILE"
printf '%s\n' "$MULTICA_INTERNAL_DATABASE_STARTUP_STARTED_AT_UNIX" >"$MIGRATE_STARTED_AT_FILE"
while :; do
  sleep 1
done
SCRIPT

cat >"$TEST_DIR/server" <<'SCRIPT'
#!/bin/sh
printf 'started\n' >"$SERVER_STARTED_FILE"
printf '%s\n' "$MULTICA_INTERNAL_DATABASE_STARTUP_STARTED_AT_UNIX" >"$SERVER_STARTED_AT_FILE"
SCRIPT

chmod +x "$TEST_DIR/entrypoint.sh" "$TEST_DIR/migrate" "$TEST_DIR/server"

export MIGRATE_PID_FILE="$TEST_DIR/migrate.pid"
export MIGRATE_SIGNAL_FILE="$TEST_DIR/migrate.signal"
export MIGRATE_STARTED_AT_FILE="$TEST_DIR/migrate.started-at"
export SERVER_STARTED_FILE="$TEST_DIR/server.started"
export SERVER_STARTED_AT_FILE="$TEST_DIR/server.started-at"

(
  cd "$TEST_DIR"
  exec ./entrypoint.sh
) &
ENTRYPOINT_PID=$!

for _ in $(seq 1 50); do
  if [ -s "$MIGRATE_PID_FILE" ]; then
    break
  fi
  sleep 0.1
done
if [ ! -s "$MIGRATE_PID_FILE" ]; then
  echo "migrator did not start"
  exit 1
fi

kill -TERM "$ENTRYPOINT_PID"
set +e
wait "$ENTRYPOINT_PID"
status=$?
set -e
ENTRYPOINT_PID=""

if [ "$status" -ne 143 ]; then
  echo "entrypoint exited with $status, want 143 after SIGTERM"
  exit 1
fi
if [ "$(cat "$MIGRATE_SIGNAL_FILE" 2>/dev/null || true)" != "TERM" ]; then
  echo "entrypoint did not forward SIGTERM to the migrator"
  exit 1
fi
if [ -e "$SERVER_STARTED_FILE" ]; then
  echo "entrypoint started the server after interrupted migrations"
  exit 1
fi

cat >"$TEST_DIR/migrate" <<'SCRIPT'
#!/bin/sh
printf '%s\n' "$MULTICA_INTERNAL_DATABASE_STARTUP_STARTED_AT_UNIX" >"$MIGRATE_STARTED_AT_FILE"
exit 0
SCRIPT
chmod +x "$TEST_DIR/migrate"

(
  cd "$TEST_DIR"
  ./entrypoint.sh
)
if [ "$(cat "$SERVER_STARTED_FILE" 2>/dev/null || true)" != "started" ]; then
  echo "entrypoint did not start the server after successful migrations"
  exit 1
fi
started_at="$(cat "$MIGRATE_STARTED_AT_FILE" 2>/dev/null || true)"
if [ -z "$started_at" ] || [ "$started_at" != "$(cat "$SERVER_STARTED_AT_FILE" 2>/dev/null || true)" ]; then
  echo "entrypoint did not share one database startup timestamp"
  exit 1
fi
case "$started_at" in
  *[!0-9]*)
    echo "entrypoint database startup timestamp is not a Unix timestamp"
    exit 1
    ;;
esac

# Verify the optional unattended token path configures the CLI and starts the
# daemon without exposing the token in a command-line argument.
export MULTICA_DAEMON_AUTO_START=true
export MULTICA_DAEMON_AUTO_START_INTERVAL=0.1
export MULTICA_DAEMON_TOKEN=mul_test_token
export MULTICA_SERVER_URL=https://backend.example.test
export MULTICA_APP_URL=https://frontend.example.test
export DAEMON_STATE_FILE="$TEST_DIR/daemon.state"
export DAEMON_LOGIN_INPUT_FILE="$TEST_DIR/daemon.login-input"
export DAEMON_CONFIG_FILE="$TEST_DIR/daemon.config"

cat >"$TEST_DIR/migrate" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT

cat >"$TEST_DIR/server" <<'SCRIPT'
#!/bin/sh
trap 'exit 143' TERM INT
while :; do
  sleep 1
done
SCRIPT

cat >"$TEST_DIR/multica" <<'SCRIPT'
#!/bin/sh
set -eu

case "$1:$2" in
  config:set)
    printf '%s=%s\n' "$3" "$4" >>"$DAEMON_CONFIG_FILE"
    ;;
  auth:status)
    if [ -s "$DAEMON_LOGIN_INPUT_FILE" ]; then
      printf 'Server: %s\nUser:    Test User (test@example.test)\n' "$MULTICA_SERVER_URL"
    else
      printf "Not authenticated.\n"
      exit 1
    fi
    ;;
  login:--token=)
    cat >"$DAEMON_LOGIN_INPUT_FILE"
    ;;
  daemon:status)
    if [ "$(cat "$DAEMON_STATE_FILE" 2>/dev/null || true)" = "running" ]; then
      printf '{"status":"running"}\n'
    else
      printf '{"status":"stopped"}\n'
    fi
    ;;
  daemon:start)
    printf 'running\n' >"$DAEMON_STATE_FILE"
    ;;
  daemon:stop)
    printf 'stopped\n' >"$DAEMON_STATE_FILE"
    ;;
  *)
    printf 'unexpected multica invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
SCRIPT

chmod +x "$TEST_DIR/entrypoint.sh" "$TEST_DIR/migrate" "$TEST_DIR/server" "$TEST_DIR/multica"

(
  cd "$TEST_DIR"
  ./entrypoint.sh
) &
ENTRYPOINT_PID=$!

for _ in $(seq 1 50); do
  if [ "$(cat "$DAEMON_STATE_FILE" 2>/dev/null || true)" = "running" ]; then
    break
  fi
  sleep 0.1
done
if [ "$(cat "$DAEMON_STATE_FILE" 2>/dev/null || true)" != "running" ]; then
  echo "entrypoint did not automatically start the daemon"
  exit 1
fi
if [ "$(cat "$DAEMON_LOGIN_INPUT_FILE" 2>/dev/null || true)" != "$MULTICA_DAEMON_TOKEN" ]; then
  echo "entrypoint did not pipe the daemon token to login"
  exit 1
fi
if ! grep -q '^server_url=https://backend.example.test$' "$DAEMON_CONFIG_FILE"; then
  echo "entrypoint did not persist the daemon server URL"
  exit 1
fi
if ! grep -q '^app_url=https://frontend.example.test$' "$DAEMON_CONFIG_FILE"; then
  echo "entrypoint did not persist the daemon app URL"
  exit 1
fi

kill -TERM "$ENTRYPOINT_PID"
set +e
wait "$ENTRYPOINT_PID"
status=$?
set -e
ENTRYPOINT_PID=""

if [ "$status" -ne 143 ]; then
  echo "auto-start entrypoint exited with $status, want 143 after SIGTERM"
  exit 1
fi
if [ "$(cat "$DAEMON_STATE_FILE" 2>/dev/null || true)" != "stopped" ]; then
  echo "entrypoint did not stop the daemon during shutdown"
  exit 1
fi

echo "entrypoint startup, auto-start, and signal forwarding ok"
