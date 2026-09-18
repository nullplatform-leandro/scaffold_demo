#!/bin/bash
#
# The ECR repository the build will push to.
#
#   tests/test_asset_repository.sh
#
# ECR does not create a repository on push the way Docker Hub does, and the
# docker-server asset provider only records the URI, so the first build of every
# application pushed at something nobody had made. The scaffolding makes it.
#
# The name has to match what the platform will push to, character for character,
# so it is built the same way the ECR asset provider builds it:
# <path>/<namespace><separator><application>.
#
# `aws` is stubbed here: this checks the name and the calls, not AWS.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")

source "$ROOT/scaffold.sh"
set +e

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
checked=0

check() {
  local description="$1" expected="$2" actual="$3"

  checked=$((checked + 1))

  if [[ "$actual" == "$expected" ]]; then
    printf '  ok   %s\n' "$description"
  else
    failures=$((failures + 1))
    printf '  FAIL %s\n         expected: %s\n         actual:   %s\n' \
      "$description" "$expected" "$actual"
  fi
}

echo "==> the repository name"

# The combination this installation runs: a path, and namespaces as a path
# segment. `nullplatform/test/test-7` is what the failing push asked for.
NAMESPACE_SLUG=test APPLICATION_SLUG=test-7 \
  ECR_REPOSITORY_PATH=nullplatform ECR_USE_NAMESPACE=true \
  check "path and namespace as a segment" "nullplatform/test/test-7" \
    "$(NAMESPACE_SLUG=test APPLICATION_SLUG=test-7 ECR_REPOSITORY_PATH=nullplatform ECR_USE_NAMESPACE=true asset_repository_name)"

check "without a path" "test/test-7" \
  "$(NAMESPACE_SLUG=test APPLICATION_SLUG=test-7 ECR_REPOSITORY_PATH= ECR_USE_NAMESPACE=true asset_repository_name)"

# Not `true` means a hyphen, which is the provider's default and a different
# repository -- getting this wrong pushes at something that does not exist.
check "namespace joined with a hyphen" "nullplatform/test-test-7" \
  "$(NAMESPACE_SLUG=test APPLICATION_SLUG=test-7 ECR_REPOSITORY_PATH=nullplatform ECR_USE_NAMESPACE=false asset_repository_name)"

check "neither" "test-test-7" \
  "$(NAMESPACE_SLUG=test APPLICATION_SLUG=test-7 ECR_REPOSITORY_PATH= ECR_USE_NAMESPACE= asset_repository_name)"

python_name() {
  python3 - "$ROOT/scaffold.py" "$@" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("scaffold", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

print(module.asset_repository_name(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]), end="")
PY
}

echo "==> and python agrees"
check "path and namespace as a segment" "nullplatform/test/test-7" "$(python_name test test-7 nullplatform true)"
check "without a path"                  "test/test-7"              "$(python_name test test-7 '' true)"
check "namespace joined with a hyphen"  "nullplatform/test-test-7" "$(python_name test test-7 nullplatform false)"
check "neither"                         "test-test-7"              "$(python_name test test-7 '' '')"

echo "==> the AWS calls"

cat > "$WORK/aws" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$AWS_CALLS"
if [[ "$2" == "describe-repositories" ]]; then
  [[ "${STUB_REPOSITORY_EXISTS:-false}" == "true" ]] && exit 0
  echo "RepositoryNotFoundException" >&2
  exit 254
fi
exit 0
STUB
chmod +x "$WORK/aws"
export PATH="$WORK:$PATH"

export NAMESPACE_SLUG=test APPLICATION_SLUG=test-7
export ECR_REPOSITORY_PATH=nullplatform ECR_USE_NAMESPACE=true AWS_REGION=us-east-1

# Missing: described, then created.
export AWS_CALLS="$WORK/calls-missing"; : > "$AWS_CALLS"
STUB_REPOSITORY_EXISTS=false ensure_asset_repository >/dev/null
check "describes before creating" "yes" \
  "$(grep -q 'describe-repositories --repository-names nullplatform/test/test-7' "$AWS_CALLS" && echo yes || echo no)"
check "creates the missing repository" "yes" \
  "$(grep -q 'create-repository --repository-name nullplatform/test/test-7' "$AWS_CALLS" && echo yes || echo no)"

# Present: described, and left alone. Re-running the scaffolding, or scaffolding a
# second application into a repository that already exists, must not be an error.
export AWS_CALLS="$WORK/calls-present"; : > "$AWS_CALLS"
STUB_REPOSITORY_EXISTS=true ensure_asset_repository >/dev/null
check "an existing repository is not re-created" "no" \
  "$(grep -q 'create-repository' "$AWS_CALLS" && echo yes || echo no)"

# No region configured: nothing is attempted. The scaffolding has to stay usable
# on an installation whose assets do not live in ECR at all.
export AWS_CALLS="$WORK/calls-noregion"; : > "$AWS_CALLS"
AWS_REGION= ensure_asset_repository >/dev/null
check "no region means no AWS calls at all" "0" "$(wc -l < "$AWS_CALLS" | tr -d ' ')"

echo
if (( failures )); then
  echo "FAILED: $failures of $checked checks"
  exit 1
fi

echo "PASSED: $checked checks"
