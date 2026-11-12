#!/bin/bash
# Build, sign, notarize and publish a CaptureDesktop release.
#
# Run by .github/workflows/release.yml on the release Mac. It needs:
#   APPLE_TEAM_ID                  Developer ID team
#   APP_STORE_CONNECT_KEY_ID       App Store Connect API key ID, with the key file at
#                                  ~/.appstoreconnect/private_keys/AuthKey_<id>.p8
#                                  (or APP_STORE_CONNECT_API_KEY_PATH)
#   APP_STORE_CONNECT_ISSUER_ID    App Store Connect issuer ID
#   GH_TOKEN                       token allowed to create releases
#   HOMEBREW_TAP_DEPLOY_KEY        private SSH key allowed to push to the Homebrew tap
#                                  (without it the release is still published, then the run fails)
# and a "Developer ID Application" certificate in the login keychain.
#
# DRY_RUN=1 builds and signs only: nothing is notarized or published.
set -euo pipefail

cd "$(dirname "$0")/.."
fail() { echo "release: $*" >&2; exit 1; }

DRY_RUN="${DRY_RUN:-0}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
# Once a release is published, two things follow it: the website (it shows the latest
# version and its download link, read when it builds) and the Homebrew cask. Both run
# for every release, including a re-run that finds it already published, so a step
# that failed last time is retried. Both are attempted before either failure is reported.
after_publish() {
  local failed=""
  # The cask first: the site shows the Homebrew command.
  ./scripts/update-cask.sh "$version" || failed="the Homebrew cask was not updated"
  gh workflow run site.yml --ref main || failed="${failed:+$failed, and }the site rebuild could not be started"
  [[ -z "$failed" ]] || fail "the release is published, but $failed: re-run this workflow"
}

ASSET="CaptureDesktop.zip"   # fixed name: the website links to releases/latest/download/CaptureDesktop.zip

# Version: major.minor from project.yml, patch = number of commits on this branch.
base="$(sed -n 's/^ *MARKETING_VERSION: *"\([0-9]*\.[0-9]*\)\..*/\1/p' project.yml)"
[[ -n "$base" ]] || fail "could not read MARKETING_VERSION from project.yml"
[[ "$(git rev-parse --is-shallow-repository)" == "false" ]] || fail "needs full git history to number the build"
build="$(git rev-list --count HEAD)"
version="$base.$build"
tag="v$version"
echo "release: version $version ($(git rev-parse --short HEAD))"

if [[ "$DRY_RUN" != 1 ]]; then
  : "${APP_STORE_CONNECT_KEY_ID:?Set APP_STORE_CONNECT_KEY_ID}"
  : "${APP_STORE_CONNECT_ISSUER_ID:?Set APP_STORE_CONNECT_ISSUER_ID}"
  key="${APP_STORE_CONNECT_API_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8}"
  [[ -r "$key" ]] || fail "App Store Connect key file not found"
  # A release only counts when it is published and carries the fully uploaded app. An earlier run that
  # died mid-upload can leave a draft or an empty release behind: remove it and start over.
  if state="$(gh release view "$tag" --json isDraft,assets --jq '[.isDraft, any(.assets[]; .name == "'"$ASSET"'" and .state == "uploaded" and .size > 0)] | @tsv' 2>/dev/null)"; then
    if [[ "$state" == $'false\ttrue' ]]; then
      echo "release: $tag is already published, nothing to build"
      after_publish
      exit 0
    fi
    echo "release: $tag exists but is incomplete, replacing it"
    gh release delete "$tag" --yes
  fi
fi

out="$PWD/build/release"
rm -rf "$out"
mkdir -p "$out"

xcodegen generate
xcodebuild -project CaptureDesktop.xcodeproj -scheme CaptureDesktop -configuration Release \
  -derivedDataPath "$out/derived" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ONLY_ACTIVE_ARCH=NO \
  build | tail -n 3

app="$out/derived/Build/Products/Release/CaptureDesktop.app"
[[ -d "$app" ]] || fail "build produced no app"
built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$built" == "$version" ]] || fail "app reports version $built, expected $version"
codesign --verify --deep --strict "$app"
codesign -d --entitlements - "$app" 2>/dev/null | grep -q get-task-allow && fail "app carries the debug entitlement"
echo "release: built $(lipo -archs "$app/Contents/MacOS/CaptureDesktop") for team $(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"

if [[ "$DRY_RUN" == 1 ]]; then
  ditto -c -k --keepParent "$app" "$out/$ASSET"
  echo "release: dry run, stopping before notarization. Unnotarized archive: $out/$ASSET"
  exit 0
fi

# Notarize, then staple the ticket so the app opens offline. No release without both.
ditto -c -k --keepParent "$app" "$out/notarize.zip"
xcrun notarytool submit "$out/notarize.zip" --key "$key" --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" --wait --output-format json > "$out/notary.json" || true
status="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$out/notary.json" 2>/dev/null || true)"
if [[ "$status" != "Accepted" ]]; then
  id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$out/notary.json" 2>/dev/null || true)"
  [[ -n "$id" ]] && xcrun notarytool log "$id" --key "$key" --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" >&2 || true
  fail "notarization did not succeed (status: ${status:-unknown})"
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute -vv "$app"

ditto -c -k --keepParent "$app" "$out/$ASSET"
sum="$(shasum -a 256 "$out/$ASSET" | cut -d' ' -f1)"
gh release create "$tag" "$out/$ASSET" --target "$(git rev-parse HEAD)" --title "CaptureDesktop $version" \
  --generate-notes --notes "Download **$ASSET**, unzip it and move CaptureDesktop to your Applications folder. Needs macOS 15 or later.

SHA-256: \`$sum\`"
echo "release: published $tag"
after_publish
