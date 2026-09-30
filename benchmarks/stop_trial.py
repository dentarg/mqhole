"""Terminate only benchmark child processes carrying this trial's unique queue."""

import os
import pathlib
import signal
import sys

name = sys.argv[1].encode()
for process in pathlib.Path("/proc").iterdir():
    if not process.name.isdigit() or int(process.name) == os.getpid():
        continue
    try:
        args = (process / "cmdline").read_bytes().split(b"\0")
        if name in args and any(arg.startswith(b"/bench/") for arg in args[:2]):
            os.kill(int(process.name), signal.SIGTERM)
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        pass
