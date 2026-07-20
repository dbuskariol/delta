#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

# Keep the audit terms out of tracked content while assembling the exact
# case-insensitive pattern at runtime.
FORBIDDEN='deco''der-developer|deco''der-dev|deco''derdev|dan''buskariol|nft''dannyboy'
EXPECTED_IDENTITIES=$'Daniel Buskariol|32349796+dbuskariol@users.noreply.github.com\nGitHub|noreply@github.com\ndbuskariol|32349796+dbuskariol@users.noreply.github.com'

cd "$ROOT_DIR"
[[ "$(/usr/bin/git config --local user.name)" == "dbuskariol" ]] || delta_fail 'repository Git user.name is incorrect'
[[ "$(/usr/bin/git config --local user.email)" == "32349796+dbuskariol@users.noreply.github.com" ]] || delta_fail 'repository Git user.email is incorrect'
[[ "$(/usr/bin/git remote)" == "origin" ]] || delta_fail 'origin must be the only Git remote'
[[ "$(/usr/bin/git remote get-url --all origin)" == "git@github.com:dbuskariol/delta.git" ]] || delta_fail 'origin URL is incorrect'

if /usr/bin/git for-each-ref --format='%(refname)' \
  | /usr/bin/grep -E '^refs/(original|replace|rewritten|backup)/|refs/codex/' >/dev/null; then
  delta_fail 'rewrite backup or replacement refs remain'
fi

IDENTITIES="$(/usr/bin/git log --all --format='%an|%ae%n%cn|%ce' | /usr/bin/sort -u)"
[[ "$IDENTITIES" == "$EXPECTED_IDENTITIES" ]] || delta_fail "reachable commit identities are not the exact approved account and GitHub service identities: $IDENTITIES"

while IFS='|' read -r ref object_type tagger_name tagger_email; do
  [[ -n "$ref" ]] || continue
  [[ "$object_type" == "tag" ]] || delta_fail "release tag is lightweight: $ref"
  [[ "$tagger_name" == "dbuskariol" && "$tagger_email" == "<32349796+dbuskariol@users.noreply.github.com>" ]] \
    || delta_fail "tagger identity is incorrect: $ref"
done < <(/usr/bin/git for-each-ref --format='%(refname)|%(objecttype)|%(taggername)|%(taggeremail)' refs/tags)

if /usr/bin/git log --all --format='%B' | /usr/bin/grep -E -i "$FORBIDDEN" >/dev/null; then
  delta_fail 'a forbidden identity remains in reachable commit messages'
fi
if /usr/bin/git rev-list --objects --all | /usr/bin/grep -E -i "$FORBIDDEN" >/dev/null; then
  delta_fail 'a forbidden identity remains in a reachable tracked path'
fi
BAD_FORBIDDEN_BLOBS="$(/usr/bin/git rev-list --objects --all \
  | /usr/bin/awk '{print $1}' \
  | /usr/bin/git cat-file --batch-check='%(objectname) %(objecttype)' \
  | /usr/bin/awk '$2 == "blob" {print $1}' \
  | while IFS= read -r blob; do
      if /usr/bin/git cat-file blob "$blob" | /usr/bin/grep -a -E -i "$FORBIDDEN" >/dev/null; then
        printf '%s\n' "$blob"
      fi
    done)"
[[ -z "$BAD_FORBIDDEN_BLOBS" ]] \
  || delta_fail "a forbidden identity remains in reachable tracked file contents: $BAD_FORBIDDEN_BLOBS"

# A published release tag is an immutable audit baseline. Recheck the complete
# current tree and every object introduced since the previous release so an old,
# already-public blob cannot permanently block later releases while any
# reintroduced or newly added machine-specific path still fails closed.
CURRENT_COMMIT="$(/usr/bin/git rev-parse HEAD)"
PREVIOUS_RELEASE_TAG=''
while IFS= read -r candidate_tag; do
  [[ -n "$candidate_tag" ]] || continue
  if [[ "$(/usr/bin/git rev-list -n 1 "$candidate_tag")" != "$CURRENT_COMMIT" ]]; then
    PREVIOUS_RELEASE_TAG="$candidate_tag"
    break
  fi
