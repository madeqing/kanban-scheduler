---
name: kanban-scheduler
description: |
  Kanban 版多智能体逐步调度 — 将复杂任务拆解为步骤，每步由 Dev 执行 + Tester 严格审查，通过才进下一步。
  核心融合：Kanban 的持久化任务板（SQLite）+ multi-agent-scheduler 的步骤化编排（Leader拆步→Dev执行→Tester审查→PASS推进）。
  触发条件：用户提到"看板调度"、"Kanban步骤"、"多步骤审查"、"Dev+Tester"、"step审查"、"逐步完成"、"分步开发"。
  也适用于：复杂任务需要多轮 dev/tester 协作、有明确步骤顺序、有失败返修循环、需要完整审计轨迹的场景。
version: 1.0.0
platforms: [linux, macos, windows]
trigger:
  keywords:
    - kanban步骤
    - 看板调度
    - 多步骤审查
    - dev tester协作
    - step审查
    - 逐步完成
    - 分步开发
    - 多步骤开发
  scenarios:
    - 复杂任务需要分解为多个步骤，每步完成后严格审查
    - 需要多轮 dev/tester 协作，有失败返修循环
    - 需要完整审计轨迹，步骤级进度可见
    - 任务需要持久化，跨会话保持状态
---

# Kanban Scheduler — 多智能体逐步调度（Kanban版）

> 核心融合：Kanban 持久化任务板 + multi-agent-scheduler 步骤化编排。
> 流程：Leader 拆步 → Dev 执行 → Tester 审查 → PASS 才进下一步 → 全部 PASS 后生成 final.md → 用户确认后清理。

## 一、与 multi-agent-scheduler 的关系

| | multi-agent-scheduler | kanban-scheduler |
|---|---|---|
| **状态存储** | JSON 文件 | Kanban SQLite DB |
| **任务持久化** | workflow/ 目录 | ~/.hermes/kanban.db |
| **派发机制** | delegate_task subagent | kanban dispatcher spawn |
| **步骤进度** | JSON step_status | kanban 任务状态 + comment 线程 |
| **失败恢复** | 读取 JSON 续跑 | kanban_show() 读取 prior attempts |
| **审计轨迹** | 本地文件 | SQLite 持久，永不丢失 |

**共同的核心原则**：
- Leader 负责拆步分配，不自己执行实现
- Dev 负责执行，Tester 负责判定
- FAIL = 回到 Dev 的返修信号，不是终点
- 只有 PASS 才推进下一步
- 全部 PASS → final.md → 用户确认 → 清理

## 二、核心概念

### 2.1 角色职责

| 角色 | 职责 | 使用的 Profile |
|---|---|---|
| **Leader（我）** | 拆步规划、派发任务、协调审查、状态管理 | 当前会话 Agent |
| **Dev（执行者）** | 接收任务、执行实现、修复 FAIL | `dev` profile |
| **Tester（审查者）** | 严格验收、输出 PASS/FAIL、提供修复建议 | `tester` profile |

### 2.2 任务状态

```
dev执行 ──(complete)──→ tester审查 ──┬──(PASS)──→ 进入下一步
                                    └──(FAIL)──→ 打回 dev 修复
```

每步的 Dev 任务和 Tester 任务是**独立的两张 Kanban 卡**，通过 parent→child 链接。

### 2.3 步骤结构

每个开发步骤包含：

```
[Dev任务] ──(done)──→ [Tester任务] ──┬──(PASS)──→ [下一Dev任务]
                                      └──(FAIL + block)──→ [原Dev任务修复]
```

## 三、工作流程（标准 8 步）

### Step 0: 发现环境

**必须首先执行**。读取当前 Kanban board 状态，确认已有 profile。

```bash
hermes kanban list
hermes profile list
```

### Step 1: 分析需求

理解用户目标，判断是否需要多步骤审查编排。

**触发条件**（满足任一）：
- 任务需要 2+ 个有序步骤
- 需要 Dev + Tester 协作
- 有失败返修循环
- 需要完整审计轨迹

