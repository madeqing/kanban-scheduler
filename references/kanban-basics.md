# Kanban 基础速查

## 核心命令

```bash
# 查看任务
hermes kanban list                    # 所有任务
hermes kanban list --assignee dev    # 按 assignee 筛选
hermes kanban show <task_id>          # 任务详情

# 创建任务
hermes kanban create "标题" --assignee <profile>
hermes kanban create "标题" --assignee <profile> --parent <parent_id>

# 生命周期操作
hermes kanban complete <task_id> --summary "..." --metadata '{"key":"value"}'
hermes kanban block <task_id> "原因"
hermes kanban unblock <task_id>

# 评论（审查结果、交接信息）
hermes kanban comment <task_id> "内容"

# 依赖
hermes kanban link <parent_id> <child_id>

# 监控
hermes kanban tail <task_id>        # 实时日志
hermes kanban runs <task_id>        # 历史 attempts
hermes kanban watch                 # 全局事件流
hermes kanban diagnostics           # stranded 任务

# 恢复
hermes kanban reclaim <task_id>     # 强制回收
hermes kanban reassign <task_id> <new_profile> --reclaim
```

## Profile 发现

```bash
hermes profile list
```

## 任务状态

```
ready    → running   (dispatcher spawn)
running  → done      (kanban_complete)
running  → blocked   (kanban_block)
blocked  → ready     (kanban_unblock)
running  → archived  (进程崩溃/超时时自动处理)
```

## Workspace 路径

```
$HERMES_KANBAN_WORKSPACE/  ← Dev/Testers 在此工作
```

## Tool 工具箱（agent 内部调用）

| 工具 | 用途 |
|---|---|
| `kanban_show()` | 读取上下文（含 prior attempts + parent handoffs） |
| `kanban_create()` | 创建任务，返回 `{task_id: ...}` |
| `kanban_complete()` | 成功终结 |
| `kanban_block()` | 阻塞等待人工 |
| `kanban_comment()` | 写评论线程 |
| `kanban_heartbeat()` | 进度声明 |
| `kanban_link()` | 建立 parent→child 依赖 |
| `kanban_unblock()` | 解除阻塞 |
