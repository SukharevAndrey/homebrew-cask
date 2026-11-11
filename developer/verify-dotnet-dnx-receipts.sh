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

record_state() {
  python3 - "$1" "$report_dir" "$PACKAGE_ARCH" <<'PYTHON'
from pathlib import Path
import json, plistlib, subprocess, sys
label, report, arch = sys.argv[1:]
p = Path(report) / 'cleanup.json'
records = json.loads(p.read_text()) if p.exists() else []
receipt = subprocess.run(['pkgutil', '--pkg-info-plist', f'com.microsoft.dotnet.sharedhost.component.osx.{arch}'], capture_output=True)
info = plistlib.loads(receipt.stdout) if receipt.returncode == 0 else {}
row = {'stage': label, 'dnx_exists': Path('/usr/local/share/dotnet/dnx').exists(), 'dotnet_exists': Path('/usr/local/share/dotnet/dotnet').exists(), 'sharedhost_receipt_version': info.get('pkg-version')}
records.append(row)
p.write_text(json.dumps(records, indent=2) + '\n')
print(json.dumps(row), flush=True)
PYTHON
}

brew install --cask dotnet-sdk
assert_commands
record_state 'original-main11-installed'
brew install --cask dotnet-sdk@10
record_state 'original-sdk10-installed'
remove_versioned_sdk
record_state 'original-sdk10-removed'
brew uninstall --cask dotnet-sdk
assert_uninstalled
record_state 'original-all-casks-removed'
checkpoint 'Recorded direct dnx file after full removal, in addition to command links'

# A diagnostic alternative: omit only the obsolete sharedhost component.
# This fixed runtime version is specific to the downloaded SDK10.0.404 test artifact.
python3 - "$candidate_dir/dotnet-sdk@10.rb" "$cask_tap/Casks/d/dotnet-sdk@10.rb" <<'PYTHON'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
s = s.replace('  pkg "dotnet-sdk-#{version.csv.first}-osx-#{arch}.pkg"', '  pkg "dotnet-sdk-#{version.csv.first}-osx-#{arch}.pkg",\n      choices: [\n        { "choiceIdentifier" => "com.microsoft.dotnet.sharedhost.10.0.15.component.osx.#{arch}.pkg",\n          "choiceAttribute" => "selected", "attributeSetting" => 0 },\n      ]')
Path(sys.argv[2]).write_text(s)
PYTHON
brew install --cask dotnet-sdk
assert_commands
record_state 'choices-main11-installed'
brew install --cask dotnet-sdk@10
record_state 'choices-sdk10-installed'
remove_versioned_sdk
record_state 'choices-sdk10-removed'
brew uninstall --cask dotnet-sdk
assert_uninstalled
record_state 'choices-all-casks-removed'
[[ ! -e "$dotnet_root/dnx" ]]
checkpoint 'Excluding the older sharedhost preserves its receipt owner and complete cleanup'
