#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

# Keep the audit terms out of tracked content while assembling the exact
# case-insensitive pattern at runtime.
FORBIDDEN='deco''der-developer|deco''der-dev|deco''derdev|dan''buskariol|nft''dannyboy'
EXPECTED_IDENTITY='dbuskariol|32349796+dbuskariol@users.noreply.github.com'

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
[[ "$IDENTITIES" == "$EXPECTED_IDENTITY" ]] || delta_fail "reachable commit identities are not unique and expected: $IDENTITIES"

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

# Generic test-fixture home paths are intentional. Real user-home paths are not.
USER_HOME_PREFIX='/''Users/'
GENERIC_FIXTURE_HOME="${USER_HOME_PREFIX}me"
BAD_HOME_BLOBS="$(/usr/bin/git rev-list --objects --all \
  | /usr/bin/awk '{print $1}' \
  | /usr/bin/git cat-file --batch-check='%(objectname) %(objecttype)' \
  | /usr/bin/awk '$2 == "blob" {print $1}' \
  | while IFS= read -r blob; do
      if /usr/bin/git cat-file blob "$blob" \
        | GENERIC_FIXTURE_HOME="$GENERIC_FIXTURE_HOME" /usr/bin/perl -pe 's#\Q$ENV{GENERIC_FIXTURE_HOME}\E(?=/|\b)#~#g' \
        | /usr/bin/grep -a -E "${USER_HOME_PREFIX}[^/[:space:]]+" >/dev/null; then
        printf '%s\n' "$blob"
      fi
    done)"
[[ -z "$BAD_HOME_BLOBS" ]] \
  || delta_fail "a machine-specific user-home path remains in reachable history: $BAD_HOME_BLOBS"

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

delta_note "Audited $(/usr/bin/git rev-list --all --count) reachable commits, every reachable blob and tag, Git objects, and Gitleaks across all refs"
