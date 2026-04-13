#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

bump="patch"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --minor) bump="minor"; shift ;;
        --major) bump="major"; shift ;;
        *) echo "Usage: $0 [--minor | --major]" >&2; exit 1 ;;
    esac
done

current=$(cat VERSION | tr -d '[:space:]')
IFS=. read -r major minor patch <<< "$current"

case "$bump" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
esac

new="${major}.${minor}.${patch}"

echo "$new" > VERSION
sed -i '' "s/^DTT_VERSION=\".*\"/DTT_VERSION=\"${new}\"/" dtt.sh

echo "${current} → ${new}"

git add VERSION dtt.sh
git commit -m "Bump build version"
git push
