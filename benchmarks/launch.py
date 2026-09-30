"""Load broker credentials inside a client container, without command-line secrets."""

import json
import os
import resource
import subprocess
import sys

with open("/bench/connections.json") as source:
    connections = json.load(source)
os.environ["AMQP_URL"] = connections[sys.argv[1]]
os.environ["BENCH_BROKER"] = sys.argv[1]
if sys.argv[2].endswith("-encrypted"):
    os.environ["BENCH_ENCRYPTED"] = "1"
if sys.argv[2].endswith("-keepalive300"):
    os.environ["MQTT_KEEPALIVE"] = "300"
if sys.argv[2].endswith("-memory"):
    result = subprocess.run(sys.argv[2:], check=False)
    print(
        "rss_kib=" + str(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss),
        file=sys.stderr,
    )
    sys.exit(result.returncode)
os.execv(sys.argv[2], sys.argv[2:])
