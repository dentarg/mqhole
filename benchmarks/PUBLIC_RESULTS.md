# Public Tailcat relays versus CloudAMQP free brokers

Measured from one ARM64 VM on 2026-09-30. Both clients are separate containers; traffic
leaves the VM for the public service. This follow-up answers the hosted-service
comparison; the [earlier local/private-relay results](RESULTS.md) do not answer that
question.

[Raw results and diagnostics](results/2026-09-30-public/) ·
[Reproduction](README.md#public-derp-versus-free-regional-brokers)

From this VM, nearby free LavinMQ is substantially faster than Tailcat’s public relay
for file copies. Stockholm and Amsterdam both win the encrypted 16 MiB comparison.
Native RabbitMQ is slower than Tailcat here; its European upload bottleneck matches a
small remote TCP receive window. The alternate AMQP/WebSocket endpoint improves
RabbitMQ, but remains a benchmark experiment rather than a production CLI feature.

## Actual encrypted file commands

Median wall time in seconds, three successful trials per cell unless the raw count says
otherwise. Both tools encrypt the payload. Tailcat uses its public Frankfurt DERP relay,
with peer UDP blocked; mqhole uses the listed free broker. Client startup and connection
teardown are included.

| Command / service | 1 KiB | 1 MiB | 16 MiB | 16 MiB MiB/s |
| --- | ---: | ---: | ---: | ---: |
| Tailcat cp | 0.95 | 2.66 | 11.05 | 1.45 |
| Tailcat stream | 0.56 | 1.73 | 10.18 | 1.57 |
| lavinmq-ams | 0.65 | 0.84 | 1.74 | 9.18 |
| rabbitmq-ams | 0.63 | 2.36 | 29.16 | 0.55 |
| lavinmq-stockholm | 0.43 | 0.43 | 1.03 | 15.53 |
| rabbitmq-stockholm | 0.33 | 1.14 | 12.55 | 1.28 |
| lavinmq-virginia | 4.70 | 3.27 | 7.86 | 2.04 |
| rabbitmq-virginia | 1.79 | 3.66 | 26.99 | 0.59 |

## Larger files and many files

64 MiB uses one diagnostic trial per route, not a median. The 1,000-file case contains
distinct 1 KiB files, tar batching on both tools, and three successful trials per route.
mqhole tar uses verified TLS but no payload encryption; Tailcat always encrypts.

| Service | 64 MiB encrypted command, seconds | 1,000 files via tar, seconds |
| --- | ---: | ---: |
| tailcat-cp | 28.25 | 3.05 |
| tailcat-stream | 25.20 | — |
| lavinmq-ams | 5.50 | 1.14 |
| rabbitmq-ams | 107.86 | 3.36 |
| lavinmq-stockholm | 1.84 | 0.59 |
| rabbitmq-stockholm | 50.32 | 1.60 |
| lavinmq-virginia | 10.79 | 3.26 |
| rabbitmq-virginia | 102.98 | 4.54 |

The separate single trial copying 100 tiny files individually with Tailcat took 26.30
seconds. This has a different file count and transfer strategy from the tar table.

## Why Amsterdam RabbitMQ was much slower

Ready-connection, unencrypted mqhole payload over TLS, 16 MiB; median MiB/s. This
isolates transfer work and must not be mixed with cold-command timings.

| Region | LavinMQ | RabbitMQ |
| --- | ---: | ---: |
| ams | 8.34 | 0.56 |
| stockholm | 22.62 | 1.31 |
| virginia | 3.73 | 0.67 |

The key observation is TCP flow control on the tested European RabbitMQ endpoints. The
remote endpoint advertised a receive window of about 16 KiB, and the sender spent almost
all of its busy time limited by that window. With that window, throughput is bounded
approximately by `window / RTT`, before TLS and AMQP overhead. This is an
endpoint/configuration result, not a general RabbitMQ throughput limit.

TCP samples below select sender sockets with more than 1 MiB transmitted and unsent data
still queued. Statistics are medians across the samples; they also include the
socket-option diagnostics. Fast LavinMQ transfers yield few qualifying samples. Window /
RTT is a bound from flow control alone, not a prediction of the available bandwidth.
Endpoint addresses have been removed.

| Broker | Samples | Remote window, bytes | RTT, ms | Window-limited time, % | Window / RTT, MiB/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| lavinmq-ams | 1 | 5434624 | 26.88 | 31.7 | 192.83 |
| rabbitmq-ams | 205 | 14736 | 25.16 | 97.5 | 0.56 |
| lavinmq-stockholm | 2 | 3783488 | 10.30 | 5.8 | 350.47 |
| rabbitmq-stockholm | 35 | 15964 | 11.47 | 97.0 | 1.33 |
| lavinmq-virginia | 20 | 3449280 | 112.73 | 2.5 | 29.18 |
| rabbitmq-virginia | 69 | 122112 | 109.85 | 51.4 | 1.06 |

The Virginia RabbitMQ endpoint advertised a larger window and showed
retransmissions/congestion effects, so the exact European 16 KiB explanation should not
be applied to every region. LavinMQ allowed much larger windows under load.

### Separate upload and download

8 MiB fits below the observed RabbitMQ queue byte policy. Each trial first uploads the
whole file with 32 outstanding publisher confirmations, then downloads and verifies it.
Two trials per condition. Rates below divide 8 MiB by the median elapsed time. These are
diagnostics, not simultaneous end-to-end file transfers.

| Broker | Persistent upload MiB/s | Transient upload MiB/s | Persistent download MiB/s |
| --- | ---: | ---: | ---: |
| lavinmq-ams | 10.50 | 14.62 | 16.17 |
| rabbitmq-ams | 0.56 | 0.56 | 4.10 |
| lavinmq-stockholm | 35.29 | 37.01 | 34.63 |
| rabbitmq-stockholm | 1.28 | 1.28 | 5.35 |
| lavinmq-virginia | 4.88 | 4.98 | 4.28 |
| rabbitmq-virginia | 0.96 | 1.02 | 0.63 |

### Client socket options

16 MiB warm transfers, two trials per variant. The payload, AMQP confirmation window,
queue policy and TLS verification are unchanged.

| Variant | MiB/s |
| --- | ---: |
| lavinmq-ams-nodelay | 15.91 |
| rabbitmq-ams-buffer64k | 0.55 |
| rabbitmq-ams-frame1m | 0.58 |
| rabbitmq-ams-nodelay | 0.59 |

The `frame1m` variant requests a 1 MiB frame maximum, but the broker still negotiated
128 KiB. `buffer64k` changes the client I/O buffer; `nodelay` disables Nagle’s
algorithm. None removes the native RabbitMQ upload ceiling. The two LavinMQ nodelay
samples vary from 12.03 to 19.79 MiB/s; this separate small batch is not a controlled
estimate of a default-setting improvement.

### AMQP over the HTTPS/WebSocket endpoint

The benchmark-only WebSocket client reuses mqhole’s persistent queues, 32-message
confirmation window and full-file acknowledgement behavior. It connects to the same
service hostname on verified HTTPS port 443 at `/ws/amqp`. This changes the transport
framing and network entry point; it is not a production CLI option. Warm 16 MiB, three
trials per route.

| Broker | Native AMQPS MiB/s | AMQP/WebSocket MiB/s |
| --- | ---: | ---: |
| rabbitmq-ams | 0.56 | 1.74 |
| lavinmq-ams | 8.34 | 13.48 |
| rabbitmq-stockholm | 1.31 | 1.70 |

The alternate endpoint improves Amsterdam RabbitMQ throughput without changing
persistence or acknowledgement semantics. It supports the endpoint-bottleneck diagnosis,
but adds its own overhead and does not identify the provider’s precise internal socket
configuration. It remains a diagnostic; the nearby LavinMQ AMQPS route is faster.
[CloudAMQP documents this endpoint on all
plans](https://www.cloudamqp.com/docs/amqp_over_websockets.html).

## Limits and failures

All successful transfers passed SHA-256 verification. Cold file hashes are checked after
the command timer; warm mqhole hashes are inside its timer. Tailcat has an
already-running receiver server; mqhole starts sender and receiver commands. No receiver
`fsync` is forced. The source files are incompressible random bytes, and both peers
share one VM and origin network. No artificial network delay is applied in this
follow-up. Separate batches and WAN variation can make encrypted cold medians appear
faster than unencrypted warm medians; these are not isolated encryption-cost
measurements. The successful 1 MiB Virginia LavinMQ samples include a 55.71-second
outlier, retained in the raw data and summary ranges.

Public-relay tests use the default published map and verified `DERP(fra)` pongs before
and after the runs. UDP except DNS/loopback is blocked in both IPv4-only client
namespaces. Actual ordinary file copies are bounded; no `tailcat perf` restriction was
disabled and no public load flood was run. Public-copy deadlines were tightened to 120
seconds after a stalled copy. The first interrupted copy exceeded two minutes; its
already-written bytes do not count as a successful command.

The main matrix contains 130 successful trials, plus 8 larger-file trials, 36
directional diagnostics, 8 socket-option trials and 18 WebSocket trials. There are 4
recorded unsuccessful attempts; see `public-failures.jsonl`. Successful medians are
conditional on completion. Three trials describe this run, not a precise service-level
latency distribution.

A benchmark diagnostic on stdout interrupted one initial warm Virginia result. Benchmark
logs now go to stderr; that attempt is recorded separately and was rerun. Two
socket-option trials completed their data transfer but failed queue cleanup because Pika
rejected Crystal-specific tuning parameters or a larger requested frame maximum; those
timings were excluded, cleanup was fixed, and the trials were rerun. These changes
affect benchmark instrumentation, not production transfer behavior.

Free subscriptions use Lemming (LavinMQ) and Lemur (RabbitMQ). Versions and regions are
in `metadata.json`. Both plans share infrastructure. The visible RabbitMQ queue policy
includes a 15,000,000-byte limit; it limits ready (undelivered) queue contents, not
bytes per second. Tests with an online receiver do not demonstrate offline retention of
files larger than that policy. Policies were inspected without changing them. The
instance configuration API did not expose an AMQP receive-buffer setting, so the exact
server/proxy setting responsible for the small advertised window remains unconfirmed.

RabbitMQ documents the relationship between TCP buffer size and throughput in its
[networking guide](https://www.rabbitmq.com/docs/networking) and the treatment of ready
versus unacknowledged messages in its [queue-limit
guide](https://www.rabbitmq.com/docs/maxlength). [CloudAMQP
plans](https://www.cloudamqp.com/plans.html) describe the shared free tiers. [Tailcat
documentation](https://github.com/tailscale/tailcat/blob/b4dc28e8aa8936f0a90a41ad8293a64e3d6b645f/README.md)
describes its public relays as rate limited. These documents provide context; the
numerical findings above come from the archived measurements.

## Validation and cleanup

`make check` passed: Crystal formatting, 26 specs and the release build. Python
compilation, Ruff lint/format checks, hosted probe smoke transfers, timeout-message
redaction and container-side timeout cleanup also passed. All six temporary CloudAMQP
subscriptions, both client containers and their network were removed. Unrelated
subscriptions and the API-key file were preserved. See `validation.json` and
`cleanup.json` for the records. Credentials, capabilities, subscription identifiers and
raw private management responses are excluded from the archive.
