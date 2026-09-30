# mqhole vs tailcat: transfer benchmarks

Measured 2026-09-30. These are results from one 4-core ARM64 VM, not general
rankings of brokers or protocols. All successful trials verified file contents
with SHA-256. Failures are reported separately and never treated as throughput.

[Raw measurements and metadata](results/2026-09-30/) ·
[CSV summary](results/2026-09-30/summary.csv) ·
[Data definitions](results/README.md)

## Findings

Keep AMQP as mqhole's production transport. Pipelining confirmations and
subscribing to deliveries produced the main improvement while preserving
acknowledgement after successful full-file output/hooks. MQTT and stream probes
win some individual measurements, but do not implement that complete contract.

For 256 MiB local transfers, the updated implementation is 44.4× faster through
LavinMQ and 2.6× faster through RabbitMQ. Peak receiver process RSS fell from
about 553–557 MiB to 14–15 MiB. Hosted LavinMQ's 16 MiB throughput improved 6.5×;
the hosted RabbitMQ path remained near 0.55 MiB/s.

Cold encrypted mqhole commands transferred 256 MiB in about 0.73 seconds on
both local brokers, versus 0.94 seconds for tailcat's direct-allowed byte stream
and 1.11 seconds for SFTP `cp`. Tailcat `cp` won the small cold-command cases.
These are separate batches on one VM; small differences, including apparently
faster encrypted results, should not be interpreted as precise encryption costs.

Batching is the main many-file improvement. For 1,000 distinct tiny files,
local tar transfers took about 0.16 seconds with tailcat and 0.20 seconds with
mqhole, compared with 1.17 seconds for individual tailcat copies. Under added
network delay, the difference is much larger. Comparing mqhole tar against only
individual SFTP copies would wrongly attribute batching's benefit to the broker.

Larger chunks helped some local cases but did not remove the hosted RabbitMQ
limit and gave inconsistent hosted LavinMQ results. The default remains 128 KiB;
a larger chunk also increases the bytes held by each 32-message window/buffer.

## Throughput before and after

Warm, hash-verified transfers; MiB/s, median of three trials.

| Broker | File | Original MiB/s | Updated MiB/s | Speedup |
| --- | --- | --- | --- | --- |
| Local LavinMQ | 16 MiB | 6.97 | 194.96 | 28.0× |
| Local LavinMQ | 256 MiB | 8.47 | 376.58 | 44.4× |
| Local RabbitMQ | 16 MiB | 135.52 | 510.16 | 3.8× |
| Local RabbitMQ | 256 MiB | 243.56 | 624.72 | 2.6× |
| Hosted LavinMQ | 16 MiB | 2.02 | 13.14 | 6.5× |
| Hosted RabbitMQ | 16 MiB | 0.53 | 0.55 | 1.0× |

Hosted 64 MiB updated transfers: lavinmq 15.33 MiB/s, rabbitmq 0.59 MiB/s.

## Actual file commands versus tailcat

Median wall time, including client startup; seconds. Tailcat has a running server. A dash means unmeasured. See timing and encryption differences below.

| Command | Route | 1 KiB | 1 MiB | 16 MiB | 256 MiB |
| --- | --- | --- | --- | --- | --- |
| mqhole | lavinmq-local | 0.13 | 0.13 | 0.23 | 0.83 |
| mqhole encrypted | lavinmq-local | 0.12 | — | 0.23 | 0.73 |
| mqhole | rabbitmq-local | 0.13 | 0.13 | 0.13 | 0.63 |
| mqhole encrypted | rabbitmq-local | 0.23 | — | 0.23 | 0.73 |
| mqhole | lavinmq-cloud | 0.64 | 0.84 | 2.35 | — |
| mqhole | rabbitmq-cloud | 0.54 | 2.45 | 28.10 | — |
| tailcat cp | direct allowed | 0.05 | 0.06 | 0.15 | 1.11 |
| tailcat byte stream | direct allowed | 0.14 | 0.13 | 0.23 | 0.94 |
| tailcat cp | forced private DERP | 0.06 | 0.07 | 0.33 | 4.57 |
| tailcat byte stream | forced private DERP | 0.14 | 0.13 | 0.33 | 3.73 |

## Many files

1,000 distinct 1 KiB files; median seconds. mqhole includes uncompressed tar packing and extraction. Tailcat copies individual files unless tar is indicated. mqhole tar uses no payload encryption here; hosted links still use TLS. These are different directory-transfer strategies.

| Route / strategy | Seconds |
| --- | --- |
| lavinmq-local | 0.20 |
| rabbitmq-local | 0.20 |
| lavinmq-cloud | 1.03 |
| rabbitmq-cloud | 3.34 |
| tailcat direct allowed | 1.17 |
| tailcat forced private DERP | 1.59 |
| tailcat tar direct allowed | 0.16 |
| tailcat tar forced private DERP | 0.17 |

