#!/usr/bin/env bash
# Commit <image>:<sha> as the next-bff-service image in k8s/kustomization.yaml
# and push it to main: the GitOps deploy. Safe when several CI runs finish in
# any order: it never replaces a newer deployed commit, and a rejected push
# (main moved) re-reads main and tries again.
#
# Usage: update-image-tag.sh <image-repository> <commit-sha>
set -euo pipefail

image=$1
sha=$2
kustomization=k8s/kustomization.yaml
remote=${REMOTE:-origin}
branch=${BRANCH:-main}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

run_url=""
if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
  run_url=" by ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

for attempt in 1 2 3 4 5; do
  git fetch --quiet "$remote" "$branch"
  git reset --quiet --hard FETCH_HEAD

  deployed=$(awk '/name: next-bff-service/ { found = 1 } found && /newTag:/ { print $2; exit }' "$kustomization")

  if [[ "$deployed" == "$sha" ]]; then
    echo "Already deployed: ${sha}"
    exit 0
  fi

  # A commit SHA can be ordered against ours; anything else (e.g. the initial
  # 0.1.0 placeholder) is simply replaced.
  if git cat-file -e "${deployed}^{commit}" 2>/dev/null \
     && ! git merge-base --is-ancestor "$deployed" "$sha"; then
    echo "Deployed ${deployed} is newer than (or unrelated to) ${sha}; not replacing it."
    exit 0
  fi

  (cd k8s && kustomize edit set image "next-bff-service=${image}:${sha}")
  git add "$kustomization"
  git commit --quiet -m "deploy(next-bff-service): ${sha:0:12}" -m "Image built from ${sha}${run_url}"

  if git push --quiet "$remote" "HEAD:${branch}"; then
    echo "Deployed ${deployed} -> ${sha}"
    exit 0
  fi

  echo "main moved while deploying; retrying (${attempt}/5)"
  sleep $((attempt * 2))
done

echo "Gave up after 5 attempts" >&2
exit 1
