import json
import sys

import pika

with open("/bench/connections.json") as source:
    url = json.load(source)[sys.argv[1]]
connection = pika.BlockingConnection(pika.URLParameters(url))
connection.channel().queue_delete(sys.argv[2])
connection.close()
