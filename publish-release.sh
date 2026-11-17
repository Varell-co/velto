#!/bin/bash
# One-step release: bump VERSION, draft notes from commits, build, publish on GitHub,
# point the Homebrew cask at the new ZIP, and upgrade the local Homebrew install.
#
# Usage: bash publish-release.sh [patch|minor|major|X.Y.Z] [-y]
#   patch is the default. -y skips the confirmation prompt.
#   Notes come from feat:/fix: commit subjects since the last tag. To write them yourself,
#   put a "# Velto vX.Y.Z" section at the top of RELEASE_NOTES.md before running.
set -euo pipefail
cd "$(dirname "$0")"

# Pinned: with an upstream remote, gh would otherwise default to the original repo.
REPO="Varell-co/Velto"
CASK="Casks/velto.rb"
BUMP="patch"
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    *) BUMP="$arg" ;;
  esac
done

fail() { echo "$*" >&2; exit 1; }

[[ "$(git branch --show-current)" == "main" ]] || fail "Switch to main first."
[[ -z "$(git status --porcelain)" ]] || fail "Working tree is not clean; commit or stash first."
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main differs from origin/main; pull or push first."

CURRENT="$(tr -d '[:space:]' < VERSION)"
IFS=. read -r MAJOR MINOR PATCH <<< "$CURRENT"
case "$BUMP" in
  patch) VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
  minor) VERSION="$MAJOR.$((MINOR + 1)).0" ;;
  major) VERSION="$((MAJOR + 1)).0.0" ;;
  *) VERSION="$BUMP" ;;
esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must be patch, minor, major or MAJOR.MINOR.PATCH."
TAG="v$VERSION"
gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 && fail "Release $TAG already exists."

# Use hand-written notes if present, otherwise draft them from conventional commit subjects.
if [[ "$(head -1 RELEASE_NOTES.md)" != "# Velto $TAG" ]]; then
  LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  RANGE="${LAST_TAG:+$LAST_TAG..}HEAD"
  section() { # $1 = commit type, $2 = heading
    local lines
    lines="$(git log --format=%s "$RANGE" | sed -nE "s/^$1(\([^)]*\))?!?: (.)(.*)/- \2\3/p" | awk '{ print toupper(substr($0,1,3)) substr($0,4) }')"
    [[ -n "$lines" ]] && printf '## %s\n\n%s' "$2" "$lines"
    return 0
  }
  # $(...) drops trailing newlines, so the blank lines between sections are added here.
  BODY=""
  for part in "$(section feat New)" "$(section fix Fixed)"; do
    [[ -n "$part" ]] && BODY+="$part"$'\n\n'
  done
  [[ -n "$BODY" ]] || fail "No feat: or fix: commits since ${LAST_TAG:-the start}; nothing to release."
  printf '# Velto %s\n\n%s---\n\n' "$TAG" "$BODY" | cat - RELEASE_NOTES.md > RELEASE_NOTES.md.tmp
  mv RELEASE_NOTES.md.tmp RELEASE_NOTES.md
fi

# Ctrl+C at the prompt must not leave a half-written draft behind.
trap 'git checkout -- RELEASE_NOTES.md; echo; fail "Cancelled; nothing was changed."' INT
echo "Releasing $CURRENT -> $VERSION with these notes:"
echo
awk '/^---$/{exit} {print "  " $0}' RELEASE_NOTES.md
if ! $ASSUME_YES; then
  read -r -p "Publish $TAG? [y = yes, e = edit notes first, anything else = cancel] " answer
  if [[ "$answer" == "e" ]]; then
    "${EDITOR:-nano}" RELEASE_NOTES.md
    read -r -p "Publish $TAG? [y/N] " answer
  fi
  if [[ "$answer" != "y" ]]; then
    trap - INT
    git checkout -- RELEASE_NOTES.md
    fail "Cancelled; nothing was changed."
  fi
fi

trap - INT
echo "$VERSION" > VERSION
bash build-release.sh "$VERSION"
ARCHIVE="dist/Velto-$VERSION-universal.zip"
SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"

# One commit per release: version, notes and cask together, so the tag matches what brew installs.
git add VERSION RELEASE_NOTES.md "$CASK"
git commit -q -m "chore: release $VERSION"
git push -q origin main
# Push the tag over git: creating it through the API needs the extra "workflow" token scope.
git tag "$TAG"
git push -q origin "$TAG"

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
awk '/^---$/{exit} {print}' RELEASE_NOTES.md > "$NOTES"
gh release create "$TAG" "$ARCHIVE" -R "$REPO" --verify-tag --title "Velto $TAG" --notes-file "$NOTES" \
  || fail "GitHub release failed. Retry: gh release create $TAG $ARCHIVE -R $REPO --verify-tag --title \"Velto $TAG\" --notes-file <notes>"

if brew list --cask velto >/dev/null 2>&1; then
  echo "Upgrading your Homebrew install..."
  brew update -q && brew upgrade --cask velto
fi
echo "Published $TAG. Others get it with: brew update && brew upgrade --cask velto"
