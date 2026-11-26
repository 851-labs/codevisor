__codevisor_resume_file="${CODEVISOR_RESUME_FILE-}"
builtin unset CODEVISOR_RESUME_FILE

builtin source "${GHOSTTY_RESOURCES_DIR}/shell-integration/bash/ghostty.bash"

__codevisor_resume() {
  builtin local file="${__codevisor_resume_file-}" line program code
  builtin local -a lines
  lines=()
  builtin unset __codevisor_resume_file
  [[ -n "$file" && -r "$file" ]] || builtin return 0

  while IFS= builtin read -r line; do lines+=("$line"); done < "$file"
  command rm -f -- "$file"
  command rmdir -- "${file%/*}" 2>/dev/null
  (( ${#lines[@]} >= 2 )) || builtin return 0

  [[ -z "${lines[0]}" ]] || builtin cd -- "${lines[0]}" || builtin return 0
  program="${lines[1]}"
  [[ "$program" == /* ]] || program="$(builtin type -P -- "$program")" || builtin return 0
  builtin printf '\e]133;C\a'
  (builtin exec -a "${lines[1]}" "$program" "${lines[@]:2}")
  code=$?
  builtin printf '\e]133;D;%s\a' "$code"
}

if [[ "$-" == *i* && -n "$__codevisor_resume_file" ]]; then
  if [[ "$(builtin declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
    PROMPT_COMMAND+=("__codevisor_resume")
  else
    PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND}$'\n'}__codevisor_resume"
  fi
fi
