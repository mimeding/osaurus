#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

DERIVED_DATA_PATH="${OSAURUS_DERIVED_DATA_PATH:-$ROOT/build/CodexDerivedData}"
APP_DESTINATION="${OSAURUS_APP_DESTINATION:-platform=macOS,arch=$(uname -m)}"

section() {
  printf '\n==> %s\n' "$1"
}

run_xcodebuild() {
  if command -v xcbeautify >/dev/null 2>&1; then
    set -o pipefail
    xcodebuild "$@" | xcbeautify --renderer terminal
  else
    xcodebuild "$@"
  fi
}

section "swiftlint"
swiftlint lint --strict --config .swiftlint.yml

section "shellcheck"
shell_scripts=()
if [[ "${OSAURUS_SHELLCHECK_SCOPE:-touched}" == "all" ]]; then
  while IFS= read -r -d '' script; do
    shell_scripts+=("$script")
  done < <(
    find . -type f -name '*.sh' \
      -not -path './.git/*' \
      -not -path './build/*' \
      -not -path './Packages/*/.build/*' \
      -print0
  )
else
  BASE_REF="${OSAURUS_BASE_REF:-origin/main}"
  if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 git fetch origin --prune
  fi
  while IFS= read -r path; do
    if [[ -f "$path" && "$path" == *.sh ]]; then
      shell_scripts+=("$path")
    fi
  done < <(
    {
      git diff --name-only --diff-filter=ACMRT "$BASE_REF"...HEAD --
      git diff --name-only --diff-filter=ACMRT --
      git diff --cached --name-only --diff-filter=ACMRT --
      git ls-files --others --exclude-standard
    } | sort -u
  )
fi

if ((${#shell_scripts[@]} > 0)); then
  shellcheck "${shell_scripts[@]}"
else
  echo "No shell scripts found."
fi

section "swift build OsaurusCore"
swift build --package-path Packages/OsaurusCore

section "swift test OsaurusCore"
swift test --package-path Packages/OsaurusCore

section "swift build app"
run_xcodebuild build \
  -workspace osaurus.xcworkspace \
  -scheme osaurus \
  -configuration Debug \
  -destination "$APP_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  COMPILER_INDEX_STORE_ENABLE=NO

section "test-cli equivalent"
swift build --package-path Packages/OsaurusCLI
swift test --package-path Packages/OsaurusCLI

section "local CI parity complete"
