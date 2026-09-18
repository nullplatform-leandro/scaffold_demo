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

    1. a repository custom property                -- optional, warns and carries on
    2. a deployment environment                    -- optional, warns and carries on
    3. the application files, committed and pushed -- the actual scaffolding, fatal

Which application files depends on the repository name: net-* gets a .NET
skeleton, node-* a Node one. Anything else is left as the "Any technology"
template made it.

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
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATES = HERE / "templates"

# Which technology a repository gets, keyed off its name. A real orchestrator is
# just as likely to read $APPLICATION metadata for this -- see the README -- but a
# prefix needs nothing configured on the nullplatform side to work.
#
# The prefixes end in a hyphen on purpose: `netflix-clone` is not a .NET repository.
FLAVOURS = (
    ("net-", ".NET", "dotnet"),
    ("node-", "Node", "node"),
)

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


def github(token: str, method: str, path: str, body: dict | None = None) -> tuple[bool, str]:
    """One GitHub call. Returns (ok, detail) instead of raising: the caller
    decides whether a failure is fatal, and two of the three here are not."""
    request = urllib.request.Request(
        f"{API}{path}",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return True, response.read().decode(errors="replace")
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


def app_name_for(repository_name: str, base_name: str) -> str:
    """The namespace and the assembly, from the name left after the routing prefix.

    The prefix is normally dropped -- it routed the repository here and has no
    business in the name of the thing being built. The exception is a remainder
    that starts with a DIGIT, which C# refuses as an identifier: the agent's
    REPOSITORY_NAME_RULE builds .NET names as
    {architecture}-{dotnet_version}-..., so `net-8-billing` would leave
    `8Billing`. There the prefix stays, and the assembly is Net8Billing.
    """
    candidate = pascal_case(base_name)

    if candidate[:1].isdigit():
        return pascal_case(repository_name)

    return candidate


def package_name_for(base_name: str) -> str:
    """npm rejects a package name with a capital in it, so Node gets the flat
    spelling. A leading digit is fine here -- npm allows it where C# does not."""
    return base_name.replace("_", "-").lower()


def flavour_for(name: str) -> tuple[str, str, str] | None:
    """Route a repository name to (flavour, template directory, name without the
    prefix), or None for a name that matches nothing.

    None is not an error: the repository was created from the "Any technology"
    template and already builds, so a name this does not recognise is left alone
    rather than failing the application.
    """
    # Underscores already separate words everywhere else in here (pascal_case
    # folds them), so `net_payments` routes exactly like `net-payments`.
    normalised = name.replace("_", "-")
    lowered = normalised.lower()

    for prefix, flavour, template in FLAVOURS:
        # Longer than the prefix, not just starting with it: `net-` on its own
        # leaves no name to build an application out of.
        if lowered.startswith(prefix) and len(normalised) > len(prefix):
            return flavour, template, normalised[len(prefix):]

    return None


def render_template(
    template: Path,
    destination_root: Path,
    substitutions: dict[str, str],
) -> list[str]:
    """Render every file under `template` into `destination_root`, substituting the
    __PLACEHOLDERS__ in the file NAMES as well as the contents: the .NET template
    ships src/__APP_NAME__/__APP_NAME__.csproj, and .NET expects those to match the
    assembly.

    The rendered files overwrite whatever the "Any technology" template left in the
    checkout -- the Dockerfile above all, which otherwise keeps serving http-echo no
    matter what else lands beside it.

    Returns the paths written, relative to the destination, so the caller can log
    them. Taking the destination as an argument is what lets tests render into a
    scratch directory instead of a clone.
    """
    written = []

    for source_file in sorted(path for path in template.rglob("*") if path.is_file()):
        relative = str(source_file.relative_to(template)).replace(
            "__APP_NAME__", substitutions["__APP_NAME__"]
        )
        destination = destination_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)

        content = source_file.read_text()
        for placeholder, value in substitutions.items():
            content = content.replace(placeholder, value)

        destination.write_text(content)
        written.append(relative)

    return written


