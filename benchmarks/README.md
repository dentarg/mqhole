# mqhole transport benchmarks

`RESULTS.md` records the measurements and limitations. These scripts are a lab,
not additional supported mqhole transports. They never print the CloudAMQP API
key or broker URLs. Credentials and generated files stay outside Git.

## Environment

Use a Linux VM with Docker, Crystal, Go, Python 3.12+, and the project's frozen
shards. The client image installs Pika 1.3.2, Paho MQTT 2.1.0 and rstream 0.40.0.
It also includes `tc`, `iptables`, OpenSSH and certificate roots. No broker
limits, persistence settings, or cloud subscription tiers are relaxed.

Run commands from the repository root. Choose an absolute working directory on
the VM's native filesystem, not a host-shared source mount:

```sh
export MQHOLE_BENCH_DIR=/workspace/mqhole-bench
mkdir -p "$MQHOLE_BENCH_DIR"
docker build -t mqhole-bench-client benchmarks
docker network create mqhole-bench

docker run -d --name mqhole-bench-lavinmq --network mqhole-bench \
  -p 127.0.0.1:5673:5672 -p 127.0.0.1:15673:15672 \
  cloudamqp/lavinmq:2.10.0

docker run -d --name mqhole-bench-rabbitmq --network mqhole-bench \
  -e RABBITMQ_DEFAULT_USER=bench -e RABBITMQ_DEFAULT_PASS=bench \
  -p 127.0.0.1:5674:5672 -p 127.0.0.1:15674:15672 \
  rabbitmq:4.3.6-management

# Wait for RabbitMQ to start before enabling these plugins.
docker exec mqhole-bench-rabbitmq rabbitmq-plugins enable \
  rabbitmq_mqtt rabbitmq_stream

for role in sender receiver; do
  docker run -d --name "mqhole-bench-$role" --network mqhole-bench \
    --cap-add NET_ADMIN -v "$MQHOLE_BENCH_DIR:/bench" \
    -v "$PWD/benchmarks:/scripts:ro" mqhole-bench-client
done
```

Use `metadata.json` in the results directory for the exact image digests used in
the recorded run. `NET_ADMIN` is only needed for the optional network experiments.
The ordinary benchmark runs use independent sender, receiver, and broker network
namespaces on one Docker bridge.

Create `$MQHOLE_BENCH_DIR/connections.json`, mode 0600:

```json
{
  "lavinmq-local": "amqp://guest:guest@mqhole-bench-lavinmq",
  "rabbitmq-local": "amqp://bench:bench@mqhole-bench-rabbitmq"
}
```

For CloudAMQP, set `CLOUDAMQP_API_KEY` and run:

```sh
python3 benchmarks/cloud.py
```

The script verifies that `lemming` and `lemur` cost zero, creates or reuses
benchmark-named subscriptions in `scaleway::nl-ams`, and adds their AMQPS URLs to
the private connection file. It does not modify unrelated subscriptions.
`--suffix` distinguishes separate experiments; retain the generated instance IDs
for cleanup. `probe.py` checks MQTT authentication, stream ports and stream queue
declarations from a client container:

```sh
docker exec mqhole-bench-sender python3 /scripts/probe.py
```

## Build the clients

```sh
shards install --frozen
shards build --release
cp bin/mqhole "$MQHOLE_BENCH_DIR/mqhole-current"
crystal build --release benchmarks/transfer.cr \
  -o "$MQHOLE_BENCH_DIR/transfer-current"
crystal build --release -Dstream_benchmark benchmarks/transfer.cr \
  -o "$MQHOLE_BENCH_DIR/transfer-stream"

mkdir -p "$MQHOLE_BENCH_DIR/baseline/benchmarks"
git archive 2c62f95 src | tar -x -C "$MQHOLE_BENCH_DIR/baseline"
cp benchmarks/transfer.cr "$MQHOLE_BENCH_DIR/baseline/benchmarks/transfer.cr"
ln -s "$PWD/lib" "$MQHOLE_BENCH_DIR/baseline/lib"
crystal build --release \
  "$MQHOLE_BENCH_DIR/baseline/benchmarks/transfer.cr" \
  -o "$MQHOLE_BENCH_DIR/transfer-baseline-final"

ln -s transfer-current "$MQHOLE_BENCH_DIR/transfer-encrypted"
ln -s transfer-current "$MQHOLE_BENCH_DIR/transfer-current-memory"
ln -s transfer-baseline-final "$MQHOLE_BENCH_DIR/transfer-baseline-memory"
for protocol in mqtt-qos0 mqtt-qos1 mqtt-qos0-keepalive300 native-stream native-stream-window; do
  ln -s /scripts/protocol.py "$MQHOLE_BENCH_DIR/$protocol"
done
```

