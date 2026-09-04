from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


def run_git(*args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=True,
        text=True,
        capture_output=True,
    )


def find_bash() -> Path | None:
    discovered = shutil.which("bash")
    if discovered:
        return Path(discovered)
    windows_git_bash = Path("C:/Program Files/Git/bin/bash.exe")
    return windows_git_bash if windows_git_bash.is_file() else None


def bash_path(path: Path) -> str:
    resolved = path.resolve()
    if os.name != "nt":
        return resolved.as_posix()
    drive = resolved.drive.rstrip(":").lower()
    remainder = resolved.as_posix().split(":", maxsplit=1)[1]
    return f"/{drive}{remainder}"


@unittest.skipUnless(shutil.which("git"), "git is required")
class GitSafetyIntegrationTests(unittest.TestCase):
    def test_emergency_cleanup_reverts_and_pushes_the_baseline(self) -> None:
        bash = find_bash()
        if bash is None:
            self.skipTest("bash is required")

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            remote = root / "remote.git"
            work = root / "work"
            values = work / "helm" / "microservices-app" / "values.yaml"

            run_git("init", "--bare", str(remote))
            run_git("init", "--initial-branch=main", str(work))
            values.parent.mkdir(parents=True)
            shutil.copy2(
                REPOSITORY_ROOT / "helm" / "microservices-app" / "values.yaml",
                values,
            )
            run_git("config", "user.name", "Experiment Test", cwd=work)
            run_git("config", "user.email", "experiment@example.invalid", cwd=work)
            run_git("add", "helm/microservices-app/values.yaml", cwd=work)
            run_git("commit", "-m", "baseline", cwd=work)
            run_git("remote", "add", "origin", str(remote), cwd=work)
            run_git("push", "-u", "origin", "main", cwd=work)
            baseline = values.read_text(encoding="utf-8")

            environment = os.environ.copy()
            environment.update(
                {
                    "COMMON_SH": bash_path(REPOSITORY_ROOT / "experiments/lib/common.sh"),
                    "GIT_SH": bash_path(REPOSITORY_ROOT / "experiments/lib/git.sh"),
                    "TEST_REPO": bash_path(work),
                    "TEST_VALUES": bash_path(values),
                    "TEST_LOG": bash_path(root / "experiment.log"),
                }
            )
            script = r"""
set -euo pipefail
source "$COMMON_SH"
source "$GIT_SH"
REPO_ROOT="$TEST_REPO"
VALUES_FILE="$TEST_VALUES"
VALUES_RELATIVE=""
GIT_REMOTE=origin
GIT_BRANCH=main
SERVICE=gateway-service
TOOL=argocd
CURRENT_LOG="$TEST_LOG"
prepare_git_mutation
values_set env.EXPERIMENT_CONFIG emergency-test
commit_and_push_values "experiment: emergency cleanup test"
test -n "$ACTIVE_CHANGE_COMMIT"
emergency_git_cleanup
test -z "$ACTIVE_CHANGE_COMMIT"
"""
            subprocess.run(
                [str(bash), "-c", script],
                check=True,
                text=True,
                capture_output=True,
                env=environment,
                timeout=30,
            )

            self.assertEqual(values.read_text(encoding="utf-8"), baseline)
            remote_values = run_git(
                f"--git-dir={remote}",
                "show",
                "main:helm/microservices-app/values.yaml",
            ).stdout
            self.assertEqual(remote_values, baseline)
            subjects = run_git("log", "--format=%s", cwd=work).stdout.splitlines()
            self.assertEqual(len(subjects), 3)
            self.assertTrue(subjects[0].startswith("Revert"))


if __name__ == "__main__":
    unittest.main()
