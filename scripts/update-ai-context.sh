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
# Auto-discovers the matching topic YAML for a given markdown file.
#
# Strategy:
#   1. Strip -metrics / _metrics / -context etc. from the md filename
#      to get a stem (e.g. "arr-metrics.md" → "arr")
#   2. Find all *.topic.yml files in the Omni model directory
#   3. Match topic files whose name contains the stem
#   4. If exactly one match → use it
#      If multiple → pick the closest (shortest filename)
#      If none → skip
# ──────────────────────────────────────────────────────────────────

# Optional manual overrides (only needed if auto-match gets it wrong)
declare -A TOPIC_OVERRIDES=(
  # ["some-edge-case.md"]="topics/specific_topic.topic.yml"
)

find_topic_yaml() {
  local md_filename="$1"
  local model_dir="$2"

  # Check override first
  local override="${TOPIC_OVERRIDES[$md_filename]:-}"
  if [ -n "$override" ] && [ -f "$model_dir/$override" ]; then
    echo "$override"
    return 0
  fi

  # Extract stem: remove extension, strip common suffixes
  local stem
  stem=$(echo "$md_filename" | sed \
    -e 's/\.md$//' \
    -e 's/[-_]metrics$//' \
    -e 's/[-_]context$//' \
    -e 's/[-_]docs$//')

  # Normalize: replace hyphens with underscores for matching
  local stem_normalized
  stem_normalized=$(echo "$stem" | tr '-' '_')

  # Find all topic YAML files
  local matches=()
  while IFS= read -r topic_file; do
    local topic_basename
    topic_basename=$(basename "$topic_file")
    local topic_normalized
    topic_normalized=$(echo "$topic_basename" | tr '-' '_' | tr '[:upper:]' '[:lower:]')

    # Check if the topic filename contains our stem
    if [[ "$topic_normalized" == *"$stem_normalized"* ]]; then
      local rel_path="${topic_file#$model_dir/}"
      matches+=("$rel_path")
    fi
  done < <(find "$model_dir" -name '*.topic.yml' -type f 2>/dev/null)

  case ${#matches[@]} in
    0)
      return 1
      ;;
    1)
      echo "${matches[0]}"
      return 0
      ;;
    *)
      # Multiple matches — pick shortest filename (most specific match)
      local best=""
      local best_len=9999
      for m in "${matches[@]}"; do
        local len=${#m}
        if (( len < best_len )); then
          best="$m"
          best_len=$len
        fi
      done
      echo "$best"
      return 0
      ;;
  esac
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
    # Replace existing ai_context block
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

# Show available topics for debugging
echo "Available topics in model:"
find "$OMNI_DIR" -name '*.topic.yml' -type f | while read -r f; do
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
  topic_yaml=$(find_topic_yaml "$filename" "$OMNI_DIR") || true
  if [ -z "$topic_yaml" ]; then
    echo "  ⚠ No matching topic found"
    echo "    Add an override in TOPIC_OVERRIDES if the match isn't obvious"
    ((skipped++))
    continue
  fi

  echo "  → Matched to: $topic_yaml"

  full_yaml_path="$OMNI_DIR/$topic_yaml"

  # Read and escape the markdown
  raw_content=$(cat "$filepath")
  escaped_content=$(escape_for_omni_context "$raw_content")

  # Prepend a source header
  header="# Synced from: context/consumption/docs/$filename
# Last sync: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Do not edit here — update the source doc and re-sync.
"
  final_content="${header}${escaped_content}"

  # Write to the YAML file
  write_ai_context "$full_yaml_path" "$final_content"
  echo "  ✓ Updated"
  ((updated++))

done < "$CHANGED_FILES"

echo ""
echo "Done. Updated: $updated, Skipped: $skipped"
