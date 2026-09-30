"""Run a sequential matrix so competing benchmark jobs do not skew results."""

import argparse
import json
import time

from run import ROOT, trial


def run_case(broker, binary, size, count=1, repeat=3, chunk=131072, scenario="lan"):
    for iteration in range(repeat):
        started = time.time()
        try:
            result = trial(broker, binary, size, count, chunk)
            result.update(scenario=scenario, iteration=iteration, timestamp=started)
            with (ROOT / "results.jsonl").open("a") as target:
                target.write(json.dumps(result) + "\n")
            print(
                f"{scenario} {broker} {binary} size={size} count={count} "
                f"seconds={result['seconds']:.4f} MiB/s={result['mib_per_second']:.2f}",
                flush=True,
            )
        except Exception as error:
            # Never serialize connection URLs or authentication exceptions.
            result = {
                "broker": broker,
                "binary": binary,
                "size": size,
                "count": count,
                "chunk": chunk,
                "scenario": scenario,
                "error": type(error).__name__,
            }
            with (ROOT / "failures.jsonl").open("a") as target:
                target.write(json.dumps(result) + "\n")
            print("FAILED", json.dumps(result), flush=True)
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "group", choices=["local", "cloud", "protocols", "large", "chunks", "delay"]
    )
    args = parser.parse_args()
    if args.group in ("local", "cloud"):
        location = args.group
        for broker in (f"lavinmq-{location}", f"rabbitmq-{location}"):
            for binary in ("transfer-baseline-final", "transfer-current"):
                for size in (1024, 1048576, 16777216):
                    run_case(broker, binary, size, scenario=location)
                run_case(broker, binary, 1024, count=100, scenario=location)
    elif args.group == "large":
        for broker in ("lavinmq-local", "rabbitmq-local"):
            for binary in ("transfer-baseline-final", "transfer-current"):
                run_case(broker, binary, 268435456)
        for broker in ("lavinmq-cloud", "rabbitmq-cloud"):
            run_case(broker, "transfer-current", 67108864, scenario="cloud")
    elif args.group == "protocols":
        for broker in (
            "lavinmq-local",
            "rabbitmq-local",
            "lavinmq-cloud",
            "rabbitmq-cloud",
        ):
            binaries = ["mqtt-qos0", "mqtt-qos1", "transfer-stream"]
            if broker == "rabbitmq-local":
                binaries.append("native-stream")
            for binary in binaries:
                for size in (1024, 1048576, 16777216):
                    # The hosted RabbitMQ MQTT path is very slow. Keep one
                    # full large-file run, with repeats for smaller files.
                    repeats = (
                        1
                        if broker == "rabbitmq-cloud"
                        and binary.startswith("mqtt")
                        and size == 16777216
                        else 3
                    )
                    run_case(broker, binary, size, repeat=repeats, scenario="protocol")
                run_case(broker, binary, 1024, count=100, scenario="protocol")
    elif args.group == "chunks":
        for broker in (
            "lavinmq-local",
            "rabbitmq-local",
            "lavinmq-cloud",
            "rabbitmq-cloud",
        ):
            for chunk in (16384, 524288, 1048576):
                run_case(
                    broker,
                    "transfer-current",
                    16777216,
                    chunk=chunk,
                    scenario="chunk-sweep",
                )
    else:
        for broker in ("lavinmq-local", "rabbitmq-local"):
            for binary in (
                "transfer-baseline-final",
                "transfer-current",
                "mqtt-qos1",
                "transfer-stream",
            ):
                for size in (1024, 16777216):
                    run_case(broker, binary, size, scenario="delay-10ms")
                run_case(broker, binary, 1024, count=100, scenario="delay-10ms")
