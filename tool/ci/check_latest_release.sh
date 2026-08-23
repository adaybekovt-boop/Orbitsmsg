#!/usr/bin/env bash
# After a tag release: /releases/latest must resolve to THIS tag.
# GitHub sometimes lags the "latest" alias; retry with backoff.
set -euo pipefail

repo="${GITHUB_REPOSITORY:-adaybekovt-boop/tkmessenger}"
tag="${1:-${GITHUB_REF_NAME:-}}"
if [[ -z "$tag" ]]; then
  echo "usage: $0 <tag>   (or set GITHUB_REF_NAME)" >&2
  exit 2
fi

url="https://github.com/${repo}/releases/latest"
for i in 1 2 3 4 5 6; do
  loc="$(curl -fsSI -o /dev/null -w '%{redirect_url}' "$url" || true)"
  echo "latest -> ${loc:-<empty>}"
  if [[ "$loc" == *"/releases/tag/${tag}" ]]; then
    exit 0
  fi
  sleep $((i * 2))
done

echo "::error::releases/latest did not resolve to tag ${tag}" >&2
exit 1
