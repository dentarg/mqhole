"""Compare actual SFTP file copies; server setup is excluded, client setup included."""

import argparse
import hashlib
import json
import os
import subprocess
import time

from run import ROOT

MAP = os.environ.get(
    "TAILCAT_DERPMAP_URL", "http://mqhole-bench-receiver:8880/derpmap.json"
)


def route(relay):
    if relay and MAP == "https://tailcat.dev/derpmap.json":
        return "public-relay"
    return "private-relay" if relay else "local-direct"


def run_command(command, timeout=600):
    if MAP == "https://tailcat.dev/derpmap.json":
        timeout = min(timeout, 120)
    container_command = command[:3] == ["docker", "exec", "mqhole-bench-sender"]
    if container_command:
        # Kill the complete client process group inside its container on timeout.
        command = [
            *command[:3],
            "timeout",
            "--kill-after=5",
            str(timeout),
            *command[3:],
        ]
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            timeout=timeout + 10 if container_command else timeout,
        )
    except subprocess.TimeoutExpired:
        # TimeoutExpired includes argv, which contains the private address.
        raise TimeoutError(f"tailcat command exceeded {timeout} seconds") from None
    if result.returncode == 124:
        raise TimeoutError(f"tailcat command exceeded {timeout} seconds")
    return result


def run(size, count, relay=False, scenario="lan"):
    address = (ROOT / "tailcat-address").read_text().strip()
    sources = []
    for index in range(count):
        path = ROOT / f"tailcat-source-{size}-{index}"
        if not path.exists():
            import os

            with path.open("wb") as target:
                remaining = size
                while remaining:
                    block = os.urandom(min(remaining, 1048576))
                    target.write(block)
                    remaining -= len(block)
        sources.append(path)
    hashes = {
        source.name: hashlib.file_digest(source.open("rb"), "sha256").hexdigest()
        for source in sources
    }
    command = [
        "docker",
        "exec",
        "mqhole-bench-sender",
        "/bench/tailcat-bin",
        "--derpmap-url=" + MAP,
    ]
    started = time.perf_counter()
    copy = run_command(
        [*command, "cp", *("/bench/" + p.name for p in sources), address + ":"]
    )
    elapsed = time.perf_counter() - started
    if copy.returncode:
        raise RuntimeError(copy.stderr.decode().replace(address, "<address>"))
    for name, digest in hashes.items():
        destination = ROOT / "tailcat-inbox" / name
        assert (
            hashlib.file_digest(destination.open("rb"), "sha256").hexdigest() == digest
        )
    return {
        "binary": "tailcat-cp",
        "scenario": scenario,
        "broker": route(relay),
        "size": size,
        "count": count,
        "seconds": elapsed,
        "mib_per_second": size * count / elapsed / 1048576,
        "verified": True,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--sizes", default="1024,1048576,16777216,268435456")
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--relay", action="store_true")
    parser.add_argument("--scenario", default="lan")
    args = parser.parse_args()
    for size in map(int, args.sizes.split(",")):
        for _ in range(args.repeat):
            result = run(size, args.count, args.relay, args.scenario)
            with (ROOT / "tailcat-results.jsonl").open("a") as target:
                target.write(json.dumps(result) + "\n")
            print(json.dumps(result), flush=True)