**不满足时**：使用普通 Kanban workflow 或 delegate_task。

### Step 2: 规划步骤

将任务拆解为**最小可审查单元**，每步应该：

- 有明确的完成标准（acceptance criteria）
- 可被 Tester 独立验证
- 失败时修复范围明确

**规划原则**：
- 每步工作量 10-30 分钟（太短→开销大，太长→风险集中）
- 独立验证点作为单独步骤
- 有依赖的步骤之间用 `parent` 链接

### Step 3: 创建任务链

按顺序创建 Kanban 任务：

```bash
# 创建主任务（Leader 规划用）
hermes kanban create "【规划】任务名称" --assignee leader

# 创建第一步 Dev 任务
hermes kanban create "Step-1 Dev: xxx" --assignee dev

# 创建第一步 Tester 审查任务
hermes kanban create "Step-1 Tester: xxx" --assignee tester --parent <Step1Dev>
```

### Step 4: 派发 Dev 任务

通过 `kanban_unblock` 或等待 dispatcher 自动 spawn：

```bash
# 确认 Dev 任务已创建并被 dispatcher 拾取
hermes kanban list --assignee dev
```

**Dev 执行的 artifact** 必须放在确定路径（`$HERMES_KANBAN_WORKSPACE/` 或约定路径）。

### Step 5: Dev 完成，触发 Tester

Dev 任务 `done` 后，Tester 任务自动升为 `ready`（parent→child 链接）。

**Tester 必须逐项检查**：
1. 读取 acceptance criteria
2. 验证每项标准
3. 尝试找出问题
4. 输出 **PASS** 或 **FAIL + 具体原因**

### Step 6: FAIL 处理

```
 Tester 输出 FAIL
       │
       ▼
 记录失败原因到 comment
 kanban_block(reason="FAIL: 具体原因")
       │
       ▼
 ┌─ 自动路径（推荐）：auto-retry-on-fail.sh 每2分钟轮询检测
 │  → 自动创建 "Step-N Dev Fix #K: ..." 打回 dev
 │  → 连续4次仍 FAIL → 通知人工介入
 │
 └─ 手动路径：Leader 看到 FAIL 后手动创建修复任务
       │
       ▼
 Dev 修复后 → 重新触发 Tester 审查
```

**关键规则**：
- Tester 不能自己修复，必须打回 Dev
- Leader 不能代替 Dev 修改实现
- 连续 4 次 FAIL → 暂停任务，通知用户

### Step 7: PASS 处理

```
 Tester 输出 PASS
       │
       ▼
 tester 任务 done
       │
       ▼
 自动触发下一步 Dev 任务（parent→child 链接）
       │
       ▼
 重复 Step 4-7，直到所有步骤完成
```

### Step 8: 生成 final.md + 清理

所有步骤 PASS 后：

1. 生成 final.md（汇总所有步骤成果）
2. 导出交付物
3. 用户确认"没问题"
4. 清理 Kanban 任务记录

## 四、命令参考

### 创建任务链

```bash
# 步骤 N: Dev 实现
hermes kanban create "Step-N Dev: 任务描述" \
  --assignee dev \
  --body "## 任务目标
...
## 验收标准
- [ ] 标准1
- [ ] 标准2
## 文件路径
$HERMES_KANBAN_WORKSPACE/output.html
"

# 步骤 N: Tester 审查（parent = 步骤N Dev）
hermes kanban create "Step-N Tester: 任务描述" \
  --assignee tester \
  --parent <StepNDevTaskId> \
  --body "## 审查任务
验证 Step-N Dev 的实现是否满足验收标准。

## 验收标准
- [ ] 标准1
- [ ] 标准2

## 审查方法
1. 读取 $HERMES_KANBAN_WORKSPACE/output.html
2. 逐项验证每条标准
3. 输出 PASS 或 FAIL + 具体原因
"
```

### 监控与轮询（优先于 `kanban watch`）

`kanban watch --timeout N` 在部分环境返回重复/空输出，**不要依赖它**。正确方式是轮询：