done < <(/usr/bin/git tag --merged HEAD --list 'v[0-9]*' --sort=-version:refname)

RELEASE_RANGE='HEAD'
if [[ -n "$PREVIOUS_RELEASE_TAG" ]]; then
  RELEASE_RANGE="$PREVIOUS_RELEASE_TAG..HEAD"
fi
RELEASE_AUDIT_BLOBS="$({
  /usr/bin/git ls-tree -r HEAD | /usr/bin/awk '$2 == "blob" {print $3}'
  /usr/bin/git rev-list --objects "$RELEASE_RANGE" \
    | /usr/bin/awk '{print $1}' \
    | /usr/bin/git cat-file --batch-check='%(objectname) %(objecttype)' \
    | /usr/bin/awk '$2 == "blob" {print $1}'
} | /usr/bin/sort -u)"

# Generic test-fixture home paths are intentional. Real user-home paths are not.
USER_HOME_PREFIX='/''Users/'
GENERIC_FIXTURE_USERS='me|test|tester|example|private-user'
BAD_HOME_BLOBS="$(while IFS= read -r blob; do
      if /usr/bin/git cat-file blob "$blob" \
        | USER_HOME_PREFIX="$USER_HOME_PREFIX" GENERIC_FIXTURE_USERS="$GENERIC_FIXTURE_USERS" \
          /usr/bin/perl -pe 's#\Q$ENV{USER_HOME_PREFIX}\E(?:$ENV{GENERIC_FIXTURE_USERS})(?=/|\b)#~#g' \
        | /usr/bin/grep -a -E "${USER_HOME_PREFIX}[[:alnum:]_.-][^/[:space:]]*" >/dev/null; then
        printf '%s\n' "$blob"
      fi
    done <<<"$RELEASE_AUDIT_BLOBS")"
[[ -z "$BAD_HOME_BLOBS" ]] \
  || delta_fail "a machine-specific user-home path exists in the current tree or objects introduced after ${PREVIOUS_RELEASE_TAG:-the repository baseline}: $BAD_HOME_BLOBS"

if /usr/bin/git rev-list --objects --all \
  | /usr/bin/grep -E -i '\.(p12|p8|pem|mobileprovision|key)([[:space:]]|$)' >/dev/null; then
  delta_fail 'private signing or provisioning material is reachable by path'
fi

if /usr/bin/git grep -I -i -E "$FORBIDDEN" -- . >/dev/null; then
  delta_fail 'the current tracked tree contains a forbidden identity'
fi
if /usr/bin/git diff --cached --no-ext-diff --binary \
  | /usr/bin/grep -a -E -i "$FORBIDDEN" >/dev/null; then
  delta_fail 'the staged diff contains a forbidden identity'
fi

GITLEAKS_BIN="$(/usr/bin/command -v gitleaks 2>/dev/null || true)"
if [[ -z "$GITLEAKS_BIN" ]]; then
  for candidate in /opt/homebrew/bin/gitleaks /usr/local/bin/gitleaks; do
    if [[ -x "$candidate" ]]; then
      GITLEAKS_BIN="$candidate"
      break
    fi
  done
fi
[[ -n "$GITLEAKS_BIN" ]] || delta_fail 'required tool is unavailable: gitleaks'
"$GITLEAKS_BIN" git --no-banner --redact --log-opts='--all' "$ROOT_DIR"

FSCK_OUTPUT="$(/usr/bin/git fsck --full --unreachable --no-reflogs 2>&1 || true)"
[[ -z "$FSCK_OUTPUT" ]] || delta_fail "unreachable Git objects remain; prune before release:\n$FSCK_OUTPUT"

delta_note "Audited $(/usr/bin/git rev-list --all --count) reachable commits, every reachable identity and tag, the current release tree and objects after ${PREVIOUS_RELEASE_TAG:-the repository baseline}, Git objects, and Gitleaks across all refs"
