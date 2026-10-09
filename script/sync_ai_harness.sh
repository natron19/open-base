#!/usr/bin/env bash
# Copies the shared guardrail + eval harness from open-base into sibling demo apps.
#
#   script/sync_ai_harness.sh [--dry-run] ../open-foo ../open-bar ...
#
# New shared files are copied as-is. Files that already exist in the app are
# overwritten only when the app's copy is unchanged from open-base's committed
# version; customized copies are listed under MERGE for a hand merge.
# Per-app files (config/ai_guards.yml, evals/cases/) are never touched.
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=true; shift; fi

NEW_FILES=(
  app/services/ai_output_guard.rb
  app/services/secret_redactor.rb
  app/services/ai_guard_config.rb
  app/views/shared/ai_error_page.html.erb
  lib/evals/adapters/result.rb
  lib/evals/adapters/template.rb
  lib/evals/calibration.rb
  lib/evals/case_file.rb
  lib/evals/checks.rb
  lib/evals/guardrail_suite.rb
  lib/evals/judge.rb
  lib/evals/report.rb
  lib/evals/runner.rb
  lib/tasks/evals.rake
  docs/ai-evals.md
  evals/bars.yml
  evals/guardrails.yml
  evals/judge_calibration.yml
  spec/services/ai_output_guard_spec.rb
  spec/services/secret_redactor_spec.rb
  spec/services/gemini_key_transport_spec.rb
  spec/lib/evals/checks_spec.rb
  spec/lib/evals/judge_spec.rb
)

MODIFIED_FILES=(
  app/services/ai_gatekeeper.rb
  app/services/gemini_service.rb
  app/models/llm_request.rb
  app/views/admin/llm_requests/_status_badge.html.erb
  app/views/admin/llm_requests/index.html.erb
  app/views/shared/_ai_error.html.erb
  docs/ai-guardrails.md
  docs/ai-templates.md
  CLAUDE.md
  spec/services/ai_gatekeeper_spec.rb
  spec/services/gemini_service_spec.rb
)

copy() {
  $DRY_RUN || { mkdir -p "$(dirname "$2")"; cp "$1" "$2"; }
}

for app in "$@"; do
  app="$(cd "$app" && pwd)"
  echo "== $(basename "$app")"

  for f in "${NEW_FILES[@]}"; do
    if [[ -f "$app/$f" ]] && ! cmp -s "$BASE/$f" "$app/$f"; then
      echo "  MERGE  $f (exists and differs)"
    else
      copy "$BASE/$f" "$app/$f"
    fi
  done

  for f in "${MODIFIED_FILES[@]}"; do
    if cmp -s "$BASE/$f" "$app/$f"; then
      continue
    elif git -C "$BASE" show "HEAD:$f" 2>/dev/null | cmp -s - "$app/$f"; then
      copy "$BASE/$f" "$app/$f"
      echo "  update $f"
    else
      echo "  MERGE  $f (customized in this app)"
    fi
  done

  if ! grep -q 'eval_judge_v1' "$app/db/seeds.rb"; then
    $DRY_RUN || sed -n '/^# LLM-as-judge template/,$p' "$BASE/db/seeds.rb" | { echo; cat; } >> "$app/db/seeds.rb"
    echo "  seed   eval_judge_v1"
  fi

  [[ -f "$app/config/ai_guards.yml" ]] || echo "  TODO   config/ai_guards.yml"
  ls "$app"/evals/cases/*.yml >/dev/null 2>&1 || echo "  TODO   evals/cases/<template>.yml"
done
