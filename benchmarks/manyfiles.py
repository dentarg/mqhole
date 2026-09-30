"""Measure a tar-batched directory transfer, including packing and unpacking."""

import argparse
import hashlib
import json
import os
import subprocess
import tarfile
import time
import uuid

from run import ROOT, client, stop_clients


def run(broker, count):
    use_tailcat = broker in ("local-direct", "private-relay", "public-relay")
    sources = []
    for index in range(count):
        path = ROOT / f"tailcat-source-1024-{index}"
        if not path.exists():
            path.write_bytes(os.urandom(1024))
        sources.append(path)
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    name = "mqhole-directory-" + uuid.uuid4().hex
    archive = ROOT / (name + ".tar")
    received = (
        ROOT / "tailcat-inbox" / archive.name
        if use_tailcat
        else ROOT / (name + ".received.tar")
    )
    receiver = (
        None
        if use_tailcat
        else client(
            "receiver",
            broker,
            "mqhole-current",
            "receive",
            name,
            "--output",
            "/bench/" + received.name,
            "--timeout",
            "300",
        )
    )
    sender = None
    try:
        started = time.perf_counter()
        with tarfile.open(archive, "w", format=tarfile.USTAR_FORMAT) as target:
            for source in sources:
                target.add(source, arcname=source.name)
        if use_tailcat:
            from tailcat import MAP, run_command

            address = (ROOT / "tailcat-address").read_text().strip()
            result = run_command(
                [
                    "docker",
                    "exec",
                    "mqhole-bench-sender",
                    "/bench/tailcat-bin",
                    "--derpmap-url=" + MAP,
                    "cp",
                    "/bench/" + archive.name,
                    address + ":",
                ]
            )
            if result.returncode:
                raise RuntimeError("tailcat archive copy failed")
        else:
            sender = client(
                "sender",
                broker,
                "mqhole-current",
                "send",
                name,
                "--file",
                "/bench/" + archive.name,
            )
            _, send_err = sender.communicate(timeout=600)
            _, recv_err = receiver.communicate(timeout=600)
            assert sender.returncode == receiver.returncode == 0, (send_err, recv_err)
        # Extract into a disposable directory and verify the actual files.
        import tempfile

        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            with tarfile.open(received) as source:
                source.extractall(directory, filter="data")
            elapsed = time.perf_counter() - started
            from pathlib import Path

            for filename, digest in hashes.items():
                assert (
                    hashlib.sha256(
                        (Path(directory) / filename).read_bytes()
                    ).hexdigest()
                    == digest
                )
        return {
            "binary": "tailcat-tar-cp" if use_tailcat else "mqhole-tar-cli",
            "broker": broker,
            "size": 1024,
            "count": count,
            "archive_bytes": archive.stat().st_size,
            "seconds": elapsed,
            "mib_per_second": 1024 * count / elapsed / 1048576,
            "verified": True,
        }
    finally:
        for process in (sender, receiver):
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
        if not use_tailcat:
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
        archive.unlink(missing_ok=True)
        subprocess.run(
            [
                "docker",
                "exec",
                "mqhole-bench-receiver",
                "rm",
                "-f",
                "/bench/" + str(received.relative_to(ROOT)),
            ],
            check=True,
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--broker", required=True)
    parser.add_argument("--count", type=int, default=1000)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--scenario", default="cli")
    args = parser.parse_args()
    for _ in range(args.repeat):
        result = run(args.broker, args.count)
        result["scenario"] = args.scenario
        with (ROOT / "cold-results.jsonl").open("a") as output:
            output.write(json.dumps(result) + "\n")
        print(json.dumps(result), flush=True)
