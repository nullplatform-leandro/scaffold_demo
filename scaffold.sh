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
#   1. a repository custom property                -- optional, warns and carries on
#   2. a deployment environment                    -- optional, warns and carries on
#   3. the ECR repository the build pushes to      -- fatal
#   4. the application files, committed and pushed -- the actual scaffolding, fatal
#
# Which application files depends on the repository name: net-* gets a .NET
# skeleton, node-* a Node one. Anything else is left as the "Any technology"
# template made it.
#
# Steps 1 and 2 are deliberately non-fatal. A failure there leaves a repository
# that still builds; a failure in step 3 does not, and the difference is what
# decides whether the application gets created at all.

set -euo pipefail

# $BASH_SOURCE and not $0: sourced, $0 is the caller, and the templates would be
# looked for next to whatever sourced this.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATES="$HERE/templates"

# Which technology a repository gets, keyed off its name. A real orchestrator is
# just as likely to read $APPLICATION metadata for this -- see the README -- but a
# prefix needs nothing configured on the nullplatform side to work.
flavour_for() {
  local normalised lower

  # Underscores already separate words everywhere else in here (the assembly name
  # folds them into hyphens), so `net_payments` routes exactly like `net-payments`.
  normalised=$(printf '%s' "$1" | tr '_' '-')
  lower=$(printf '%s' "$normalised" | tr '[:upper:]' '[:lower:]')

  # `?*` and not `*`: the prefix has to be followed by something, or there is no
  # name left to build an application out of. And the pattern ends in a hyphen on
  # purpose -- `netflix-clone` is not a .NET repository.
  case "$lower" in
    net-?*)  printf '%s\t%s\t%s' '.NET' 'dotnet' "${normalised:4}" ;;
    node-?*) printf '%s\t%s\t%s' 'Node' 'node'   "${normalised:5}" ;;
    *)       return 1 ;;
  esac
}


# Renders every file under $1 into $2, substituting the __PLACEHOLDERS__ in the
# file NAMES as well as the contents: the .NET template ships
# src/__APP_NAME__/__APP_NAME__.csproj, and .NET expects those to match the
# assembly.
#
# The rendered files overwrite whatever the "Any technology" template left in the
# checkout -- the Dockerfile above all, which otherwise keeps serving http-echo no
# matter what else lands beside it.
#
# The values come from the variables the caller has already set, which is what
# lets tests/ render into a scratch directory instead of a clone.
render_template() {
  local template="$1" destination_root="$2"
  local source_file relative destination

  while IFS= read -r -d '' source_file; do
    relative="${source_file#"$template"/}"
    relative="${relative//__APP_NAME__/$APP_NAME}"
    destination="$destination_root/$relative"

    mkdir -p "$(dirname "$destination")"

    sed \
      -e "s|__APP_NAME__|$APP_NAME|g" \
      -e "s|__PACKAGE_NAME__|$PACKAGE_NAME|g" \
      -e "s|__REPOSITORY_NAME__|$REPOSITORY_NAME|g" \
      -e "s|__APPLICATION_SLUG__|${APPLICATION_SLUG:-unknown}|g" \
      -e "s|__NAMESPACE_SLUG__|${NAMESPACE_SLUG:-unknown}|g" \
      -e "s|__NRN__|${NRN:-unknown}|g" \
      "$source_file" > "$destination"

    echo "    + $relative"
  done < <(find "$template" -type f -print0 | sort -z)
}


# my-payments-api -> MyPaymentsApi, for the namespace and the assembly. The kind
# of substitution a template cannot do for itself: it depends on a name that only
# exists once the application is being created.
#
# $1 is the repository name, $2 the part left after the routing prefix. Normally
# the prefix is dropped -- it routed the repository here and has no business in
# the name of the thing being built. The exception is a remainder that starts with
# a DIGIT, which C# refuses as an identifier: the agent's REPOSITORY_NAME_RULE
# builds .NET names as {architecture}-{dotnet_version}-..., so `net-8-billing`
# would leave `8Billing`. There the prefix stays, and the assembly is Net8Billing.
app_name_for() {
  local repository_name="$1" base_name="$2" candidate

  candidate=$(pascal_case "$base_name")

  case "$candidate" in
    [0-9]*) pascal_case "$repository_name" ;;
    *)      printf '%s' "$candidate" ;;
  esac
}

pascal_case() {
  printf '%s' "$1" \
    | tr '_' '-' \
    | awk -F- '{for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i, 1, 1)), substr($i, 2)}'
}

# npm rejects a package name with a capital in it, so Node gets the flat spelling.
# A leading digit is fine here -- npm allows it where C# does not.
package_name_for() {
  printf '%s' "$1" | tr '_' '-' | tr '[:upper:]' '[:lower:]'
}


# The repository the build will push its image to.
#
# Built exactly the way the ECR asset provider builds it --
# <path>/<namespace><separator><application>, the separator a slash when
# ECR_USE_NAMESPACE is `true` and a hyphen otherwise -- because it has to match
# what the platform pushes to character for character. The same two variables
# name it, so when that provider becomes usable this function and its caller are
# deleted and nothing else moves.
asset_repository_name() {
  local namespace="${1:-$NAMESPACE_SLUG}" application="${2:-$APPLICATION_SLUG}"
  local path="${3-${ECR_REPOSITORY_PATH:-}}" use_namespace="${4-${ECR_USE_NAMESPACE:-}}"
  local separator="-" prefix=""

  [[ "$use_namespace" == "true" ]] && separator="/"
  [[ -n "$path" ]] && prefix="$path/"

  printf '%s%s%s%s' "$prefix" "$namespace" "$separator" "$application"
}

