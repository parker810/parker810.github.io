#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"

branch=$(git branch --show-current)
if [ "$branch" != "source" ]; then
  echo "请在 source 分支上发布。当前是 $branch" >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "source 上还有未提交的修改。先提交，再发布。" >&2
  exit 1
fi

hugo --minify
stage=$(mktemp -d)
cp -a public/. "$stage/"
touch "$stage/.nojekyll"

work=$(mktemp -d)
git worktree add "$work" main
cleanup() {
  git worktree remove --force "$work" >/dev/null 2>&1 || true
  rm -rf "$stage"
}
trap cleanup EXIT

cd "$work"
git rm -rf . >/dev/null
cp -a "$stage"/. .
git add -A
if git diff --cached --quiet; then
  echo "网页没有变化，未推送。"
  exit 0
fi

git commit -m "Publish the built site."
git push origin main
echo "已推送到 main。站点将更新为 https://parker810.github.io/"
