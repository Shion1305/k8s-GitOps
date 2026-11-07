#!/usr/bin/env python3
"""Exercise the deployed wrapper with a fake clock and GitHub/Renovate boundary.

Requires bash, jq, openssl, and yq. No credentials or network access are used.
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


CONFIG_MAP = Path(__file__).resolve().parents[1] / "scripts-configmap.yaml"
FAKE_COMMAND = r'''#!/usr/bin/env python3
import base64
import json
import os
from pathlib import Path
import sys
import uuid

root = Path(os.environ["WRAPPER_TEST_DIR"])
state_path = root / "state.json"
state = json.loads(state_path.read_text())
command = Path(sys.argv[0]).name

if command == "date":
    print(state["now"])
elif command == "curl":
    url = sys.argv[-1]
    if url.endswith("/app/installations"):
        if state.get("discovery_failure"):
            print(json.dumps({"message": "Service unavailable"}))
            sys.exit(22 if any("-f" in arg or "--fail" in arg for arg in sys.argv) else 0)
        print(json.dumps([{"id": number} for number in [1, 2, 3]]))
    else:
        installation = int(url.split("/")[-2])
        auth = next(arg for arg in sys.argv if arg.startswith("Authorization: Bearer "))
        payload = auth.split()[-1].split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        if claims["exp"] <= state["now"] or installation == state.get("token_failure"):
            print(json.dumps({"message": "Bad credentials", "status": "401"}))
            sys.exit(22 if any("-f" in arg or "--fail" in arg for arg in sys.argv) else 0)
        token = str(uuid.uuid4())
        state["tokens"][token] = installation
        print(json.dumps({"token": token}))
elif command == "renovate":
    installation = state["tokens"][os.environ["RENOVATE_TOKEN"]]
    state["processed"].append(installation)
    state["arguments"].append(sys.argv[1:])
    state["now"] += state["duration"]
    state_path.write_text(json.dumps(state))
    sys.exit(1 if installation == state.get("renovate_failure") else 0)
state_path.write_text(json.dumps(state))
'''


class WrapperTests(unittest.TestCase):
    def run_wrapper(self, **scenario):
        with tempfile.TemporaryDirectory(prefix="renovate-wrapper-") as directory:
            root = Path(directory)
            state = {
                "now": 1_800_000_000,
                "duration": 1_200,
                "tokens": {},
                "processed": [],
                "arguments": [],
                **scenario,
            }
            (root / "state.json").write_text(json.dumps(state))
            script = subprocess.check_output(
                ["yq", "-r", '.data."run-renovate-core.sh"', str(CONFIG_MAP)],
                text=True,
            )
            wrapper = root / "wrapper.sh"
            wrapper.write_text(script)
            key = subprocess.check_output(
                ["openssl", "genrsa", "2048"], stderr=subprocess.DEVNULL, text=True
            )
            for name in ["curl", "date", "renovate"]:
                executable = root / name
                executable.write_text(FAKE_COMMAND)
                executable.chmod(0o755)
            result = subprocess.run(
                ["bash", str(wrapper), "--dry-run=full"],
                env={
                    **os.environ,
                    "PATH": f"{root}{os.pathsep}{os.environ['PATH']}",
                    "WRAPPER_TEST_DIR": str(root),
                    "RENOVATE_APP_ID": "1",
                    "RENOVATE_APP_PRIVATE_KEY": key,
                },
                capture_output=True,
                text=True,
                timeout=15,
            )
            state = json.loads((root / "state.json").read_text())
            for token in state["tokens"]:
                self.assertNotIn(token, result.stdout + result.stderr)
            self.assertNotIn(key, result.stdout + result.stderr)
            return result, state

    def test_later_installations_run_after_first_exceeds_jwt_lifetime(self):
        result, state = self.run_wrapper()
        self.assertEqual(state["processed"], [1, 2, 3], result.stdout + result.stderr)
        self.assertEqual(state["arguments"], [["--dry-run=full"]] * 3)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_token_failure_marks_job_failed_but_continues_other_installations(self):
        result, state = self.run_wrapper(duration=0, token_failure=2)
        self.assertEqual(state["processed"], [1, 3], result.stdout + result.stderr)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_renovate_failure_marks_job_failed_but_continues_other_installations(self):
        result, state = self.run_wrapper(duration=0, renovate_failure=2)
        self.assertEqual(state["processed"], [1, 2, 3], result.stdout + result.stderr)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_discovery_failure_does_not_run_renovate(self):
        result, state = self.run_wrapper(discovery_failure=True)
        self.assertEqual(state["processed"], [])
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
