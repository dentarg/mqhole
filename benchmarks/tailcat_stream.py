"""Copy file bytes through tailcat's exec service, without SFTP framing."""

import argparse
import hashlib
import json
import subprocess
import time

from run import ROOT
from tailcat import MAP


def run(size, relay=False, scenario="lan"):
    payload = ROOT / ("payload-" + str(size))
    assert payload.exists(), "generate payloads with run.py first"
    address = (ROOT / "tailcat-stream-address").read_text().strip()
    started = time.perf_counter()
    try:
        result = subprocess.run(
            [
                "docker",
                "exec",
                "mqhole-bench-sender",
                "timeout",
                "600",
                "sh",
                "-c",
                'exec /bench/tailcat-bin --derpmap-url="$1" "$2" < "$3"',
                "sh",
                MAP,
                address,
                "/bench/" + payload.name,
            ],
            check=False,
            capture_output=True,
            timeout=610,
        )
    except subprocess.TimeoutExpired:
        raise TimeoutError("tailcat stream exceeded 610 seconds") from None
    elapsed = time.perf_counter() - started
    if result.returncode:
        raise RuntimeError(result.stderr.decode().replace(address, "<address>"))
    output = ROOT / "tailcat-stream.out"
    with output.open("rb") as received, payload.open("rb") as source:
        assert (
            hashlib.file_digest(received, "sha256").digest()
            == hashlib.file_digest(source, "sha256").digest()
        )
    return {
        "binary": "tailcat-stream",
        "scenario": scenario,
        "broker": "private-relay" if relay else "local-direct",
        "size": size,
        "count": 1,
        "seconds": elapsed,
        "mib_per_second": size / elapsed / 1048576,
        "verified": True,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--sizes", default="1024,1048576,16777216,268435456")
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--relay", action="store_true")
    parser.add_argument("--scenario", default="lan")
    args = parser.parse_args()
    for size in map(int, args.sizes.split(",")):
        for _ in range(args.repeat):
            result = run(size, args.relay, args.scenario)
            with (ROOT / "tailcat-results.jsonl").open("a") as target:
                target.write(json.dumps(result) + "\n")
            print(json.dumps(result), flush=True)
