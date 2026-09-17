#!/bin/bash
#
# Dummy scaffolding orchestrator -- the bash half of the demo.
#
# Reached from application-lifecycle-manager's scaffold_repository step:
#
#   TRIGGER_SCAFFOLD_SCRIPT=/opt/scaffold_demo/scaffold.sh
#
# It runs as a subprocess of that step, in an empty working directory of its own
# ($SCAFFOLD_WORKDIR) that the step removes afterwards, with the repository
# already created and $GH_TOKEN already authenticated.
#
# Three things, in the order a real one would do them:
#
#   1. a repository custom property        -- optional, warns and carries on
#   2. a deployment environment            -- optional, warns and carries on
#   3. the .NET files, committed and pushed -- the actual scaffolding, fatal
#
# Steps 1 and 2 are deliberately non-fatal. A failure there leaves a repository
# that still builds; a failure in step 3 does not, and the difference is what
# decides whether the application gets created at all.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TEMPLATES="$HERE/templates/dotnet"

# The step exports all of these. Naming them up front turns a missing one into a
# message instead of an empty expansion three commands later.
: "${REPOSITORY_NAME:?not set -- is this running outside scaffold_repository?}"
: "${GITHUB_ACCOUNT:?not set -- the GitHub build_context exports it}"
: "${GH_TOKEN:?not set -- the GitHub build_context exports it}"

REPO="$GITHUB_ACCOUNT/$REPOSITORY_NAME"

# my-payments-api -> MyPaymentsApi, for the namespace and the assembly. This is
# the kind of substitution a template cannot do for itself: it depends on a name
# that only exists once the application is being created.
APP_NAME=$(printf '%s' "$REPOSITORY_NAME" \
  | tr '_' '-' \
  | awk -F- '{for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i, 1, 1)), substr($i, 2)}')

echo "==> scaffolding $REPO as $APP_NAME"
echo "    application : ${APPLICATION_SLUG:-<none>} (${APPLICATION_ID:-?})"
echo "    namespace   : ${NAMESPACE_SLUG:-<none>}"
echo "    provider    : ${CODE_REPOSITORY_PROVIDER:-<none>} / ${CODE_REPOSITORY_STRATEGY:-<none>}"
echo "    workdir     : $(pwd)"

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh is not on PATH. application-lifecycle-manager installs it before this step runs."
  exit 1
fi


# 1. A repository custom property ------------------------------------------------
#
# Custom properties are defined at the ORGANIZATION level and only then set on a
# repository, so this answers 404 on a personal account and 403 when the property
# was never defined. Neither breaks the repository, so neither is fatal here.

echo "==> [1/3] setting the 'nullplatform-application' custom property"

if gh api --method PATCH "/repos/$REPO/properties/values" \
  --input - <<JSON >/dev/null 2>&1
{
  "properties": [
    { "property_name": "nullplatform-application", "value": "${APPLICATION_SLUG:-unknown}" },
    { "property_name": "nullplatform-namespace",   "value": "${NAMESPACE_SLUG:-unknown}" }
  ]
}
JSON
then
  echo "    set"
else
  echo "    WARNING: could not set the custom properties."
  echo "             They have to be defined on the organization first (Settings > Custom properties),"
  echo "             and they do not exist at all on a personal account. Carrying on."
fi


# 2. A deployment environment ----------------------------------------------------
#
# Environments on a PRIVATE repository need GitHub Pro, Team or Enterprise, and
# application-lifecycle-manager creates repositories private. On a Free plan this
# is a 403: worth reporting, not worth failing for.

echo "==> [2/3] creating the 'development' environment"

if gh api --method PUT "/repos/$REPO/environments/development" >/dev/null 2>&1; then
  echo "    created"
else
  echo "    WARNING: could not create the environment."
  echo "             Environments on a private repository need GitHub Pro, Team or Enterprise."
  echo "             Carrying on."
fi


# 3. The .NET files --------------------------------------------------------------
#
# This one is fatal. A repository whose first build runs against an empty tree is
# worse than an application that was not created: the error would surface in CI,
# far from the cause.

echo "==> [3/3] pushing the .NET skeleton"

# The token in the URL is how a GitHub App installation token authenticates git.
# It reaches .git/config, which is why this happens inside $SCAFFOLD_WORKDIR --
# the step deletes the whole directory when it returns.
git clone --quiet --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" repo

# Substituting in the file NAMES as well as the contents: the template ships
# src/__APP_NAME__/__APP_NAME__.csproj, and .NET expects those to match the
# assembly.
while IFS= read -r -d '' source_file; do
  relative="${source_file#"$TEMPLATES"/}"
  destination="repo/${relative//__APP_NAME__/$APP_NAME}"

  mkdir -p "$(dirname "$destination")"

  sed \
    -e "s|__APP_NAME__|$APP_NAME|g" \
    -e "s|__REPOSITORY_NAME__|$REPOSITORY_NAME|g" \
    -e "s|__APPLICATION_SLUG__|${APPLICATION_SLUG:-unknown}|g" \
    -e "s|__NAMESPACE_SLUG__|${NAMESPACE_SLUG:-unknown}|g" \
    -e "s|__NRN__|${NRN:-unknown}|g" \
    "$source_file" > "$destination"

  echo "    + ${relative//__APP_NAME__/$APP_NAME}"
done < <(find "$TEMPLATES" -type f -print0)

# -c rather than `git config`: the agent host has no git identity, and this
# commit should not be the reason it acquires a global one.
git -C repo \
  -c user.name="nullplatform scaffolding" \
  -c user.email="noreply@nullplatform.com" \
  commit --quiet --all --message "chore: scaffold the .NET skeleton

Generated for the nullplatform application ${APPLICATION_SLUG:-unknown}."

git -C repo push --quiet origin HEAD

echo "    pushed to $REPO"
echo "==> scaffolding done"
