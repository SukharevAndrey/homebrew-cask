#!/bin/bash
set -euo pipefail

# Package installation and removal are restricted to GitHub's disposable macOS machines.
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_OS:-}" != macOS ||
      "${RUNNER_ENVIRONMENT:-}" != github-hosted ||
      "${GITHUB_REPOSITORY:-}" != SukharevAndrey/homebrew-cask ]]; then
  printf '%s\n' 'This test only runs on GitHub-hosted macOS machines in the test fork.' >&2
  exit 1
fi

[[ "$(uname -m)" == "${EXPECTED_ARCH:?}" ]]
sudo -n true

report_dir="${RUNNER_TEMP:?}/dotnet-lifecycle-results"
candidate_dir="${RUNNER_TEMP}/dotnet-cask-candidates"
mkdir -p "$report_dir" "$candidate_dir"
exec > >(tee "$report_dir/lifecycle.log") 2>&1

brew_prefix="$(brew --prefix)"
cask_tap="$(brew --repository homebrew/cask)"
dotnet_root=/usr/local/share/dotnet
dotnet_command="${dotnet_root}/dotnet"
export PATH="${brew_prefix}/bin:$PATH"
export DOTNET_ROOT="$dotnet_root"
unset DOTNET_ROOT_X64 DOTNET_ROOT_ARM64 DOTNET_HOST_PATH MSBuildSDKsPath
export HOMEBREW_NO_INSTALL_FROM_API=1

cp Casks/d/dotnet-sdk.rb "$candidate_dir/dotnet-sdk.rb"
cp Casks/d/dotnet-sdk@10.rb "$candidate_dir/dotnet-sdk@10.rb"
cp "$candidate_dir/dotnet-sdk.rb" "$cask_tap/Casks/d/dotnet-sdk.rb"
cp "$candidate_dir/dotnet-sdk@10.rb" "$cask_tap/Casks/d/dotnet-sdk@10.rb"

checkpoint() {
  printf '\nPASS: %s\n' "$1"
  printf -- '- PASS: %s\n' "$1" >> "${GITHUB_STEP_SUMMARY:?}"
}

assert_sdk() {
  "$dotnet_command" --list-sdks | tee "$report_dir/sdks-latest.txt" |
    awk -v expected="$1" '$1 == expected { found = 1 } END { exit !found }'
}

assert_no_sdk() {
  if "$dotnet_command" --list-sdks | awk -v expected="$1" \
    '$1 == expected { found = 1 } END { exit !found }'; then
    printf 'Unexpected SDK still installed: %s\n' "$1" >&2
    exit 1
  fi
}

assert_commands() {
  [[ -x "$dotnet_command" && -x "$dotnet_root/dnx" ]]
  [[ "$(readlink "$brew_prefix/bin/dotnet")" == "$dotnet_command" ]]
  [[ "$(readlink "$brew_prefix/bin/dnx")" == "$dotnet_root/dnx" ]]
  "$brew_prefix/bin/dnx" --help > "$report_dir/dnx-help.txt"
}

smoke_app() {
  local major="$1"
  local sdk_version="$2"
  local project_dir="$RUNNER_TEMP/dotnet-smoke-${major}"
  mkdir -p "$project_dir"
  cat > "$project_dir/global.json" <<EOF
{"sdk":{"version":"${sdk_version}","rollForward":"disable"}}
EOF
  cat > "$project_dir/Smoke.csproj" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net${major}.0</TargetFramework>
  </PropertyGroup>
</Project>
EOF
  printf 'System.Console.WriteLine("smoke-net%s.0");\n' "$major" > "$project_dir/Program.cs"
  (
    cd "$project_dir"
    [[ "$("$dotnet_command" --version)" == "$sdk_version" ]]
    "$dotnet_command" run --project Smoke.csproj --verbosity quiet | tee "$report_dir/smoke-net${major}.txt"
  )
  grep -Fxq "smoke-net${major}.0" "$report_dir/smoke-net${major}.txt"
}

