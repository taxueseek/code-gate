#!/usr/bin/env bash
# extract-review-scope.sh
# 确定性工程底座（零 LLM 消耗）：单条命令完成状态持久化、工作树安全预检、
# 审查目标识别与准入、变更文件盘点、scoped 规约收集，并输出唯一的 review_plan。
#
# review_plan 是档位编排、复核开关、diff 取数命令与子代理占位符的唯一真源。
# SKILL.md 与 references/ 只描述「怎么审」，不重复这张映射表。
# 兼容 macOS 默认 Bash 3.2（不使用 declare -A、mapfile、${var^^}）

set -euo pipefail

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

STATE_DIR="${CODE_GATE_STATE_DIR:-$HOME/.code-gate}"
STATE_FILE="$STATE_DIR/state.json"
INVENTORY_FILE="$STATE_DIR/inventory.tsv"
mkdir -p "$STATE_DIR"

# ---------- 读取并校验持久化状态 ----------
PERSISTED_TIER="medium"
PERSISTED_MAX_FINDINGS="all"
if [[ -f "$STATE_FILE" ]]; then
  val_tier=$(sed -n 's/.*"tier"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1)
  # 同时兼容 "max_findings": 3 与 "max_findings": "3"
  val_max=$(sed -n 's/.*"max_findings"[[:space:]]*:[[:space:]]*"*\([^",}]*\)"*.*/\1/p' "$STATE_FILE" | head -n 1 | tr -d '[:space:]')
  case "$val_tier" in
    low|medium|high|xhigh) PERSISTED_TIER="$val_tier" ;;
  esac
  if [[ "$val_max" == "all" || "$val_max" =~ ^[1-9][0-9]*$ ]]; then
    PERSISTED_MAX_FINDINGS="$val_max"
  fi
fi

# ---------- 参数解析 ----------
REQ_TIER=""
REQ_MAX_FINDINGS=""
FLAG_FIX="false"
FLAG_COMMENT="false"
FLAG_VERIFY="false"
FLAG_FORCE="false"
TARGET_ARG=""
COMMIT_MODE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    low|medium|high|xhigh|max)
      REQ_TIER="$1"
      shift
      ;;
    --tier)
      [[ -n "${2:-}" ]] || fail "--tier requires one of low|medium|high|xhigh|max"
      REQ_TIER="$2"
      shift 2
      ;;
    --tier=*)
      REQ_TIER="${1#*=}"
      shift
      ;;
    --max-findings)
      [[ -n "${2:-}" ]] || fail "--max-findings requires <n>|all|default"
      REQ_MAX_FINDINGS="$2"
      shift 2
      ;;
    --max-findings=*)
      REQ_MAX_FINDINGS="${1#*=}"
      shift
      ;;
    --fix)      FLAG_FIX="true";      shift ;;
    --comment)  FLAG_COMMENT="true";  shift ;;
    --verify)   FLAG_VERIFY="true";   shift ;;
    --force)    FLAG_FORCE="true";    shift ;;
    -c|--commit)
      [[ -n "${2:-}" ]] || fail "-c/--commit requires a commit SHA"
      COMMIT_MODE="true"
      TARGET_ARG="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage: extract-review-scope.sh [low|medium|high|xhigh|max] [--max-findings <n|all|default>] [--fix] [--comment] [--verify] [--force] [target]
  tiers:
    low | medium        main agent, single-pass (no subagents)
    high | xhigh | max  parallel subagents + adversarial verification
    max                 one-shot only, never overwrites the persisted default
  flags:
    --tier <tier>       same as the positional tier
    --max-findings      keep top N (positive integer), all, or default (= all); persisted
    --fix               apply fixes to the worktree after review
    --comment           post inline comments to a remote PR (mutually exclusive with --fix)
    --verify            force the verification pass on any tier, including low / medium
    --force             override PR Draft / Closed / Merged SKIP verdicts only
  target:
    (omitted)           workspace diff (staged + unstaged + untracked, or ahead-of-upstream commits)
    #123 | 123 | URL    remote Pull Request (read-only via gh)
    -c <sha> | --commit <sha>   single commit
    <branch|tag|a..b>   branch or commit range
    <file-or-dir-path>  changes scoped to path
EOF
      exit 0
      ;;
    *)
      if [[ -z "$TARGET_ARG" ]]; then
        TARGET_ARG="$1"
      else
        TARGET_ARG="$TARGET_ARG $1"
      fi
      shift
      ;;
  esac
done

