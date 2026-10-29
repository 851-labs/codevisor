#!/usr/bin/env bash
set -uo pipefail
input=$(cat)
check="$(cd "$(dirname "$0")" && pwd -P)/check-files.sh"

event=$(printf '%s' "$input" | jq -r '.hook_event_name // ""')
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null

files=$(printf '%s' "$input" | jq -r '
  [ .file_path, .tool_input.file_path, .tool_input.path, .tool_input.notebook_path,
    .tool_input.target_file ]
  + ( (.tool_input.command // "") | if type == "string" then
        [ scan("(?m)^\\*\\*\\* (?:Add|Update) File: (.+)$")[0], scan("(?m)^\\*\\*\\* Move to: (.+)$")[0] ]
      else [] end )
  | map(select(type == "string" and . != "")) | unique | .[]')
[ -n "$files" ] || exit 0

report=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 "$check") && exit 0

message="Formatted the edited file(s). Lint errors to fix now:
$report"
case "$event" in
  AfterTool) jq -n --arg m "$message" '{hookSpecificOutput: {hookEventName: "AfterTool", additionalContext: $m}}' ;;
  postToolUse) jq -n --arg m "$message" '{additional_context: $m}' ;;
  *) jq -n --arg m "$message" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}' ;;
esac
