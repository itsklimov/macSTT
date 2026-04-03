#!/bin/bash
set -e

pkill -x macSTT 2>/dev/null || true
sleep 0.3
swift build

APP_BINARY=".build/debug/macSTT"
LOG_FILE="${TMPDIR:-/tmp}/macstt-dev.log"

if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "${CODE_SIGN_IDENTITY}" "${APP_BINARY}"
fi

: >"${LOG_FILE}"
nohup "${APP_BINARY}" >"${LOG_FILE}" 2>&1 </dev/null &
APP_PID=$!

echo "macSTT started (pid ${APP_PID})"
echo "Streaming logs from ${LOG_FILE}"
echo "Press Ctrl-C to stop watching logs. macSTT will keep running."

trap 'printf "\nStopped log streaming. macSTT is still running (pid %s).\n" "${APP_PID}"; exit 0' INT TERM
tail -F "${LOG_FILE}"
