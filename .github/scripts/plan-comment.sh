#!/usr/bin/env bash
# Render a Terraform plan as a PR comment: plan-comment.sh <stack> <plan.txt> <outcome>
set -euo pipefail

stack=$1
plan_file=$2
outcome=$3
max_chars=60000 # GitHub comments are capped at 65536 characters

echo "### Terraform plan: \`${stack}\` (${outcome})"
echo
if [[ -s "$plan_file" ]]; then
  summary=$(grep -E '^(Plan:|No changes\.)' "$plan_file" || true)
  [[ -n "$summary" ]] && echo "**${summary}**" && echo
  echo "<details><summary>Show plan</summary>"
  echo
  echo '```hcl'
  head -c "$max_chars" "$plan_file"
  [[ $(wc -c < "$plan_file") -gt $max_chars ]] && printf '\n... truncated, see the job log\n'
  echo '```'
  echo "</details>"
else
  echo "The plan did not complete; see the job log."
fi
echo
echo "_Commit ${GITHUB_SHA:-unknown} · [run](${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-})_"