# ECR does not create a repository on push the way Docker Hub does, and the
# docker-server asset provider only records the URI, so without this the first
# build of every application pushes at something nobody made and fails with
# "name unknown". Describing first rather than creating and ignoring the error
# keeps a repository that already exists untouched -- its lifecycle policy and its
# tags are not this script's to reset.
ensure_asset_repository() {
  local repository

  # Assets do not live in ECR on every installation, and this has nothing to do
  # for the ones where they do not.
  if [[ -z "${AWS_REGION:-}" ]]; then
    echo "    AWS_REGION is not set, leaving the asset repository alone"
    return 0
  fi

  repository=$(asset_repository_name)

  if aws ecr describe-repositories --repository-names "$repository" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "    $repository already exists"
    return 0
  fi

  echo "    creating $repository"
  aws ecr create-repository --repository-name "$repository" --region "$AWS_REGION" >/dev/null
}


# --- the main body starts here --------------------------------------------------
#
# Sourced rather than executed: hand back the definitions above and stop. That is
# what lets tests/ exercise the routing without a GitHub token, a repository to
# push to, or any of the variables the step exports.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

# The step exports all of these. Naming them up front turns a missing one into a
# message instead of an empty expansion three commands later.
: "${REPOSITORY_NAME:?not set -- is this running outside scaffold_repository?}"
: "${GITHUB_ACCOUNT:?not set -- the GitHub build_context exports it}"
: "${GH_TOKEN:?not set -- the GitHub build_context exports it}"

REPO="$GITHUB_ACCOUNT/$REPOSITORY_NAME"

# An unrecognised name is deliberately not fatal here -- step 3 explains why. The
# empty FLAVOUR is what it checks.
if routed=$(flavour_for "$REPOSITORY_NAME"); then
  IFS=$'\t' read -r FLAVOUR TEMPLATE_DIR BASE_NAME <<<"$routed"
else
  FLAVOUR=""
  TEMPLATE_DIR=""
  BASE_NAME="$REPOSITORY_NAME"
fi

APP_NAME=$(app_name_for "$REPOSITORY_NAME" "$BASE_NAME")
PACKAGE_NAME=$(package_name_for "$BASE_NAME")

echo "==> scaffolding $REPO as $APP_NAME"
echo "    technology  : ${FLAVOUR:-<no prefix matched>}"
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

echo "==> [1/4] setting the 'nullplatform-application' custom property"

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

echo "==> [2/4] creating the 'Development' environment"

if gh api --method PUT "/repos/$REPO/environments/Development" >/dev/null 2>&1; then
  echo "    created"
else
  echo "    WARNING: could not create the environment."
  echo "             Environments on a private repository need GitHub Pro, Team or Enterprise."
  echo "             Carrying on."
fi


# 3. The ECR repository -----------------------------------------------------------
#
# Before the files, because pushing them is what starts the first build, and that
# build pushes an image at this repository. Fatal: ECR answers "name unknown" and
# the failure surfaces in CI, far from the cause.

echo "==> [3/4] making sure the asset repository exists"

ensure_asset_repository


# 4. The application files ---------------------------------------------------------
#
# This one is fatal. A repository whose first build runs against an empty tree is
# worse than an application that was not created: the error would surface in CI,
# far from the cause.
#
# A name that routed nowhere is the exception, and it is not an empty tree: the
# repository was created from the "Any technology" template and still carries the
# Dockerfile and the CI that came with it, so it builds and deploys untouched.

if [[ -z "$FLAVOUR" ]]; then
  echo "==> [4/4] no technology matched '$REPOSITORY_NAME'"
  echo "    Names route by prefix: net-* gets .NET, node-* gets Node."
  echo "    Leaving the repository as the 'Any technology' template made it."
  echo "==> scaffolding done"
  exit 0
fi

TEMPLATE="$TEMPLATES/$TEMPLATE_DIR"

echo "==> [4/4] pushing the $FLAVOUR skeleton"

# GitHub copies a template's content asynchronously: create_repository returns as
# soon as the repository exists, and for a few seconds after that it has no
# commits at all. Cloning into that window gives an empty checkout, and the
# scaffolding would then race the template copy over the first commit.
for attempt in $(seq 1 10); do
  if [[ "$(gh api "/repos/$REPO/commits?per_page=1" --jq 'length' 2>/dev/null)" == "1" ]]; then
    break
  fi

  echo "    waiting for the template content to land ($attempt/10)"
  sleep 3
done

# The token in the URL is how a GitHub App installation token authenticates git.
# It reaches .git/config, which is why this happens inside $SCAFFOLD_WORKDIR --
# the step deletes the whole directory when it returns.
git clone --quiet --depth 1 "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" repo

render_template "$TEMPLATE" repo

# `commit --all` stages modifications to TRACKED files and nothing else, so on its
# own it finds nothing to do here: every rendered file is new. `add --all` is what
# actually stages them.
git -C repo add --all

# -c rather than `git config`: the agent host has no git identity, and this
# commit should not be the reason it acquires a global one.
git -C repo \
  -c user.name="nullplatform scaffolding" \
  -c user.email="noreply@nullplatform.com" \
  commit --quiet --message "chore: scaffold the $FLAVOUR skeleton

Generated for the nullplatform application ${APPLICATION_SLUG:-unknown}."

git -C repo push --quiet origin HEAD

echo "    pushed to $REPO"
echo "==> scaffolding done"
