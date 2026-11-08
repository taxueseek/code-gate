<div align="center">
  <img src="https://raw.githubusercontent.com/taxueseek/code-gate/main/assets/logo.svg" width="110" />
  <h1>code-gate</h1>
  <p><b>工业级代码把关。一条命令，把一次改动审到能交付。</b></p>
  <p>中文 · <a href="README_EN.md">English</a></p>
  <a href="https://github.com/taxueseek/code-gate/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/taxueseek/code-gate/test.yml?branch=main&style=flat-square&label=tests" alt="Tests"></a>
  <a href="https://github.com/taxueseek/code-gate/releases"><img src="https://img.shields.io/github/v/tag/taxueseek/code-gate?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/taxueseek/code-gate/stargazers"><img src="https://img.shields.io/github/stars/taxueseek/code-gate?style=flat-square" alt="Stars"></a>
</div>

<br/>

## 这是什么

`code-gate` 是一个给编码 agent 用的代码审查 skill。它只做一件事：**把这次改动审干净，然后告诉你结论**。

分工是刻意的。文件盘点、工作树预检、PR 状态查询、作用域解析、取数命令生成这些确定性活儿，交给一条零 Token 的脚本；判断交给模型。所以开局不烧上下文，审查的每一分算力都花在「这行代码会不会出错」上。

装好之后你说 `/code-gate`、`审一下这次改动`、`合并前把关`、`把这个 PR 过一遍`，它自己走完四步：定范围 → 取数 → 审查 → 证据链自检 → 出报告。

## 安装

**一行装到所有 agent（推荐）**

```bash
npx skills add taxueseek/code-gate -g -y
```

技能落在 `~/.agents/skills/code-gate`，Claude Code、Codex、Cursor、Gemini CLI、Copilot 以及所有读该目录的 agent 都能用。更新用 `npx skills update -g -y`。

**Claude Code 插件市场**

```
/plugin marketplace add taxueseek/code-gate
/plugin install code-gate@code-gate
```

**手动**

```bash
git clone https://github.com/taxueseek/code-gate
cp -R code-gate/skills/code-gate ~/.agents/skills/
```

依赖极少：`bash` 3.2+ 与 `git`。审远端 PR 需要 `gh`，没装会明确报 `ERROR` 退出，不会假装审完了。

## 怎么用

```bash
/code-gate                                # 审当前工作区改动（staged + unstaged + untracked；工作树干净则审领先上游的提交）
/code-gate #123                           # 审远端 PR，只读拉取，不切你的分支
/code-gate main..HEAD                     # 审分支区间（自动解析 merge-base）
/code-gate -c 1a2b3c4                     # 审单次提交
/code-gate high src/auth/                 # 高力度，范围收敛到这个目录
/code-gate xhigh --verify --fix           # 复核确认后直接改，逐条回报处置结果
/code-gate max --comment                  # 四路对抗 + 逐条独立复核，结论作为行内评论发到 PR
```

## 它查什么

主责是**正确性**，顺带**做减法**。两条主轴、四个互斥穷尽（MECE）的象限，每条发现只归属一个象限。

| 象限 | 权重 | 典型问题 |
| :--- | :--- | :--- |
| Q1 正确性与运行时安全 | 主责 | 条件写反、越界、空指针；竞态与非原子更新；非原子文件覆写；注入与硬编码凭据；改了签名没同步调用方 |
| Q2 需求契约与范围边界 | 主责 | 需求漏做或做错；夹带无关重构；没有真实用户分化的配置开关；给从未发布的字段写迁移；逐字违反 `AGENTS.md` / `CLAUDE.md` |
| Q3 复用、简化与效率 | 顺带 | 重复造轮子与重复派生；能整层删掉的薄包装与散落特判；越过 1,000 行红线；无谓串行 `await`、异常路径资源泄漏 |
| Q4 AI 编码纪律与测试真实度 | 顺带 | `?? 0` 静默兜底；业务层吞异常返回 `null`；迎合测试的硬编码假实现；只有 `toBeDefined()` 的空心断言；未确认就删调试日志 |

## 五档力度

档位只决定「过几遍、谁过、报多细」，不决定「过哪几套规则」。规则始终是同一套。

| 档位 | 子代理编排 | 复核门禁 | 严重度下限 | 历史追踪 |
| :--- | :--- | :--- | :--- | :--- |
| `low` | 主代理单遍 | 关 | CRITICAL / HIGH | 无 |
| `medium`（首次默认） | 主代理单遍 | 关 | CRITICAL / HIGH / MEDIUM | 无 |
| `high` | 正确性契约 + 结构复用 | 开 | 三级全报 | 定向 `git blame` |
| `xhigh` | 再加历史调用链分析 | 开 | 全报 | 跨文件深追 |
| `max` | 再加四路对抗攻击 | 开（逐条独立复核） | 全报 | 跨文件深追 |

不写档位就沿用 `~/.code-gate/state.json` 里的持久化档位。`max` 只在你当轮明确写出时生效，一次性，绝不改写你的默认档位。

## 为什么信得过

一条误报会训练人忽略真缺陷，所以出口前先做减法：

**八不报**。存量旧账、单行看似有病但全链路已保护的假警报、纯品味 nitpick、编译器或 linter 必拦的机械错误、拿不出规约原文的宽泛说教、代码已显式标豁免的项、与作者声明意图一致的刻意改造、Diff 未触及且无调用交集的无关代码，命中任一条静默丢弃。

