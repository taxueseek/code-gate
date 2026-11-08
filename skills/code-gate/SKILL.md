---
name: code-gate
description: "工业级代码把关（/code-gate）。对标 Claude Code 内置 /code-review 全部 8 项核心能力，基于第一性原理、奥卡姆剃刀与 MECE 原则内化 code-review（代码柔道与结构简化）、matt-code-review（需求与规范双轴正交）、check（工作树保护、三件套铁证与同型扫）、open-code-review-delegate（确定性工程与 LLM 审查分离）、review-suite（反例自检）与 ai-coding-discipline（AI 编码六大反模式拦截）。默认只读，零噪音交付。"
when_to_use: "code-gate, /code-gate, 代码把关, 把把关, 审查代码, 看看代码, 检查改动, 看diff, 查代码, PR把关, 审PR, diff检查, 合并前把关, 修到绿, check pr, code review, /code-review"
dispatch_intent: "Code review gate for workspace diff, PR, branch, commit, or path; five effort tiers (low/medium/high/xhigh/max) with state persistence; correctness bugs + reuse/simplification/efficiency/AI-discipline; CONFIRMED/PLAUSIBLE verification gate; --fix with fixed/skipped/no_change_needed disposition; --comment inline PR review; --max-findings persistence"
---

# Code-Gate：工业级代码把关

先用一条确定性脚本完成状态持久化、工作树安全预检、作用域解析与文件盘点（零 LLM 消耗），再按 MECE 四象限审查「正确性缺陷」与「需求契约、复用、结构简化、运行效率、AI 编码纪律」，按唯一 `review_plan` 决定编排，经证据链自检后输出报告，最后按需执行 `--fix` 或 `--comment`。编排参数只有一份真源，档位只决定「过几遍、谁过、报多细」，不决定「过哪几套规则」。

---

## 一、 命令接口与 8 项核心能力契约

```bash
/code-gate [low|medium|high|xhigh|max] [target] [--fix|--comment] [--verify] [--max-findings <n|all|default>] [--force]
```

1. **审查对象（Target Scope）**：
   - **默认（不传 target）**：审查当前工作区 Diff（含已暂存 staged、未暂存 unstaged、未跟踪 untracked 文件；若工作树干净但存在领先上游分支的本地提交，自动审领先提交）。
   - **PR 编号或链接**（如 `#123`、`123` 或 PR URL）：只读拉取远端 PR 信息与 Diff，严禁切换本地分支或污染工作树。
   - **分支、区间、标签或提交**（如 `main`、`origin/main..HEAD`、`v1.2.3`、`-c <sha>`）：自动解析 `merge-base` 并提取区间或单次提交 Diff。
   - **文件或目录路径**（如 `src/auth/`）：将 Diff 与未跟踪文件收敛至指定路径；若该路径无未提交改动，则直接对该路径下的现有源码执行把关。
2. **查什么（MECE 四象限，详见 [references/scoring-rubric.md](references/scoring-rubric.md)）**：
   - **主责（Q1 正确性与运行时安全 + Q2 需求契约与范围边界）**：逻辑写反、越界、空指针、竞态与非原子更新、非原子文件覆写、安全汇点注入、上下游调用链破坏、`git blame` 历史保护分支回归，以及对照 PR/Issue 意图的需求漏做、做错或范围漂移（含无用户分化的冗余配置开关、未发布字段的死迁移）。
   - **顺带清理（Q3 复用、简化与效率 + Q4 AI 编码纪律）**：重复造轮子与重复派生、Code Judo 删层简化（消除薄包装、透传层、散落特判与跨过 1,000 行红线的膨胀文件）、无谓串行 `await` 与资源泄漏，以及拦截 AI 六大反模式（`?? 0` 静默兜底、业务层大包大揽 `try/catch` 返回 `null`、迎合测试的硬编码假实现、空心测试断言、未红先绿、调试未确认前混删日志）。
