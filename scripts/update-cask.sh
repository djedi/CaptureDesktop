#!/bin/bash
# Point the Homebrew cask at a published CaptureDesktop release.
#
#   scripts/update-cask.sh 0.1.12
#
# Run by scripts/release.sh after a release is published. It downloads the
# release's CaptureDesktop.zip, writes Casks/capturedesktop.rb for that version
# and checksum, and pushes it to the Homebrew tap. Running it again for the
# same release changes nothing. It needs:
#   GH_TOKEN                   token allowed to read the release (or a gh login)
#   HOMEBREW_TAP_DEPLOY_KEY    private SSH key allowed to push to the tap
#
# CASK_OUT=<file> writes the cask to that file instead and pushes nothing.
set -euo pipefail

fail() { echo "cask: $*" >&2; exit 1; }

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: update-cask.sh <major.minor.patch>"

REPO="djedi/CaptureDesktop"
TAP="djedi/homebrew-tap"
ASSET="CaptureDesktop.zip"
CASK="Casks/capturedesktop.rb"
# GitHub's published SSH host key (https://api.github.com/meta), pinned so the
# push does not depend on the machine's known_hosts.
GITHUB_HOST_KEY="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The checksum comes from the published file, which is what Homebrew downloads.
gh release download "v$version" --repo "$REPO" --pattern "$ASSET" --dir "$work/asset" \
  || fail "could not download $ASSET from release v$version"
sum="$(shasum -a 256 "$work/asset/$ASSET" | cut -d' ' -f1)"

write_cask() {
  cat > "$1" <<EOF
cask "capturedesktop" do
  version "$version"
  sha256 "$sum"

  url "https://github.com/$REPO/releases/download/v#{version}/$ASSET"
  name "CaptureDesktop"
  desc "Screen recorder that hands its recordings to DaVinci Resolve Studio"
  homepage "https://capturedesk.top/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "CaptureDesktop.app"

  # Recordings in ~/Movies/CaptureDesktop are the user's work and are never removed.
  zap trash: "~/Library/Preferences/top.capturedesk.CaptureDesk.plist"
end
EOF
}

if [[ -n "${CASK_OUT:-}" ]]; then
  write_cask "$CASK_OUT"
  echo "cask: wrote $CASK_OUT for $version"
  exit 0
fi

: "${HOMEBREW_TAP_DEPLOY_KEY:?Set HOMEBREW_TAP_DEPLOY_KEY}"
( umask 077; printf '%s\n' "$HOMEBREW_TAP_DEPLOY_KEY" > "$work/key" )
echo "$GITHUB_HOST_KEY" > "$work/known_hosts"
# -F /dev/null: only this key is used, never an identity from the machine's SSH config.
export GIT_SSH_COMMAND="ssh -F /dev/null -i $work/key -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$work/known_hosts"

# Returns 0 when the tap is settled (updated, already current, or newer), 1 when
# the push was rejected and it is worth trying again from a fresh clone.
update_tap() {
  rm -rf "$work/tap"
  git clone --quiet --depth 1 "git@github.com:$TAP.git" "$work/tap" || fail "could not clone the tap"
  # Never move the cask backwards: a re-run of an older release, or runs finishing
  # out of order, must not replace a newer version.
  local current newest
  current="$(sed -n 's/^ *version "\([0-9.]*\)"$/\1/p' "$work/tap/$CASK" 2>/dev/null || true)"
  if [[ -n "$current" && "$current" != "$version" ]]; then
    newest="$(printf '%s\n%s\n' "$current" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
    if [[ "$newest" == "$current" ]]; then
      echo "cask: the tap has $current, which is newer than $version; leaving it"
      return 0
    fi
  fi
  # Checked one by one: "set -e" is off inside a function called from a condition.
  mkdir -p "$work/tap/$(dirname "$CASK")" || fail "could not write the cask"
  write_cask "$work/tap/$CASK" || fail "could not write the cask"
  git -C "$work/tap" add "$CASK" || fail "could not stage the cask"
  if git -C "$work/tap" diff --cached --quiet; then
    echo "cask: the tap already has $version"
    return 0
  fi
  # A neutral identity: these commits are made by the release machine, not a person.
  git -C "$work/tap" -c user.name="CaptureDesktop release" -c user.email="noreply@capturedesk.top" \
    commit --quiet -m "Update capturedesktop to $version" || fail "could not commit the cask"
  git -C "$work/tap" push --quiet origin HEAD || return 1
  echo "cask: the tap now has $version"
}

# Someone else may push to the tap between the clone and the push: start again.
for attempt in 1 2 3; do
  update_tap && exit 0
  echo "cask: push rejected, trying again ($attempt)" >&2
  sleep 2
done
fail "could not push to the tap"