```bash
# 每30秒检查一次状态（用于等待Dev/Tester完成）
sleep 30 && hermes kanban list

# 典型等待模式（Dev任务约需45-90秒）
sleep 60 && hermes kanban list

# 如果任务还在 running，继续等待
sleep 60 && hermes kanban list
```

**状态判断**：
- `running` → 正在执行，继续等待
- `done` + Tester `ready` → Dev完成，Tester已触发
- `done` + Tester `running` → Tester审查中
- `done` + Tester `done` → 本步完成，检查下一状态

### tester gateway 启动

如果 tester profile 的 gateway 为 `stopped`，Tester 任务无法自动执行。启动方式：

```bash
# 前台运行（临时，用于当前session）
hermes -p tester gateway run

# 后台长期运行（推荐）
hermes -p tester gateway run 2>&1 &
```

启动后 `hermes profile list` 确认 `tester` 的 Gateway 变为 `running`。

### 强制重派（Dev 任务卡住时）

```bash
hermes kanban reclaim <task_id>
```

## 五、PASS / FAIL 判定规范

### PASS 的条件
- **所有** acceptance criteria 都满足
- 实现与规格一致
- 无明显遗漏

### FAIL 的输出格式

```markdown
## 审查结果：FAIL

### 失败原因
1. **[标准X不满足]** 具体描述
2. **[缺陷]** 具体描述

### 修复建议
- 针对每条失败原因的修复方向

### 影响范围
- 哪些文件需要修改
- 哪些功能可能受影响
```

## 六、自动打回机制（Auto-Retry）

### 组成

| 组件 | 路径 | 作用 |
|---|---|---|
| watchdog 脚本 | `~/.hermes/scripts/auto-retry-on-fail.sh` | 轮询 FAIL + 创建修复任务 |
| cron 调度器 | `kanban-auto-retry` | 每分钟触发，脚本内部跑两轮实现~30秒间隔 |
| 幂等 tag | `<!-- auto-retry -->` | 双向写入 Dev+Tester comment，防止重复处理 |

### 自动打回工作流

```
Tester 输出 FAIL
       │
       ↓
 cron 每分钟触发 auto-retry-on-fail.sh
       │
       ↓
 脚本内部 Round 1 → sleep 30 → Round 2（~30秒间隔）
       │
       ↓
 发现 DONE 状态 + 未打 tag 的 Tester 任务
       │
       ↓
 提取 summary / parent_id / dev_title / dev_body
       │
       ↓
 检查重试计数 < 4
       │
       ↓
 创建 "Step-N Dev 修复 #K: ..." → dev profile
       │
       ↓
 双向写入 <!-- auto-retry --> tag（Dev + Tester）
       │
       ↓
 Dev 拾取修复 → 完成后 → Tester 重新审查
```

### 关键实现细节（踩坑记录）

**hermes kanban list 输出格式**：
```
✓ t_4db9714f  done      dev                   Step-0: ...
# 列1=状态图标  列2=task_id  列3=status  列4=assignee
```
→ 用 `awk '{print $2}'` 取 task_id，不要用 `$1`（会取到 `✓`）

**grep -c 返回值陷阱**：
- `grep -c` 找不到时返回 1（旧版 bash），但 `set -e` 会导致脚本退出
- 修复：`|| echo "0"` 后必须跟 `: "${var:=0}"` 做空值保护
- 多行风险：`grep -c` 可能输出一行整数，但也可能多行 → 加 `| head -1 | tr -cd '0-9'`

**整数比较陷阱**：
```bash
# 错误：值含换行符时 [[ $retry_count -ge 4 ]] 会报 syntax error
retry_count=$(grep -c "pattern" | head -1 | tr -cd '0-9')
[[ "$retry_count" -ge 4 ]]  # 可能失败

# 正确：先确保是纯整数，用 : "${var:=0}" 做空值兜底
retry_count=$(grep -c "pattern" 2>/dev/null | head -1 | tr -cd '0-9' || echo "0")
: "${retry_count:=0}"
[[ "${retry_count}" -ge 4 ]]
```

