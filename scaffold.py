#!/usr/bin/env python3
"""Dummy scaffolding orchestrator -- the Python half of the demo.

Reached from application-lifecycle-manager's scaffold_repository step, either by
naming the interpreter:

    TRIGGER_SCAFFOLD_SCRIPT=/opt/scaffold_demo/scaffold.py
    TRIGGER_SCAFFOLD_INTERPRETER=python3

or, if the file is executable, through the shebang above:

    TRIGGER_SCAFFOLD_SCRIPT=/opt/scaffold_demo/scaffold.py    # chmod +x

It does what scaffold.sh does, and is here to prove the step does not care which
language answers. The GitHub calls go through urllib rather than `gh` on purpose:
nothing outside the standard library is installed, so this runs on an agent image
that carries a bare python3 and nothing else.

Three things, in the order a real one would do them:

    1. a repository custom property         -- optional, warns and carries on
    2. a deployment environment             -- optional, warns and carries on
    3. the .NET files, committed and pushed -- the actual scaffolding, fatal

Steps 1 and 2 are deliberately non-fatal. A failure there leaves a repository
that still builds; a failure in step 3 does not, and that difference is what
decides whether the application gets created at all.
"""

# Annotations as strings, so `dict | None` is not evaluated at import time. The
# Python on an agent host is not ours to choose, and that syntax needs 3.10 --
# without this the script dies on the first `def`, before printing anything.
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATES = HERE / "templates" / "dotnet"

API = "https://api.github.com"


def required(name: str) -> str:
    """Read a variable the step is meant to export, or say which one is missing.

    Left to itself an absent variable becomes an empty string and fails three
    calls later, against a URL with a hole in it.
    """
    value = os.environ.get(name)
    if not value:
        sys.exit(f"ERROR: ${name} is not set -- is this running outside scaffold_repository?")
    return value