With added delay, the same tar strategy (1,000 files, seconds):

| Tar route | Seconds |
| --- | --- |
| lavinmq-local | 0.80 |
| rabbitmq-local | 0.80 |
| direct allowed | 0.72 |
| forced private DERP | 2.47 |

For 100 separate warm mqhole transfers (no tar), original → updated seconds:

| Broker | Original | Updated |
| --- | --- | --- |
| lavinmq-local | 4.19 | 0.35 |
| rabbitmq-local | 4.28 | 0.09 |
| lavinmq-cloud | 14.39 | 10.25 |
| rabbitmq-cloud | 14.40 | 5.33 |

## Small-file latency

1 KiB, 30 independent trials per row; milliseconds. mqhole starts with ready broker connections. Tailcat includes a new client and connection per copy, so these measure different usage patterns.

| Command | Route | p50 ms | p95 ms |
| --- | --- | --- | --- |
| mqhole warm | lavinmq-local | 4.12 | 43.88 |
| mqhole warm | rabbitmq-local | 2.69 | 4.66 |
| mqhole warm | lavinmq-cloud | 99.30 | 114.64 |
| mqhole warm | rabbitmq-cloud | 54.76 | 59.53 |
| tailcat cold | direct allowed | 46.06 | 56.79 |
| tailcat cold | forced private DERP | 51.12 | 71.01 |

## Protocol experiments

16 MiB warm transfers; median MiB/s. These clients have different framing and acknowledgement semantics; see the limitations below. “—” means unavailable or unsuccessful, never zero throughput.

| Transport | Local LavinMQ | Local RabbitMQ | Hosted LavinMQ | Hosted RabbitMQ |
| --- | --- | --- | --- | --- |
| mqhole AMQP | 194.96 | 510.16 | 13.14 | 0.55 |
| MQTT QoS 0 | 297.63 | 578.68 | 9.26 | — |
| MQTT QoS 1 | 269.57 | 543.34 | 12.60 | — |
| AMQP stream | 200.88 | 470.71 | 10.94 | 0.55 |
| Native stream, one batch | — | 280.41 | — | — |
| Native stream, window | — | 226.34 | — | — |
| MQTT QoS 0, 300s keepalive (1 trial) | — | — | — | 0.02 |

Local 256 MiB files, median MiB/s, with the same semantic differences:

| Transport | Local LavinMQ | Local RabbitMQ |
| --- | --- | --- |
| mqhole AMQP | 376.58 | 624.72 |
| MQTT QoS 0 | 504.58 | — |
| MQTT QoS 1 | 539.47 | 669.08 |
| AMQP stream | 336.81 | 569.90 |
| Native stream, one batch | — | 386.44 |
| Native stream, window | — | 385.71 |

Single 1 KiB transfer latency for the same clients, median milliseconds of three trials, with ready connections:

| Transport | Local LavinMQ ms | Local RabbitMQ ms | Hosted LavinMQ ms | Hosted RabbitMQ ms |
| --- | --- | --- | --- | --- |
| mqhole AMQP | 5.04 | 2.65 | 100.17 | 53.99 |
| MQTT QoS 0 | 2.49 | 2.07 | 54.46 | 140.73 |
| MQTT QoS 1 | 2.82 | 2.37 | 93.85 | 105.10 |
| AMQP stream | 3.58 | 3.32 | 101.19 | 53.54 |
| Native stream, one batch | — | 1.50 | — | — |
| Native stream, window | — | 1.25 | — | — |

## Added network delay

10 ms egress delay per container. Warm protocol rates for 16 MiB, median MiB/s:

| Transport | LavinMQ | RabbitMQ |
| --- | --- | --- |
| Original AMQP | 2.55 | 2.63 |
| Updated AMQP | 18.78 | 17.85 |
| MQTT QoS 1 | 16.40 | 24.94 |
| AMQP stream | 20.29 | 15.94 |
| Native stream, window | — | 25.03 |

Tailcat with the same per-container delay (cold commands):

| Tailcat route | 1 KiB p50 ms | 1 KiB p95 ms | 16 MiB seconds | 1,000 files seconds |
| --- | --- | --- | --- | --- |
| direct allowed | 455.67 | 464.08 | 0.79 | 112.98 |
| forced private DERP | 770.48 | 807.23 | 24.14 | 228.80 |

Tailcat byte streams with added delay, median of three cold clients:

| Route | 1 KiB ms | 16 MiB seconds |
| --- | --- | --- |
| direct allowed | 341.27 | 0.64 |
| forced private DERP | 338.99 | 24.73 |

## Chunk size, encryption and memory

Updated AMQP, 16 MiB files, median MiB/s. The default is 128 KiB.