if [[ "$FLAG_FIX" == "true" && "$FLAG_COMMENT" == "true" ]]; then
  fail "--fix and --comment are mutually exclusive (one writes the local worktree, the other posts to a remote PR)"
fi

# ---------- 档位与 max-findings 计算（唯一真源） ----------
TIER_SOURCE="persisted"
if [[ -n "$REQ_TIER" ]]; then
  case "$REQ_TIER" in
    low|medium|high|xhigh)
      ACTIVE_TIER="$REQ_TIER"
      PERSISTED_TIER="$REQ_TIER"
      TIER_SOURCE="explicit (persisted)"
      ;;
    max)
      ACTIVE_TIER="max"
      TIER_SOURCE="explicit (one-shot, persisted remains $PERSISTED_TIER)"
      ;;
    *)
      fail "Invalid tier '$REQ_TIER'. Expected low|medium|high|xhigh|max."
      ;;
  esac
else
  ACTIVE_TIER="$PERSISTED_TIER"
fi

MAX_FINDINGS_SOURCE="persisted"
if [[ -n "$REQ_MAX_FINDINGS" ]]; then
  if [[ "$REQ_MAX_FINDINGS" == "default" ]]; then
    ACTIVE_MAX_FINDINGS="all"
    PERSISTED_MAX_FINDINGS="all"
    MAX_FINDINGS_SOURCE="reset-to-default (all)"
  elif [[ "$REQ_MAX_FINDINGS" == "all" ]] || [[ "$REQ_MAX_FINDINGS" =~ ^[1-9][0-9]*$ ]]; then
    ACTIVE_MAX_FINDINGS="$REQ_MAX_FINDINGS"
    PERSISTED_MAX_FINDINGS="$REQ_MAX_FINDINGS"
    MAX_FINDINGS_SOURCE="explicit (persisted)"
  else
    fail "Invalid --max-findings '$REQ_MAX_FINDINGS'. Expected positive integer, 'all', or 'default'."
  fi
else
  ACTIVE_MAX_FINDINGS="$PERSISTED_MAX_FINDINGS"
fi

# 原子写入状态文件
TMP_STATE="$STATE_FILE.tmp.$$"
cat > "$TMP_STATE" <<EOF
{
  "tier": "$PERSISTED_TIER",
  "max_findings": "$PERSISTED_MAX_FINDINGS"
}
EOF
mv "$TMP_STATE" "$STATE_FILE"

# 档位 -> 编排映射表：全项目唯一一处
case "$ACTIVE_TIER" in
  low)
    SUBAGENTS="none"; BASE_VERIFY="false"
    SEVERITY_FLOOR="HIGH"; HISTORY_TRACKING="none"
    ;;
  medium)
    SUBAGENTS="none"; BASE_VERIFY="false"
    SEVERITY_FLOOR="MEDIUM"; HISTORY_TRACKING="none"
    ;;
  high)
    SUBAGENTS="correctness-spec,structure-ai"; BASE_VERIFY="true"
    SEVERITY_FLOOR="MEDIUM"; HISTORY_TRACKING="shallow"
    ;;
  xhigh)
    SUBAGENTS="correctness-spec,structure-ai,history"; BASE_VERIFY="true"
    SEVERITY_FLOOR="LOW"; HISTORY_TRACKING="deep"
    ;;
  max)
    SUBAGENTS="correctness-spec,structure-ai,history,adversarial"; BASE_VERIFY="true"
    SEVERITY_FLOOR="LOW"; HISTORY_TRACKING="deep"
    ;;
esac

if [[ "$FLAG_VERIFY" == "true" ]]; then
  VERIFICATION_PASS="true"
else
  VERIFICATION_PASS="$BASE_VERIFY"
fi
if [[ "$ACTIVE_TIER" == "max" ]]; then
  VERIFICATION_MODE="per-finding"
else
  VERIFICATION_MODE="centralized"
fi

# ---------- 审查目标识别 ----------
TARGET_MODE="workspace"
PR_NUMBER=""
RANGE_SPEC=""
DIFF_RANGE="HEAD"
PRECHECK_VERDICT="ELIGIBLE"
PRECHECK_NOTE=""

if [[ -z "$TARGET_ARG" ]]; then
  TARGET_MODE="workspace"
elif [[ "$COMMIT_MODE" == "true" ]]; then
  TARGET_MODE="commit"
