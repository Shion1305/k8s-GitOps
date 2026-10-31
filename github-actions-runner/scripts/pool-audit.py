#!/usr/bin/env python3
"""Flag GARM pools whose sizing drifted above the approved ceilings.

Reads `garm-cli pool list --format json` on stdin. Exits non-zero if any pool
exceeds its default or narrowly approved ceiling, so it can be used as a check.

Pools are configured imperatively via garm-cli, so nothing in Git prevents
drift. Oversized pools are not merely wasteful: every idle runner is a fresh
pod that must pull and unpack the pool image before it can register, and
kubelet pulls images one at a time per node by default. See "Pool Sizing" in
../README.md.
"""

import json
import os
import re
import sys


RUST_2605_IMAGE = re.compile(
    r"harbor\.shion1305\.com/shion1305/garm-runner-rust@sha256:[0-9a-f]{64}"
)


def is_approved_isucon_rust_pool(pool: dict) -> bool:
    return (
        pool.get("repo_name") == "Shion1305/isucon2026-problem"
        and pool.get("provider_name") == "kubernetes_amd64_rust_2605"
        and pool.get("flavor") == "default"
        and pool.get("os_type") == "linux"
        and pool.get("os_arch") == "amd64"
        and RUST_2605_IMAGE.fullmatch(pool.get("image", "")) is not None
        and [tag.get("name") for tag in pool.get("tags", [])]
        == ["shion1305-ubuntu-2605-rust"]
    )


def main() -> int:
    max_ok = int(os.environ.get("MAX_OK", "6"))
    idle_ok = int(os.environ.get("IDLE_OK", "0"))

    pools = json.load(sys.stdin)
    drifted = []

    for pool in pools:
        # garm omits min_idle_runners from its JSON when the value is 0.
        max_runners = pool.get("max_runners", 0)
        min_idle = pool.get("min_idle_runners", 0)
        rust_isucon = is_approved_isucon_rust_pool(pool)
        pool_max_ok = 10 if rust_isucon else max_ok
        pool_idle_ok = 3 if rust_isucon else idle_ok

        over = []
        if max_runners > pool_max_ok:
            over.append(f"max_runners={max_runners} > {pool_max_ok}")
        if min_idle > pool_idle_ok:
            over.append(f"min_idle_runners={min_idle} > {pool_idle_ok}")

        if over:
            drifted.append((pool, over))

    for pool, over in drifted:
        print(
            f"DRIFT {pool['id'][:8]} {pool.get('repo_name')} "
            f"({pool['os_arch']}): {', '.join(over)}"
        )
        print(f"      image={pool['image']}")

    if not drifted:
        print(f"OK: {len(pools)} pool(s) within limits "
              f"(default max_runners<={max_ok}, min_idle_runners<={idle_ok}; "
              "approved ISUCON Rust pool <=10/3)")
        return 0

    print(f"\n{len(drifted)} of {len(pools)} pool(s) over limits. Fix with:")
    print("  just cli pool update <id> --max-runners N --min-idle-runners N")
    return 1


if __name__ == "__main__":
    sys.exit(main())
