# 步骤化工作流详解

## 完整的 Dev + Tester 协作循环

```
┌─────────────────────────────────────────────────────────────────┐
│                        Step N                                  │
│                                                                 │
│  ┌──────────────┐    完成    ┌──────────────┐  PASS  ┌───────┐ │
│  │  Step-N Dev  │ ──done──→ │ Step-N Tester│ ──ok──→│ Step  │
│  │  (执行者)    │           │  (审查者)    │        │ N+1   │
│  └──────────────┘           └──────────────┘        └───────┘ │
│       ↑                            │                            │
│       │ FAIL                      │                            │
│       └────────────────────────────┘                            │
│                    打回修复                                      │
└─────────────────────────────────────────────────────────────────┘
```

## Step Packet（派发给 Dev 的任务内容）

每张 Dev 卡片的 body 必须包含：

```markdown
## 任务 ID
{task_id}

## 任务标题
Step-N: xxx

## 任务目标
{goal}

## 允许修改的文件
- file1.html
- file2.js

## 验收标准（必须全部满足）
- [ ] 标准1
- [ ] 标准2

## 约束条件
- 技术约束
- 依赖约束

## 前置依赖
- Step-N-1 Tester 必须 PASS

## 修复模式（首次执行为空，返修时有值）
{fix_mode}
```

## Review Packet（派发给 Tester 的任务内容）

```markdown
## 任务 ID
{task_id}

## 对应的 Dev 任务 ID
{dev_task_id}

## 任务标题
Step-N Tester: xxx

## 审查目标
验证 Step-N Dev 的实现是否满足验收标准。

## Dev 声称的实现摘要
{implementation_summary}

## Dev 标记的已修改文件
- file1.html
- file2.js

## 验收标准（必须逐项检查）
- [ ] 标准1：检查方法 + 预期结果
- [ ] 标准2：检查方法 + 预期结果

## 审查方法
1. 读取 {file_path}
2. 验证每条标准
3. 输出 PASS 或 FAIL

## 已知风险
{known_risks}
```

## 监控方式（不使用 `kanban watch`）

`kanban watch` 在部分环境有重复输出问题，用轮询替代：

```bash
# 等待约45-60秒后检查
sleep 60 && hermes kanban list
```

典型等待节奏：
- Dev任务从 ready → running → done：约 45-90秒
- Tester从 running → done：约 30-60秒
- 如果还在 running，继续 sleep + list

## 常见陷阱（Dev 实现时容易出错的地方）

### Wave/波次类游戏：wave 变量忘记递增

**症状**：波次永远停在第一波（敌人数量不变）
**根因**：wave++ 逻辑缺失，或放在错误位置（仅在玩家死亡时++而非敌人全灭时++）
**修复**：在 `enemies.length === 0` 时 `wave++` 并触发下一波生成

### Tester gateway 未启动

**症状**：Tester 任务始终 `ready`，无法自动执行
**根因**：tester profile 的 gateway 是 `stopped` 状态
**修复**：`hermes -p tester gateway run` 启动

## 审查流程（Tester 必须执行）

```
1. kanban_show()  — 读取任务上下文
2. 读取 Dev 标记的文件
3. 对照验收标准逐项检查
4. 尝试找出问题（不要假设没问题）
5. 决定 PASS 或 FAIL
6. kanban_comment() — 写入审查结果详情
7. kanban_complete() — PASS 时
   或 kanban_block(reason="FAIL: ...") — FAIL 时
```

## FAIL 时的处理

### Leader（我）的职责

1. 读取 Tester 的 FAIL 原因（comment 线程 + block reason）
2. 整理修复指令（具体说明哪里要改）
3. 创建/更新 Dev 返修任务
4. 将 `fix_mode=repair` 信息传递给 Dev

### Dev 收到返修指令后

1. 读取 kanban_show() → 从 comment 线程获取失败原因
2. 针对每条失败原因进行修复
3. 完成后 kanban_complete()
4. 触发下一轮 Tester 审查

## 连续失败的处理

连续 4 次 FAIL → 暂停任务：

```
记录：
- 卡住的步骤
- 4 次错误原因
- 最可能根因
- 建议（继续/拆分/补充信息/重启）
```

## 步骤间的依赖管理

```
Step-1 Dev ──done──→ Step-1 Tester ──PASS──→ Step-2 Dev ──done──→ Step-2 Tester ──PASS──→ ...
                                │
                                └─── FAIL ───→ 打回 Step-1 Dev 修复
```

**关键**：
- Step-2 Dev 不能在 Step-1 Tester PASS 之前开始
- 使用 Kanban 的 parent→child 链接自动控制
- Dev 任务和 Tester 任务是独立的两张卡，但通过链接控制流程
