'builtin' 'typeset' -g _codevisor_resume_file="${CODEVISOR_RESUME_FILE-}"
'builtin' 'unset' CODEVISOR_RESUME_FILE

'builtin' 'source' -- "${GHOSTTY_RESOURCES_DIR}/shell-integration/zsh/.zshenv"

_codevisor_resume() {
  'builtin' 'local' file="$_codevisor_resume_file" line code
  'builtin' 'local' -a lines
  'builtin' 'unset' _codevisor_resume_file
  [[ -r "$file" ]] || 'builtin' 'return' 0

  while IFS= 'builtin' 'read' -r line; do lines+=("$line"); done < "$file"
  'command' 'rm' -f -- "$file"
  'command' 'rmdir' -- "${file:h}" 2>/dev/null
  (( ${#lines} >= 2 )) || 'builtin' 'return' 0

  [[ -z "${lines[1]}" ]] || 'builtin' 'cd' -- "${lines[1]}" || 'builtin' 'return' 0
  'builtin' 'print' -rn -- $'\e]133;C\a'
  'command' -- "${(@)lines[2,-1]}"
  code=$?
  'builtin' 'print' -rn -- $'\e]133;D;'"$code"$'\a'
}

if [[ -o interactive && -n "$_codevisor_resume_file" ]]; then
  'builtin' 'zmodload' zsh/sched && 'builtin' 'sched' +0 _codevisor_resume
fi
