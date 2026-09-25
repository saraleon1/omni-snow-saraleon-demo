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
# MAPPING: markdown filename → topic YAML path (relative to model dir)
#
# Add a line for each context doc that should sync to a topic.
# ──────────────────────────────────────────────────────────────────
declare -A FILE_TO_TOPIC=(
  ["arr-metrics.md"]="topics/arr_and_retention.topic.yml"
  ["activity-metrics.md"]="topics/activity.topic.yml"
  ["customer_metrics.md"]="topics/customer.topic.yml"
  ["opportunity-metrics.md"]="topics/opportunity.topic.yml"
  # Add more as needed
)

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
    # Replace existing ai_context block
    # Skip lines until next top-level key
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
    # No existing ai_context — insert after first line
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
updated=0
skipped=0

while IFS= read -r filepath; do
  [ -z "$filepath" ] && continue
  filename=$(basename "$filepath")
  echo "→ $filename"

  topic_yaml="${FILE_TO_TOPIC[$filename]:-}"
  if [ -z "$topic_yaml" ]; then
    echo "  ⚠ No mapping — add to FILE_TO_TOPIC"
    ((skipped++))
    continue
  fi

  full_yaml_path="$OMNI_DIR/$topic_yaml"
  if [ ! -f "$full_yaml_path" ]; then
    echo "  ⚠ Topic YAML not found: $full_yaml_path"
    ((skipped++))
    continue
  fi

  raw_content=$(cat "$filepath")
  escaped_content=$(escape_for_omni_context "$raw_content")

  header="# Synced from: context/consumption/docs/$filename
# Last sync: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Do not edit here — update the source doc and re-sync.
"
  final_content="${header}${escaped_content}"

  write_ai_context "$full_yaml_path" "$final_content"
  echo "  ✓ Updated $topic_yaml"
  ((updated++))

done < "$CHANGED_FILES"

echo ""
echo "Done. Updated: $updated, Skipped: $skipped"
