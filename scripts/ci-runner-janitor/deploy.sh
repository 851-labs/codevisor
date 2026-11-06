#!/usr/bin/env bash
set -euo pipefail

targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=(croissant@croissants-mac-mini tamale@tamales-mac-mini)
source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for target in "${targets[@]}"; do
  echo "Deploying to $target"
  ssh "$target" 'mkdir -p ~/runner-janitor'
  scp -q "$source_dir/runner_janitor.py" "$source_dir/job-started.sh" "${target}:runner-janitor/"
  ssh "$target" 'bash -s' <<'REMOTE'
set -euo pipefail
hook="$HOME/runner-janitor/job-started.sh"
chmod +x "$hook"
cd "$HOME/actions-runner"
touch .env
{ grep -v '^ACTIONS_RUNNER_HOOK_JOB_STARTED=' .env || true; echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=$hook"; } >.env.next
if cmp -s .env .env.next; then
  rm .env.next
  echo "  hook already configured; updated the script"
  exit 0
fi
mv .env.next .env
while pgrep -q -x Runner.Worker; do
  echo "  waiting for the current job to finish before restarting the runner"
  sleep 30
done
./svc.sh stop >/dev/null
./svc.sh start >/dev/null
echo "  runner restarted with the job-started hook"
REMOTE
done
