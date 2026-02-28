#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README_PATH="$ROOT_DIR/README.md"

GITHUB_USER="AgensK"
REPOS=("Sinan" "VibeBar" "TrustSkill" "jsonrpc4cj")

payload_file="$(mktemp)"
echo "[]" > "$payload_file"

for repo in "${REPOS[@]}"; do
  lang_json="$(curl -fsSL "https://api.github.com/repos/${GITHUB_USER}/${repo}/languages")"
  tmp_file="$(mktemp)"
  jq --arg repo "$repo" --argjson langs "$lang_json" \
    '. + [{repo: $repo, langs: $langs}]' \
    "$payload_file" > "$tmp_file"
  mv "$tmp_file" "$payload_file"
done

# GitHub Linguist does not classify Cangjie yet, so detect it via file extensions.
cangjie_file_count="$(
  curl -fsSL "https://api.github.com/repos/${GITHUB_USER}/jsonrpc4cj/git/trees/main?recursive=1" \
    | jq '[.tree[] | select(.path | endswith(".cj"))] | length'
)"

rows_json="$(jq '
  def totals:
    [ .[] | .langs | to_entries[] ]
    | group_by(.key)
    | map({lang: .[0].key, bytes: (map(.value) | add)});

  def repos_per_lang:
    [ .[] as $item | ($item.langs | keys[]) as $lang | {lang: $lang, repo: $item.repo} ]
    | group_by(.lang)
    | map({lang: .[0].lang, repos: (map(.repo) | unique | join(", "))});

  (totals) as $totals
  | ([$totals[].bytes] | add) as $sum
  | (repos_per_lang | INDEX(.lang)) as $repo_idx
  | {
      sum: $sum,
      rows: (
        $totals
        | sort_by(.bytes)
        | reverse
        | map({
            lang: .lang,
            share: (.bytes / $sum * 100),
            repos: $repo_idx[.lang].repos
          })
      )
    }
' "$payload_file")"

total_bytes="$(jq -r '.sum' <<<"$rows_json")"
if [[ "$total_bytes" -le 0 ]]; then
  echo "No language bytes found from GitHub API."
  rm -f "$payload_file"
  exit 1
fi

generated_file="$(mktemp)"
{
  echo "<!-- TECH_STACK_START -->"
  echo "_Data source: GitHub Linguist bytes from \`Sinan\`, \`VibeBar\`, \`TrustSkill\`, and \`jsonrpc4cj\`._"
  echo "_Last refreshed: $(date '+%Y-%m-%d %H:%M %Z')._"
  echo
  echo "| Language | Share (bytes) | Repositories |"
  echo "| --- | ---: | --- |"

  jq -r '.rows[] | "| \(.lang) | \(.share | tostring) | \(.repos) |"' <<<"$rows_json" \
    | while IFS='|' read -r _ lang share repos _; do
        share_clean="$(awk -v n="$(echo "$share" | xargs)" 'BEGIN { printf "%.1f%%", n }')"
        printf "| %s | %s | %s |\n" "$(echo "$lang" | xargs)" "$share_clean" "$(echo "$repos" | xargs)"
      done

  if [[ "$cangjie_file_count" -gt 0 ]]; then
    echo "| Cangjie* | N/A | jsonrpc4cj |"
  fi
  echo
  if [[ "$cangjie_file_count" -gt 0 ]]; then
    echo "\\* GitHub Linguist currently does not classify Cangjie, so percentage shares exclude \`.cj\` files."
  fi
  echo "<!-- TECH_STACK_END -->"
} > "$generated_file"

start_line="$(grep -n '^<!-- TECH_STACK_START -->$' "$README_PATH" | cut -d: -f1)"
end_line="$(grep -n '^<!-- TECH_STACK_END -->$' "$README_PATH" | cut -d: -f1)"

if [[ -z "${start_line}" || -z "${end_line}" ]]; then
  echo "Markers not found in README: <!-- TECH_STACK_START --> / <!-- TECH_STACK_END -->"
  exit 1
fi

if [[ "$start_line" -ge "$end_line" ]]; then
  echo "Invalid marker order in README."
  exit 1
fi

updated_file="$(mktemp)"
head -n $((start_line - 1)) "$README_PATH" > "$updated_file"
cat "$generated_file" >> "$updated_file"
tail -n +"$((end_line + 1))" "$README_PATH" >> "$updated_file"

mv "$updated_file" "$README_PATH"
rm -f "$generated_file" "$payload_file"

echo "Tech stack section refreshed in $README_PATH"