The Python transport probes have a separate binary framing format. They check
chunk sequence numbers, write temporary files, and verify SHA-256, but do not
implement mqhole's encryption, hooks, offline-delivery or retry contract. QoS 0
has no broker confirmation. MQTT QoS 1 acknowledges messages while receiving,
not after complete file delivery. Stream credit acknowledgements do not delete
messages; the stream probe does not persist a completed-file offset.
The probes reject duplicate or out-of-order chunks; MQTT QoS 1 deduplication
after reconnects is not implemented.

MQTT uses a 60-second keepalive by default. `mqtt-qos0-keepalive300` changes only
that interval to 300 seconds, for a separately labeled diagnostic of disconnects
on the slow hosted RabbitMQ path. It does not change the broker's limits.

For native RabbitMQ streams, make the broker's advertised hostname resolvable in
both clients. In this lab it is the RabbitMQ container hostname: add its bridge
IP and hostname to each client's `/etc/hosts`, or configure RabbitMQ's advertised
stream hostname before starting it. LavinMQ does not implement that binary
protocol; its stream probe uses AMQP 0-9-1. `native-stream` confirms each batch;
`native-stream-window` pipelines batches with approximately 32 messages in
flight, respecting the native protocol's 1 MiB frame limit.

## Run

Run one benchmark at a time, after builds finish:

```sh
python3 benchmarks/matrix.py local
python3 benchmarks/matrix.py cloud
python3 benchmarks/matrix.py large
python3 benchmarks/matrix.py protocols
python3 benchmarks/matrix.py chunks

python3 benchmarks/run.py --broker lavinmq-local \
  --binary transfer-encrypted --sizes 1024,16777216,268435456 --scenario encrypted
python3 benchmarks/run.py --broker lavinmq-local \
  --binary transfer-current-memory --sizes 268435456 --repeat 1 --scenario memory
python3 benchmarks/run.py --broker lavinmq-local \
  --binary transfer-baseline-memory --sizes 268435456 --repeat 1 --scenario memory
python3 benchmarks/run.py --broker lavinmq-local \
  --sizes 1024 --repeat 30 --scenario latency

python3 benchmarks/cold.py --broker lavinmq-local
python3 benchmarks/cold.py --broker lavinmq-local --encrypted
python3 benchmarks/manyfiles.py --broker lavinmq-local --count 1000
```

`run.py` generates incompressible random files, opens both broker connections,
then releases a sender barrier. Its completion time is the later of the final
publisher confirmation and the final verified receiver receipt, excluding
connection teardown. Raw records also retain those two times separately and
per-transfer publisher times. `--count 100` sends 100 separate transfers on
reused connections. `cold.py` uses the real CLI and includes connection setup
and teardown; CloudAMQP API provisioning is excluded. `--encrypted` includes
passphrase generation and key derivation, automatically handing the generated
passphrase to the receiver over stdin without recording it. `manyfiles.py` includes
packing and unpacking a directory as an uncompressed tar file, with verification
outside the timer.

Generated queues have random names and are deleted after each trial. Tests have
bounded waits and terminate their own children on failure. The matrix stops on
failure so the operator can inspect it, rather than treating incomplete data as
a throughput measurement. Raw JSONL and logs are written to the working
directory. Original experimental binaries and exploratory runs are not required
for reproduction.

After running the desired cases, `python3 benchmarks/summarize.py` writes
`summary.csv` and `summary.json` beside the raw JSONL. It groups by scenario,
broker, client, file size, count, and chunk size; it does not combine cold and
warm measurements. Use `MQHOLE_BENCH_DIR` to summarize an archived result directory.

## Tailcat and network experiments

Build the pinned tailcat commit in a separate checkout:

```sh
git clone https://github.com/tailscale/tailcat.git "$MQHOLE_BENCH_DIR/tailcat"
cd "$MQHOLE_BENCH_DIR/tailcat"
git checkout b4dc28e8aa8936f0a90a41ad8293a64e3d6b645f
# Build with the Go version required by this commit.
go build -o "$MQHOLE_BENCH_DIR/tailcat-bin" ./cmd/tailcat
go build -mod=mod -o "$MQHOLE_BENCH_DIR/derper" tailscale.com/cmd/derper
```

The recorded tests use a private `derper` container on the same bridge, named
`mqhole-bench-derp`, with a self-signed certificate for that hostname. Its DERP
map uses region 901, hostname `mqhole-bench-derp`, TLS port 443, STUN port 3478,
and `InsecureForTests: true` for this isolated lab only. Back at the mqhole
repository root, create and start that private relay:

