"""Apply delay or force tailcat through the private relay, only in lab containers."""

import argparse
import subprocess


def docker(*args):
    return subprocess.run(["docker", *args], check=True, capture_output=True, text=True)


def delay(milliseconds):
    for role in ("sender", "receiver", "lavinmq", "rabbitmq", "derp"):
        command = [
            "run",
            "--rm",
            "--network",
            "container:mqhole-bench-" + role,
            "--cap-add",
            "NET_ADMIN",
            "mqhole-bench-client",
            "tc",
            "qdisc",
        ]
        if milliseconds:
            docker(
                *command,
                "replace",
                "dev",
                "eth0",
                "root",
                "netem",
                "delay",
                str(milliseconds) + "ms",
            )
        else:
            # An absent qdisc is already the desired state.
            subprocess.run(
                ["docker", *command, "del", "dev", "eth0", "root"],
                check=False,
                capture_output=True,
            )


def relay(enabled):
    # Keep DNS and STUN working. Block peer-to-peer UDP in both directions;
    # tailcat can still bootstrap and exchange data over our private DERP TLS.
    for role, peer in (("sender", "receiver"), ("receiver", "sender")):
        ip = docker(
            "inspect",
            "-f",
            "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
            "mqhole-bench-" + peer,
        ).stdout.strip()
        rule = ["OUTPUT", "-p", "udp", "-d", ip, "-j", "DROP"]
        exists = (
            subprocess.run(
                ["docker", "exec", "mqhole-bench-" + role, "iptables", "-C", *rule],
                check=False,
                capture_output=True,
            ).returncode
            == 0
        )
        if enabled and not exists:
            docker("exec", "mqhole-bench-" + role, "iptables", "-A", *rule)
        elif not enabled and exists:
            docker("exec", "mqhole-bench-" + role, "iptables", "-D", *rule)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--delay-ms", type=int)
    parser.add_argument("--relay", choices=["on", "off"])
    args = parser.parse_args()
    if args.delay_ms is not None:
        delay(args.delay_ms)
    if args.relay:
        relay(args.relay == "on")
