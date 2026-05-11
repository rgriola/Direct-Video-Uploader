#!/usr/bin/env bash
# May 10, 2026 - 10:15am - GitHub Copilot (GPT-5.3-Codex)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_yml="$repo_root/ios/project.yml"
info_plist="$repo_root/ios/DirectVideoUploader/Info.plist"
launch_bg_asset="$repo_root/ios/DirectVideoUploader/Assets.xcassets/LaunchBg.colorset"
launch_image_asset="$repo_root/ios/DirectVideoUploader/Assets.xcassets/launchscreen.imageset"

errors=0

check_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq "$needle" "$file"; then
    echo "[FAIL] Missing $label in $file"
    errors=$((errors + 1))
  fi
}

check_exists() {
  local path="$1"
  local label="$2"
  if [[ ! -d "$path" ]]; then
    echo "[FAIL] Missing $label directory: $path"
    errors=$((errors + 1))
  fi
}

echo "Verifying launch screen hardening for Fixer iOS..."

# project.yml is the source of truth for XcodeGen output.
check_contains "$project_yml" "INFOPLIST_KEY_UILaunchScreen_Generation: YES" "build setting INFOPLIST_KEY_UILaunchScreen_Generation"
check_contains "$project_yml" "INFOPLIST_KEY_UILaunchScreen_BackgroundColor: LaunchBg" "build setting launch background color"
check_contains "$project_yml" "INFOPLIST_KEY_UILaunchScreen_ImageName: launchscreen" "build setting launch image name"
check_contains "$project_yml" "UILaunchScreen:" "info.properties UILaunchScreen dict"
check_contains "$project_yml" "UIColorName: LaunchBg" "info.properties UILaunchScreen.UIColorName"
check_contains "$project_yml" "UIImageName: launchscreen" "info.properties UILaunchScreen.UIImageName"

# Generated plist must include the launch screen dictionary.
if ! /usr/bin/plutil -extract UILaunchScreen.UIColorName raw "$info_plist" >/dev/null 2>&1; then
  echo "[FAIL] Missing UILaunchScreen.UIColorName in $info_plist"
  errors=$((errors + 1))
else
  color_name="$(/usr/bin/plutil -extract UILaunchScreen.UIColorName raw "$info_plist")"
  if [[ "$color_name" != "LaunchBg" ]]; then
    echo "[FAIL] UILaunchScreen.UIColorName expected LaunchBg, got: $color_name"
    errors=$((errors + 1))
  fi
fi

if ! /usr/bin/plutil -extract UILaunchScreen.UIImageName raw "$info_plist" >/dev/null 2>&1; then
  echo "[FAIL] Missing UILaunchScreen.UIImageName in $info_plist"
  errors=$((errors + 1))
else
  image_name="$(/usr/bin/plutil -extract UILaunchScreen.UIImageName raw "$info_plist")"
  if [[ "$image_name" != "launchscreen" ]]; then
    echo "[FAIL] UILaunchScreen.UIImageName expected launchscreen, got: $image_name"
    errors=$((errors + 1))
  fi
fi

# Required asset catalogs.
check_exists "$launch_bg_asset" "LaunchBg.colorset"
check_exists "$launch_image_asset" "launchscreen.imageset"

if [[ "$errors" -gt 0 ]]; then
  echo "\nLaunch screen verification failed with $errors issue(s)."
  echo "Tip: Run 'cd ios && xcodegen generate' after fixing project.yml, then re-run this script."
  exit 1
fi

echo "Launch screen verification passed."
