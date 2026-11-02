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


def pruning_script():
    step = WORKFLOW.split("      - name: Remove entries from repos.json + grant configs\n", 1)[1]
    step = step.split("\n      - name:", 1)[0]
    return textwrap.dedent(step.split("        run: |\n", 1)[1])


class RoleGrantLifecycleTests(unittest.TestCase):
    def test_actual_pruning_step_removes_owned_and_legacy_grants_only(self):
        script = pruning_script()
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

    def test_all_repository_writers_and_onboarding_share_lock_and_fresh_checkout(self):
        workflows = {p.name: p.read_text() for p in (ROOT / ".github/workflows").glob("*.yml")}
        writers = {name for name, source in workflows.items() if re.search(r"(?m)^\s+git push\s*$", source)}
        self.assertEqual(writers, {"add-repo.yml", "add-dns-record.yml", "remove-dns-record.yml", "decommission-repo.yml"})
        for name in sorted(writers | {"onboard-repos.yml"}):
            with self.subTest(workflow=name):
                source = workflows[name]
                self.assertTrue("concurrency:\n  group: estate-rbac-${{ github.repository }}\n  cancel-in-progress: false\n  queue: max\n" in source, f"{name} must use the shared non-cancelling queue")
                checkout = source.split("        uses: actions/checkout@v5\n", 1)[1].split("\n      - name:", 1)[0]
                self.assertTrue("          ref: ${{ github.ref }}" in checkout, f"{name} must refresh its selected branch after waiting")

    def test_queued_decommission_preserves_a_preceding_dns_push(self):
        # Only local repositories: capture an old dispatch SHA, let a preceding
        # DNS writer push, then exercise branch checkout and the actual pruning
        # shell against a real local Git remote. No CLI/provider mocks hide push
        # failures in this regression.
        environment = {
            **os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_AUTHOR_NAME": "Offline Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Offline Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
        }

        def git(*arguments, cwd=None):
            return subprocess.run(["git", *map(str, arguments)], cwd=cwd, env=environment,
                                  capture_output=True, text=True, check=True).stdout.strip()

        with tempfile.TemporaryDirectory(prefix="queued-decommission-") as directory:
            temporary = Path(directory)
            remote, seed, dns, cleanup = (temporary / name for name in ("remote.git", "seed", "dns-writer", "cleanup"))
            git("init", "--bare", "--initial-branch=main", remote)
            git("init", "--initial-branch=main", seed)
            (seed / "repos.json").write_text(json.dumps({"repos": ["offline", "keep"]}))
            (seed / "role-grants.json").write_text(json.dumps({"grants": [{"ownerRepo": "offline", "identityName": "runtime"}]}))
            (seed / "graph-grants.json").write_text(json.dumps({"grants": []}))
            (seed / "dns").mkdir()
            (seed / "dns/records.app.json").write_text(json.dumps({"records": []}))
            git("add", ".", cwd=seed)
            git("commit", "-m", "Synthetic initial state", cwd=seed)
            old_event_sha = git("rev-parse", "HEAD", cwd=seed)
            git("remote", "add", "origin", remote, cwd=seed)
            git("push", "--set-upstream", "origin", "main", cwd=seed)

            git("clone", "--branch", "main", remote, dns)
            records = {"records": [{"type": "TXT", "name": "offline", "values": ["synthetic"]}]}
            (dns / "dns/records.app.json").write_text(json.dumps(records))
            git("add", "dns/records.app.json", cwd=dns)
            git("commit", "-m", "Preceding DNS writer", cwd=dns)
            git("push", cwd=dns)

            git("clone", "--branch", "main", remote, cleanup)
            # Default actions/checkout binds to the captured event SHA; an
            # explicit github.ref instead fetches the current branch head.
            if "          ref: ${{ github.ref }}" not in WORKFLOW:
                git("checkout", "-B", "main", old_event_sha, cwd=cleanup)
            result = subprocess.run(["bash", "-c", pruning_script()], cwd=cleanup,
                                    env={**environment, "NAME": "offline"}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(git("show", "main:role-grants.json", cwd=remote))["grants"], [])
            self.assertEqual(json.loads(git("show", "main:repos.json", cwd=remote))["repos"], ["keep"])
            self.assertEqual(json.loads(git("show", "main:dns/records.app.json", cwd=remote)), records)


if __name__ == "__main__":
    unittest.main(verbosity=2)
