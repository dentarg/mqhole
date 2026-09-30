"""Time the real CLI, including AMQP connection setup and teardown."""

import argparse
import hashlib
import json
import shlex
import subprocess
import time
import uuid

from run import ROOT, client, stop_clients


def trial(broker, size, encrypted=False):
    payload = ROOT / ("payload-" + str(size))
    assert payload.exists()
    name = "mqhole-cold-" + uuid.uuid4().hex
    output = ROOT / (name + ".out")
    receiver = client(
        "receiver",
        broker,
        "mqhole-current",
        "receive",
        name,
        "--output",
        "/bench/" + output.name,
        "--timeout",
        300,
        *(["--encrypted"] if encrypted else []),
    )
    started = time.perf_counter()
    sender = client(
        "sender",
        broker,
        "mqhole-current",
        "send",
        name,
        "--file",
        "/bench/" + payload.name,
        *(["--encrypted"] if encrypted else []),
    )
    try:
        if encrypted:
            # The CLI generates its passphrase before connecting. Pass it over
            # stdin without recording it in results, argv, or console output.
            fields = dict(
                field.split("=", 1)
                for field in shlex.split(sender.stderr.readline())
                if "=" in field
            )
            assert fields.get("event") == "encryption_passphrase"
            receiver.stdin.write(fields["passphrase"] + "\n")
            receiver.stdin.flush()
        _, send_err = sender.communicate(timeout=600)
        _, recv_err = receiver.communicate(timeout=600)
        elapsed = time.perf_counter() - started
        assert sender.returncode == 0, send_err
        assert receiver.returncode == 0, recv_err
        assert (
            hashlib.file_digest(output.open("rb"), "sha256").digest()
            == hashlib.file_digest(payload.open("rb"), "sha256").digest()
        )
        return {
            "binary": "mqhole-encrypted-cli" if encrypted else "mqhole-cli",
            "broker": broker,
            "size": size,
            "count": 1,
            "seconds": elapsed,
            "mib_per_second": size / elapsed / 1048576,
            "verified": True,
        }
    finally:
        for process in (sender, receiver):
            if process.poll() is None:
                process.kill()
                process.wait()
        stop_clients(name)
        subprocess.run(
            [
                "docker",
                "exec",
                "mqhole-bench-sender",
                "python3",
                "/scripts/delete_queue.py",
                broker,
                "mqhole.v1." + hashlib.sha256(name.encode()).hexdigest(),
            ],
            check=True,
        )
        # Remove only this run's output, inside its owning container.
        subprocess.run(
            [
                "docker",
                "exec",
                "mqhole-bench-receiver",
                "rm",
                "-f",
                "/bench/" + output.name,
            ],
            check=True,
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--broker", required=True)
    parser.add_argument("--sizes", default="1024,1048576,16777216")
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--encrypted", action="store_true")
    args = parser.parse_args()
    for size in map(int, args.sizes.split(",")):
        for _ in range(args.repeat):
            result = trial(args.broker, size, args.encrypted)
            with (ROOT / "cold-results.jsonl").open("a") as target:
                target.write(json.dumps(result) + "\n")
            print(json.dumps(result), flush=True)
