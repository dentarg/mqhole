"""Provision free, dedicated-to-this-benchmark subscriptions; keep credentials private."""

import argparse
import base64
import json
import os
import time
import urllib.request

from run import ROOT


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--region", default="scaleway::nl-ams")
    parser.add_argument("--suffix", default=time.strftime("%Y%m%d"))
    parser.add_argument("--label", default="cloud", help="broker alias suffix")
    args = parser.parse_args()
    key = os.environ["CLOUDAMQP_API_KEY"]
    os.umask(0o077)
    ROOT.mkdir(parents=True, exist_ok=True)
    authorization = "Basic " + base64.b64encode((":" + key).encode()).decode()

    def request(path, data=None):
        req = urllib.request.Request(
            "https://customer.cloudamqp.com/api" + path,
            data=json.dumps(data).encode() if data else None,
            headers={
                "Authorization": authorization,
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.load(response)

    plans = request("/plans")
    instances = request("/instances")
    config = ROOT / "connections.json"
    connections = json.loads(config.read_text()) if config.exists() else {}
    for backend, plan in (("lavinmq", "lemming"), ("rabbitmq", "lemur")):
        assert any(
            p["name"] == plan and p.get("backend") == backend and p.get("price") == 0
            for p in plans
        )
        name = "mqhole-bench-" + backend + "-" + args.suffix
        instance = next((i for i in instances if i.get("name") == name), None)
        if instance is None:
            instance = request(
                "/instances",
                {
                    "name": name,
                    "plan": plan,
                    "region": args.region,
                    "tags": ["mqhole-benchmark"],
                },
            )
        assert instance.get("plan", plan) == plan
        assert instance.get("region", args.region) == args.region
        for _ in range(60):
            detail = request("/instances/" + str(instance["id"]))
            url = (detail.get("urls") or {}).get("external") or detail.get("url")
            if detail.get("ready") and url:
                break
            time.sleep(5)
        else:
            raise TimeoutError("instance provisioning timed out")
        alias = backend + "-" + args.label
        detail_name = backend if args.label == "cloud" else alias
        (ROOT / (detail_name + "-cloud.json")).write_text(json.dumps(detail))
        connections[alias] = url
        config.write_text(json.dumps(connections))
        config.chmod(0o600)
        print(f"{backend} instance_id={instance['id']} ready=true")


if __name__ == "__main__":
    main()