3. **力度五档与持久化（Effort Tiers）**：`low`、`medium`、`high`、`xhigh`、`max` 五档。档位越低只报少量把握极大的致命问题，档位越高覆盖面越广并纳入边界隐患与深层结构建议。不写档位时沿用 `~/.code-gate/state.json` 的持久化档位（首次默认 `medium`）。`max` 档位仅在用户当轮明确写出 `max` 时启用，单次生效、绝不覆写持久化默认档位。**编排细节（子代理清单、复核开关、严重度下限、历史追踪深度）一律以脚本输出的 `review_plan` 为准，本文档不另列映射表。**
4. **复核标记规则（Verification Tags）**：`verification_pass: true` 时（默认由档位决定，或显式传 `--verify`）每条存活发现必须标 `CONFIRMED` 或 `PLAUSIBLE`，被推翻项 `REFUTED` 静默丢弃；`verification_pass: false` 时严禁附带这两个标记。任何档位都可叠加 `--verify` 强制开启复核，`low --verify` 表示「单遍直审 + 追加证据链复核」，不是矛盾组合。
5. **单条发现五要素与排序**：每条发现必含文件路径与行号（`file#Lstart-Lend`）、一句话问题说明、具体怎么出错（什么输入或状态序列触发哪条分支导致什么错误结果，及现有防线为何失效）、可执行修复或简化方案。严格按 `CRITICAL` → `HIGH` → `MEDIUM` → `LOW` 排序。
6. **`--fix` 闭环修复与三态回报**：审完后直接修改工作区（含同型缺陷全仓检索与本地验证命令最多 3 轮收敛），随后逐条回报 `fixed`、`skipped`、`no_change_needed`。与 `--comment` 互斥，脚本会拒绝同时传入。
7. **`--comment` 远端 PR 逐行评论**：二次校验 PR 未关闭、未合并且 HEAD SHA 未漂移后，把每条发现作为逐行行内评论发到 PR 上，附 40 位完整 SHA 链接与 5 行内 `suggestion` 块。
8. **`--max-findings <n|all|default>` 限制与持久化**：按严重度排序后最多报告前 `<n>` 条；`all` 表示全部报出；`default` 重置为 `all`。该设置持久化保存在 `~/.code-gate/state.json` 中。

---

## 二、 四步执行流

严禁为文件盘点、状态读取或 PR 状态查询派生 LLM 子代理。确定性工程与模型推理严格分离：

```
Step 1: 确定性底座（scripts/extract-review-scope.sh）单条 Bash，0 Token
   ├─ 状态持久化 / 工作树安全预检 / 目标识别与 PR 准入
   ├─ 完整变更文件账本（status, path）与 scoped CLAUDE.md / AGENTS.md
   └─ 输出唯一 review_plan（precheck_verdict、档位编排、取数命令、total_files）
          │
          ▼
Step 2: 按 review_plan 取数并审查（Core Review Pass）
   ├─ diff_command / untracked_command / intent_command 三条命令取上下文
   ├─ subagents: none -> 主代理单遍；否则按清单并发派发正交子代理
   └─ 四象限清单见 scoring-rubric.md，子代理模板见 subagent-prompts.md
          │
          ▼
Step 3: 证据链自检（单张漏斗，见 negative-filters.md）
   └─ 候选 -> 过滤 -> 三件套 -> verification_pass ? 四问抗辩 + 标记 : 直出
          │
          ▼
Step 4: 排序截断、报告输出与动作执行（见 action-modes.md）
```

### Step 1：运行确定性作用域脚本（必跑第一步）

开局直接运行脚本（用户参数原样传入）。脚本与本文件同处一个 skill 目录：`SKILL.md` 同级就是 `scripts/extract-review-scope.sh`，因此按本文件的**实际安装位置**解析根目录，不绑定任何固定家目录：

```bash
# SKILL_ROOT 即本 SKILL.md 所在目录（读入本文件时即已知其绝对路径）
SKILL_ROOT="${CODE_GATE_SKILL_ROOT:-<skill-root>}"
bash "$SKILL_ROOT/scripts/extract-review-scope.sh" [args...]
```

常见安装位置仅供定位参考，不影响执行：`npx skills add` 装到 `$HOME/.agents/skills/code-gate`；Claude Code 的发现根是 `$HOME/.claude/skills/code-gate`（指向同一份真源的软链）。skill 装在别处时用 `CODE_GATE_SKILL_ROOT` 指向其根目录即可。**脚本与本文档均不得出现任何绝对路径或用户名**，换机器、换仓库、换安装位置均可直接运行。

**准入判定（fail-closed）**：`review_plan` 的 `precheck_verdict` 恒为三态之一：

- `ELIGIBLE`：正常进入 Step 2。
- `SKIP`：PR 为 Draft 或已关闭合并，或作用域内 0 文件；仅 `SKIP` 可被 `--force` 覆盖。
- `ERROR`：`gh` 缺失或 PR 取数失败，说明见 `precheck_note`。**`ERROR` 不可被 `--force` 覆盖**，直接输出 `status:` 说明原因并结束。

