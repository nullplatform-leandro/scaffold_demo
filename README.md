# scaffold_demo

A dummy scaffolding orchestrator for `application-lifecycle-manager`, in two
languages that do the same thing. It exists to exercise the
`TRIGGER_SCAFFOLD_SCRIPT` extension point end to end, and to be read as a
starting point for a real one.

```
scaffold.sh                 the bash version, GitHub through `gh`
scaffold.py                 the Python version, GitHub through urllib (stdlib only)
templates/dotnet/           the files that get pushed, with __PLACEHOLDERS__
```

## What it does

Both scripts perform the same three steps against the repository that
`application-lifecycle-manager` has just created:

| Step | What | On failure |
|---|---|---|
| 1 | Sets the `nullplatform-application` and `nullplatform-namespace` repository custom properties | Warns, carries on |
| 2 | Creates a `development` deployment environment | Warns, carries on |
| 3 | Renders `templates/dotnet/` into the repository, commits and pushes | **Fails the workflow** |

The split is the point. Steps 1 and 2 leave a repository that still builds, so
they are not worth failing an application creation for. Step 3 does not: an empty
repository would fail in CI instead, far from the cause.

Steps 1 and 2 will often warn in a test environment, and that is expected:

- **Custom properties** are defined at the *organization* level before they can be
  set on a repository. On a personal account they do not exist at all (404), and
  on an organization that has not defined them the call is refused (403).
- **Environments** on a *private* repository need GitHub Pro, Team or Enterprise.
  `application-lifecycle-manager` creates repositories private, so a Free plan
  answers 403.

## Wiring it to the agent

The path is read on the agent host, so the files have to be there — cloned onto
the host, baked into the agent image, or mounted. Nothing fetches them.

```yaml
# Bash. The file needs no execute bit: a non-executable script runs under bash.
extra_envs:
  TRIGGER_SCAFFOLD_SCRIPT: /opt/scaffold_demo/scaffold.sh

# Python, interpreter named outright. Also needs no execute bit, which is what
# makes this the convenient form for a file mounted from a ConfigMap.
extra_envs:
  TRIGGER_SCAFFOLD_SCRIPT: /opt/scaffold_demo/scaffold.py
  TRIGGER_SCAFFOLD_INTERPRETER: python3

# Python, through its own shebang. Requires chmod +x.
extra_envs:
  TRIGGER_SCAFFOLD_SCRIPT: /opt/scaffold_demo/scaffold.py

# Under mise, for a toolchain the agent image does not carry.
extra_envs:
  TRIGGER_SCAFFOLD_SCRIPT: /opt/scaffold_demo/scaffold.sh
  TRIGGER_SCAFFOLD_INTERPRETER: mise exec --
```

The path must be absolute. A relative one is refused with a message saying so,
because it would otherwise resolve against `application-lifecycle-manager`'s own
directory.

## What the environment provides

Everything below is exported by the scaffolding step; none of it is looked up
here:

| Variable | Used for |
|---|---|
| `REPOSITORY_NAME` | The repository, and the .NET assembly name derived from it |
| `GITHUB_ACCOUNT`, `GH_TOKEN` | The GitHub calls and the push. Already authenticated |
| `APPLICATION_SLUG`, `NAMESPACE_SLUG`, `NRN` | Substituted into the rendered files |
| `APPLICATION` | The full application document — where a real orchestrator reads its metadata |
| `SCAFFOLD_WORKDIR` | The working directory, empty on entry and removed afterwards |

The clone happens in the working directory the step hands over, so the token that
lands in `.git/config` goes away with it.

## Branching by technology

This demo always scaffolds .NET. A real orchestrator reads `$APPLICATION` and
dispatches:

```bash
FLAVOUR=$(jq -r '.metadata.<your_metadata_key>.architecture // empty' <<<"$APPLICATION")

case "$FLAVOUR" in
  .NET)   exec "$(dirname "$0")/dotnet.sh" ;;
  Node)   exec "$(dirname "$0")/node.sh"   ;;
  *)      echo "No scaffolding defined for '$FLAVOUR', leaving the repository as it is" ;;
esac
```

Which field that is, and what its values mean, is entirely this side's business —
`application-lifecycle-manager` reads nothing out of the application document on
your behalf.

`$(dirname "$0")` is how sibling scripts resolve. The working directory belongs to
the step, not to this repository, so a relative `./dotnet.sh` would not be found.

## Budget

The scaffolding runs while the application is held in `pending_hook`, and that is
a `before` hook: it fails closed, so nothing can create an application anywhere
under the NRN until this returns. `TRIGGER_SCAFFOLD_TIMEOUT` caps it at fifteen
minutes by default. Restoring packages or publishing an SDK belongs in the first
build, not here.