```sh
mkdir -p "$MQHOLE_BENCH_DIR/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout "$MQHOLE_BENCH_DIR/certs/mqhole-bench-derp.key" \
  -out "$MQHOLE_BENCH_DIR/certs/mqhole-bench-derp.crt" \
  -subj /CN=mqhole-bench-derp -addext subjectAltName=DNS:mqhole-bench-derp

docker run -d --name mqhole-bench-derp --network mqhole-bench \
  -v "$MQHOLE_BENCH_DIR:/bench" mqhole-bench-client \
  /bench/derper -hostname mqhole-bench-derp -certmode manual \
  -certdir /bench/certs -a :443 -http-port -1
```

Save the following as `$MQHOLE_BENCH_DIR/derpmap.json`:

```json
{
  "Regions": {
    "901": {
      "RegionID": 901,
      "RegionCode": "bench",
      "RegionName": "Private benchmark relay",
      "Nodes": [{
        "Name": "bench1",
        "RegionID": 901,
        "HostName": "mqhole-bench-derp",
        "DERPPort": 443,
        "STUNPort": 3478,
        "InsecureForTests": true
      }]
    }
  }
}
```

Serve the map inside the private bridge, then start tailcat in the receiver:

```sh
docker exec -d mqhole-bench-receiver \
  python3 -m http.server 8880 --directory /bench
```

```sh
mkdir -p "$MQHOLE_BENCH_DIR/tailcat-inbox"
docker exec -d mqhole-bench-receiver sh -c \
  'TAILCAT_ADDR_FILE=/bench/tailcat-address /bench/tailcat-bin \
  --derpmap-url=http://mqhole-bench-receiver:8880/derpmap.json \
  serve --files=/bench/tailcat-inbox:rw files perf \
  >/bench/tailcat-server.log 2>&1'
```

Make the address file readable by the VM user; treat it as a capability, not a
public URL. The benchmark scripts never print it. `tailcat.py` times actual
`tailcat cp` file transfers, including client connection setup. The server is
already running. Verify that a direct path is available with
`tailcat ping --until-direct` before using the `local-direct` label. Every copy
starts a fresh client and may bootstrap over DERP before switching to UDP; this
label means direct routing is allowed, not that every packet used it. Run:

```sh
python3 benchmarks/tailcat.py
python3 benchmarks/tailcat.py --sizes 1024 --count 1000
python3 benchmarks/manyfiles.py --broker local-direct --count 1000
python3 benchmarks/network.py --relay on
# Verify pings stay on DERP before labeling these runs relayed.
python3 benchmarks/tailcat.py --relay
python3 benchmarks/manyfiles.py --broker private-relay --count 1000
python3 benchmarks/network.py --relay off

python3 benchmarks/network.py --delay-ms 10
python3 benchmarks/matrix.py delay
python3 benchmarks/tailcat.py --scenario delay-10ms
python3 benchmarks/network.py --delay-ms 0
```

Delay is applied on egress from both clients, both brokers, and the private
relay. Thus direct tailcat has about 20 ms RTT; broker/relay routes have two
hops. The relay rule blocks UDP between the two client IPs only. Restore both
delay and relay rules when done, then remove only the `mqhole-bench-*`
containers/network and benchmark-created CloudAMQP subscriptions.

The `manyfiles.py` tailcat routes use the same tar packing, extraction, and hash
verification as mqhole. They measure batching separately from individual SFTP
copies. Route names label the experiment; use `network.py` and verify the actual
path before running them. Set `--scenario delay-10ms` when delay is active.

For a byte-stream comparison without SFTP, start another tailcat server that
writes each connection to a file. Run transfers sequentially because this
receiver deliberately has one output path:

```sh
docker exec -d mqhole-bench-receiver sh -c \
  'TAILCAT_ADDR_FILE=/bench/tailcat-stream-address /bench/tailcat-bin \
  --derpmap-url=http://mqhole-bench-receiver:8880/derpmap.json \
  serve exec -- sh -c "cat > /bench/tailcat-stream.out" \
  >/bench/tailcat-stream-server.log 2>&1'
```

Make its address file readable by the VM user and verify its route with ping.
After `run.py` has generated the payload files:

```sh
python3 benchmarks/tailcat_stream.py
# With peer UDP blocked and relay routing verified:
python3 benchmarks/tailcat_stream.py --relay
```

This measures a fresh tailcat client connecting to a running exec server,
writing actual file bytes and waiting for the remote command to close the
connection. SHA-256 is verified after the timer. The receiver does not implement
mqhole's manifest, offline buffering, or hook acknowledgement semantics.

