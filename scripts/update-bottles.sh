#!/bin/bash
set -e

VERSION="$1"
TAG="v${VERSION}"
TAP_REPO="Chunkwang/homebrew-open-wispr"
TAP_DIR="/tmp/homebrew-open-wispr"
FORMULA="${TAP_DIR}/open-wispr.rb"

if [ -z "$VERSION" ]; then
  echo "Usage: update-bottles.sh <version>"
  exit 1
fi

# TODO(D1 follow-up): no Homebrew tap repo exists yet under the real org
# (confirmed: https://github.com/Chunkwang/homebrew-open-wispr returns 404).
# Don't point this at a repo that doesn't exist -- skip cleanly until one
# is created. Keep this check in sync with scripts/deploy.sh.
if ! curl -sfo /dev/null "https://api.github.com/repos/${TAP_REPO}"; then
  echo "Skipping: no Homebrew tap configured yet (${TAP_REPO} does not exist)."
  echo "Create the tap repo, then re-run scripts/update-bottles.sh ${VERSION}."
  exit 0
fi

DL_DIR=$(mktemp -d)
trap 'rm -rf "${DL_DIR}"' EXIT

echo "==> Downloading bottles from release ${TAG}..."
gh release download "${TAG}" --pattern "*.bottle.tar.gz" --dir "${DL_DIR}" --repo Chunkwang/open-wispr

BOTTLES_JSON="{"
FIRST=true

for file in "${DL_DIR}"/*.bottle.tar.gz; do
  filename=$(basename "$file")
  sha=$(shasum -a 256 "$file" | awk '{print $1}')
  os_tag=""
  if [[ "$filename" == *"arm64_sequoia"* ]]; then
    os_tag="arm64_sequoia"
  elif [[ "$filename" == *"ventura"* ]]; then
    os_tag="ventura"
  elif [[ "$filename" == *"sonoma"* ]]; then
    os_tag="sonoma"
  elif [[ "$filename" == *"sequoia"* ]]; then
    os_tag="sequoia"
  fi
  if [ -n "$os_tag" ]; then
    echo "    ${os_tag}: ${sha}"
    $FIRST || BOTTLES_JSON="${BOTTLES_JSON},"
    BOTTLES_JSON="${BOTTLES_JSON}\"${os_tag}\":\"${sha}\""
    FIRST=false
  fi
done

BOTTLES_JSON="${BOTTLES_JSON}}"

if [ "$BOTTLES_JSON" = "{}" ]; then
  echo "Error: No bottle files found in release ${TAG}"
  exit 1
fi

echo "==> Updating tap formula with bottle SHAs..."

if [ ! -d "${TAP_DIR}" ]; then
  git clone "git@github.com:${TAP_REPO}.git" "${TAP_DIR}"
fi
git -C "${TAP_DIR}" pull --rebase

ruby -e '
  require "json"
  formula_path = ARGV[0]
  tag = ARGV[1]
  bottles = JSON.parse(ARGV[2])

  formula = File.read(formula_path)
  formula.gsub!(/\n  bottle do.*?  end\n/m, "\n")

  lines = ["  bottle do"]
  lines << "    root_url \"https://github.com/Chunkwang/open-wispr/releases/download/#{tag}\""
  bottles.each do |os_tag, sha|
    lines << "    sha256 cellar: :any, #{os_tag}: \"#{sha}\""
  end
  lines << "  end"

  bottle_block = "\n" + lines.join("\n") + "\n"
  formula.sub!(/^(  license "MIT"\n)/) { $1 + bottle_block }
  File.write(formula_path, formula)
' "$FORMULA" "$TAG" "$BOTTLES_JSON"

git -C "${TAP_DIR}" add open-wispr.rb
git -C "${TAP_DIR}" diff --cached --quiet && echo "Tap already up to date." || \
  git -C "${TAP_DIR}" commit -m "Add bottles for ${TAG}"
git -C "${TAP_DIR}" push origin main

echo "==> Bottle update complete"
