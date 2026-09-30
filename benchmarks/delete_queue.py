import json
import sys
import urllib.parse

import pika

with open("/bench/connections.json") as source:
    url = json.load(source)[sys.argv[1]]
uri = urllib.parse.urlsplit(url)
# These tune the Crystal transfer client, not the Pika cleanup connection.
query = urllib.parse.urlencode(
    [
        (key, value)
        for key, value in urllib.parse.parse_qsl(uri.query)
        if key not in {"tcp_nodelay", "buffer_size", "frame_max"}
    ]
)
url = urllib.parse.urlunsplit(uri._replace(query=query))
connection = pika.BlockingConnection(pika.URLParameters(url))
connection.channel().queue_delete(sys.argv[2])
connection.close()
