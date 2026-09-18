# scaffold_demo

A dummy scaffolding orchestrator for `application-lifecycle-manager`, in two
languages that do the same thing. It exists to exercise the
`TRIGGER_SCAFFOLD_SCRIPT` extension point end to end, and to be read as a
starting point for a real one.

```
scaffold.sh                 the bash version, GitHub through `gh`
scaffold.py                 the Python version, GitHub through urllib (stdlib only)
templates/dotnet/           the .NET files, with __PLACEHOLDERS__
templates/node/             the Node files, same placeholders
tests/                      the routing, the rendering and the containers
```

## What it does

Both scripts perform the same three steps against the repository that
`application-lifecycle-manager` has just created:

| Step | What | On failure |
|---|---|---|
| 1 | Sets the `nullplatform-application` and `nullplatform-namespace` repository custom properties | Warns, carries on |
| 2 | Creates a `Development` deployment environment | Warns, carries on |
| 3 | Renders the template the repository name routes to, commits and pushes | **Fails the workflow** |

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

`scripts/code-repo/scaffold_repository` in `application-lifecycle-manager` is an
extension point that ships doing nothing:

```bash
echo "scaffold_repository: no scaffolding configured"
return 0
```

**Wiring this in means replacing that body.** There is no environment variable
that points at a script. `TRIGGER_SCAFFOLD_SCRIPT` is read by no branch and no tag
of `application-lifecycle-manager`, and neither are `TRIGGER_SCAFFOLD_INTERPRETER`,
`TRIGGER_SCAFFOLD_TIMEOUT` or `SCAFFOLD_WORKDIR`. Setting it on the agent is
silent: the step prints its "no scaffolding configured" line and the workflow
carries on.

The file is **sourced** into the workflow's shared shell, so `exit 0` inside it
ends that shell and silently skips every step after it. Run the orchestrator as a
subprocess, and hand it the empty working directory it expects:

```bash
SCAFFOLD_WORKDIR=$(mktemp -d)
export SCAFFOLD_WORKDIR

if ! ( cd "$SCAFFOLD_WORKDIR" && /root/.np/nullplatform-leandro/scaffold_demo/scaffold.sh ); then
  rm -rf "$SCAFFOLD_WORKDIR"
  exit 1          # stops the workflow -- never `exit 0`
fi

rm -rf "$SCAFFOLD_WORKDIR"
return 0
```

Swap `scaffold.sh` for `scaffold.py` to run the Python half; it takes the same
environment and needs no interpreter named for it, given the shebang and the
execute bit.

The files are read on the agent host, so they have to be there — nothing fetches
them. `agent_repo` is what puts this repository at `/root/.np/<owner>/<repo>/`:

```hcl
agent_repo = [
  "https://github.com/nullplatform-leandro/scaffold_demo#main",
]
```

A failed clone there does not bring the agent down, so a missing path shows up
only as this step failing to find the script.

## What the environment provides

Everything below is exported by the scaffolding step; none of it is looked up
here:

| Variable | Used for |
|---|---|
| `REPOSITORY_NAME` | The repository, the technology it routes to, and the assembly or package name derived from it |
| `GITHUB_ACCOUNT`, `GH_TOKEN` | The GitHub calls and the push. Already authenticated |
| `APPLICATION_SLUG`, `NAMESPACE_SLUG`, `NRN` | Substituted into the rendered files |
| `APPLICATION` | The full application document — where a real orchestrator reads its metadata |
| `SCAFFOLD_WORKDIR` | The working directory, empty on entry and removed afterwards |

`SCAFFOLD_WORKDIR` is the one the step does **not** export — the snippet above
makes it. Everything else comes from `scripts/base_context` and the GitHub
`build_context`, both of which have already run by the time this is reached.

The clone happens in that working directory, so the token that lands in
`.git/config` goes away with it.

## Routing by technology

The repository name decides what gets scaffolded:

| Repository | Technology | Template |
|---|---|---|
| `net-8-vt7-fire-issuance-test-2` | .NET | `templates/dotnet/` |
| `node-frontend-fire-issuance-test-3` | Node | `templates/node/` |
| anything else | — | nothing is written |

