#!/usr/bin/env python3
"""Check the original OpenBot branch; merge only after personal work is recorded."""
import argparse
import pathlib
import subprocess
import sys


def git(*arguments, capture=True):
    result = subprocess.run(
        ["git", *arguments], cwd=ROOT, text=True,
        stdout=subprocess.PIPE if capture else None, check=True,
    )
    return result.stdout.strip() if capture else ""


ROOT = pathlib.Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--merge", action="store_true", help="Merge upstream without making a commit or pushing.")
parser.add_argument("--no-fetch", action="store_true", help="Use the last fetched upstream reference.")
options = parser.parse_args()

branch = git("branch", "--show-current")
if not branch:
    sys.exit("Check out your personal branch first.")
dirty = bool(git("status", "--porcelain", "--untracked-files=normal"))
if options.merge and dirty:
    sys.exit("Personal changes exist. Review and commit them before merging upstream. No files were changed.")
if options.merge and branch in {"main", "master"}:
    sys.exit("Run the merge from your personal feature branch, so main can track the original app.")

remote = git("remote", "get-url", "upstream").rstrip("/").removesuffix(".git")
if remote not in {"https://github.com/nightly-labs/openbot", "git@github.com:nightly-labs/openbot"}:
    sys.exit("The upstream remote does not point to the original OpenBot repository.")
if not options.no_fetch:
    git("fetch", "--no-tags", "upstream", "main", capture=False)

behind, personal = git("rev-list", "--left-right", "--count", "upstream/main...HEAD").split()
print(f"Branch: {branch}")
print(f"Upstream: {git('rev-parse', '--short=12', 'upstream/main')}")
print(f"Incoming commits: {behind}; personal commits: {personal}; uncommitted work: {'yes' if dirty else 'no'}")
if options.merge and behind != "0":
    git("merge", "--no-commit", "--no-ff", "upstream/main", capture=False)
    print("Review the merge and run the affected checks before you commit it.")
elif behind == "0":
    print("This branch contains the last fetched upstream version.")