## Public DERP versus free regional brokers

Use a fresh `MQHOLE_BENCH_DIR` to keep this experiment separate from local
results. Mount that directory at `/bench` in both clients and copy the built
`mqhole-current`, `transfer-current`, and `tailcat-bin` into it. No local broker
or private DERP container is needed. Provision each region with distinct names
and aliases, for example:

```sh
python3 benchmarks/cloud.py --region scaleway::nl-ams \
  --suffix public-ams --label ams
python3 benchmarks/cloud.py --region amazon-web-services::eu-north-1 \
  --suffix public-stockholm --label stockholm
python3 benchmarks/cloud.py --region amazon-web-services::us-east-1 \
  --suffix public-virginia --label virginia
export TAILCAT_DERPMAP_URL=https://tailcat.dev/derpmap.json
```

Start the file and exec servers as above, using that public map URL in both
server commands. Keep their addresses private. To prevent direct paths,
including public-address hairpin paths, apply these rules inside both dedicated
client containers before starting the servers:

```sh
for role in sender receiver; do
  docker exec "mqhole-bench-$role" iptables -A OUTPUT -o lo -j ACCEPT
  docker exec "mqhole-bench-$role" iptables -A OUTPUT \
    -p udp ! --dport 53 -j DROP
done
```

Loopback is allowed because Docker's embedded DNS rewrites ports internally.
Verify both addresses with `tailcat ping --until-direct --timeout=5s`: successful
pongs must name a public DERP region, and the command must fail to find a direct
path. Record sanitized pings and the public map. Check routing again after the
measurements. Do not use `tailcat perf`: it disallows public relays. This matrix
uses bounded, sequential copies of real files, with hash verification. Public
copy commands have a 120-second deadline and terminate their container-side
process group on timeout:

```sh
python3 benchmarks/public_matrix.py \
  --brokers lavinmq-ams,rabbitmq-ams,lavinmq-stockholm,rabbitmq-stockholm,lavinmq-virginia,rabbitmq-virginia
```

Each of three rounds measures 1 KiB, 1 MiB, and 16 MiB encrypted CLI transfers,
1,000 tar-batched tiny files, and ready-connection AMQP diagnostics. The public
relay also gets raw byte-stream copies, and one 100-file individual-copy sample.
Tar mqhole transfers use TLS but no payload encryption; the individual-file
comparison uses payload encryption for both tools. Timers follow the definitions
above. The recorded matrix is sequential, not a concurrent load test.

To isolate upload from download, build `directions.cr` and give it a random
payload of at most 8 MiB. It first publishes the entire payload with a window of
32 confirmations, then consumes it, verifies its hash and removes its queue.
This fits under the observed 15 MB RabbitMQ queue policy:

```sh
crystal build --release benchmarks/directions.cr \
  -o "$MQHOLE_BENCH_DIR/directions"
docker exec mqhole-bench-sender python3 /scripts/launch.py rabbitmq-ams \
  /bench/directions /bench/payload-8388608 131072 persistent
```

The last argument can be `transient` to diagnose persistence overhead; this does
not change mqhole's persistent production messages. Socket-option experiments
use separate private connection aliases with `tcp_nodelay=true`,
`frame_max=1048576`, or `buffer_size=65536` appended to the URL query. Preserve TLS
certificate verification. `ss -tin` in the sender shows the remote receive
window (`snd_wnd`), RTT and time limited by that window (`rwnd_limited`); redact
endpoint addresses before archiving it. `docker exec mqhole-bench-sender
python3 /scripts/tcp_sample.py` emits those statistics with broker aliases in
place of endpoint addresses. These are endpoint observations, not
access to the provider's underlying broker configuration.

Delete only the subscriptions and containers created for this experiment when
finished. Preserve unrelated subscriptions and the API key.

A further diagnostic uses CloudAMQP's documented `/ws/amqp` endpoint on port
443. It reuses mqhole's persistent queues, bounded confirmations and deferred
full-file acknowledgements; only the connection transport changes. It is a
benchmark client, not a new production CLI option:

```sh
crystal build --release -Dwebsocket_benchmark benchmarks/transfer.cr \
  -o "$MQHOLE_BENCH_DIR/transfer-websocket"
python3 benchmarks/run.py --broker rabbitmq-ams --binary transfer-websocket \
  --sizes 1024,16777216 --scenario websocket-endpoint
```

The supplied broker URL remains AMQPS: the diagnostic takes its credentials and
vhost and connects to the same hostname over verified HTTPS. This avoids the
pinned AMQP client's fixed empty WebSocket path, without modifying dependencies.
