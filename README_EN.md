<div align="center">
  <img src="https://raw.githubusercontent.com/taxueseek/code-gate/main/assets/logo.svg" width="110" />
  <h1>code-gate</h1>
  <p><b>Industrial-grade code review for coding agents. One command, one clean verdict.</b></p>
  <p><a href="README.md">中文</a> · English</p>
  <a href="https://github.com/taxueseek/code-gate/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/taxueseek/code-gate/test.yml?branch=main&style=flat-square&label=tests" alt="Tests"></a>
  <a href="https://github.com/taxueseek/code-gate/releases"><img src="https://img.shields.io/github/v/tag/taxueseek/code-gate?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="License"></a>
</div>

<br/>

## What it is

`code-gate` is a code review skill for coding agents. It does one thing: review the change in front of you and hand back a verdict.

The split is deliberate. Scope resolution, worktree preflight, PR state lookup, file inventory, and diff command generation are deterministic work, so one shell script does them with zero LLM tokens. Judgment goes to the model. Nothing is spent before the review starts, and every token goes into "can this line fail".

Skill content is written in Chinese; commands, fields, and identifiers stay English.

## Install

```bash
npx skills add taxueseek/code-gate -g -y
```

Lands in `~/.agents/skills/code-gate` and is picked up by Claude Code, Codex, Cursor, Gemini CLI, Copilot, and every other agent that reads that directory. Update with `npx skills update -g -y`.

Claude Code plugin marketplace:

```
/plugin marketplace add taxueseek/code-gate
/plugin install code-gate@code-gate
```

Or clone and copy `skills/code-gate` into your agent's skills directory.

Requires `bash` 3.2+ and `git`. Reviewing a remote PR requires `gh`; without it the run stops with an explicit `ERROR` instead of pretending to have reviewed anything.

## Usage

```bash
/code-gate                                # current workspace change (staged + unstaged + untracked)
/code-gate #123                           # remote PR, read-only, your branch is never touched
/code-gate main..HEAD                     # branch range (merge-base resolved for you)
/code-gate -c 1a2b3c4                     # a single commit
/code-gate high src/auth/                 # high effort, scoped to a directory
/code-gate xhigh --verify --fix           # verify, then fix in place with per-item disposition
/code-gate max --comment                  # adversarial pass, per-finding verification, inline PR comments
```

## What it reviews

Correctness first, simplification second. Four mutually exclusive quadrants; every finding belongs to exactly one.

| Quadrant | Weight | Typical findings |
| :--- | :--- | :--- |
| Q1 Correctness & runtime safety | Primary | Reversed conditions, off-by-one, null dereference; races and non-atomic updates; non-atomic file overwrite; injection and hardcoded credentials; signature changed without updating callers |
| Q2 Spec & scope alignment | Primary | Requirement missing or inverted; unrelated refactors riding along; config knobs with no real user split; migrations for never-shipped fields; verbatim `AGENTS.md` / `CLAUDE.md` violations |
| Q3 Reuse, simplification, efficiency | Secondary | Reinvented utilities and duplicated derivations; thin wrappers and scattered special cases that should be deleted; the 1,000-line smell; needless sequential `await`, leaked handles on error paths |
| Q4 AI coding discipline & test fidelity | Secondary | `?? 0` silent fallbacks; catch-all `try/catch` returning `null`; hardcoded returns fitted to tests; `toBeDefined()`-only assertions; diagnostic logs removed before the bug is confirmed |

## Effort tiers

A tier decides how many passes, who runs them, and how much is reported. It never changes which rules apply.

| Tier | Subagents | Verification gate | Severity floor | History tracking |
| :--- | :--- | :--- | :--- | :--- |
| `low` | main agent, single pass | off | CRITICAL / HIGH | none |
| `medium` (first-run default) | main agent, single pass | off | CRITICAL / HIGH / MEDIUM | none |
| `high` | correctness/spec + structure/reuse | on | all three | targeted `git blame` |
| `xhigh` | plus cross-file history | on | everything | deep |
| `max` | plus adversarial attacker | on, per-finding | everything | deep |

Omit the tier and the persisted one in `~/.code-gate/state.json` is used. `max` runs only when you write it in the current turn, is one-shot, and never overwrites your default.

## Why the findings hold up

One false positive teaches a reader to ignore the real defect, so the funnel removes noise before output:

**Eight negative filters.** Pre-existing issues on untouched lines, alarms already protected upstream, cosmetic nitpicks, anything a compiler or linter will catch, vague advice without a verbatim rule quote, explicitly suppressed rules, intentional behavior the author declared, and unrelated code with no call-path intersection. Any hit is dropped silently.

**Three-part evidence.** Every `CRITICAL` and `HIGH` must carry an exact line range, the concrete input or state sequence that triggers the failure, and why existing guards fail. Missing one drops or downgrades the finding.

**Four-point skeptic pass.** With verification on, each candidate is attacked from the author's side: upstream guard, type-system guard, framework default, rule and intent validity. Survivors are tagged `CONFIRMED` or `PLAUSIBLE`; `REFUTED` findings are dropped and never reach the report.

**A clean review is a complete delivery.** With nothing left after filtering the report says `status: clean review (0 issues found)` plus the reviewed scope. Nothing is invented to fill space.

## Safety

- Read-only by default. `--fix` writes your worktree, `--comment` posts to a remote PR, they are mutually exclusive, and the script rejects both in one call.
- Never runs `git checkout`, `switch`, `reset --hard`, `stash`, `clean`, or `gh pr checkout`; untracked files are never moved to `/tmp`.
- `--fix` runs a fast check after patching and converges within 3 rounds; if it cannot, it restores the files it touched and marks the item `skipped` with the root cause, leaving your own uncommitted work alone.
- Per-item disposition is always `fixed`, `skipped`, or `no_change_needed`, and test results that were not actually run are reported as `not run (based on reading the code)`.

## Repository layout

| Path | Purpose |
| :--- | :--- |
| [skills/code-gate/SKILL.md](skills/code-gate/SKILL.md) | Skill entry: command contract, four-step flow, sign-off ledger |
| [skills/code-gate/references/](skills/code-gate/references/) | Loaded on demand: quadrant matrix, evidence funnel, action modes, subagent specs |
| [skills/code-gate/scripts/extract-review-scope.sh](skills/code-gate/scripts/extract-review-scope.sh) | Deterministic base: state, preflight, target resolution, inventory, single `review_plan` |
| [scripts/verify_release.py](scripts/verify_release.py) | Release checks: frontmatter, manifest/version agreement, internal links, privacy shapes |
| [tests/test_scope.sh](tests/test_scope.sh) | Scope-script smoke: eligibility states, tier mapping, one-shot tier, conflicting flags |
| [SCOPE.md](SCOPE.md) | What belongs here and what does not |
| [AGENTS.md](AGENTS.md) | Contribution and maintenance invariants |

## License

MIT, see [LICENSE](LICENSE).
