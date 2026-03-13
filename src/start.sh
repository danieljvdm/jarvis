#!/usr/bin/env bash
# start.sh — entrypoint wrapper: run init then hand off to the Node server.
set -euo pipefail

/app/src/init.sh

exec node /app/src/server.js
