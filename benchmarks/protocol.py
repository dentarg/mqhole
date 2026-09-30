#!/opt/venv/bin/python3
"""Experimental file transports; deliberately separate from mqhole's wire format."""

import asyncio
import collections
import hashlib
import json
import os
import pathlib
import queue
import socket
import ssl
import struct
import sys
import tempfile
import threading
import time
import urllib.parse

MODE, NAME, PATH = sys.argv[1:4]
COUNT, CHUNK = map(int, sys.argv[4:6])
URI = urllib.parse.urlparse(os.environ["AMQP_URL"])
PROTOCOL = pathlib.Path(sys.argv[0]).name


def frames():
    yield b"H"
    with open(PATH, "rb") as source:
        index = 0
        while chunk := source.read(CHUNK):
            yield b"D" + struct.pack(">Q", index) + chunk
            index += 1
    yield b"E"


class Collector:
    def __init__(self):
        self.index = 0
        self.file = None
        self.completed = 0

    def accept(self, frame):
        if frame == b"W":
            return
        if frame[:1] == b"H":
            assert self.file is None
            self.file = tempfile.TemporaryFile()  # noqa: SIM115 - closed on the end frame
            self.index = 0
            self.started = time.perf_counter()
        elif frame[:1] == b"D":
            assert self.file is not None
            index = struct.unpack(">Q", frame[1:9])[0]
            if index != self.index:
                raise ValueError(
                    f"unexpected chunk index: expected {self.index}, received {index}"
                )
            self.file.write(frame[9:])
            self.index += 1
        elif frame == b"E":
            size = self.file.tell()
            self.file.seek(0)
            digest = hashlib.file_digest(self.file, "sha256").hexdigest()
            self.file.close()
            self.file = None
            print(
                json.dumps(
                    {
                        "index": self.completed,
                        "seconds": time.perf_counter() - self.started,
                        "bytes": size,
                        "sha256": digest,
                    }
                ),
                flush=True,
            )
            self.completed += 1
        else:
            raise ValueError("unexpected frame")


def ready():
    print("ready", file=sys.stderr, flush=True)
    if MODE == "send":
        sys.stdin.readline()


def mqtt_run():
    import paho.mqtt.client as mqtt

    qos = 0 if "-qos0" in PROTOCOL else 1
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=NAME + "-" + MODE)
    client.username_pw_set(
        (urllib.parse.unquote(URI.path[1:]) or "/")
        + ":"
        + urllib.parse.unquote(URI.username),
        urllib.parse.unquote(URI.password),
    )
    client.max_inflight_messages_set(32)
    if URI.scheme == "amqps":
        client.tls_set_context(ssl.create_default_context())
    connected, subscribed = threading.Event(), threading.Event()
    messages = queue.Queue(maxsize=128)
    errors = []

    def on_connect(client, userdata, flags, reason, properties):
        if reason.is_failure:
            errors.append(str(reason))
        connected.set()

    def on_subscribe(client, userdata, mid, reasons, properties):
        if any(reason.is_failure for reason in reasons):
            errors.append("subscription rejected")
        subscribed.set()

    client.on_connect = on_connect
    client.on_subscribe = on_subscribe

    def on_disconnect(client, userdata, flags, reason, properties):
        if reason.is_failure:
            print("MQTT disconnected: " + str(reason), file=sys.stderr, flush=True)
            # Keep failures from both peers even if the other peer exits first.
            # Only lab identifiers and the protocol reason are recorded.
            event = {
                "timestamp": time.time(),
                "broker": os.environ.get("BENCH_BROKER"),
                "binary": PROTOCOL,
                "mode": MODE,
                "queue": NAME,
                "reason": str(reason),
            }
            with open("/bench/mqtt-disconnect-events.jsonl", "a") as target:
                target.write(json.dumps(event) + "\n")

    client.on_disconnect = on_disconnect
    client.on_message = lambda client, userdata, message: messages.put(message.payload)
    client.on_socket_open = lambda client, userdata, sock: sock.setsockopt(
        socket.IPPROTO_TCP, socket.TCP_NODELAY, 1
    )
    client.connect(
        URI.hostname,
        8883 if URI.scheme == "amqps" else 1883,
        keepalive=int(os.environ.get("MQTT_KEEPALIVE", "60")),
    )
    client.loop_start()
    try:
        assert connected.wait(15) and not errors, errors
        if MODE == "receive":
            client.subscribe(NAME, qos=qos)
            assert subscribed.wait(15) and not errors, errors
            ready()
            collector = Collector()
            while collector.completed < COUNT:
                collector.accept(messages.get(timeout=300))
        else:
            ready()
            for index in range(COUNT):
                started = time.perf_counter()
                pending = collections.deque()
                for frame in frames():
                    pending.append(client.publish(NAME, frame, qos=qos))
                    if len(pending) >= 32:
                        message = pending.popleft()
                        message.wait_for_publish(30)
                        if not message.is_published():
                            raise TimeoutError("MQTT publish exceeded 30 seconds")
                for message in pending:
                    message.wait_for_publish(30)
                    if not message.is_published():
                        raise TimeoutError("MQTT publish exceeded 30 seconds")
                print(
                    json.dumps(
                        {"index": index, "seconds": time.perf_counter() - started}
                    ),
                    flush=True,
                )
    finally:
        client.disconnect()
        client.loop_stop()


