#!/bin/bash
#
# The names derived from a repository name.
#
#   tests/test_names.sh
#
# Separate from the routing because these have a constraint the routing does not:
# the .NET one becomes a namespace and an assembly, so it has to be a valid C#
# identifier. Real repository names come out of the agent's
# REPOSITORY_NAME_RULE, which builds them from application metadata --
# `{architecture}-{dotnet_version}-...` puts a DIGIT right after the prefix.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")

source "$ROOT/scaffold.sh"
set +e

# repository name | expected APP_NAME | expected PACKAGE_NAME
CASES=(
  "net-payments-api|PaymentsApi|payments-api"
  "node-payments-api|PaymentsApi|payments-api"

  # Names the naming rule actually produces. The .NET pattern is
  # {architecture}-{dotnet_version}-..., so the prefix is followed by the major
  # version: dropping `net-` would leave `8Vt7...`, which C# refuses.
  "net-8-vt7-fire-issuance-test-2|Net8Vt7FireIssuanceTest2|8-vt7-fire-issuance-test-2"
  "node-frontend-fire-issuance-test-3|FrontendFireIssuanceTest3|frontend-fire-issuance-test-3"

  # Same guard, whatever follows the digit.
  "net-8|Net8|8"
  "net-2024-billing|Net2024Billing|2024-billing"

  "NET-Payments-API|PaymentsAPI|payments-api"
  "net_payments_api|PaymentsApi|payments-api"
)

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

ask_python() {
  python3 - "$ROOT/scaffold.py" "$1" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("scaffold", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

name = sys.argv[2]
routed = module.flavour_for(name)
base = routed[2] if routed else name
print(f"{module.app_name_for(name, base)}\t{module.package_name_for(base)}", end="")
PY
}

echo "==> derived names"

for row in "${CASES[@]}"; do
  name="${row%%|*}"
  rest="${row#*|}"
  expected_app="${rest%%|*}"
  expected_package="${rest##*|}"

  routed=$(flavour_for "$name")
  if [[ -n "$routed" ]]; then
    IFS=$'\t' read -r _ _ base <<<"$routed"
  else
    base="$name"
  fi

  check "bash   $name -> app"     "$expected_app"     "$(app_name_for "$name" "$base")"
  check "bash   $name -> package" "$expected_package" "$(package_name_for "$base")"

  IFS=$'\t' read -r py_app py_package <<<"$(ask_python "$name")"
  check "python $name -> app"     "$expected_app"     "$py_app"
  check "python $name -> package" "$expected_package" "$py_package"
done

echo
if (( failures )); then
  echo "FAILED: $failures of $checked checks"
  exit 1
fi

echo "PASSED: $checked checks"