| Broker | 16 KiB chunks | 128 KiB chunks | 512 KiB chunks | 1 MiB chunks |
| --- | --- | --- | --- | --- |
| lavinmq-local | 78.21 | 194.96 | 185.27 | 198.51 |
| rabbitmq-local | 266.92 | 510.16 | 479.71 | 622.49 |
| lavinmq-cloud | 6.60 | 13.14 | 8.27 | 9.20 |
| rabbitmq-cloud | 0.54 | 0.55 | 0.55 | 0.55 |

Warm encrypted mqhole, including per-file key derivation, median MiB/s:

| Broker | 16 MiB | 256 MiB |
| --- | --- | --- |
| lavinmq-local | 103.31 | 356.97 |
| rabbitmq-local | 231.16 | 457.52 |

Peak receiver RSS for a 256 MiB file; one diagnostic sample each, MiB:

| Broker | Original | Updated |
| --- | --- | --- |
| lavinmq-local | 556.5 | 14.3 |
| rabbitmq-local | 552.7 | 14.5 |

## Changes retained in mqhole

- Existing brokers can be selected through `AMQP_URL`.
- A bounded window of 32 publisher confirmations replaces one round trip per
  message; completion still waits for every confirmation.
- Subscription delivery replaces `basic.get` polling. Written chunk bodies are
  released while acknowledgements remain deferred until output/hooks succeed.
- Closed consumers fail promptly, and connection setup retries cannot replay an
  already-started transfer.

The normal AMQP transport remains the production default. MQTT and stream
implementations live only in this benchmark directory; they do not implement
mqhole's complete delivery contract.

The normal API-key flow was also exercised against CloudAMQP: the first send,
including free-instance provisioning, took 2.61 seconds; receive with instance
lookup took 1.68 seconds. This was one verified smoke transfer, not a throughput
sample. The repeated benchmarks use `AMQP_URL` to keep provisioning out of
transfer timings.

## Measurement details

Original mqhole is `2c62f95`; measured production code is `10821b2` (the following
commit only adds a rejection regression spec). Tailcat is
`b4dc28e8aa8936f0a90a41ad8293a64e3d6b645f`. See the adjacent version metadata and
[reproduction instructions](README.md).

Sender, receiver, local broker, and private DERP relay each use a separate
Docker network namespace on one bridge. They share four CPUs, 7.73 GiB RAM and
native VM storage. Files contain incompressible random bytes; repeated runs can
benefit from filesystem caching. Receivers write files but do not force an
`fsync`; these are not stable-storage write benchmarks. Broker durability
settings were left at their defaults. No CPU pinning, packet loss, bandwidth shaping, or cross-host disk
isolation was applied.

Local brokers: LavinMQ 2.10.0 and RabbitMQ 4.3.6. CloudAMQP free plans:
LavinMQ 2.9.3 Lemming and RabbitMQ 4.3.5 Lemur in `scaleway::nl-ams`. Hosted
connections use verified TLS. Local default AMQP and protocol probes use
plaintext transport; encrypted mqhole results use its existing AES-GCM payload
encryption and include per-file key derivation. Tailcat always encrypts traffic.

Warm transfer timing starts after both broker connections are ready. It ends
only after the last sender completion and hash-verified receiver receipt; it
excludes teardown. It does not imply a receiver-delivery acknowledgement in the
mqhole wire protocol. Cold CLI timing includes Docker exec, client startup,
connection setup and teardown, but excludes CloudAMQP provisioning and human
passphrase entry. mqhole also runs the small Python credential-loading helper;
these are harness-level command timings, not isolated process startup costs. Tailcat's server is already running; every `cp` starts a new
client. The separate raw-byte-stream experiment uses a running tailcat exec
server that writes each connection to a file; the client waits for that command
to close. It bypasses SFTP, but does not provide mqhole manifests, offline
buffering or hook acknowledgements. Tailcat hash verification and CLI hash verification happen after those
command timers. Warm mqhole verification is inside its timer. Thus the cold
comparison reflects actual command use, while warm numbers isolate transfer
work; do not mix the two as a single speed ratio.

Many-file warm trials send 100 independent 1 KiB transfers on reused broker
connections. Directory trials send 1,000 distinct 1 KiB files: mqhole carries an
uncompressed tar and includes pack/unpack time; tailcat copies the files with
SFTP. Rates count payload bytes, not protocol or archive overhead.

Unless stated otherwise, tables use medians of three trials. Small-file latency
series use 30 trials; p95 is nearest-rank, not a confidence interval. The RSS
comparison is one diagnostic run per variant and broker, for the transfer
process only; it excludes broker, Docker and Python harness memory. Raw results include
range, elapsed publisher/receiver times, and hashes. Publisher timings are not
end-to-end delivery latency, especially for MQTT QoS 0.