async def stream_run():
    from rstream import Consumer, ConsumerOffsetSpecification, OffsetType, Producer

    options = {
        "host": URI.hostname,
        "port": 5552,
        "username": urllib.parse.unquote(URI.username),
        "password": urllib.parse.unquote(URI.password),
        "vhost": urllib.parse.unquote(URI.path[1:]) or "/",
    }
    if MODE == "receive":
        async with Consumer(**options) as consumer:
            await consumer.create_stream(NAME, exists_ok=True)
            collector = Collector()
            done = asyncio.Event()

            async def accept(message, context):
                collector.accept(bytes(message))
                if collector.completed == COUNT:
                    done.set()

            await consumer.subscribe(
                NAME,
                accept,
                offset_specification=ConsumerOffsetSpecification(
                    OffsetType.FIRST, None
                ),
            )
            ready()
            await asyncio.wait_for(done.wait(), 300)
    else:
        async with Producer(**options) as producer:
            await producer.send_wait(NAME, b"W")
            ready()
            for index in range(COUNT):
                started = time.perf_counter()
                batch = []
                # Keep a batch below the negotiated 1 MiB frame maximum.
                limit = min(32, max(1, 900000 // (CHUNK + 32)))

                async def publish(batch):
                    remaining = len(batch)
                    confirmed = asyncio.Event()
                    failures = []

                    async def confirmation(status):
                        nonlocal remaining
                        if not status.is_confirmed:
                            failures.append(status.response_code)
                        remaining -= 1
                        if remaining == 0:
                            confirmed.set()

                    await producer.send_batch(
                        NAME, batch, on_publish_confirm=confirmation
                    )
                    return confirmed, failures

                async def wait_for_confirmation(receipt):
                    confirmed, failures = receipt
                    await asyncio.wait_for(confirmed.wait(), 30)
                    assert not failures, failures

                window = max(1, 32 // limit) if PROTOCOL.endswith("-window") else 1
                pending = collections.deque()
                for frame in frames():
                    batch.append(frame)
                    if len(batch) == limit:
                        pending.append(await publish(batch))
                        batch = []
                        if len(pending) >= window:
                            await wait_for_confirmation(pending.popleft())
                if batch:
                    pending.append(await publish(batch))
                for receipt in pending:
                    await wait_for_confirmation(receipt)
                print(
                    json.dumps(
                        {"index": index, "seconds": time.perf_counter() - started}
                    ),
                    flush=True,
                )


if PROTOCOL.startswith("mqtt"):
    mqtt_run()
else:
    asyncio.run(stream_run())
