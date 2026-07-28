#!/usr/bin/env python3
"""Flag GARM pools whose sizing drifted above the safe defaults.

Reads `garm-cli pool list --format json` on stdin. Exits non-zero if any pool
exceeds MAX_OK / IDLE_OK, so it can be used as a check.

Pools are configured imperatively via garm-cli, so nothing in Git prevents
drift. Oversized pools are not merely wasteful: every idle runner is a fresh
pod that must pull and unpack the pool image before it can register, and
kubelet pulls images one at a time per node by default. See "Pool Sizing" in
../README.md.
"""

import json
import os
import sys


def main() -> int:
    max_ok = int(os.environ.get("MAX_OK", "6"))
    idle_ok = int(os.environ.get("IDLE_OK", "0"))

    pools = json.load(sys.stdin)
    drifted = []

    for pool in pools:
        # garm omits min_idle_runners from its JSON when the value is 0.
        max_runners = pool.get("max_runners", 0)
        min_idle = pool.get("min_idle_runners", 0)

        over = []
        if max_runners > max_ok:
            over.append(f"max_runners={max_runners} > {max_ok}")
        if min_idle > idle_ok:
            over.append(f"min_idle_runners={min_idle} > {idle_ok}")

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
              f"(max_runners<={max_ok}, min_idle_runners<={idle_ok})")
        return 0

    print(f"\n{len(drifted)} of {len(pools)} pool(s) over limits. Fix with:")
    print("  just cli pool update <id> --max-runners N --min-idle-runners N")
    return 1


if __name__ == "__main__":
    sys.exit(main())
