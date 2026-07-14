#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

delta_assert_clean_worktree "$ROOT_DIR"
export DELTA_REQUIRE_RELEASE_TAG=1
IFS=$'\t' read -r VERSION BUILD < <(delta_assert_release_metadata "$ROOT_DIR")
TAG="v$VERSION"
COMMIT="$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)"
UPDATES_DIR="$ROOT_DIR/dist/updates"
BASE_NAME="Delta-$VERSION-$BUILD"
ASSETS=(
  "$UPDATES_DIR/Delta-$VERSION-$BUILD.dmg"
  "$UPDATES_DIR/Delta-$VERSION-$BUILD.zip"
  "$UPDATES_DIR/appcast.xml"
  "$UPDATES_DIR/Delta-$VERSION-$BUILD.md"
  "$UPDATES_DIR/SHA256SUMS"
  "$UPDATES_DIR/release.json"
)

for asset in "${ASSETS[@]}"; do
  [[ -f "$asset" ]] || delta_fail "public release asset is missing: $asset"
done

"$ROOT_DIR/Scripts/audit-release-history.sh"
DELTA_EXPECTED_RELEASE_COMMIT="$COMMIT" "$ROOT_DIR/Scripts/verify-release-assets.sh" "$UPDATES_DIR"

delta_require_tool gh
[[ "$(gh api user --jq .login)" == "dbuskariol" ]] || delta_fail 'the active GitHub CLI account is not dbuskariol'
[[ "$(gh repo view "$DELTA_EXPECTED_GITHUB_REPOSITORY" --json isPrivate --jq .isPrivate)" == "false" ]] \
  || delta_fail 'the destination GitHub repository is not public'
[[ "$(/usr/bin/git -C "$ROOT_DIR" ls-remote origin refs/heads/main | /usr/bin/awk '{print $1}')" == "$COMMIT" ]] \
  || delta_fail 'origin/main does not point to the audited release commit'
[[ "$(/usr/bin/git -C "$ROOT_DIR" ls-remote origin "refs/tags/$TAG^{}" | /usr/bin/awk '{print $1}')" == "$COMMIT" ]] \
  || delta_fail 'the pushed annotated release tag does not peel to the audited release commit'

if gh release view "$TAG" --repo "$DELTA_EXPECTED_GITHUB_REPOSITORY" >/dev/null 2>&1; then
  delta_fail "$TAG already has a GitHub release; refusing to overwrite it"
fi

delta_note "Creating the $TAG GitHub release as a draft"
gh release create "$TAG" \
  "${ASSETS[@]}" \
  --repo "$DELTA_EXPECTED_GITHUB_REPOSITORY" \
  --draft \
  --verify-tag \
  --title "Delta $VERSION" \
  --notes-file "$ROOT_DIR/Documentation/RELEASE_NOTES.md"

DOWNLOAD_DIR="$(/usr/bin/mktemp -d -t delta-github-draft.XXXXXX)"
cleanup() {
  /bin/rm -rf "$DOWNLOAD_DIR"
}
trap cleanup EXIT INT TERM

gh release download "$TAG" \
  --repo "$DELTA_EXPECTED_GITHUB_REPOSITORY" \
  --dir "$DOWNLOAD_DIR"

[[ "$(/usr/bin/find "$DOWNLOAD_DIR" -maxdepth 1 -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" == "6" ]] \
  || delta_fail 'the draft release does not contain exactly six public assets'
for asset in "${ASSETS[@]}"; do
  downloaded="$DOWNLOAD_DIR/$(basename "$asset")"
  [[ -f "$downloaded" ]] || delta_fail "draft download is missing $(basename "$asset")"
  /usr/bin/cmp -s "$asset" "$downloaded" || delta_fail "GitHub draft bytes differ for $(basename "$asset")"
done

DELTA_EXPECTED_RELEASE_COMMIT="$COMMIT" "$ROOT_DIR/Scripts/verify-release-assets.sh" "$DOWNLOAD_DIR"

delta_note "Draft bytes passed independent verification; publishing $TAG"
gh release edit "$TAG" \
  --repo "$DELTA_EXPECTED_GITHUB_REPOSITORY" \
  --draft=false \
  --latest

RELEASE_JSON="$(gh api "repos/$DELTA_EXPECTED_GITHUB_REPOSITORY/releases/tags/$TAG")"
[[ "$(/usr/bin/plutil -extract draft raw -o - - <<<"$RELEASE_JSON")" == "false" ]] || delta_fail 'GitHub release remained a draft'
[[ "$(/usr/bin/plutil -extract prerelease raw -o - - <<<"$RELEASE_JSON")" == "false" ]] || delta_fail 'GitHub release is unexpectedly a prerelease'
[[ "$(/usr/bin/plutil -extract tag_name raw -o - - <<<"$RELEASE_JSON")" == "$TAG" ]] || delta_fail 'GitHub release tag mismatch'

for asset in "${ASSETS[@]}"; do
  url="https://github.com/$DELTA_EXPECTED_GITHUB_REPOSITORY/releases/latest/download/$(basename "$asset")"
  /usr/bin/curl --fail --silent --show-error --location --head "$url" >/dev/null \
    || delta_fail "public latest-download URL failed: $url"
done

URL="$(gh release view "$TAG" --repo "$DELTA_EXPECTED_GITHUB_REPOSITORY" --json url --jq .url)"
delta_note "Published and verified $URL"
