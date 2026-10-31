#!/usr/bin/env python3
"""Check the approved 2605 exception remains narrow at the current pool size."""

import json
import subprocess
import sys
from pathlib import Path


AUDIT = Path(__file__).with_name("pool-audit.py")
IMAGE = "harbor.shion1305.com/shion1305/garm-runner-rust@sha256:" + "a" * 64


def check(pool: dict, should_pass: bool) -> None:
    result = subprocess.run(
        [sys.executable, str(AUDIT)],
        input=json.dumps([pool]),
        text=True,
        capture_output=True,
        check=False,
    )
    assert (result.returncode == 0) == should_pass, result.stdout + result.stderr


approved = {
    "id": "12345678-1234-1234-1234-123456789abc",
    "repo_name": "Shion1305/isucon2026-problem",
    "provider_name": "kubernetes_amd64_rust_2605",
    "flavor": "default",
    "os_type": "linux",
    "os_arch": "amd64",
    "image": IMAGE,
    "tags": [
        {"name": "shion1305-ubuntu-2605"},
        {"name": "shion1305-ubuntu-2605-rust"},
    ],
    "max_runners": 20,
    "min_idle_runners": 3,
}

check(approved, True)
check({**approved, "max_runners": 21}, False)
check({**approved, "min_idle_runners": 4}, False)
check({**approved, "repo_name": "Shion1305/another-repo"}, False)
check({**approved, "provider_name": "kubernetes_amd64"}, False)
check({**approved, "image": "harbor.shion1305.com/shion1305/garm-runner-rust:latest"}, False)
print("GARM pool audit boundaries passed")