def github(method: str, path: str, body: dict | None = None) -> tuple[bool, str]:
    """One GitHub call. Returns (ok, detail) instead of raising: the caller
    decides whether a failure is fatal, and two of the three here are not."""
    request = urllib.request.Request(
        f"{API}{path}",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Authorization": f"Bearer {GH_TOKEN}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return True, str(response.status)
    except urllib.error.HTTPError as error:
        return False, f"HTTP {error.code}: {error.read().decode(errors='replace')[:200]}"
    except urllib.error.URLError as error:
        return False, str(error.reason)


def run(*command: str, cwd: Path | None = None) -> None:
    """git, and nothing else. Fatal by design -- every call site is step 3."""
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(
            f"ERROR: {' '.join(command[:2])} failed with status {result.returncode}\n"
            f"{result.stderr.strip()}"
        )


def pascal_case(name: str) -> str:
    """my-payments-api -> MyPaymentsApi, for the namespace and the assembly.

    The kind of substitution a template cannot do for itself: it depends on a
    name that only exists once the application is being created.
    """
    return "".join(part[:1].upper() + part[1:] for part in re.split(r"[-_]+", name) if part)


GH_TOKEN = required("GH_TOKEN")
GITHUB_ACCOUNT = required("GITHUB_ACCOUNT")
REPOSITORY_NAME = required("REPOSITORY_NAME")

REPO = f"{GITHUB_ACCOUNT}/{REPOSITORY_NAME}"
APP_NAME = pascal_case(REPOSITORY_NAME)

SUBSTITUTIONS = {
    "__APP_NAME__": APP_NAME,
    "__REPOSITORY_NAME__": REPOSITORY_NAME,
    "__APPLICATION_SLUG__": os.environ.get("APPLICATION_SLUG", "unknown"),
    "__NAMESPACE_SLUG__": os.environ.get("NAMESPACE_SLUG", "unknown"),
    "__NRN__": os.environ.get("NRN", "unknown"),
}

print(f"==> scaffolding {REPO} as {APP_NAME}")
print(f"    application : {os.environ.get('APPLICATION_SLUG', '<none>')} "
      f"({os.environ.get('APPLICATION_ID', '?')})")
print(f"    namespace   : {os.environ.get('NAMESPACE_SLUG', '<none>')}")
print(f"    provider    : {os.environ.get('CODE_REPOSITORY_PROVIDER', '<none>')} / "
      f"{os.environ.get('CODE_REPOSITORY_STRATEGY', '<none>')}")
print(f"    workdir     : {Path.cwd()}")


# 1. A repository custom property ---------------------------------------------
#
# Custom properties are defined at the ORGANIZATION level and only then set on a
# repository, so this answers 404 on a personal account and 403 when the property
# was never defined. Neither breaks the repository, so neither is fatal.

print("==> [1/3] setting the 'nullplatform-application' custom property")

ok, detail = github("PATCH", f"/repos/{REPO}/properties/values", {
    "properties": [
        {"property_name": "nullplatform-application", "value": SUBSTITUTIONS["__APPLICATION_SLUG__"]},
        {"property_name": "nullplatform-namespace", "value": SUBSTITUTIONS["__NAMESPACE_SLUG__"]},
    ],
})

if ok:
    print("    set")
else:
    print(f"    WARNING: could not set the custom properties ({detail})")
    print("             They have to be defined on the organization first "
          "(Settings > Custom properties),")
    print("             and they do not exist at all on a personal account. Carrying on.")


# 2. A deployment environment --------------------------------------------------
#
# Environments on a PRIVATE repository need GitHub Pro, Team or Enterprise, and
# application-lifecycle-manager creates repositories private. On a Free plan this
# is a 403: worth reporting, not worth failing for.

print("==> [2/3] creating the 'development' environment")

ok, detail = github("PUT", f"/repos/{REPO}/environments/development")

if ok:
    print("    created")
else:
    print(f"    WARNING: could not create the environment ({detail})")
    print("             Environments on a private repository need GitHub Pro, Team or Enterprise.")
    print("             Carrying on.")


# 3. The .NET files -------------------------------------------------------------
#
# This one is fatal. A repository whose first build runs against an empty tree is
# worse than an application that was not created: the error would surface in CI,
# far from the cause.

print("==> [3/3] pushing the .NET skeleton")

# The token in the URL is how a GitHub App installation token authenticates git.
# It reaches .git/config, which is why this happens in the working directory the
# step handed over -- it deletes the whole thing when this returns.
checkout = Path.cwd() / "repo"
run("git", "clone", "--quiet", "--depth", "1",
    f"https://x-access-token:{GH_TOKEN}@github.com/{REPO}.git", str(checkout))

# Substituting in the file NAMES as well as the contents: the template ships
# src/__APP_NAME__/__APP_NAME__.csproj, and .NET expects those to match the
# assembly.
for source_file in sorted(path for path in TEMPLATES.rglob("*") if path.is_file()):
    relative = str(source_file.relative_to(TEMPLATES)).replace("__APP_NAME__", APP_NAME)
    destination = checkout / relative
    destination.parent.mkdir(parents=True, exist_ok=True)

    content = source_file.read_text()
    for placeholder, value in SUBSTITUTIONS.items():
        content = content.replace(placeholder, value)

    destination.write_text(content)
    print(f"    + {relative}")

# -c rather than `git config`: the agent host has no git identity, and this
# commit should not be the reason it acquires a global one.
run("git", "-c", "user.name=nullplatform scaffolding",
    "-c", "user.email=noreply@nullplatform.com",
    "commit", "--quiet", "--all",
    "--message", "chore: scaffold the .NET skeleton\n\n"
                 f"Generated for the nullplatform application "
                 f"{SUBSTITUTIONS['__APPLICATION_SLUG__']}.",
    cwd=checkout)

run("git", "push", "--quiet", "origin", "HEAD", cwd=checkout)

print(f"    pushed to {REPO}")
print("==> scaffolding done")
