# 动作模式、报告格式与持久化控制（Action Modes & Output Contracts）

`code-gate` 默认处于只读报告模式（Report-Only）。仅当显式指定 `--fix` 或 `--comment` 时，才分别激活工作区自动修复或 PR 逐行评论。二者互斥：一个写本地工作区，一个向远端 PR 发评论，`../scripts/extract-review-scope.sh` 在参数解析阶段即拒绝同时传入。

---

## 一、 默认只读报告规范（Report-Only Mode）

### 1. 首行契约与零噪音收尾
- **首行铁律**：终端输出的第一行必须以 `status:` 开头，一句话给出当前审查结论。
- **零发现契约（Clean Review）**：若无达到报告门槛的问题，直接输出零发现结论与覆盖面说明，严禁凑数：
  ```markdown
  status: clean review (0 issues found)
  scope: workspace (3 files, +48 -12) | tier: medium (persisted) | max-findings: all
  verdict: Checked correctness, spec alignment, code-judo simplification, reuse, efficiency, and AI coding discipline. No actionable issues found.
  ```

### 2. 单条发现的五要素与排序规则（对齐内置 `ReportFindings` 契约）
存在发现时，严格按严重度从高到低排序（`CRITICAL` → `HIGH` → `MEDIUM` → `LOW`），并按 `review_plan.severity_floor` 过滤低于门槛的发现。每条发现包含以下五项：
1. **文件与精确行号**：`path/to/file.ext#Lstart-Lend`。
2. **严重度与（可选）复核标记**：
   - `review_plan.verification_pass` 为 `true`：标题格式为 `### [SEVERITY] [CONFIRMED | PLAUSIBLE] 一句话说明问题`。
   - `review_plan.verification_pass` 为 `false`：标题格式为 `### [SEVERITY] 一句话说明问题`（**不带标记**）。
3. **一句话问题摘要**：直指缺陷本质或结构异味。
4. **具体出错机理（Trigger & Impact）**：写明什么具体输入、调用顺序或状态边界会触发哪条代码分支，导致什么错误结果（以及为何现有类型或校验防线拦不住）。
5. **修复或简化方案（Remedy / Code Judo）**：给出最小可落地的修复代码、复用既有工具的替换写法或删层简化方案（涉及同型缺陷时注明同型位点）。

**示例（`verification_pass: true` 的报告）**：
```markdown
status: 2 issues found (1 confirmed, 1 plausible)
scope: PR #42 (4 files, +112 -19) | tier: high (persisted) | max-findings: all

### [CRITICAL] [CONFIRMED] Authorization 头缺少空值守卫导致进程未捕获异常
- **位置**：`src/server/auth.ts#L42-L46`
- **出错机理**：当请求未携带 `Authorization` 头或格式不含空格时，第 44 行 `req.headers.authorization.split(' ')[1].trim()` 对 `undefined` 调用 `.trim()`，抛出未捕获的 `TypeError`，且上游路由未挂载 schema 校验器。
- **修复方案**：
  ```typescript
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing or malformed token' });
  }
  const token = authHeader.slice(7).trim();
  ```

### [MEDIUM] [PLAUSIBLE] 静默兜底掩盖缺失的商品价格契约且重复实现金额格式化
- **位置**：`src/checkout/total.ts#L18-L24`
- **出错机理**：使用 `item.price ?? 0` 将数据库中异常缺失的价格静默转为免费结算，违反 Fail-Fast 纪律；同时手搓的 `toFixed(2)` 货币拼接与仓库既有的 `src/lib/currency.ts#formatCents` 重复。
- **修复方案**：当 `item.price == null` 时直接抛出明确错误，并复用 `formatCents(item.price)`。
```

**示例（`verification_pass: false` 的报告，不带复核标记）**：
```markdown
status: 1 issue found
scope: workspace (2 files, +30 -5) | tier: medium (persisted) | max-findings: all

