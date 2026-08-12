#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README_PATH="$ROOT_DIR/README.md"

GITHUB_USER="BubblePtr"
REPOS=("PiGUI" "AgentHuntify" "LawTriage" "gtrboard" "ZenBlog" "Voily" "VibeBar" "concerto" "MindBack")

payload_file="$(mktemp)"
echo "[]" > "$payload_file"

# Use gh (authenticated) so private repos and higher rate limits work.
for repo in "${REPOS[@]}"; do
  if ! lang_json="$(gh api "repos/${GITHUB_USER}/${repo}/languages")"; then
    echo "Failed to fetch languages for ${GITHUB_USER}/${repo}" >&2
    exit 1
  fi
  tmp_file="$(mktemp)"
  jq --arg repo "$repo" --argjson langs "$lang_json" \
    '. + [{repo: $repo, langs: $langs}]' \
    "$payload_file" > "$tmp_file"
  mv "$tmp_file" "$payload_file"
done

rows_json="$(jq '
  def totals:
    [ .[] | .langs | to_entries[] ]
    | group_by(.key)
    | map({lang: .[0].key, bytes: (map(.value) | add)});

  def repos_per_lang:
    # Rank repos within a language by their byte count so "Key Repos" shows
    # the most representative ones first, capped at 4 to keep rows short.
    [ .[] as $item
      | ($item.langs | to_entries[]) as $entry
      | {lang: $entry.key, repo: $item.repo, bytes: $entry.value} ]
    | group_by(.lang)
    | map({
        lang: .[0].lang,
        # Each repo appears at most once per language, so no dedupe needed;
        # jq unique would re-sort alphabetically and destroy the byte order.
        repos: (sort_by(-.bytes) | map(.repo) | .[0:4] | join(", "))
      });

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
        | map(select(.share >= 1.0))
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
  echo "_GitHub Linguist bytes from active repositories · refreshed $(date '+%Y-%m-%d')._"
  echo
  echo "| Language | Share | Key Repos |"
  echo "| --- | ---: | --- |"

  jq -r '.rows[] | "| \(.lang) | \(.share | tostring) | \(.repos) |"' <<<"$rows_json" \
    | while IFS='|' read -r _ lang share repos _; do
        share_clean="$(awk -v n="$(echo "$share" | xargs)" 'BEGIN { printf "%.1f%%", n }')"
        printf "| %s | %s | %s |\n" "$(echo "$lang" | xargs)" "$share_clean" "$(echo "$repos" | xargs)"
      done
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
