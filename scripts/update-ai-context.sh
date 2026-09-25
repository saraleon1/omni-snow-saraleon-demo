#!/usr/bin/env bash
set -euo pipefail

# update-ai-context.sh
#
# Reads changed markdown files and writes their content into the
# corresponding Omni topic YAML file's ai_context field.
#
# Usage: bash update-ai-context.sh <changed-files-list> <omni-model-dir>

CHANGED_FILES="$1"
OMNI_DIR="$2"

# ──────────────────────────────────────────────────────────────────
# find_topic_yaml
#
# Content-based matching: reads the markdown for backtick-wrapped
# dbt model/table references, then finds which topic YAML file
# references the most of those same models.
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
  local refs=()
  while IFS= read -r ref; do
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
  done < <(find "$model_dir" \( -name '*.topic.yml' -o -name '*.topic.yaml' \) -type f 2>/dev/null)

  if [ "$best_score" -eq 0 ]; then
    echo "  (no topic matched any references)" >&2
    return 1
  fi

  echo "  Best match: $best_topic (score: $best_score/${#refs[@]})" >&2
  echo "$best_topic"
  return 0
}

# ──────────────────────────────────────────────────────────────────
# escape_for_omni_context
#
# Omni's ai_context interprets:
#   {{omni_attributes.*}}  → user attribute substitution
#   @{constant_name}       → model constant reference
#   {{# omni_llm.*}}       → LLM conditional
#   {{# omni_agent.*}}     → agent conditional
#
# Escapes {{ and @{ so source markdown isn't misinterpreted.
# ──────────────────────────────────────────────────────────────────
escape_for_omni_context() {
  local content="$1"
  echo "$content" | sed \
    -e 's/{{/{ {/g' \
    -e 's/@{/@ {/g'
}

# ──────────────────────────────────────────────────────────────────
# write_ai_context
#
# Replaces the ai_context field in a YAML file with new content.
# Uses YAML block scalar (|) with 2-space indentation.
# ──────────────────────────────────────────────────────────────────
write_ai_context() {
  local yaml_file="$1"
  local context_content="$2"
  local tmp_file="${yaml_file}.tmp"

  # Indent every line by 2 spaces; empty lines stay empty
  local indented
  indented=$(echo "$context_content" | sed 's/^/  /' | sed 's/^  $//')

  local new_block
  new_block=$(printf 'ai_context: |\n%s' "$indented")

  if grep -q '^ai_context:' "$yaml_file"; then
    awk -v new_block="$new_block" '
      /^ai_context:/ {
        print new_block
        in_context = 1
        next
      }
      in_context && /^[a-zA-Z_]/ {
        in_context = 0
      }
      !in_context {
        print
      }
    ' "$yaml_file" > "$tmp_file"
    mv "$tmp_file" "$yaml_file"
  else
    {
      head -1 "$yaml_file"
      echo "$new_block"
      tail -n +2 "$yaml_file"
    } > "$tmp_file"
    mv "$tmp_file" "$yaml_file"
  fi
}

# ──────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────

echo "Available topics in model:"
find "$OMNI_DIR" \( -name '*.topic.yml' -o -name '*.topic.yaml' \) -type f | while read -r f; do
  echo "  $(basename "$f")"
done
echo ""

updated=0
skipped=0

while IFS= read -r filepath; do
  [ -z "$filepath" ] && continue
  filename=$(basename "$filepath")

  echo "→ $filename"

  # Auto-discover matching topic
  topic_yaml=$(find_topic_yaml "$filepath" "$OMNI_DIR") || true
  if [ -z "$topic_yaml" ]; then
    echo "  ⚠ No matching topic found"
    echo "    Add an override in TOPIC_OVERRIDES if the match isn't obvious"
    skipped=$((skipped + 1))
    continue
  fi

  echo "  → Matched to: $topic_yaml"

  full_yaml_path="$OMNI_DIR/$topic_yaml"

  # Read and escape the markdown
  raw_content=$(cat "$filepath")
  escaped_content=$(escape_for_omni_context "$raw_content")

  # Prepend a source header
  header="# Synced from: context/docs/$filename
# Last sync: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Do not edit here — update the source doc and re-sync.
"
  final_content="${header}${escaped_content}"

  # Write to the YAML file
  write_ai_context "$full_yaml_path" "$final_content"
  echo "  ✓ Updated"
  updated=$((updated + 1))

done < "$CHANGED_FILES"

echo ""
echo "Done. Updated: $updated, Skipped: $skipped"