def main() -> None:
    """Everything the step actually asks for. Behind a function rather than at
    import time so tests can reach the helpers above without a token, a
    repository, or any of the variables the step exports."""
    GH_TOKEN = required("GH_TOKEN")
    GITHUB_ACCOUNT = required("GITHUB_ACCOUNT")
    REPOSITORY_NAME = required("REPOSITORY_NAME")

    REPO = f"{GITHUB_ACCOUNT}/{REPOSITORY_NAME}"

    # An unrecognised name is deliberately not fatal here -- step 3 explains why.
    routed = flavour_for(REPOSITORY_NAME)
    flavour, template_dir, base_name = routed or ("", "", REPOSITORY_NAME)

    APP_NAME = app_name_for(REPOSITORY_NAME, base_name)
    PACKAGE_NAME = package_name_for(base_name)

    SUBSTITUTIONS = {
        "__APP_NAME__": APP_NAME,
        "__PACKAGE_NAME__": PACKAGE_NAME,
        "__REPOSITORY_NAME__": REPOSITORY_NAME,
        "__APPLICATION_SLUG__": os.environ.get("APPLICATION_SLUG", "unknown"),
        "__NAMESPACE_SLUG__": os.environ.get("NAMESPACE_SLUG", "unknown"),
        "__NRN__": os.environ.get("NRN", "unknown"),
    }

    print(f"==> scaffolding {REPO} as {APP_NAME}")
    print(f"    technology  : {flavour or '<no prefix matched>'}")
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

    ok, detail = github(GH_TOKEN, "PATCH", f"/repos/{REPO}/properties/values", {
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

    print("==> [2/3] creating the 'Development' environment")

    ok, detail = github(GH_TOKEN, "PUT", f"/repos/{REPO}/environments/Development")

    if ok:
        print("    created")
    else:
        print(f"    WARNING: could not create the environment ({detail})")
        print("             Environments on a private repository need GitHub Pro, Team or Enterprise.")
        print("             Carrying on.")


    # 3. The application files --------------------------------------------------------
    #
    # This one is fatal. A repository whose first build runs against an empty tree is
    # worse than an application that was not created: the error would surface in CI,
    # far from the cause.
    #
    # A name that routed nowhere is the exception, and it is not an empty tree: the
    # repository was created from the "Any technology" template and still carries the
    # Dockerfile and the CI that came with it, so it builds and deploys untouched.

    if not flavour:
        print(f"==> [3/3] no technology matched '{REPOSITORY_NAME}'")
        print("    Names route by prefix: net-* gets .NET, node-* gets Node.")
        print("    Leaving the repository as the 'Any technology' template made it.")
        print("==> scaffolding done")
        return

    template = TEMPLATES / template_dir

    print(f"==> [3/3] pushing the {flavour} skeleton")

    # GitHub copies a template's content asynchronously: create_repository returns as
    # soon as the repository exists, and for a few seconds after that it has no
    # commits at all. Cloning into that window gives an empty checkout, and the
    # scaffolding would then race the template copy over the first commit.
    for attempt in range(1, 11):
        ok, payload = github(GH_TOKEN, "GET", f"/repos/{REPO}/commits?per_page=1")

        if ok and json.loads(payload):
            break

        print(f"    waiting for the template content to land ({attempt}/10)")
        time.sleep(3)

    # The token in the URL is how a GitHub App installation token authenticates git.
    # It reaches .git/config, which is why this happens in the working directory the
    # step handed over -- it deletes the whole thing when this returns.
    checkout = Path.cwd() / "repo"
    run("git", "clone", "--quiet", "--depth", "1",
        f"https://x-access-token:{GH_TOKEN}@github.com/{REPO}.git", str(checkout))

    for relative in render_template(template, checkout, SUBSTITUTIONS):
        print(f"    + {relative}")

    # `commit --all` stages modifications to TRACKED files and nothing else, so on its
    # own it finds nothing to do here: every rendered file is new. `add --all` is what
    # actually stages them.
    run("git", "add", "--all", cwd=checkout)

    # -c rather than `git config`: the agent host has no git identity, and this
    # commit should not be the reason it acquires a global one.
    run("git", "-c", "user.name=nullplatform scaffolding",
        "-c", "user.email=noreply@nullplatform.com",
        "commit", "--quiet",
        "--message", f"chore: scaffold the {flavour} skeleton\n\n"
                     f"Generated for the nullplatform application "
                     f"{SUBSTITUTIONS['__APPLICATION_SLUG__']}.",
        cwd=checkout)

    run("git", "push", "--quiet", "origin", "HEAD", cwd=checkout)

    print(f"    pushed to {REPO}")
    print("==> scaffolding done")


if __name__ == "__main__":
    main()
