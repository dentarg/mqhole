"""Check protocol availability without displaying broker credentials."""

import json
import socket
import ssl
import threading
import urllib.parse
import uuid

import paho.mqtt.client as mqtt
import pika

with open("/bench/connections.json") as source:
    connections = json.load(source)
for name, url in connections.items():
    uri = urllib.parse.urlparse(url)
    secure = uri.scheme == "amqps"
    for protocol, port in [
        ("mqtt", 8883 if secure else 1883),
        ("stream", 5551 if secure else 5552),
    ]:
        try:
            with socket.create_connection((uri.hostname, port), timeout=5):
                print(name, protocol, "port-open", flush=True)
        except OSError as ex:
            print(name, protocol, type(ex).__name__, flush=True)
    try:
        connection = pika.BlockingConnection(pika.URLParameters(url))
        channel = connection.channel()
        queue = "mqhole-probe-" + uuid.uuid4().hex
        channel.queue_declare(queue, durable=True, arguments={"x-queue-type": "stream"})
        channel.queue_delete(queue)
        connection.close()
        print(name, "amqp-stream", "supported", flush=True)
    except pika.exceptions.ChannelClosedByBroker as ex:
        print(name, "amqp-stream", ex.reply_code, ex.reply_text, flush=True)
    event = threading.Event()
    result = []
    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2, client_id="mqhole-probe-" + uuid.uuid4().hex
    )
    client.username_pw_set(
        (urllib.parse.unquote(uri.path[1:]) or "/")
        + ":"
        + urllib.parse.unquote(uri.username),
        urllib.parse.unquote(uri.password),
    )
    if secure:
        client.tls_set_context(ssl.create_default_context())

    def on_connect(client, userdata, flags, reason, props, result=result, event=event):
        result.append(str(reason))
        event.set()

    client.on_connect = on_connect
    try:
        client.connect_timeout = 5
        client.connect(uri.hostname, 8883 if secure else 1883)
        client.loop_start()
        event.wait(10)
        print(name, "mqtt-auth", result or ["timeout"], flush=True)
        client.disconnect()
        client.loop_stop()
    except OSError as ex:
        print(name, "mqtt-auth", type(ex).__name__, flush=True)
