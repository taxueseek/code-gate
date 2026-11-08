# MECE 审查矩阵与证据链自检规范

本文件定义 `code-gate` 的两项核心判断标准：
1. **查什么（MECE 四象限审查矩阵）**：以正确性缺陷为主责，顺带覆盖需求契约、复用与结构简化（Code Judo）、运行效率及 AI 编码纪律。
2. **怎么复核（单张证据链漏斗）**：区分「单遍直审（无标记）」与「复核门禁（标 `CONFIRMED` 或 `PLAUSIBLE`）」，用最小复杂度实现高信噪比。

**编排参数不在本文件定义**：档位决定哪些子代理、是否复核、报多细、历史追踪多深，全部由 `../scripts/extract-review-scope.sh` 输出的 `review_plan` 唯一提供。本文件只描述每个象限「审什么」与复核「怎么判」。

---

## 一、 MECE 四象限审查矩阵（What to Check）

审查按主次分为两大主轴、四个互斥穷尽（MECE）象限。任何一条发现必归属且仅归属其中一个象限。象限只按「缺陷性质」切分，不按「谁去查」切分；档位编排（如历史分析子代理）是横切关注点，可同时服务 Q1 与 Q2。

### 象限 Q1：正确性与运行时安全（Correctness & Runtime Safety —— 第一主责）
聚焦会导致错误结果、崩溃、数据损坏、安全漏洞或调用方回归的真实缺陷：
1. **逻辑与边界硬伤**：条件写反、Off-by-one 越界、未校验的空指针或 `undefined` 解引用、除零或数值溢出。
2. **并发、时序与原子性**：
   - 异步竞态（Race Condition）：乱序返回导致脏状态覆盖。
   - 半应用状态（Non-atomic Update）：多步状态更新在中途异常退出时留下不一致状态。
   - **非原子文件覆写**：直接对既有用户文件执行截断写入（如 `>`、`curl -o`、直接打开覆写），中途失败即损毁原文件；必须先写同目录临时文件再原子替换，并处理中断信号。
   - **硬编码等待替代完成信号**：用固定 `sleep`、`setTimeout` 或帧数猜测代替真实的回调、状态标志或完成事件。
3. **安全与破坏性汇点（Safety Sinks）**：
   - SQL、Shell、路径遍历注入与硬编码凭据。
   - **破坏性匹配过宽**：递归删除、批量清理或通配符分支中，用展示名、前缀或宽泛正则代替精确 ID 与受保护路径白名单。
4. **上下游契约破坏**：修改函数签名、返回形状或副作用后，未同步更新上游调用方或下游消费方；违背代码旁显式标注的 `// SAFETY:`、`// INVARIANT:` 或 Docstring 契约。

> 历史演进核查（`git blame` 保护分支回归、隐式不变量）属于横切关注点，由 `review_plan.history_tracking` 决定投入深度：`none` 时仅在 diff 明显删除保护分支时顺手核查，`shallow` 时对被删关键行做定向 `blame`，`deep` 时全量跨文件调用链追踪。它本身不是象限，结论按性质归入 Q1（回归缺陷）或 Q2（违背作者声明的规约）。

### 象限 Q2：需求契约与范围边界（Spec & Scope Alignment —— 源自 `matt-code-review` 与 `check`）
先回答「改得对不对题」，再看局部代码：
1. **需求漏做或做错（Spec Mismatch）**：对照 PR 描述、关联 Issue 或提交意图，排查要求实现的功能缺失、只做了一半或行为与规格相反。
2. **范围漂移（Scope Drift）**：每个被改文件与新增公开接口必须能一句话归因到本次目标；夹带无关重构、未声明的依赖变更或静默改变对外默认行为均属漂移。
3. **无分化配置开关（Unused Knobs）**：新增配置项、环境变量或布尔参数，但不存在真实的用户群体分化（本应直接修默认路径）。
4. **未发布迁移死码（Never-Shipped Migrations）**：对从未在任何已发布 Tag 中上线过的新字段编写向后兼容或旧键迁移逻辑。
5. **规约违背（Scoped Standards）**：逐字违反变更文件路径父级目录链上生效的 `CLAUDE.md`、`AGENTS.md` 条款，必须附原文引用。

### 象限 Q3：复用、结构简化与效率（Reuse, Code Judo & Efficiency —— 源自 `code-review`）
在保证正确性的前提下，推动代码结构做减法：
1. **复用与归属层位（Reuse & Canonical Layer）**：
   - **重复造轮子**：仓库已有标准工具函数或组件，却在局部手搓近似副本。
   - **重复派生（Duplicated Derivations）**：同一分类、排序、阈值或资格判断在两处独立计算（改动一处即与另一处失步）。
   - **层位泄漏**：业务特判漏进通用底层模块，或实现细节穿透公共 API。
2. **代码柔道与结构简化（Code Judo & Simplification）**：
   - **删层优先**：识别可通过重述状态模型让整条条件分支、薄包装（`Middle Man`）、透传层或预留泛化（`Speculative Generality`）直接消失的重构路径。
   - **条件蔓延（Spaghetti Growth）**：往已繁忙的主流程里硬插一次性布尔旗标或散落特判（`Repeated Switches`、`Shotgun Surgery`）。
   - **千行红线（1,000-Line Smell）**：变更将文件从 1,000 行以下推过 1,000 行且未做职责拆分。
3. **运行效率与资源生命周期（Efficiency）**：
   - 明显互不依赖的异步 I/O 被无谓串行 `await`。
   - 热路径中的 N+1 查询、循环内重复编译正则或深拷贝。
   - 异常分支或提前返回路径上未关闭文件句柄、锁、定时器或订阅。

