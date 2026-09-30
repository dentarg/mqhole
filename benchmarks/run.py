"""Run hash-verified mqhole transfers between separate Docker containers."""

import argparse
import hashlib
import json
import os
import pathlib
import queue as queue_module
import re
import subprocess
import threading
import time
import uuid

ROOT = pathlib.Path(os.environ.get("MQHOLE_BENCH_DIR", "/workspace/mqhole-bench"))


def stop_clients(name):
    for side in ("sender", "receiver"):
        subprocess.run(
            [
                "docker",
                "exec",
                "mqhole-bench-" + side,
                "python3",
                "/scripts/stop_trial.py",
                name,
            ],
            check=True,
        )


def client(side, broker, binary, *args):
    return subprocess.Popen(
        [
            "docker",
            "exec",
            "-i",
            "mqhole-bench-" + side,
            "timeout",
            "1800",
            "python3",
            "/scripts/launch.py",
            broker,
            "/bench/" + binary,
            *map(str, args),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def wait_ready(process):
    lines = queue_module.Queue()

    def read():
        while True:
            line = process.stderr.readline()
            lines.put(line)
            if not line or line.strip() == "ready":
                return

    threading.Thread(target=read, daemon=True).start()
    errors = []
    while True:
        line = lines.get(timeout=60)
        if line.strip() == "ready":
            return
        if not line:
            raise RuntimeError("".join(errors))
        errors.append(line)


def trial(broker, binary, size, count, chunk):
    payload = ROOT / ("payload-" + str(size))
    if not payload.exists():
        with payload.open("wb") as target:
            remaining = size
            while remaining:
                block = os.urandom(min(remaining, 1024 * 1024))
                target.write(block)
                remaining -= len(block)
    digest = hashlib.file_digest(payload.open("rb"), "sha256").hexdigest()
    queue = "mqhole-benchmark-" + uuid.uuid4().hex
    processes = []
    try:
        receiver = client(
            "receiver",
            broker,
            binary,
            "receive",
            queue,
            "/bench/" + payload.name,
            count,
            chunk,
        )
        processes.append(receiver)
        wait_ready(receiver)
        sender = client(
            "sender",
            broker,
            binary,
            "send",
            queue,
            "/bench/" + payload.name,
            count,
            chunk,
        )
        processes.append(sender)
        wait_ready(sender)
        receipts = queue_module.Queue()
        confirmations = queue_module.Queue()

        def read_lines(process, events):
            for _ in range(count):
                line = process.stdout.readline()
                events.put((time.perf_counter(), line))

        readers = [
            threading.Thread(target=read_lines, args=(receiver, receipts), daemon=True),
            threading.Thread(
                target=read_lines, args=(sender, confirmations), daemon=True
            ),
        ]
        for reader in readers:
            reader.start()
        started = time.perf_counter()
        sender.stdin.write("go\n")
        sender.stdin.flush()

        def collect(events, process):
            rows, times = [], []
            deadline = time.perf_counter() + 1800
            for _ in range(count):
                while True:
                    for child in processes:
                        if child.poll() not in (None, 0):
                            raise RuntimeError(child.stderr.read())
                    remaining = deadline - time.perf_counter()
                    if remaining <= 0:
                        raise TimeoutError("transfer exceeded 1800 seconds")
                    try:
                        timestamp, line = events.get(timeout=min(1, remaining))
                        break
                    except queue_module.Empty:
                        continue
                if not line:
                    raise RuntimeError(process.stderr.read())
                times.append(timestamp - started)
                rows.append(json.loads(line))
            return rows, times

        received, receipt_times = collect(receipts, receiver)
        sent, confirm_times = collect(confirmations, sender)
        elapsed = max(receipt_times[-1], confirm_times[-1])
        for reader in readers:
            reader.join()
        _out, err = receiver.communicate(timeout=60)
        _send_out, send_err = sender.communicate(timeout=60)
        assert receiver.returncode == 0, err
        assert sender.returncode == 0, send_err
        assert len(received) == len(sent) == count
        assert all(row["sha256"] == digest and row["bytes"] == size for row in received)
        return {
            "broker": broker,
            "binary": binary,
            "size": size,
            "count": count,
            "chunk": chunk,
            "seconds": elapsed,
            "delivered_seconds": receipt_times[-1],
            "confirmed_seconds": confirm_times[-1],
            "mib_per_second": size * count / elapsed / 1048576,
            "send_seconds": [row["seconds"] for row in sent],
            "receipt_seconds": receipt_times,
            "verified": True,
            "sha256": digest,
            "receiver_rss_kib": int(re.search(r"rss_kib=(\d+)", err)[1])
            if "rss_kib=" in err
            else None,
            "sender_rss_kib": int(re.search(r"rss_kib=(\d+)", send_err)[1])
            if "rss_kib=" in send_err
            else None,
        }
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait()
        stop_clients(queue)
        # Dedicated random queue; delete it even if a transfer failed.
        if not binary.startswith("mqtt"):
            subprocess.run(
                [
                    "docker",
                    "exec",
                    "mqhole-bench-sender",
                    "python3",
                    "/scripts/delete_queue.py",
                    broker,
                    queue,
                ],
                check=True,
            )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--broker", required=True)
    parser.add_argument("--binary", default="transfer-current")
    parser.add_argument("--sizes", default="1024,1048576,16777216")
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--chunk", type=int, default=131072)
    parser.add_argument("--scenario", default="manual")
    args = parser.parse_args()
    for size in map(int, args.sizes.split(",")):
        for iteration in range(args.repeat):
            started = time.time()
            row = trial(args.broker, args.binary, size, args.count, args.chunk)
            row.update(scenario=args.scenario, iteration=iteration, timestamp=started)
            with (ROOT / "results.jsonl").open("a") as target:
                target.write(json.dumps(row) + "\n")
            print(json.dumps(row), flush=True)
