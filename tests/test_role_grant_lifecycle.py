"""Offline checks of the workflow's actual manifest-pruning shell step."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = (ROOT / ".github/workflows/decommission-repo.yml").read_text()


class RoleGrantLifecycleTests(unittest.TestCase):
    def test_actual_pruning_step_removes_owned_and_legacy_grants_only(self):
        step = WORKFLOW.split("      - name: Remove entries from repos.json + grant configs\n", 1)[1]
        step = step.split("\n      - name:", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        grants = [
            {"identityName": "arbitrary-runtime-name", "ownerRepo": "offline"},
            {"identityName": "sp-offline-github"},
            {"identityName": "sp-offline-preview-github"},
            {"identityName": "id-offline", "identityResourceGroup": "rg-offline"},
            {"identityName": "id-offline-preview", "identityResourceGroup": "rg-offline-preview"},
            {"identityName": "case-varied-owner", "ownerRepo": "OFFLINE"},
            {"identityName": "sp-offline-runtime-extra", "ownerRepo": "offline-extra"},
            {"identityName": "another-runtime", "ownerRepo": "another-repo"},
            {"identityName": "unrelated-id", "identityResourceGroup": "rg-offline-extra"},
        ]
        with tempfile.TemporaryDirectory(prefix="role-grant-lifecycle-") as directory:
            temporary = Path(directory)
            # Prevent the actual shell step from writing Git configuration,
            # committing, or pushing; jq still operates on the real fixtures.
            executable = temporary / "bin"
            executable.mkdir()
            git = executable / "git"
            git.write_text("#!/bin/sh\nexit 0\n")
            git.chmod(0o755)
            (temporary / "repos.json").write_text(json.dumps({"repos": ["offline", {"name": "offline"}, "offline-extra"]}))
            for filename in ("role-grants.json", "graph-grants.json"):
                (temporary / filename).write_text(json.dumps({"grants": grants}))
            subprocess.run(
                ["bash", "-c", script], cwd=temporary,
                env={**os.environ, "NAME": "offline", "PATH": str(executable) + os.pathsep + os.environ["PATH"]},
                capture_output=True, text=True, check=True,
            )
            self.assertEqual(json.loads((temporary / "repos.json").read_text())["repos"], ["offline-extra"])
            for filename in ("role-grants.json", "graph-grants.json"):
                self.assertEqual(json.loads((temporary / filename).read_text())["grants"], grants[6:])

    def test_cleanup_precedes_pruning_and_identity_teardown(self):
        login = WORKFLOW.index("      - name: Azure Login (OIDC)")
        cleanup = WORKFLOW.index("      - name: Revoke owned runtime role grants")
        prune = WORKFLOW.index("      - name: Remove entries from repos.json + grant configs")
        teardown = WORKFLOW.index("      - name: Tear down Azure + GitHub resources")
        self.assertLess(login, cleanup)
        self.assertLess(cleanup, prune)
        self.assertLess(prune, teardown)
        script = (ROOT / "scripts/decommission-repo.ps1").read_text()
        self.assertLess(script.index("'remove-owned-role-grants.ps1'"), script.index("az ad app delete"))

    def test_onboarding_and_decommission_share_a_non_cancelling_lock(self):
        onboarding = (ROOT / ".github/workflows/onboard-repos.yml").read_text()
        pattern = r"concurrency:\n  group: ([^\n]+)\n  cancel-in-progress: false"
        cleanup_lock = re.search(pattern, WORKFLOW)
        apply_lock = re.search(pattern, onboarding)
        self.assertIsNotNone(cleanup_lock)
        self.assertIsNotNone(apply_lock)
        self.assertEqual(cleanup_lock.group(1), apply_lock.group(1))


if __name__ == "__main__":
    unittest.main(verbosity=2)