elif [[ "$TARGET_ARG" =~ ^#?([0-9]+)$ ]]; then
  TARGET_MODE="pr"; PR_NUMBER="${BASH_REMATCH[1]}"
elif [[ "$TARGET_ARG" =~ /pull/([0-9]+) ]]; then
  TARGET_MODE="pr"; PR_NUMBER="${BASH_REMATCH[1]}"
elif [[ -e "$TARGET_ARG" ]]; then
  TARGET_MODE="path"
elif [[ "$TARGET_ARG" == *".."* ]] || git rev-parse --verify "${TARGET_ARG}^{commit}" >/dev/null 2>&1; then
  TARGET_MODE="ref"
else
  TARGET_MODE="path"
fi

echo "=== 1. Worktree Safety Preflight ==="
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ "$TARGET_MODE" == "path" && -e "$TARGET_ARG" ]]; then
    STATUS_OUT=$(git --no-pager status --short --branch -uall -- "$TARGET_ARG" 2>/dev/null || true)
  else
    STATUS_OUT=$(git --no-pager status --short --branch -uall 2>/dev/null || true)
  fi
  TOTAL_STATUS_LINES=$(printf '%s\n' "$STATUS_OUT" | wc -l | tr -d ' ')
  printf '%s\n' "$STATUS_OUT" | head -n 35 || true
  if [[ "$TOTAL_STATUS_LINES" -gt 35 ]]; then
    echo "... ($((TOTAL_STATUS_LINES - 35)) more worktree entries omitted for context hygiene; all protected)"
  fi
else
  echo "Not inside a git worktree."
fi

echo -e "\n=== 2. Target Metadata & Intent Context ==="
CHANGED_FILES=()
INVENTORY_LINES=()

add_changed_file() {
  local st="$1"
  local fp="$2"
  [[ -z "$fp" ]] && return 0
  INVENTORY_LINES+=("$st	$fp")
  CHANGED_FILES+=("$fp")
}

if [[ "$TARGET_MODE" == "pr" ]]; then
  echo "PR Target: #$PR_NUMBER"
  if ! command -v gh >/dev/null 2>&1; then
    PRECHECK_VERDICT="ERROR"
    PRECHECK_NOTE="gh CLI not installed; cannot read PR #$PR_NUMBER"
  else
    PR_JSON=$(gh pr view "$PR_NUMBER" --json number,title,state,isDraft,headRefOid,baseRefName,author,additions,deletions 2>/dev/null || echo "")
    if [[ -z "$PR_JSON" ]]; then
      PRECHECK_VERDICT="ERROR"
      PRECHECK_NOTE="gh pr view #$PR_NUMBER returned no data; check repo context, network and PR number"
    else
      echo "$PR_JSON"
      PR_STATE_REASON=""
      if echo "$PR_JSON" | grep -q '"state":"CLOSED"\|"state":"MERGED"'; then
        PR_STATE_REASON="PR is already closed or merged"
      elif echo "$PR_JSON" | grep -q '"isDraft":true'; then
        PR_STATE_REASON="PR is a Draft"
      fi
      if [[ -n "$PR_STATE_REASON" ]]; then
        if [[ "$FLAG_FORCE" == "true" ]]; then
          PRECHECK_NOTE="--force overrides: $PR_STATE_REASON"
        else
          PRECHECK_VERDICT="SKIP"
          PRECHECK_NOTE="$PR_STATE_REASON; pass --force to override"
        fi
      fi
      # 带状态的文件清单；失败时退回 name-only，状态统一标 U 强制读全文（安全侧）
      PR_FILES=$(gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER/files" --paginate \
                   --jq '.[] | [.status, .filename] | @tsv' 2>/dev/null || echo "")
      if [[ -n "$PR_FILES" ]]; then
        while IFS=$'\t' read -r st fp; do
          case "$st" in
            added) st="A" ;;
            modified|changed) st="M" ;;
            removed) st="D" ;;
            renamed) st="R" ;;
          esac
          [[ -n "$fp" ]] && add_changed_file "$st" "$fp"
        done <<< "$PR_FILES"
      else
        while IFS= read -r fp; do
          [[ -n "$fp" ]] && add_changed_file "U" "$fp"
        done < <(gh pr diff "$PR_NUMBER" --name-only 2>/dev/null || true)
      fi
    fi
  fi
elif [[ "$TARGET_MODE" == "commit" ]]; then
  echo "Commit Target: $TARGET_ARG"
  git --no-pager show --stat --oneline -n 1 "$TARGET_ARG" 2>/dev/null || true
  while IFS=$'\t' read -r st fp; do
    [[ -n "$fp" ]] && add_changed_file "$st" "$fp"
  done < <(git --no-pager diff-tree --root --no-commit-id --name-status -r "$TARGET_ARG" 2>/dev/null || true)