## Protocol and deployment limits

MQTT probes use Paho 2.1.0, MQTT 3.1.1, clean sessions, and separate framing;
QoS 0 measures socket flush without broker confirmation, while QoS 1 acknowledges
individual messages during receipt. Paho uses TCP_NODELAY and a 32-message
publish window. The probe rejects duplicate or out-of-order chunks; it does
not implement QoS 1 deduplication after reconnects. RabbitMQ's QoS 0 implementation can bypass
disk queues and discard messages under overload. That is a materially different
contract from persistent AMQP messages retained until full-file delivery.
See [RabbitMQ MQTT documentation](https://www.rabbitmq.com/docs/mqtt).

AMQP stream probes reuse mqhole framing but acknowledge chunks to advance
credit. They start from offset 0 of a fresh stream and do not persist completed
file offsets. Native streams use rstream 0.40.0, a separate framing format and
batches below the negotiated 1 MiB frame limit. Both one-batch-at-a-time and
approximately 32 outstanding messages were measured. These compare concrete
clients and settings, not just protocol encodings.

LavinMQ streams are accessed through AMQP 0-9-1, not RabbitMQ's dedicated binary
stream protocol. The native stream endpoint was available only on local
RabbitMQ in this experiment; the tested hosted endpoints were inaccessible.
See [LavinMQ streams](https://lavinmq.com/documentation/streams) and
[RabbitMQ streams](https://www.rabbitmq.com/docs/streams).

The hosted RabbitMQ policy exposed a 15,000,000-byte queue limit and 5,000,000-byte
stream segments. Large online transfer measurements do not demonstrate that an
entire large file can be retained while its receiver is offline. Shared-plan
results combine network latency, multitenancy and provider policy; they do not
establish an intrinsic RabbitMQ versus LavinMQ performance limit.

A LavinMQ 2.10.0 stream subscribed with `x-stream-offset="first"` while empty did
not deliver later publications in a separate Pika reproduction. Integer offset
0 worked and is used in all final stream trials. This is an observed edge case,
not a claim about every stream version or configuration.

Hosted RabbitMQ MQTT QoS 0 lost its connection during the 16 MiB test, reproduced
in a diagnostic rerun; no throughput is reported for either incomplete transfer.
The diagnostic reported client keepalive timeouts with the default 60-second
interval. With a 300-second keepalive, one complete 16 MiB trial passed SHA-256
verification in 731.75 seconds (22.39 KiB/s), without changing broker limits.
That fixes connection survival for this trial, not its low throughput.
The default QoS 1 16 MiB probe also failed its chunk-sequence check. A diagnostic
received index 41 again when it expected 42, after sender keepalive timeouts.
This is a duplicate-index failure in a probe without QoS 1 deduplication, not
evidence that the broker lost that chunk.

The local RabbitMQ QoS 0 256 MiB trial failed with a sequence gap: index 1568
arrived when 1559 was expected. The group stopped at that first failed trial;
no completed-file throughput is reported. The local QoS 1 trials all completed.
The gap is consistent with QoS 0 being unsuitable as a reliable file protocol
without additional recovery; the exact broker drop counter was not captured.

The raw label `local-direct` means a direct path was verified as available.
Every copy starts a fresh client and can bootstrap over DERP before switching
to UDP; it is not a guarantee that every packet, especially for a tiny file,
uses the direct path. The comparison measures ordinary tailcat command behavior.

Tailcat relay tests block peer UDP in both directions and verify that ping stays
on the private DERP relay. That relay uses a self-signed certificate with
`InsecureForTests` solely inside this lab. It does not measure public relay
capacity. Simulated delay is 10 ms on each relevant container's egress: direct
peer RTT is about 20 ms, and broker/relay forwarding adds a second hop. This is
still one machine, not a WAN capacity test.

## Validation and cleanup

The archive contains 859 successful, hash-verified final trials and five recorded
failed cases. Exploratory runs are excluded. Failure diagnostics are retained
separately; successful-transfer summaries never include incomplete files.

`make check` passed: formatting, 26 regular specs and the release build. With
`MQHOLE_TEST_AMQP_URL`, all 30 specs passed on each local broker, including four
integration cases covering confirmations/requeue, rejected publishes, connection
loss and prevention of transfer replay. Python compilation, Ruff checks and
formatting passed. Ruff 0.16.9 was installed for this work; the client image
contains the pinned Pika, Paho and rstream dependencies.

The three CloudAMQP instances created for the benchmark were deleted after
validation. The pre-existing instance and API-key file were preserved. The five
lab containers and their network were removed. Credentials, capabilities,
binaries and generated payloads are not committed. See the archived validation
and cleanup records for the completed checks and resource IDs.