### [HIGH] 非原子覆写用户配置文件导致中途失败时原配置损毁
- **位置**：`scripts/sync-config.sh#L19-L21`
- **出错机理**：`curl -fsSL "$URL" > "$HOME/.app/config.json"` 先截断目标文件再拉取网络流；一旦网络中断或返回非 200，原配置文件即被清空为 0 字节。
- **修复方案**：先写入同目录临时文件 `"$HOME/.app/config.json.tmp.$$"`，校验非空且退出码为 0 后再 `mv` 原子替换。
```

### 3. 存量高危备注（仅本地报告模式）
八不报第 1 条的唯一例外：极高危存量隐患（如明文私钥、严重注入）可在台账之后另起一行呈现，**不计入 `status:` 的发现数，PR 评论模式绝对剔除**：

```markdown
pre-existing notes: 1 item — `config/legacy.yml#L12` 明文私钥，属 base commit 存量，建议单独轮换处理
```

---

## 二、 `--max-findings <n|all|default>` 数量限制与持久化

- **排序后截断**：当发现总数 $M > N$ 时，先按严重度（`CRITICAL` → `HIGH` → `MEDIUM` → `LOW`）排序，仅输出前 $N$ 条，并在状态行注明 `showing top N of M findings (--max-findings=N)`。截断发生在 `severity_floor` 过滤之后。
- **持久化契约**：配置由 `review_plan.max_findings` 提供，脚本自动持久化至 `~/.code-gate/state.json`。传入正整数或 `all` 时沿用；传入 `default` 时重置为 `all` 并更新持久化状态。JSON 中数字带不带引号均可正确解析。

---

## 三、 `--fix` 模式：直接修改工作区与三态结果回报

当传入 `--fix`（或用户明确要求「审完直接改」「修到绿」）时，在完成审查后直接修改工作区，并严格按三态回报每条发现的处理结果。与 `--comment` 互斥。

### 1. 修复执行与三轮收敛纪律
1. **修单范围**：
   - 自动修复确定性正确性缺陷、AI 编码反模式（如静默兜底、吞异常）、明确的复用替换与安全简化项。
   - 若某条发现属于存在多套互斥业务方案的架构取舍，或属于高风险未证实的边界猜测，不强行修改，记为 `skipped`。
   - 若在准备修改并重读完整上下文后确认原代码无需改动，记为 `no_change_needed`。
2. **同型扫（Sibling Sweep）**：修复模式化缺陷时，用 `grep` 在仓内检索相同缺陷形状，同属本次作用域的一并修复，跨作用域的在报告中列明。
3. **本地快门验证与三轮收敛**：
   - 应用补丁后立即运行项目对应的秒级语法检查、类型检查或靶向单测。
   - 若验证报错，结合报错信息修正补丁（最多迭代 3 轮）。若连续 3 轮仍未收敛，立即将自己改动过的文件还原至修复前状态（严禁触碰用户原有的未提交改动），将该项标为 `skipped` 并写明根因。

### 2. 逐条处理结果回报格式（`fixed` / `skipped` / `no_change_needed`）
`--fix` 模式下，报告必须在发现详情后附上**逐条处理账本（Fix Disposition Ledger）**，状态值严格使用以下三项之一：
- `fixed`（已修）：已直接修改工作区并通过验证。
- `skipped`（跳过）：未自动修改，附具体原因（如「涉及公开接口破坏性变更，需人工确认」或「属环境受限未复现的 PLAUSIBLE 项」）。
- `no_change_needed`（不需要改）：经深入核对调用上下文确认既有逻辑已完备，无需修改。

```markdown
### Fix Disposition Ledger (`--fix`)
| # | 位置 | 严重度 | 处理结果 | 说明与验证 |
|---|---|---|---|---|
| 1 | `src/server/auth.ts#L42-L46` | CRITICAL | `fixed` | 已补齐 Bearer 前缀与空值守卫，通过 `npm test -- auth` |
| 2 | `src/checkout/total.ts#L18-L24` | MEDIUM | `fixed` | 已改为缺失价格时抛错并复用 `formatCents` |
| 3 | `src/legacy/adapter.ts#L10-L85` | LOW | `skipped` | 涉及跨模块接口签名调整，留待单独重构 PR 处理 |
```

---

## 四、 `--comment` 模式：PR 逐行评论发布

当审查对象为远端 PR 且传入 `--comment` 时，将每条入选发现作为逐行行内评论（Inline Review Comment）发布到 PR 上。`precheck_verdict` 必须为 `ELIGIBLE` 或被 `--force` 覆盖的 `SKIP`，`ERROR` 一律禁止发布。与 `--fix` 互斥。

### 1. 发布前二次门禁（Post-check Guard）
发评论前必须再次执行：
```bash
gh pr view <PR> --json state,isDraft,headRefOid
```
若 PR 已关闭、已合并，或 `headRefOid` 与开局审查时的 Commit SHA 不一致（作者刚刚强推了新提交），立即中止发布评论并在终端报告原因。

### 2. 逐行评论发布与格式契约
- **行内精准挂载**：通过 `gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews` 一次性提交包含 `commit_id`（必须取自 `gh pr view` 的 40 位 `headRefOid`）与 `comments` 数组的 Review，事件类型固定为 `COMMENT`（除非用户明确要求 `APPROVE` 或 `REQUEST_CHANGES`）：
  ```bash
  gh api "repos/{owner}/{repo}/pulls/{pr_number}/reviews" \
    --method POST \
    --input - <<'EOF'
  {
    "commit_id": "<full-40-char-headRefOid>",
    "event": "COMMENT",
    "body": "code-gate review summary",
    "comments": [
      {
        "path": "src/server/auth.ts",
        "start_line": 42,
        "line": 46,
        "side": "RIGHT",
        "body": "**[CRITICAL] [CONFIRMED] Authorization 头缺少空值守卫导致进程未捕获异常**\n\n当请求未携带 `Authorization` 头时...\n\n```suggestion\n  const authHeader = req.headers.authorization;\n  if (!authHeader?.startsWith('Bearer ')) return res.status(401).end();\n```"
      }
    ]
  }
  EOF
  ```
  *注：单行评论仅传 `line`（不传 `start_line`）；多行评论同时传 `start_line` 与 `line`（且 `start_line < line`）。*
- **完整 40 位 SHA 永久链接**：若评论正文中引用了跨文件或关联代码行，链接必须使用完整 40 位 Commit SHA（`https://github.com/<owner>/<repo>/blob/<full-40-char-sha>/<file>#L<start>-L<end>`），禁止写 `HEAD` 或分支名。
- **可一键采纳的建议块（Suggestion Block）**：若修复方案是 5 行以内、无需新增外部导入的自包含改动，在评论中使用 GitHub `suggestion` 语法块供作者一键应用。
- **防重幂等**：发布前检查该 PR 现有评论，不对同一文件同一行号重复发送相同评论。
- **存量备注禁发**：`pre-existing notes:` 不得进入 PR 评论（见第一节第 3 项）。