elif [[ "$TARGET_MODE" == "ref" ]]; then
  if [[ "$TARGET_ARG" == *".."* ]]; then
    RANGE_SPEC="$TARGET_ARG"
  else
    MERGE_BASE=$(git merge-base "$TARGET_ARG" HEAD 2>/dev/null || echo "$TARGET_ARG")
    RANGE_SPEC="$MERGE_BASE..HEAD"
  fi
  echo "Ref Range: $RANGE_SPEC (head=$(git rev-parse --short HEAD 2>/dev/null || echo unknown))"
  git --no-pager log --oneline -n 10 "$RANGE_SPEC" 2>/dev/null || true
  while IFS=$'\t' read -r st fp; do
    [[ -n "$fp" ]] && add_changed_file "$st" "$fp"
  done < <(git --no-pager diff --name-status "$RANGE_SPEC" 2>/dev/null || true)
  if [[ ${#CHANGED_FILES[@]} -eq 0 && "$TARGET_ARG" != *".."* ]]; then
    echo "Range $RANGE_SPEC is empty; falling back to single-commit inspection for $TARGET_ARG"
    git --no-pager show --stat --oneline -n 1 "$TARGET_ARG" 2>/dev/null || true
    while IFS=$'\t' read -r st fp; do
      [[ -n "$fp" ]] && add_changed_file "$st" "$fp"
    done < <(git --no-pager diff-tree --root --no-commit-id --name-status -r "$TARGET_ARG" 2>/dev/null || true)
  fi
elif [[ "$TARGET_MODE" == "path" ]]; then
  echo "Scoped Path Target: $TARGET_ARG"
  git --no-pager log -n 5 --oneline -- "$TARGET_ARG" 2>/dev/null || true
  while IFS=$'\t' read -r st fp; do
    [[ -n "$fp" ]] && add_changed_file "$st" "$fp"
  done < <(git --no-pager diff --name-status HEAD -- "$TARGET_ARG" 2>/dev/null || true)
  while IFS= read -r fp; do
    [[ -n "$fp" ]] && add_changed_file "U" "$fp"
  done < <(git ls-files --others --exclude-standard -- "$TARGET_ARG" 2>/dev/null || true)
  if [[ ${#CHANGED_FILES[@]} -eq 0 && -e "$TARGET_ARG" ]]; then
    if [[ -f "$TARGET_ARG" ]]; then
      add_changed_file "TARGET" "$TARGET_ARG"
    elif [[ -d "$TARGET_ARG" ]]; then
      while IFS= read -r fp; do
        [[ -n "$fp" ]] && add_changed_file "TARGET" "$fp"
      done < <(git ls-files -- "$TARGET_ARG" 2>/dev/null || find "$TARGET_ARG" -maxdepth 3 -type f)
    fi
  fi
else
  while IFS=$'\t' read -r st fp; do
    [[ -n "$fp" ]] && add_changed_file "$st" "$fp"
  done < <(git --no-pager diff --name-status HEAD 2>/dev/null || true)
  while IFS= read -r fp; do
    [[ -n "$fp" ]] && add_changed_file "U" "$fp"
  done < <(git ls-files --others --exclude-standard 2>/dev/null || true)

  if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
    UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "")
    if [[ -n "$UPSTREAM" ]]; then
      echo "Worktree clean; falling back to local commits ahead of $UPSTREAM"
      DIFF_RANGE="$UPSTREAM..HEAD"
      while IFS=$'\t' read -r st fp; do
        [[ -n "$fp" ]] && add_changed_file "$st" "$fp"
      done < <(git --no-pager diff --name-status "$UPSTREAM..HEAD" 2>/dev/null || true)
    fi
  fi
  git --no-pager log -n 5 --oneline 2>/dev/null || echo "No git commits available."
fi

# ---------- 完整文件账本落盘（stdout 只给预览，覆盖率对账读文件） ----------
if [[ ${#INVENTORY_LINES[@]} -eq 0 ]]; then
  : > "$INVENTORY_FILE"
else
  printf '%s\n' "${INVENTORY_LINES[@]}" > "$INVENTORY_FILE"
fi

echo -e "\n=== 3. Reviewable Files Inventory (total=${#INVENTORY_LINES[@]}) ==="
if [[ ${#INVENTORY_LINES[@]} -eq 0 ]]; then
  echo "No changed files detected in resolved scope."
else
  printf '%s\n' "${INVENTORY_LINES[@]:0:60}"
  if [[ ${#INVENTORY_LINES[@]} -gt 60 ]]; then
    echo "... ($(( ${#INVENTORY_LINES[@]} - 60 )) more files; full ledger at $INVENTORY_FILE)"
  fi
fi

if [[ "$PRECHECK_VERDICT" == "ELIGIBLE" && ${#INVENTORY_LINES[@]} -eq 0 ]]; then
  PRECHECK_VERDICT="SKIP"
  PRECHECK_NOTE="no changed files detected in resolved scope"
fi

echo -e "\n=== 4. Scoped Guideline Files (CLAUDE.md / AGENTS.md) ==="
GUIDELINE_LIST=""
append_guideline() {
  local g="$1"
  if [[ -f "$g" ]]; then
    case "
$GUIDELINE_LIST
" in
      *"
$g
"*) ;;
      *) GUIDELINE_LIST="${GUIDELINE_LIST:+$GUIDELINE_LIST
}$g" ;;
    esac
  fi
}

for root_file in "CLAUDE.md" "AGENTS.md"; do
  append_guideline "$root_file"
done

if [[ ${#CHANGED_FILES[@]} -gt 0 ]]; then
  for target_file in "${CHANGED_FILES[@]}"; do
    curr_dir=$(dirname "$target_file")
    while [[ "$curr_dir" != "." && "$curr_dir" != "/" && -n "$curr_dir" ]]; do
      for g_name in "CLAUDE.md" "AGENTS.md"; do
        append_guideline "$curr_dir/$g_name"
      done
      curr_dir=$(dirname "$curr_dir")
    done
  done
fi

if [[ -n "$GUIDELINE_LIST" ]]; then
  printf '%s\n' "$GUIDELINE_LIST"
else
  echo "(none found in scope)"
fi

# ---------- 取数命令 ----------
case "$TARGET_MODE" in
  workspace)
    DIFF_CMD="git --no-pager diff --no-ext-diff --no-textconv --no-color $DIFF_RANGE"
    UNTRACKED_CMD="git ls-files --others --exclude-standard"
    INTENT_CMD="git --no-pager log -n 5 --oneline"
    ;;
  pr)
    DIFF_CMD="gh pr diff $PR_NUMBER --patch --color never"
    UNTRACKED_CMD="(none; remote PR)"
    INTENT_CMD="gh pr view $PR_NUMBER --json title,body,state"
    ;;
  ref)
    DIFF_CMD="git --no-pager diff --no-ext-diff --no-textconv --no-color $RANGE_SPEC"
    UNTRACKED_CMD="(none)"
    INTENT_CMD="git --no-pager log --oneline -n 10 $RANGE_SPEC"
    ;;
  commit)
    DIFF_CMD="git --no-pager show --no-ext-diff --no-textconv --no-color $TARGET_ARG"
    UNTRACKED_CMD="(none)"
    INTENT_CMD="git --no-pager log -1 --format=%B $TARGET_ARG"
    ;;
  path)
    DIFF_CMD="git --no-pager diff --no-ext-diff --no-textconv --no-color HEAD -- $TARGET_ARG"
    UNTRACKED_CMD="git ls-files --others --exclude-standard -- $TARGET_ARG"
    INTENT_CMD="git --no-pager log -n 5 --oneline -- $TARGET_ARG"
    ;;
esac

# ---------- review_plan：主代理只读这一节即可执行 ----------
echo -e "\n=== 5. Review Plan (single source of truth) ==="
echo "precheck_verdict:  $PRECHECK_VERDICT"
echo "precheck_note:     ${PRECHECK_NOTE:-(none)}"
echo "target_mode:       $TARGET_MODE"
echo "target_arg:        ${TARGET_ARG:-<current-workspace>}"
echo "active_tier:       $ACTIVE_TIER ($TIER_SOURCE)"
echo "subagents:         $SUBAGENTS"
echo "verification_pass: $VERIFICATION_PASS"
echo "verification_mode: $VERIFICATION_MODE"
echo "severity_floor:    $SEVERITY_FLOOR"
echo "history_tracking:  $HISTORY_TRACKING"
echo "max_findings:      $ACTIVE_MAX_FINDINGS ($MAX_FINDINGS_SOURCE)"
echo "diff_command:      $DIFF_CMD"
echo "untracked_command: $UNTRACKED_CMD"
echo "intent_command:    $INTENT_CMD"
echo "full_read_codes:   U,A,TARGET"
echo "total_files:       ${#INVENTORY_LINES[@]}"
echo "inventory_file:    $INVENTORY_FILE"
echo "guideline_paths:   ${GUIDELINE_LIST//$'\n'/ }"
echo "actions:           fix=$FLAG_FIX | comment=$FLAG_COMMENT | force=$FLAG_FORCE"
