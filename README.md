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
| 2 | Creates a `development` deployment environment | Warns, carries on |
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
| `REPOSITORY_NAME` | The repository, the technology it routes to, and the assembly or package name derived from it |
| `GITHUB_ACCOUNT`, `GH_TOKEN` | The GitHub calls and the push. Already authenticated |
| `APPLICATION_SLUG`, `NAMESPACE_SLUG`, `NRN` | Substituted into the rendered files |
| `APPLICATION` | The full application document — where a real orchestrator reads its metadata |
| `SCAFFOLD_WORKDIR` | The working directory, empty on entry and removed afterwards |

The clone happens in the working directory the step hands over, so the token that
lands in `.git/config` goes away with it.

## Routing by technology

The repository name decides what gets scaffolded:

| Repository | Technology | Template |
|---|---|---|
| `net-payments-api` | .NET | `templates/dotnet/` |
| `node-payments-api` | Node | `templates/node/` |
| anything else | — | nothing is written |

The prefix is dropped before the name is used again, so `net-payments-api` builds
an assembly called `PaymentsApi` and `node-payments-api` a package called
`payments-api`: the prefix routed the repository here and has no business in the
name of the thing being built. Underscores count as the same separator as hyphens
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
| `test_render.sh` | what lands in the checkout: the two renderers byte for byte, no surviving placeholder, the `Dockerfile` at the root |
| `test_containers.sh` | builds each image the way the CI would and asks the container what it is. Skipped, not failed, without docker |

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
