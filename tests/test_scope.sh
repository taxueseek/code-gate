#!/usr/bin/env bash
# test_scope.sh — 作用域脚本冒烟：三态准入、档位映射、单次档位、持久化与互斥参数。
# 全部在临时仓库与临时状态目录内运行，不触碰真实 ~/.code-gate。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/skills/code-gate/scripts/extract-review-scope.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CODE_GATE_STATE_DIR="$TMP/state"
mkdir -p "$CODE_GATE_STATE_DIR"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() { grep -qE "$2" <<<"$1" || fail "$3"; }

[[ -f "$SCRIPT" ]] || fail "missing script: $SCRIPT"

REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "code-gate-smoke"
git -C "$REPO" config user.name "smoke"
printf 'a\n' >"$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -qm "init"

# 1. 工作区干净 -> SKIP，且说明原因
out="$(cd "$REPO" && bash "$SCRIPT")"
expect "$out" '^precheck_verdict: +SKIP$' "clean worktree should be SKIP"
expect "$out" 'no changed files detected' "SKIP note missing"

# 2. 已改 + 未跟踪 -> ELIGIBLE，账本与计数对账
printf 'b\n' >"$REPO/b.txt"
printf 'a2\n' >"$REPO/a.txt"
out="$(cd "$REPO" && bash "$SCRIPT")"
expect "$out" '^precheck_verdict: +ELIGIBLE$' "dirty worktree should be ELIGIBLE"
expect "$out" '^total_files: +2$' "expected 2 reviewable files"
expect "$out" '^full_read_codes: +U,A,TARGET$' "full_read_codes contract changed"
expect "$out" '^target_mode: +workspace$' "default target should be workspace"
inv="$(sed -n 's/^inventory_file: *//p' <<<"$out")"
[[ -f "$inv" ]] || fail "inventory ledger not written"
[[ "$(wc -l <"$inv" | tr -d ' ')" == "2" ]] || fail "inventory ledger should hold 2 rows"

# 3. 档位映射：high / xhigh / max 的编排字段
out="$(cd "$REPO" && bash "$SCRIPT" --tier high)"
expect "$out" '^subagents: +correctness-spec,structure-ai$' "high subagent set changed"
expect "$out" '^verification_pass: +true$' "high should verify"
expect "$out" '^severity_floor: +MEDIUM$' "high severity floor changed"
expect "$out" '^history_tracking: +shallow$' "high history depth changed"

out="$(cd "$REPO" && bash "$SCRIPT" --tier xhigh)"
expect "$out" '^active_tier: +xhigh \(explicit \(persisted\)\)$' "xhigh not persisted"
expect "$out" '^subagents: +correctness-spec,structure-ai,history$' "xhigh subagent set changed"
expect "$out" '^severity_floor: +LOW$' "xhigh severity floor changed"
expect "$out" '^history_tracking: +deep$' "xhigh history depth changed"
expect "$out" '^verification_mode: +centralized$' "non-max verification mode changed"

# 4. max 单次生效，绝不覆写持久化档位
out="$(cd "$REPO" && bash "$SCRIPT" max)"
expect "$out" '^active_tier: +max \(explicit \(one-shot' "max should be one-shot"
expect "$out" '^subagents: +correctness-spec,structure-ai,history,adversarial$' "max subagent set changed"
expect "$out" '^verification_mode: +per-finding$' "max verification mode changed"
out="$(cd "$REPO" && bash "$SCRIPT")"
expect "$out" '^active_tier: +xhigh \(persisted\)$' "max overwrote the persisted tier"

# 5. --max-findings 持久化与 reset
out="$(cd "$REPO" && bash "$SCRIPT" --max-findings 3)"
expect "$out" '^max_findings: +3 \(explicit \(persisted\)\)$' "max-findings not persisted"
out="$(cd "$REPO" && bash "$SCRIPT" --max-findings default)"
expect "$out" '^max_findings: +all \(reset-to-default' "max-findings default should reset to all"

# 6. 互斥与非法参数 fail-closed
(cd "$REPO" && bash "$SCRIPT" --fix --comment) >/dev/null 2>&1 && fail "--fix and --comment must be rejected together"
(cd "$REPO" && bash "$SCRIPT" --tier turbo) >/dev/null 2>&1 && fail "invalid tier must be rejected"
(cd "$REPO" && bash "$SCRIPT" --max-findings 0) >/dev/null 2>&1 && fail "--max-findings 0 must be rejected"
(cd "$REPO" && bash "$SCRIPT" -c) >/dev/null 2>&1 && fail "-c without a SHA must be rejected"

# 7. 路径目标模式：作用域收敛到子目录
mkdir -p "$REPO/src"
printf 'x\n' >"$REPO/src/x.txt"
out="$(cd "$REPO" && bash "$SCRIPT" src)"
expect "$out" '^target_mode: +path$' "path target should resolve to path mode"
expect "$out" '^total_files: +1$' "path target should scope to a single file"

# 8. 提交目标模式：-c <sha> 解析为单次提交
sha="$(git -C "$REPO" rev-parse HEAD)"
out="$(cd "$REPO" && bash "$SCRIPT" -c "$sha")"
expect "$out" '^target_mode: +commit$' "-c should resolve to commit mode"
expect "$out" '^precheck_verdict: +ELIGIBLE$' "commit mode should stay ELIGIBLE"

echo "test_scope: ok"
