"""Summarize saved trials without mixing cold commands and warm transfers."""

import collections
import csv
import json
import math
import statistics

from run import ROOT


def percentile(values, fraction):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * fraction) - 1)]


def main():
    grouped = collections.defaultdict(list)
    for filename in ("results.jsonl", "cold-results.jsonl", "tailcat-results.jsonl"):
        path = ROOT / filename
        if not path.exists():
            continue
        for line in path.read_text().splitlines():
            row = json.loads(line)
            if filename == "results.jsonl" and not row.get("scenario"):
                continue
            if row["binary"] in (
                "transfer-baseline",
                "transfer-push",
                "transfer-window",
            ):
                continue
            if filename == "tailcat-results.jsonl" and not row.get("scenario"):
                continue
            key = (
                row.get("scenario", "cli"),
                row["broker"],
                row["binary"],
                row["size"],
                row["count"],
                row.get("chunk", 0),
            )
            grouped[key].append(row)
    summaries = []
    for key, rows in sorted(grouped.items()):
        seconds = [row["seconds"] for row in rows]
        confirmations = [
            value * 1000 for row in rows for value in row.get("send_seconds", [])
        ]
        median = statistics.median(seconds)
        result = dict(
            zip(
                (
                    "scenario",
                    "broker",
                    "binary",
                    "bytes_per_file",
                    "files",
                    "chunk_bytes",
                ),
                key,
                strict=True,
            )
        )
        result.update(
            trials=len(rows),
            median_seconds=median,
            min_seconds=min(seconds),
            max_seconds=max(seconds),
            p95_seconds=percentile(seconds, 0.95),
            median_mib_per_second=key[3] * key[4] / median / 1048576,
            publish_p50_ms=statistics.median(confirmations) if confirmations else None,
            publish_p95_ms=percentile(confirmations, 0.95) if confirmations else None,
        )
        summaries.append(result)
    with (ROOT / "summary.csv").open("w", newline="") as target:
        writer = csv.DictWriter(
            target, fieldnames=list(summaries[0]), lineterminator="\n"
        )
        writer.writeheader()
        writer.writerows(summaries)
    (ROOT / "summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
    print(
        f"Summarized {sum(len(rows) for rows in grouped.values())} trials into {len(summaries)} groups"
    )


if __name__ == "__main__":
    main()