### 象限 Q4：AI 编码纪律与测试真实度（AI Discipline & Test Fidelity —— 源自 `ai-coding-discipline`）
专门拦截 AI 生成代码的高频反模式：
1. **静默兜底掩盖契约违背（No Silent Fallbacks）**：在数据契约不允许缺失处滥用 `?? 0`、`|| "Unknown"` 或 `?.` 掩盖上游缺陷，而非立即抛出明确错误（Fail Fast）。
2. **业务逻辑大包大揽吞异常（No Catch-All `try/catch`）**：在领域或业务函数内用 `try/catch` 吞掉所有异常并返回 `null`、`false` 或空对象（应在路由或控制器边界统一捕获）。
3. **迎合测试的硬编码假实现（No Lookup-Table Fakes）**：用 `if (amount === 1000) return 100` 等硬编码分支凑过测试断言，而非实现真实算法。
4. **空心测试与未红先绿（Test Surface Fidelity）**：
   - 断言仅检查 `toBeDefined()`、`toBeTruthy()`，删掉核心逻辑仍能通过。
   - 早退分支、可选依赖缺失跳过或空输出恰好让断言空转通过（Hollow Green）。
   - 负向断言（「不得包含 X」）缺少能证伪它的正例。
   - 在调试未获确认前，将诊断日志清理与未验证的修复混在同一提交中。

---

## 二、 证据链自检漏斗（Verification Funnel）

摒弃虚假精确的百分制打分，直接按**是否执行了独立复核环节**与**证据确凿度**定性。八不报、三件套、四问抗辩不是三套独立规则，而是同一条证据链的三个视角：

```
候选发现
  -> [过滤] 八不报铁律（negative-filters.md 第一节）：命中即静默丢弃
  -> [铁证] 三件套：CRITICAL / HIGH 缺任一要素则降级或丢弃
  -> [抗辩] verification_pass: true 时走四问抗辩，标 CONFIRMED / PLAUSIBLE，REFUTED 丢弃
            verification_pass: false 时直出，严禁标记
  -> 存活发现（按严重度排序，见 action-modes.md）
```

### 1. 标记触发条件
- **单遍直审模式（Direct Single-Pass）**：`verification_pass: false`。只做一遍直接审查，依靠八不报与三件套过滤噪音，输出中不带 `CONFIRMED` 或 `PLAUSIBLE` 标记。
- **独立复核模式（Verified Pass）**：`verification_pass: true`。对初筛产出的每条候选发现执行四问抗辩复核，存活项必须逐条标注 `CONFIRMED` 或 `PLAUSIBLE`，被推翻项 `REFUTED` 静默丢弃。

是否开启由 `review_plan.verification_pass` 决定（档位默认 + 显式 `--verify` 叠加，任何档位都可强制开启）；复核派发方式由 `review_plan.verification_mode` 决定（`centralized` 集中抗辩 / `per-finding` 逐条独立复核）。

### 2. 三态裁决标准（仅复核模式启用）
- **`CONFIRMED`（确认）**：铁证如山。在给定输入或状态序列下必然触发错误结果、崩溃、安全漏洞，或逐字违反当前文件父级目录链上的规约明确条款，且四问抗辩确认现有防线无法拦截。
- **`PLAUSIBLE`（可能）**：推导严密但依赖特定外部时序、极端高并发负载、未声明的上游边界输入，或属于高价值的 Code Judo 结构简化与复用改进建议。
- **`REFUTED`（推翻 -> 静默丢弃）**：经重读源码与上下游链路后发现不成立、已被他处拦截，或命中八不报铁律。**严禁出现在终端报告或 PR 评论中。**

### 3. 四问抗辩清单（4-Point Skeptic Checklist）
复核环节必须站在代码作者立场，尝试用以下四问推翻每一条候选发现：
1. **重读源码与上游守卫（Upstream Guard）**：重读被引代码行及全部调用点，该非法输入在进入当前函数前是否已被路由中间件、Schema 校验器（如 Zod、Pydantic）或前置守卫拦截？
2. **类型与编译期保障（Type System Guard）**：静态类型系统（TypeScript 严格模式、Rust、Go、Java）是否在编译期已排除该 `null`、`undefined` 或非法状态？
3. **框架与运行时契约（Framework Default）**：底层框架是否自动管理该事务回滚、资源释放或全局异常转换，使其属于预期内的标准受控响应？
4. **规约与设计意图适格性（Rule & Intent Validity）**：若指控违反规范，是否原文字面引用了当前路径生效的 `CLAUDE.md`、`AGENTS.md` 条款？若指控破坏旧行为，是否本就是作者在 PR 或 Commit 中明确声明的刻意改造？

---

## 三、 档位与报告粒度的唯一真源

档位表（激活方式、子代理编排、复核开关、严重度下限、历史追踪深度、报告粒度）由脚本 `review_plan` 输出，本文件不再重复。审查时按以下三个字段消费：

| `review_plan` 字段 | 消费方式 |
|---|---|
| `subagents` | `none` 由主代理单遍全四象限审查；否则按清单并发派发正交子代理（模板见 `subagent-prompts.md`） |
| `severity_floor` | 报告只输出达到该严重度及以上的发现（`HIGH` 表示仅 CRITICAL / HIGH） |
| `history_tracking` | `none` / `shallow` / `deep` 决定横切历史核查的投入，见 Q1 备注 |

`max` 档位仅限用户当轮显式点名，单次生效且不覆写持久化默认档位，此规则已固化在脚本状态计算中。
