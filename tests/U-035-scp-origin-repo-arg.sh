#!/usr/bin/env bash
# KAIZERO_WALLCLOCK_BUDGET=30s
set -uo pipefail
SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCENARIO_DIR/test-setup.sh"

# U-035-scp-origin-repo-arg — origin_parts() derives a --repo-shaped ORIGIN_REPO_ARG for a
# scp-syntax origin (BUG-058i), separate from the display-only ORIGIN_REDUCED, and decide_origin
# bakes ORIGIN_URL from that derived value instead of the display value.
# Needs real claude: no
# Tools beyond the shared prerequisites: none
# Folder under $TESTROOT: $TESTROOT/U-035-scp-origin-repo-arg

TU="$TESTROOT/U-035-scp-origin-repo-arg"; mkdir -p "$TU"

# script_funcs: sources kaizero.sh up to (not including) its trailing `main "$@"` call, so
# origin_parts/decide_origin become callable directly without running the whole program.
script_funcs(){
  local ln tmp
  ln=$(grep -nF 'main "$@"' "$REAL_SCRIPT" | tail -1 | cut -d: -f1)
  tmp="$(mktemp)"; head -n "$((ln - 1))" "$REAL_SCRIPT" > "$tmp"
  # shellcheck disable=SC1090
  . "$tmp"; rm -f "$tmp"
}

# U35a — scp-syntax GitHub origin reduces ORIGIN_REPO_ARG to OWNER/REPO, .git stripped, while
# ORIGIN_REDUCED keeps the display host:path form unchanged.
( script_funcs
  origin_parts "git@github.com:IvanRublev/kimai.git"
  check "U35a ORIGIN_REPO_ARG is OWNER/REPO" "$ORIGIN_REPO_ARG" "IvanRublev/kimai"
  check "U35a ORIGIN_REDUCED keeps host:path display form" "$ORIGIN_REDUCED" "github.com:IvanRublev/kimai.git"
  check "U35a ORIGIN_HOST" "$ORIGIN_HOST" "github.com"
)

# U35b — a non-github.com scp-syntax host reduces to HOST/OWNER/REPO
( script_funcs
  origin_parts "git@git.example.com:acme/api.git"
  check "U35b ORIGIN_REPO_ARG is HOST/OWNER/REPO" "$ORIGIN_REPO_ARG" "git.example.com/acme/api"
)

# U35c — https-scheme origin: ORIGIN_REPO_ARG unchanged, same as ORIGIN_REDUCED (no regression)
( script_funcs
  origin_parts "https://github.com/IvanRublev/kimai.git"
  check "U35c https ORIGIN_REPO_ARG equals ORIGIN_REDUCED" "$ORIGIN_REPO_ARG" "$ORIGIN_REDUCED"
  check "U35c https ORIGIN_REPO_ARG value" "$ORIGIN_REPO_ARG" "https://github.com/IvanRublev/kimai.git"
)

# U35d — decide_origin bakes ORIGIN_URL from the derived value for a scp-syntax GitHub origin,
# not the display value.
mkdir -p "$TU/repo"; ( cd "$TU/repo"; git init -q -b main; git config user.email t@t.t; git config user.name test
  echo x > f; git add f; git commit -qm init; git remote add origin git@github.com:IvanRublev/kimai.git )
( script_funcs; cd "$TU/repo"
  decide_origin "$TU/repo" >/dev/null 2>&1
  check "U35d decide_origin ORIGIN_URL is OWNER/REPO" "$ORIGIN_URL" "IvanRublev/kimai"
)

. "$SCENARIO_DIR/test-teardown-reap.sh" "$TESTROOT"
if [ "$KAIZERO_TEST_MODE" = implementor ] && { [ "$FAILED" = 1 ] || [ "$ERRORED" = 1 ]; }; then
  echo "TESTROOT retained for implementor mode: $TESTROOT"
else
  . "$SCENARIO_DIR/test-teardown-delete.sh" "$TESTROOT"
fi
[ "$FAILED" = 0 ] && [ "$ERRORED" = 0 ] && exit 0; [ "$ERRORED" = 1 ] && exit 2; exit 1   # 0 pass, 1 FAIL, 2 ERROR — test-runner.sh decodes this
