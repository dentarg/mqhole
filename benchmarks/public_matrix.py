"""Bounded public DERP copies and encrypted CLI transfers through hosted brokers."""

import argparse
import json
import os
import time

import cold
import manyfiles
import run
import tailcat
import tailcat_stream


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--brokers", required=True, help="comma-separated private aliases"
    )
    parser.add_argument("--repeat", type=int, default=3)
    args = parser.parse_args()
    if tailcat.MAP != "https://tailcat.dev/derpmap.json":
        parser.error("set TAILCAT_DERPMAP_URL=https://tailcat.dev/derpmap.json")
    brokers = args.brokers.split(",")
    connections = json.loads((run.ROOT / "connections.json").read_text())
    if any(broker not in connections for broker in brokers):
        parser.error("broker alias missing from connections.json")

    for size in (1024, 1048576, 16777216):
        payload = run.ROOT / f"payload-{size}"
        if not payload.exists():
            payload.write_bytes(os.urandom(size))

    def save(row, iteration):
        row.update(timestamp=time.time(), iteration=iteration, scenario="public-wan")
        with (run.ROOT / "public-results.jsonl").open("a") as target:
            target.write(json.dumps(row) + "\n")
        print(json.dumps(row), flush=True)

    # Use ordinary, bounded file copies; tailcat perf disallows public relays.
    # Verify relay routing and block peer UDP before invoking this matrix.
    for iteration in range(args.repeat):
        for size in (1024, 1048576, 16777216):
            save(tailcat.run(size, 1, True, "public-wan"), iteration)
            save(tailcat_stream.run(size, True, "public-wan"), iteration)
        save(manyfiles.run("public-relay", 1000), iteration)
        if iteration == 0:
            save(tailcat.run(1024, 100, True, "public-wan"), iteration)
        for broker in brokers:
            for size in (1024, 1048576, 16777216):
                save(cold.trial(broker, size, True), iteration)
            save(manyfiles.run(broker, 1000), iteration)
            for size in (1024, 16777216):
                save(run.trial(broker, "transfer-current", size, 1, 131072), iteration)


if __name__ == "__main__":
    main()
