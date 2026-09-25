# ──────────────────────────────────────────────────────────────────
# find_topic_yaml
#
# Content-based matching: reads the markdown for backtick-wrapped
# dbt model/table references, then finds which topic YAML file
# references the most of those same models.
#
# Example: arr-metrics.md mentions `measures___arr_*` and
# `measures___ttm_nrr_grr_by_ultimate_parent`. The script strips
# wildcards, greps topic YAMLs for those stems, and picks the
# topic with the most hits.
# ──────────────────────────────────────────────────────────────────

# Optional manual overrides (only needed if content match fails)
declare -A TOPIC_OVERRIDES=(
  # ["some-edge-case.md"]="topics/specific_topic.topic.yml"
)

find_topic_yaml() {
  local md_file="$1"
  local md_filename
  md_filename=$(basename "$md_file")
  local model_dir="$2"

  # Check override first
  local override="${TOPIC_OVERRIDES[$md_filename]:-}"
  if [ -n "$override" ] && [ -f "$model_dir/$override" ]; then
    echo "$override"
    return 0
  fi

  # Extract backtick-wrapped references from the markdown
  # Matches things like `measures___arr_*`, `entity__opportunity`, etc.
  local refs=()
  while IFS= read -r ref; do
    # Strip wildcards and trailing underscores for matching
    local clean
    clean=$(echo "$ref" | sed -e 's/\*//g' -e 's/_*$//')
    [ -n "$clean" ] && refs+=("$clean")
  done < <(grep -oP '`[a-zA-Z_][a-zA-Z0-9_]*`' "$md_file" | tr -d '`' | sort -u)

  if [ ${#refs[@]} -eq 0 ]; then
    echo "  (no model references found in markdown)" >&2
    return 1
  fi

  echo "  Found ${#refs[@]} model references: ${refs[*]:0:5}..." >&2

  # Score each topic YAML by how many of those references it contains
  local best_topic=""
  local best_score=0

  while IFS= read -r topic_file; do
    local score=0
    local topic_content
    topic_content=$(cat "$topic_file")

    for ref in "${refs[@]}"; do
      if echo "$topic_content" | grep -qi "$ref"; then
        score=$((score + 1))
      fi
    done

    if [ "$score" -gt "$best_score" ]; then
      best_score=$score
      best_topic="${topic_file#$model_dir/}"
    fi
  done < <(find "$model_dir" -name '*.topic.yml' -type f 2>/dev/null)

  if [ "$best_score" -eq 0 ]; then
    echo "  (no topic matched any references)" >&2
    return 1
  fi

  echo "  Best match: $best_topic (score: $best_score/${#refs[@]})" >&2
  echo "$best_topic"
  return 0
}
