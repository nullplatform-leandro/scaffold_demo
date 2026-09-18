#!/bin/bash
#
# What the two implementations actually write into the checkout.
#
#   tests/test_render.sh
#
# Renders both templates with both implementations into a scratch directory and
# compares. No GitHub, no clone, no push -- only the rendering step, which is the
# part that has to be right before a container is worth building.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")

source "$ROOT/scaffold.sh"
set +e

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fixed values so the two renderers are asked for exactly the same thing.
export REPOSITORY_NAME APPLICATION_SLUG=payments NAMESPACE_SLUG=billing
export NRN="organization=1:account=2"

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

check_contains() {
  local description="$1" file="$2" needle="$3"

  checked=$((checked + 1))

  if [[ -f "$file" ]] && grep -qF "$needle" "$file"; then
    printf '  ok   %s\n' "$description"
  else
    failures=$((failures + 1))
    printf '  FAIL %s\n         %s does not contain: %s\n' "$description" "$file" "$needle"
  fi
}

render_with_bash() {
  local template="$1" destination="$2"

  mkdir -p "$destination"
  render_template "$template" "$destination" >/dev/null
}

render_with_python() {
  python3 - "$ROOT/scaffold.py" "$1" "$2" "$APP_NAME" "$PACKAGE_NAME" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("scaffold", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

module.render_template(Path(sys.argv[2]), Path(sys.argv[3]), {
    "__APP_NAME__": sys.argv[4],
    "__PACKAGE_NAME__": sys.argv[5],
    "__REPOSITORY_NAME__": os.environ["REPOSITORY_NAME"],
    "__APPLICATION_SLUG__": os.environ["APPLICATION_SLUG"],
    "__NAMESPACE_SLUG__": os.environ["NAMESPACE_SLUG"],
    "__NRN__": os.environ["NRN"],
})
PY
}

for name in net-payments-api node-payments-api; do
  routed=$(flavour_for "$name")
  IFS=$'\t' read -r flavour template_dir base_name <<<"$routed"

  REPOSITORY_NAME="$name"
  APP_NAME=$(printf '%s' "$base_name" | tr '_' '-' \
    | awk -F- '{for (i = 1; i <= NF; i++) printf "%s%s", toupper(substr($i, 1, 1)), substr($i, 2)}')
  PACKAGE_NAME=$(printf '%s' "$base_name" | tr '_' '-' | tr '[:upper:]' '[:lower:]')

  echo "==> $name ($flavour)"

  render_with_bash "$TEMPLATES/$template_dir" "$WORK/$name-bash"
  render_with_python "$TEMPLATES/$template_dir" "$WORK/$name-python"

  # The whole point of the repository: the two have to agree, file for file and
  # byte for byte.
  diff -r "$WORK/$name-bash" "$WORK/$name-python" >/dev/null 2>&1
  check "bash and python render the same tree" "0" "$?"

  # Without this, every assertion below passes on an empty directory.
  rendered=$(find "$WORK/$name-bash" -type f | wc -l | tr -d ' ')
  check "renders something at all" "yes" \
    "$([[ "$rendered" -gt 0 ]] && echo yes || echo no)"

  # A placeholder that survives rendering reaches the repository verbatim and
  # breaks the build far from here.
  leftovers=$(grep -rlE '__[A-Z_]+__' "$WORK/$name-bash" 2>/dev/null | wc -l | tr -d ' ')
  check "no placeholder survives" "0" "$leftovers"

  # The Dockerfile has to land at the root, because that is the one the CI
  # inherited from the "Any technology" template builds.
  check "Dockerfile at the root" "yes" \
    "$([[ -f "$WORK/$name-bash/Dockerfile" ]] && echo yes || echo no)"
done

echo "==> .NET specifics"
check ".csproj renamed after the assembly" "yes" \
  "$([[ -f "$WORK/net-payments-api-bash/src/PaymentsApi/PaymentsApi.csproj" ]] && echo yes || echo no)"
check_contains "the greeting names .NET" \
  "$WORK/net-payments-api-bash/src/PaymentsApi/Program.cs" \
  'hello world. I am an app built in .NET'

echo "==> Node specifics"
check_contains "package name is npm-legal" \
  "$WORK/node-payments-api-bash/package.json" '"name": "payments-api"'
check_contains "the greeting names Node" \
  "$WORK/node-payments-api-bash/src/server.js" \
  'hello world. I am an app built in Node'

echo
if (( failures )); then
  echo "FAILED: $failures of $checked checks"
  exit 1
fi

echo "PASSED: $checked checks"
