# kanban-scheduler

Hermes Kanban 多智能体调度 Skill — 将复杂任务拆解为步骤，每步由 Dev 执行 + Tester 严格审查，通过后才推进下一步。

## 角色分工

- **Leader**：任务分解、分配、记录进度、协调返工
- **Dev**：根据任务卡实现代码
- **Tester**：严格验证，不通过则打回 Dev 修复

## 核心流程

1. Leader 将用户需求拆解为步骤序列，写入看板
2. 每步由 Dev 执行 → Tester 验证 → 通过则推进NEXT，否则打回
3. 全部完成后 Leader 输出最终交付物

## 目录结构

```
kanban-scheduler/
├── SKILL.md                        # 主技能文档
├── references/
│   ├── kanban-basics.md           # 看板基础概念
│   └── step-workflow.md           # 步骤化工作流详解
└── scripts/
    └── auto-retry-on-fail.sh      # Dev 失败自动重试脚本
```

## 安装

```bash
hermes skills install https://github.com/madeqing/kanban-scheduler
```

## 触发方式

在 Hermes 中描述任务需求即可自动加载，例如：
- "用看板调度帮我实现 XXX 功能"
- "Dev+Tester 协作完成这个需求"

## 设计原则

- Leader 只能调度/记录/拆步/转发/状态更新，不能手动修改 Dev 的实现文件
- Tester FAIL 后必须退回 Dev 修复，禁止自己改或让 Tester 改
- 兼容模式：检测到缺少子 Agent 时主动询问用户

## 踩坑记录

- `hermes kanban create --body` 含 Markdown 特殊字符（`[`, `- [ ]`, `##` 等）会导致 bash syntax error，修复：用单引号 heredoc 包裹 body
- cron 调度时任务 prompt 必须 self-contained，不依赖当前会话上下文