remove_versioned_sdk() {
  shasum -a 256 "$dotnet_root/dnx" > "$report_dir/dnx-before-uninstall.sha256"
  brew uninstall --cask dotnet-sdk@10
  assert_no_sdk 10.0.404
  assert_sdk 11.0.100
  shasum -a 256 --check "$report_dir/dnx-before-uninstall.sha256"
  assert_commands
  smoke_app 11 11.0.100
}

assert_uninstalled() {
  [[ ! -e "$dotnet_command" ]]
  [[ ! -L "$brew_prefix/bin/dotnet" && ! -L "$brew_prefix/bin/dnx" ]]
}

sw_vers
uname -m
brew config
printf 'Initial casks:\n'
brew list --cask

# Remove preinstalled SDK casks before taking control of the shared installation root.
installed_casks="$(brew list --cask)"
for cask in $installed_casks; do
  case "$cask" in
    dotnet-sdk@*|dotnet-runtime@*) brew uninstall --cask "$cask" ;;
  esac
done
for cask in $installed_casks; do
  case "$cask" in
    dotnet-sdk|dotnet-runtime) brew uninstall --cask "$cask" ;;
  esac
done
if brew list --formula | grep -Fxq dotnet; then
  brew unlink dotnet
fi
if [[ -d "$dotnet_root" ]]; then
  sudo mv "$dotnet_root" "$RUNNER_TEMP/preinstalled-dotnet"
fi
for command_name in dotnet dnx; do
  if [[ -e "$brew_prefix/bin/$command_name" || -L "$brew_prefix/bin/$command_name" ]]; then
    sudo mv "$brew_prefix/bin/$command_name" "$RUNNER_TEMP/preinstalled-${command_name}-command"
  fi
done
pkgutil --pkgs | grep -E '^com\.microsoft\.(dotnet|netstandard)\.' > "$report_dir/preinstalled-receipts.txt" || true
while IFS= read -r receipt; do
  [[ -z "$receipt" ]] || sudo pkgutil --forget "$receipt"
done < "$report_dir/preinstalled-receipts.txt"
checkpoint 'Disposable runner prepared without preinstalled SDKs'

brew style --cask dotnet-sdk dotnet-sdk@10
brew audit --cask --online dotnet-sdk
brew audit --cask --new dotnet-sdk@10
checkpoint 'Style and online audits passed'

brew install --cask dotnet-sdk
assert_sdk 11.0.100
assert_commands
smoke_app 11 11.0.100
checkpoint 'Fresh .NET 11 installation runs an application and dnx'

brew install --cask dotnet-sdk@10
assert_sdk 10.0.404
assert_sdk 11.0.100
smoke_app 10 10.0.404
smoke_app 11 11.0.100
checkpoint '.NET 10 and 11 work side by side'

remove_versioned_sdk
checkpoint 'Removing .NET 10 preserves .NET 11 and dnx'

brew install --cask dotnet-sdk@10
smoke_app 10 10.0.404
remove_versioned_sdk
brew uninstall --cask dotnet-sdk
assert_uninstalled
checkpoint 'Reinstallation and complete uninstallation passed'

git show "${BASELINE_CASK_COMMIT:?}:Casks/d/dotnet-sdk.rb" > "$cask_tap/Casks/d/dotnet-sdk.rb"
brew install --cask dotnet-sdk
assert_sdk 10.0.404
smoke_app 10 10.0.404
checkpoint 'Previous stable .NET 10 baseline installed'

cp "$candidate_dir/dotnet-sdk.rb" "$cask_tap/Casks/d/dotnet-sdk.rb"
brew upgrade --cask dotnet-sdk
assert_sdk 11.0.100
assert_no_sdk 10.0.404
assert_commands
smoke_app 11 11.0.100
checkpoint 'Upgrade of the stable cask from .NET 10 to 11 passed'

brew install --cask dotnet-sdk@10
smoke_app 10 10.0.404
smoke_app 11 11.0.100
remove_versioned_sdk
brew uninstall --cask dotnet-sdk
assert_uninstalled
checkpoint 'Versioned SDK and cleanup also passed after the upgrade'
