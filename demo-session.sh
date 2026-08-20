#!/usr/bin/env bash

set -euo pipefail

demo_dir=$(mktemp -d /tmp/mqhole-cast.XXXXXX)
message_path="$demo_dir/message.txt"
received_path="$demo_dir/received.txt"
send_log="$demo_dir/send.log"
trap 'rm -rf "$demo_dir"' EXIT

type_command() {
  local command=$1
  local index

  printf '\033[1;32m$\033[0m '
  for ((index = 0; index < ${#command}; index++)); do
    printf '%s' "${command:index:1}"
    sleep 0.018
  done
  printf '\n'
  sleep 0.25
}

filter_log() {
  sed -E 's/ region=[^ ]+ instance_id=[^ ]+$//'
}

printf '\033[1;36mmqhole — encrypted file transfer over AMQP\033[0m\n\n'
sleep 0.8

type_command 'bin/mqhole --version'
"$MQHOLE_BIN" --version
sleep 0.6

type_command "printf 'Hello from mqhole!\\nEncrypted end-to-end over AMQP.\\n' > message.txt"
printf 'Hello from mqhole!\nEncrypted end-to-end over AMQP.\n' > "$message_path"

type_command 'cat message.txt'
cat "$message_path"
sleep 0.6

type_command 'bin/mqhole send demo --encrypted --file message.txt --verbose'
"$MQHOLE_BIN" send github-pages-demo --encrypted --file "$message_path" --verbose 2>&1 |
  tee "$send_log" |
  filter_log
passphrase=$(sed -n 's/^at=info event=encryption_passphrase passphrase=//p' "$send_log")
sleep 0.8

type_command 'bin/mqhole receive demo --encrypted --output received.txt --no-echo --verbose'
printf '%s\n' "$passphrase" |
  "$MQHOLE_BIN" receive github-pages-demo --encrypted --output "$received_path" --no-echo --verbose 2>&1 |
  filter_log
sleep 0.8

type_command 'diff --report-identical-files message.txt received.txt'
diff --report-identical-files "$message_path" "$received_path" |
  sed "s|$message_path|message.txt|; s|$received_path|received.txt|"
sleep 1.5

printf '\n\033[1;32mEncrypted transfer complete.\033[0m\n'
sleep 1.5