**cron 环境 PATH 问题**：
- cron 的 PATH 通常不含 `/usr/bin`，`date` 命令会报 `command not found`
- 修复：所有 shell 外调用用绝对路径 `/usr/bin/date`，或定义 `DATE="/usr/bin/date"` 变量

**set -euo pipefail 下的安全模式**：
- 所有可能返回非0的子命令链尾加 `|| true`
- 特别是 `hermes kanban show | grep ... | awk ...` 这种多级管道

**30秒间隔实现**：
- cron 表达式只支持分钟级（`*/1` = 每分钟，不能写 `*/0.5`）
- 在脚本内部用 `for ROUND in 1 2; do ...; sleep 30; done` 实现两轮扫描

### 幂等保护（双向 tag）

防止 cron 并发 + 重复扫描：在**两个地方**都写入 tag
1. 原始 Dev 任务 comment：`<!-- auto-retry: t_xxx -->`
2. Tester 任务 comment：`<!-- auto-retry: t_xxx -->`

扫描时两个都检查，跳过已处理的任务。

### 手动触发（不等待 cron）

```bash
~/.hermes/scripts/auto-retry-on-fail.sh
```

### 连续失败保护

- 单个 Step 最多自动重试 **4 次**
- 超过后静默跳过，写入 comment 通知人工介入
- 人工介入后由 Leader 决定是否继续或终止

### 关闭自动打回

```bash
hermes cron pause kanban-auto-retry
```

### 已知陷阱（auto-retry-on-fail.sh 开发踩坑记录）

1. **`set -e` + grep exit code**：bash 中 `set -e` 导致 `grep -c` 返回 1 时（未匹配）脚本直接退出。
   **修复**：`|| true` 包裹每条可能空结果的命令链。
   ```bash
   retry_count=$(hermes kanban show "$id" | grep -c "<!-- tag -->" || echo "0")
   ```

2. **`date` 命令在 cron 环境不存在**：cron 的 PATH 不含 `/usr/bin`，`date` 会报 `command not found`。
   **修复**：用 `DATE="/usr/bin/date"` 变量替代。

3. **`mapfile` 空结果时 `set -e` 提前退出**：子 shell 中 `grep | while read` 无输出时，`set -e` 在某些 bash 版本会中断。
   **修复**：对 task_id 做 `[[ -z "$task_id" ]] && continue` 保护。

4. **cron 并发重复触发**：两个 cron 实例同时运行会重复创建 fix 任务。
   **修复**：在 Dev 任务 AND Tester 任务两处同时写入 `<!-- auto-retry -->` tag，双重幂等保护。

5. **`awk '{print $1}'` 误取状态图标**：`hermes kanban list` 输出第一列是状态图标（`✓`），不是 task_id。
   **修复**：用 `awk '{print $2}'` 取第二列。

6. **`grep -oE 't_[a-f0-9]+'` 匹配空输出**：管道中任一命令失败时不产生输出，`|| echo ""` 保底。

## 七、反作弊规则

- **Leader 不执行实现**：只拆步、派发、协调，不亲手改代码
- **Tester 不修复**：只判定，不动手改
- **Dev 不跳过审查**：实现完成后必须等待 Tester 验收
- **不允许"差不多"**：每条标准都必须严格核验

## 八、失败恢复

| 场景 | 处理方式 |
|---|---|
| Dev 任务超时/崩溃 | `hermes kanban reclaim <dev_task_id>` 重派 |
| Tester 输出 FAIL | 记录原因，打回 Dev 修复 |
| 连续 4 次 FAIL | 暂停，通知用户决策 |
| 任务卡在 ready | 检查 assignee 是否正确，`hermes profile list` 确认 |

## 九、Related Skills

- `kanban` — Kanban 基础概念
- `kanban-worker` — Kanban worker 端详尽指南
- `kanban-orchestrator` — Orchestrator 角色深度指南
- `multi-agent-scheduler` — 原始 JSON 版逐步调度（参考）

## 十、参考资料

- `references/step-workflow.md` — 步骤化工作流详解
- `references/kanban-basics.md` — Kanban 基础速查