PR 取数失败时不再静默给空账本；`--force` 的作用域仅限 PR 状态类 SKIP，不影响工作树保护、0 文件与 ERROR。

**工作树资产保护铁律**：严禁执行 `git checkout`、`git switch`、`git reset --hard`、`git stash`、`git clean` 或 `gh pr checkout`；严禁把未跟踪文件挪入 `/tmp`。

**可选 `ocr` 规则联动**：若目标仓库存在 `.opencodereview/rule.json` 且本机装有 `ocr`，可按需调用 `ocr delegate rule --format json <files>` 合并项目自定义规则，无需配置外部 LLM。

### Step 2：按 `review_plan` 取数并审查

- 直接用 `review_plan` 的 `diff_command`、`untracked_command`、`intent_command`，不要自己拼 `git diff`；三条命令已统一加 `--no-pager` 与 `--no-ext-diff --no-textconv --no-color`。
- 状态码为 `U`（未跟踪）、`A`（PR 新增）、`TARGET`（路径目标）的文件按 `full_read_codes` 直接读取全文，避免只看 diff 漏掉上下文。
- 对超大 Diff 按文件分批读取。**覆盖率对账**：账本完整落盘在 `inventory_file`（TSV），stdout 只给前 60 行预览；审查结束前以 `total_files` 与 `inventory_file` 行数核对实际已审文件数，禁止因截断漏审文件，未读完必须如实标注。
- 四象限清单见 [references/scoring-rubric.md](references/scoring-rubric.md)；子代理模板见 [references/subagent-prompts.md](references/subagent-prompts.md)，其 `{{...}}` 占位符全部由 `review_plan` 字段填充。

### Step 3：证据链自检（单张漏斗）

[references/negative-filters.md](references/negative-filters.md) 定义一条漏斗：八不报过滤 → 三件套铁证 → （`verification_pass: true` 时）四问抗辩与标记 → 存活发现。三部分描述的是同一条证据链的三个视角，不视为三套独立规则：

1. **八不报过滤**：存量旧账、全链路已保护的假警报、纯品味 Nitpicks、编译器或 Linter 必拦项、无规约原文的宽泛说教、代码已显式标注豁免项、与作者声明意图一致的刻意改造、未被 Diff 触及且无调用交集的无关代码，命中任一即静默丢弃。
2. **三件套铁证**：每条 `CRITICAL` 与 `HIGH` 发现必须同时具备精确 `file#Lstart-Lend`、触发错误的具体输入或状态序列、为何现有防线拦不住；缺一则降级或丢弃。
3. **四问抗辩与标记**：`verification_pass: true` 时逐条站在作者立场抗辩，存活项显式标注 `CONFIRMED` 或 `PLAUSIBLE`，`REFUTED` 静默丢弃；`verification_pass: false` 时直出且严禁附加标记。
4. **本地模式备注**：八不报第 1 条允许「极高危存量隐患」在本地报告模式以末尾独立一行 `pre-existing notes:` 呈现（PR 评论模式绝对剔除），格式见 [references/action-modes.md](references/action-modes.md)。这是唯一允许出现在正式发现列表之外的备注，绝不混入发现列表。

### Step 4：输出报告与执行动作

详见 [references/action-modes.md](references/action-modes.md)。

- **诚实边界**：未在本轮实际运行过的测试或构建命令，台账中如实写 `not run (based on reading the code)`，严禁伪造 `pass`。
- **零发现也是完备交付**：若过滤后无发现，直接输出 `status: clean review (0 issues found)` 与已核查范围，绝不凑数。

---

## 三、 终端收尾台账（Sign-Off Ledger）

每次审查结束时，首行输出 `status:`，文末以精炼台账收尾：

```markdown
status:           [clean review (0 issues found) | N issues found (X confirmed, Y plausible) | N issues found | fix completed (A fixed, B skipped, C no_change_needed)]
target & scope:   [workspace / PR #N / ref / path] — N files reviewed (+X -Y), 0 skipped
effort tier:      [low / medium / high / xhigh / max] ([persisted / explicit / one-shot])
max-findings:     [all / N (showing top N of M)]
verification:     [command -> pass/fail | not run (based on reading the code)]
actions:          [report-only | --fix: A fixed, B skipped, C no_change_needed | --comment: N inline comments posted]
```

本地报告模式若存在存量高危备注，在台账之后另起一行 `pre-existing notes:`，不计入 `N issues found`。
