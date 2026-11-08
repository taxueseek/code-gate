# code-gate Agent Guide

本文件是本仓的贡献者与代理指南。Claude Code、Codex 等直接读它，没有单独的 `CLAUDE.md`。

## 项目

`code-gate` 是一个代码审查 skill，只发布这一个技能。它把确定性工程（状态、预检、目标识别、文件盘点、取数命令）收进一条 shell 脚本，把判断留给模型。

## 仓库地图

- `VERSION` — 版本唯一真源。插件清单里的 `version` 必须与它一致，`scripts/verify_release.py` 会拦不一致。
- `skills/code-gate/SKILL.md` — 技能入口。命令契约、四步执行流、终审台账。
- `skills/code-gate/references/` — 按需加载的四份规范：`scoring-rubric.md`（四象限与复核裁决）、`negative-filters.md`（八不报与反例自检）、`action-modes.md`（读写模式与输出契约）、`subagent-prompts.md`（子代理模板与占位符契约）。
- `skills/code-gate/scripts/extract-review-scope.sh` — 确定性底座，输出唯一 `review_plan`。档位到子代理、复核、严重度下限、历史追踪深度的映射只此一处，别处不得重复列表。
- `scripts/verify_release.py` — 发布前校验，stdlib only，无网络。
- `tests/test_scope.sh` — 作用域脚本冒烟，跑在临时仓库与临时状态目录里。
- `.claude-plugin/marketplace.json` — Claude Code 插件清单，`source` 指向 `skills/code-gate`。
- `.github/workflows/test.yml` — CI：`bash -n`、shellcheck（只挂 error）、Python 语法、元数据校验、冒烟。

## 维护不变式

- **版本一处**：改版本只改 `VERSION`，再同步 `.claude-plugin/marketplace.json` 的 `version`，两处不一致即校验失败。
- **可移植**：技能正文与脚本不得出现绝对路径、用户名或机器专属配置。脚本只用 `$HOME` 与环境变量，`CODE_GATE_STATE_DIR` 改状态目录。
- **自包含**：分发的脚本只依赖 `bash` 与 `git`（PR 目标另需 `gh`），不引入第三方运行时、不联网。确定性检查进 `scripts/`，判断性内容进 `SKILL.md` 与 `references/`。
- **单一编排源**：档位映射只在 `extract-review-scope.sh` 里写一遍；`SKILL.md` 与 `references/` 只描述「怎么审」，不复制映射表。
- **默认只读**：任何新能力不得在未显式 `--fix` / `--comment` 时写工作区或发远端内容；工作树保护铁律（不 `checkout` / `switch` / `reset --hard` / `stash` / `clean` / `gh pr checkout`）不得放宽。
- **目录不膨胀**：不再新增同级技能，不新增含糊的 `utils` / `common` 模块。需要新能力时改进 `references/`、`scripts/` 或 `SKILL.md`。
- **对外文本干净**：README、llms.txt 与技能正文不写本机路径、邮箱、令牌。`scripts/verify_release.py` 的隐私形状检查会拦。
- **诚实描述**：README 只写已验证的能力。没在本仓跑通的安装路径、没有验证的宿主行为，不要写成结论。不用「工业级」这类无法验证的最高级形容词，改用具体能力描述。
- **仓库结构表完整**：README 的仓库结构表必须列出所有对外可见的文件，包括 `VERSION`、`.claude-plugin/marketplace.json`、`llms.txt` 与 CI 配置；描述测试文件时按实际覆盖的项写，不夸大。

## 常用命令

```bash
bash -n skills/code-gate/scripts/extract-review-scope.sh   # 语法
python3 scripts/verify_release.py                          # 元数据、链接、隐私形状
bash tests/test_scope.sh                                   # 作用域脚本冒烟
```

改动技能正文、脚本、清单或 README 后，三条都跑一遍。CI 跑的就是这三条加 shellcheck。

## 改动流程

1. 改 `skills/code-gate/` 下的真源文件。frontmatter 保持 `name`（与目录同名）、`description`、`when_to_use`、`dispatch_intent` 四个字段；`description` 说清做什么与什么时候用，`when_to_use` 放触发词。
2. 新增的按需细节放 `references/`，并在 `SKILL.md` 里用一行条件句指出何时加载；不要让每次运行都为一个偶发分支付上下文成本。
3. 改了分发脚本的可执行位要保留（`git update-index --chmod=+x`）。
4. 跑上面三条命令，再跑一次真实工作区审查确认端到端可用。
5. 版本变更：`VERSION` + 插件清单 + 打 `v{version}` 标签。

## 提交与发布

- 提交信息用 `{type}: {description}`，type 取 `feat`、`fix`、`refactor`、`docs`、`chore`。
- 提交保持原子，一个提交只说一件事。
- 打标签用小写 `v{version}`；发布说明写「以前不行、现在能行」，不写营销话术。推送、打标签、发 Release 由用户在当前会话中明确要求后再做。

## 边界

- 本仓不分发 npm 包，不提供 Claude Desktop 压缩包；安装路径只有 `npx skills add`、插件市场与手动复制三条，且都经过实跑。
- 不把项目专属命令、路径或发布仪式写进技能；运行时应从目标仓库的公开上下文（README、清单、Makefile、CI 配置）读取。
- 一次性审查报告、打分卡、诊断快照不进本仓文档；稳定规则沉淀到 `SKILL.md`、`references/`、`AGENTS.md` 或 `SCOPE.md`。
