#!/usr/bin/env bash

set -euo pipefail

: "${MQHOLE_BIN:?set MQHOLE_BIN to the built mqhole binary}"
: "${CLOUDAMQP_API_KEY:?set CLOUDAMQP_API_KEY before recording}"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

asciinema rec \
  --quiet \
  --overwrite \
  --cols 96 \
  --rows 24 \
  --idle-time-limit 2 \
  --title "mqhole encrypted transfer demo" \
  --command "$script_dir/demo-session.sh" \
  "$script_dir/demo.cast"