Those are not invented examples. The agent builds repository names from
application metadata through `REPOSITORY_NAME_RULE`, whose patterns start with
`{.application.metadata.application.architecture}` — `.NET` or `Node`. The prefix
this routes on is that field, lowercased and stripped of its dot.

The prefix is dropped before the name is used again: it routed the repository
here and has no business in the name of the thing being built. So
`node-frontend-fire-issuance-test-3` becomes the package `frontend-fire-issuance-test-3`.

The .NET side has one exception, and it is not cosmetic. That naming pattern is
`{architecture}-{dotnet_version}-...`, so the prefix is followed by a **digit** —
dropping it would leave `8Vt7FireIssuanceTest2`, which C# refuses as an
identifier and which fails at `dotnet publish`, inside the first build. When the
remainder starts with a digit the prefix stays, and the assembly is
`Net8Vt7FireIssuanceTest2`. Underscores count as the same separator as hyphens
and case is ignored, so `NET_Payments_API` lands in the same place. The prefix ends
in a separator on purpose — `netflix-clone` is not a .NET repository.

A name that matches nothing is a warning, not a failure, and this is the one place
step 3 is allowed not to be fatal. The repository was created from the "Any
technology" template and still carries the `Dockerfile` and the CI that came with
it, so it builds and deploys untouched. There is no broken tree to protect the
workflow from.

## What the templates are built on

Both templates descend from the nullplatform **"Any technology"** template
(`nullplatform/technology-templates-any`, ID `1855672260`), which is the template
the repository is created from. Every repository therefore starts with:

- a `Dockerfile` running an `http-echo` image
- `.github/workflows/ci.yml` — `np build start`, `docker build .`,
  `np asset push --type docker-image`, `np build update`
- a `.gitignore` and a README

The CI is left alone. It builds whatever `Dockerfile` sits at the root and pushes
the result as the docker-image asset, which is true of .NET and of Node without a
line changed. The `Dockerfile` is not left alone: each template ships its own, and
rendering overwrites the echo server. Miss that and every application deploys the
template's placeholder for ever, with a green build to say so.

Both flavours listen on `:8080` — the port the echo server exposed, and the one the
scope health-checks. ASP.NET would otherwise pick 5000 and Node 3000, and either
would build clean and fail at deploy.

## Tests

```
tests/run.sh
```

| | |
|---|---|
| `test_flavour.sh` | the routing table, against **both** implementations at once, so bash and Python cannot drift apart |
| `test_names.sh` | the assembly and package names, including the digit that a real .NET repository name puts after its prefix |
| `test_render.sh` | what lands in the checkout: the two renderers byte for byte, no surviving placeholder, the `Dockerfile` at the root |
| `test_containers.sh` | builds each image the way the CI would and asks the container what it is, under the names the naming rule really produces. Skipped, not failed, without docker |

None of it touches GitHub or nullplatform. Sourcing `scaffold.sh` stops at a guard
before its main body, and `scaffold.py` is imported rather than run.

Not covered: the branch that skips a repository whose name matches nothing.
Reaching it means getting past the two GitHub calls that come first, and a stub
convincing enough for both `gh` and `urllib` would end up testing the stub.

## Reading the technology from the application instead

A prefix needs nothing configured on the nullplatform side, which is why it is what
this demo does. A real orchestrator is just as likely to read `$APPLICATION` and
dispatch on metadata:

```bash
FLAVOUR=$(jq -r '.metadata.<your_metadata_key>.architecture // empty' <<<"$APPLICATION")
```

Which field that is, and what its values mean, is entirely this side's business —
`application-lifecycle-manager` reads nothing out of the application document on
your behalf. Swapping it in means replacing the body of `flavour_for` and nothing
else; everything downstream already works off what that function returns.

## Budget

The scaffolding runs while the application is held in `pending_hook`, and that is
a `before` hook: it fails closed, so nothing can create an application anywhere
under the NRN until this returns. `TRIGGER_SCAFFOLD_TIMEOUT` caps it at fifteen
minutes by default. Restoring packages or publishing an SDK belongs in the first
build, not here.
