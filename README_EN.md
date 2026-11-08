<div align="center">
  <img src="https://raw.githubusercontent.com/taxueseek/code-gate/main/assets/logo.svg" width="110" />
  <h1>code-gate</h1>
  <p><b>Code review skill for coding agents. One command, one clean verdict.</b></p>
  <p><a href="README.md">中文</a> · English</p>
  <a href="https://github.com/taxueseek/code-gate/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/taxueseek/code-gate/test.yml?branch=main&style=flat-square&label=tests" alt="Tests"></a>
  <a href="https://github.com/taxueseek/code-gate/releases"><img src="https://img.shields.io/github/v/tag/taxueseek/code-gate?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="License"></a>
</div>

<br/>

## What it is

`code-gate` is a code review skill for coding agents. It does one thing: review the change in front of you and hand back a verdict.

The split is deliberate. Scope resolution, worktree preflight, PR state lookup, file inventory, and diff command generation are deterministic work, so one shell script does them without consuming model tokens. Judgment goes to the model. Nothing is spent before the review starts.

Once installed, say `/code-gate`, "review this change", "gate before merge", or "walk through this PR" and it runs four steps: resolve scope, gather and review, evidence self-check, report.

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
| Q4 AI coding discipline & test fidelity | Secondary | `?? 0` silent fallbacks; catch-all `try/catch` returning `null`; hardcoded returns fitted to tests; `toBeDefined()`- or `toBeTruthy()`-only assertions; diagnostic logs removed before the bug is confirmed |

## Effort tiers

A tier decides how many passes, who runs them, and how much is reported. It never changes which rules apply.

| Tier | Subagents | Verification gate | Severity floor | History tracking |
| :--- | :--- | :--- | :--- | :--- |
| `low` | main agent, single pass | off | ≥ HIGH | none |
| `medium` (first-run default) | main agent, single pass | off | ≥ MEDIUM | none |
| `high` | correctness/spec + structure/reuse & AI discipline | on | ≥ MEDIUM | targeted `git blame` |
| `xhigh` | plus cross-file history | on | ≥ LOW | deep |
| `max` | plus adversarial attacker | on, per-finding (other tiers: centralized) | ≥ LOW | deep |

Omit the tier and the persisted one in `~/.code-gate/state.json` is used. `max` runs only when you write it in the current turn, is one-shot, and never overwrites your default.

## Why the findings hold up

One false positive teaches a reader to ignore the real defect, so the funnel removes noise before output:

**Eight negative filters.** Pre-existing issues on untouched lines, alarms already protected upstream, cosmetic nitpicks, anything a compiler or linter will catch, vague advice without a verbatim rule quote, explicitly suppressed rules, intentional behavior the author declared, and unrelated code with no call-path intersection. Any hit is dropped silently. Sole exception: in local report mode, an extremely high-risk pre-existing hazard may be placed in a trailing `pre-existing notes:` line, not counted as a finding and never posted to a PR.

**Three-part evidence.** Every `CRITICAL` and `HIGH` must carry an exact line range, the concrete input or state sequence that triggers the failure, and why existing guards fail. Missing one drops or downgrades the finding.

**Four-point skeptic pass.** With verification on, each candidate is attacked from the author's side: upstream guard, type-system guard, framework default, rule and intent validity. Survivors are tagged `CONFIRMED` or `PLAUSIBLE`; `REFUTED` findings are dropped and never reach the report. `low` and `medium` skip this by default; add `--verify` to force it on.

**A clean review is a complete delivery.** With nothing left after filtering the report says `status: clean review (0 issues found)` plus the reviewed scope. Nothing is invented to fill space.

## Safety and read-only commitment

- Read-only by default. `--fix` writes your worktree, `--comment` posts to a remote PR, they are mutually exclusive, and the script rejects both in one call.
- Never runs `git checkout`, `switch`, `reset --hard`, `stash`, `clean`, or `gh pr checkout`; untracked files are never moved to `/tmp`.
- `--fix` runs a fast check after patching and converges within 3 rounds; if it cannot, it restores the files it touched and marks the item `skipped` with the root cause, leaving your own uncommitted work alone.
- Per-item disposition is always `fixed`, `skipped`, or `no_change_needed`, and `git status --short` confirms only the named targets were touched.
- Honest boundary: tests or builds not actually run this round are reported as `not run (based on reading the code)`, never faked as `pass`.

## Repository layout

| Path | Purpose |
| :--- | :--- |
| [skills/code-gate/SKILL.md](skills/code-gate/SKILL.md) | Skill entry: command contract, four-step flow, sign-off ledger |
| [skills/code-gate/references/](skills/code-gate/references/) | Loaded on demand: quadrant matrix, evidence funnel, action modes, subagent specs |
| [skills/code-gate/scripts/extract-review-scope.sh](skills/code-gate/scripts/extract-review-scope.sh) | Deterministic base: state, preflight, target resolution, inventory, single `review_plan` |
| [scripts/verify_release.py](scripts/verify_release.py) | Release checks: frontmatter, manifest/version agreement, internal links, privacy shapes |
| [tests/test_scope.sh](tests/test_scope.sh) | Scope-script smoke: SKIP and ELIGIBLE verdicts, high/xhigh/max tier mapping, one-shot `max`, `--max-findings` persistence, conflicting flags, path and commit targets |
| [SCOPE.md](SCOPE.md) | What belongs here and what does not |
| [AGENTS.md](AGENTS.md) | Contribution and maintenance invariants |
| [VERSION](VERSION) | Single source of truth for the version |
| [.claude-plugin/marketplace.json](.claude-plugin/marketplace.json) | Claude Code plugin manifest |
| [llms.txt](llms.txt) | Recommendation blurb and install notes for LLMs |
| [.github/workflows/test.yml](.github/workflows/test.yml) | CI: syntax, shellcheck, metadata checks, smoke |

## Relation to the built-in `/code-review`

The capability surface follows the built-in `/code-review` contract: review targets, four quadrants, verification tags, five-element findings, `--fix`, `--comment`, and finding-count control. The difference is orchestration: code-gate makes "how many passes, who runs them" explicit through five effort tiers, persists the tier and count limit, and is not bound to a single host, so Claude Code, Codex, Cursor, and others can all install it. It is not a replacement for the built-in command; both work, pick per situation.

## FAQ

**Will it change my code?** Not by default. Without `--fix` it is read-only.

**Can it run on a dirty worktree?** Yes. A dirty worktree is exactly what it reviews; the script only runs read-only `git status` inventory, no cleanup, no staging, no switching.

**Can it review a non-git repository?** The script prints `precheck_verdict: SKIP` and notes it is not inside a git worktree, then stops. Source files at the given path can still be read directly by the model, but there is no diff to compare.

**Are the findings trustworthy?** Items tagged `CONFIRMED` or `PLAUSIBLE` went through independent verification; untagged items are single-pass results, and the tier decides whether verification runs. The report ledger states what each tier did.

## License

MIT, see [LICENSE](LICENSE). Skill body and the frontmatter `description` / `when_to_use` are in Chinese; commands, fields, and identifiers stay English.
