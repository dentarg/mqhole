"""Report TCP window diagnostics for configured brokers without endpoint addresses."""

import json
import socket
import subprocess
import time
import urllib.parse
from pathlib import Path


def main():
    connections = json.loads(Path("/bench/connections.json").read_text())
    peers = {}
    for alias, url in connections.items():
        uri = urllib.parse.urlsplit(url)
        try:
            address = socket.gethostbyname(uri.hostname)
        except OSError:
            continue
        # Socket-option aliases may refer to the same broker. Keep its base name.
        peers.setdefault((address, uri.port or 5671), alias)
    lines = subprocess.check_output(["ss", "-tin"], text=True).splitlines()
    for index, line in enumerate(lines[:-1]):
        fields = line.split()
        if len(fields) < 5 or ":" not in fields[-1]:
            continue
        address, port = fields[-1].rsplit(":", 1)
        if not port.isdecimal():
            continue
        alias = peers.get((address, int(port)))
        if alias:
            print(
                json.dumps(
                    {
                        "timestamp": time.time(),
                        "broker": alias,
                        "tcp": lines[index + 1].strip(),
                    }
                )
            )


if __name__ == "__main__":
    main()
