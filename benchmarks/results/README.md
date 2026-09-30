# Recorded measurements

The `2026-09-30` directory contains the final measured cases, with exploratory
runs and private connection details excluded. See [the report](../RESULTS.md)
for interpretation and [the harness instructions](../README.md) to reproduce.

- `results.jsonl`: ready-connection mqhole and protocol trials. `seconds` is the
  later of the final verified receipt and publisher completion. `send_seconds`
  measures each publisher operation; it is not receiver delivery latency.
- `cold-results.jsonl`: complete mqhole CLI commands and tar directory transfers,
  including packing/extraction for the latter.
- `tailcat-results.jsonl`: actual SFTP copies and raw byte-stream file transfers
  to running servers, including fresh client setup.
- `failures.jsonl`: failed cases, excluded from throughput summaries.
- `diagnostics.json` and the MQTT diagnostic files: keepalive reasons and the
  duplicate or missing chunk indices behind the failed probes.
- `summary.csv` and `summary.json`: grouped medians, ranges, nearest-rank p95 and
  trial counts. Throughput counts payload bytes, using 1 MiB = 1,048,576 bytes.
- `metadata.json`: software versions, image digests, binary hashes and the
  separate API-key provisioning smoke test.
- `rabbitmq-policy-sanitized.json`: hosted queue policy definitions, with account
  identifiers omitted.
- `validation.json` and `cleanup.json`: completed checks and removal of the
  resources created for this benchmark.
- Route-check text files: pings proving direct routing was available or blocked;
  private tailcat addresses are removed. `local-direct` means direct allowed,
  including the client's normal DERP bootstrap.

Every successful file trial verifies SHA-256. CLI and tailcat
verification happens after their timers; warm protocol verification happens
inside the timer. Large MQTT diagnostics and RSS observations have fewer
samples; inspect `trials` before interpreting percentile values.

Regenerate the summaries from this archive:

```sh
MQHOLE_BENCH_DIR="$PWD/benchmarks/results/2026-09-30" \
  python3 benchmarks/summarize.py
```
