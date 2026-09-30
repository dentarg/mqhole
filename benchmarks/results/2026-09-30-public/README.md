# Public-service benchmark data

See [the report](../../PUBLIC_RESULTS.md) for interpretation and
[the lab instructions](../../README.md#public-derp-versus-free-regional-brokers)
for reproduction. All payloads are synthetic random bytes.

- `public-results.jsonl`: three rounds of ordinary encrypted file commands,
  tar-batched directories and warm AMQP transfers. The 100-file individual
  Tailcat copy is a single additional trial. Missing labels in the initial
  driver batch were filled from its known scenario and per-group order;
  measured values are unchanged.
- `large-results.jsonl`: single 64 MiB encrypted-command trials.
- `directions-results.jsonl`: separate confirmed upload and hash-verified
  download of 8 MiB; two trials per persistence/socket-option condition.
  `frame_max` is the negotiated value, not just the requested setting.
- `socket-results.jsonl`: two 16 MiB warm transfers per client socket variant.
- `websocket-results.jsonl`: AMQP over the same provider's verified HTTPS
  `/ws/amqp` endpoint, preserving mqhole's delivery behavior.
- `public-failures.jsonl`: unsuccessful attempts, excluded from throughput.
  The first warm failure was a benchmark stdout parsing failure; the public
  SFTP stall is recorded separately from completed copies.
- `tcp-samples.jsonl`: Linux `ss -tin` statistics from client containers,
  with endpoint addresses replaced by broker aliases. `side` identifies the
  container. Absent `port` means 5671 in the initial samples; later samples
  also record port 443 for the WebSocket experiment. `snd_wnd` is the remote
  receive window, while `rwnd_limited` is cumulative time limited by that
  window. Samples can include setup, active transfer and teardown.
- `summary.json` / `summary.csv`: sample counts, medians and full ranges for
  the file-transfer datasets, grouped without mixing cold and warm clients.
- `policies.json` / `config-access.json`: whitelisted management observations,
  without credentials, subscription identifiers or endpoint hostnames.
- `public-derpmap.json` and `*-route*.txt`: public map and sanitized route
  checks before and after transfers. The peer UDP block is recorded in metadata.
- `metadata.json`, `validation.json`, `cleanup.json`: versions, binary hashes,
  completed checks and cleanup outcomes.

Times are seconds; rates are MiB/s (1 MiB = 1,048,576 bytes). Main/large/socket/
WebSocket timestamps were recorded after each trial; directional timestamps
were recorded before each command; TCP timestamps identify sample collection.
Cold hashes are checked after timing, warm AMQP hashes within timing. A
`verified` result requires matching content, not merely a successful publisher.
No receiver `fsync` is forced. Timing ranges include successful outliers.

The two peers share one VM and origin network. Services, paths and public-relay
capacity differ; these measurements are not universal broker or tool rankings.