**三件套铁证**。`CRITICAL` 与 `HIGH` 必须同时给出精确行号、触发错误的具体输入或状态序列、现有防线为何拦不住，缺一降级或丢弃。

**四问抗辩**。开复核时站在代码作者立场逐条尝试推翻：上游守卫拦住了吗、类型系统已排除该状态了吗、框架默认处理了吗、引用的规约真的适用于这条路径吗。活下来的标 `CONFIRMED` 或 `PLAUSIBLE`，被推翻的 `REFUTED` 直接消失，不会出现在报告里。

**零发现也是完备交付**。过滤后没东西，就写 `status: clean review (0 issues found)` 加已核查范围与覆盖面，不凑数。

## 安全边界

- **默认只读**。只有显式 `--fix` 才写你的工作区，只有显式 `--comment` 才碰远端 PR，两者互斥，脚本在参数解析阶段就拒绝同时传入。
- **工作树资产保护铁律**。不执行 `git checkout`、`switch`、`reset --hard`、`stash`、`clean`，不 `gh pr checkout`，不把未跟踪文件挪进 `/tmp`。审 PR 全程只读拉取。
- **`--fix` 收敛有上限**。改完立刻跑秒级检查，报错最多修 3 轮；还不收敛就把自己改过的文件还原到修复前（不碰你原有的未提交改动），该项标 `skipped` 并写明根因。
- **三态处置账本**。`fixed` / `skipped` / `no_change_needed` 逐条回报，并用 `git status --short` 确认只动了点名的目标，不顺手带进无关格式化或构建产物。
- **诚实边界**。本轮没跑过的测试或构建，台账里就写 `not run (based on reading the code)`，绝不伪造 `pass`。

## 输出长什么样

终端第一行恒为 `status:`，文末一份收尾台账：

```markdown
status:           2 issues found (1 confirmed, 1 plausible)
target & scope:   PR #42 — 4 files reviewed (+112 -19), 0 skipped
effort tier:      high (persisted)
max-findings:     all
verification:     npm test -- auth -> pass
actions:          --comment: 2 inline comments posted
```

每条发现给文件与行号、一句话问题、具体出错机理、可落地的修复或简化方案；台账之后可选一行 `pre-existing notes:`，专门放极高危存量隐患（只出现在本地报告，绝不混进发现列表，也绝不发到 PR 评论）。

## 状态与配置

| 路径 | 内容 |
| :--- | :--- |
| `~/.code-gate/state.json` | 持久化档位与 `--max-findings` |
| `~/.code-gate/inventory.tsv` | 本次变更文件完整账本，用 `total_files` 对账，防止大 Diff 被截断后漏审 |

环境变量：`CODE_GATE_SKILL_ROOT` 指 skill 根目录，`CODE_GATE_STATE_DIR` 改状态目录。

## 仓库结构

| 路径 | 作用 |
| :--- | :--- |
| [skills/code-gate/SKILL.md](skills/code-gate/SKILL.md) | 技能入口：命令契约、四步执行流、收尾台账 |
| [skills/code-gate/references/](skills/code-gate/references/) | 按需加载：四象限矩阵、证据链漏斗、动作模式、子代理模板 |
| [skills/code-gate/scripts/extract-review-scope.sh](skills/code-gate/scripts/extract-review-scope.sh) | 确定性底座：状态、预检、目标识别、文件盘点，输出唯一 `review_plan` |
| [scripts/verify_release.py](scripts/verify_release.py) | 发布前校验：frontmatter、清单与版本一致、仓内链接、隐私形状 |
| [tests/test_scope.sh](tests/test_scope.sh) | 作用域脚本冒烟：三态准入、档位映射、单次档位、互斥参数 |
| [SCOPE.md](SCOPE.md) | 这个技能收什么、不收什么 |
| [AGENTS.md](AGENTS.md) | 贡献与维护不变式 |

## 与内置 `/code-review` 的关系

能力面按内置 `/code-review` 的契约对齐：审查对象、四象限、复核标记、五要素发现、`--fix`、`--comment`、数量控制。差别在编排方式：code-gate 用五档力度把「过几遍、谁过」显式化，档位与数量限制持久化，且不绑定单一宿主，Claude Code、Codex、Cursor 等都能装。它不是内置命令的替代品，两个都能用，按场合挑。

## 常见问题

**会不会改我的代码？** 默认不会。没有 `--fix` 就只读。

**工作树很脏还敢跑吗？** 可以。脏工作树正是它要审的对象，脚本只会 `git status` 只读盘点，不清理、不暂存、不切换。

**能审非 git 仓库吗？** 脚本会明确提示不在 git worktree 内；审查本身仍可在给定路径上执行，但没有 Diff 可比对。

**审查结果可信吗？** 报告里带 `CONFIRMED` / `PLAUSIBLE` 的项经过了独立复核；不带标记的是单遍直审结果，档位决定有没有复核。哪一档做了什么，报告台账里写明。

## 许可

MIT License，见 [LICENSE](LICENSE)。技能正文为中文，命令、字段与代码标识符保持英文。

<br/>

参考了 [tw93/Waza](https://github.com/tw93/Waza) 的仓库组织与发布设置：单技能一层目录、`npx skills add` 一行安装、插件市场清单、CI 只跑确定性校验。
