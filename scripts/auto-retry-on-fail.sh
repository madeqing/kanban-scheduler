#!/usr/bin/env bash
# ============================================================
# auto-retry-on-fail.sh — Kanban FAIL 自动打回脚本
#
# 功能：轮询 DONE 状态的 Tester 任务，
#       若 summary 含 FAIL，则自动创建修复任务打回 Dev。
#
# 调用方式：
#   - 直接运行（手动）：~/.hermes/scripts/auto-retry-on-fail.sh
#   - cron 驱动：每分钟一次，内部循环2次实现~30秒间隔
#
# crontab: */1 * * * * /path/to/auto-retry-on-fail.sh
# ============================================================

set -euo pipefail

# ----------- 配置区 ----------
KANBAN_PROFILE="${KANBAN_PROFILE:-default}"
AUTO_RETRY_TAG="auto-retry"
MAX_RETRIES=4
DATE="/usr/bin/date"
# -----------------------------

echo "[$($DATE '+%H:%M:%S')] === auto-retry scan start ==="

# Run twice per invocation (cron @ */1 = once per minute)
# to approximate "every 30 seconds"
for ROUND in 1 2; do
  echo "[$($DATE '+%H:%M:%S')] --- Round $ROUND/2 ---"

  # 1. 查找所有 DONE 状态的 Tester 任务
  mapfile -t failed_tasks < <(
    hermes -p "$KANBAN_PROFILE" kanban list 2>/dev/null \
      | grep -E 'done\s+tester' \
      | while read -r line; do
          task_id=$(echo "$line" | awk '{print $2}')
          # 跳过已打过 auto-retry tag 的任务
          already_tagged=$(
            hermes -p "$KANBAN_PROFILE" kanban show "$task_id" 2>/dev/null \
              | grep -c "<!-- $AUTO_RETRY_TAG" 2>/dev/null \
              | head -1 \
              | tr -cd '0-9' \
              || echo "0"
          )
          : "${already_tagged:=0}"
          [[ "$already_tagged" -eq 0 ]] && echo "$task_id"
        done
  )

  if [[ ${#failed_tasks[@]} -eq 0 ]] || [[ -z "${failed_tasks[0]:-}" ]]; then
    echo "[$($DATE '+%H:%M:%S')] No unreviewed FAIL tasks found in round $ROUND."
  else
    echo "[$($DATE '+%H:%M:%S')] Found ${#failed_tasks[@]} unreviewed FAIL Tester task(s)"

    for task_id in "${failed_tasks[@]}"; do
      task_id=$(echo "$task_id" | tr -d '[:space:]')
      [[ -z "$task_id" ]] && continue

      echo "--- Processing: $task_id ---"

      # 2. 获取 Tester 任务的 summary（失败原因）
      summary=$(
        hermes -p "$KANBAN_PROFILE" kanban show "$task_id" 2>/dev/null \
          | grep -A1 "Latest summary" \
          | tail -1 \
          | sed 's/^[[:space:]]*//' \
          || true
      )

      # 3. 获取父 Dev 任务 ID
      parent_id=$(
        hermes -p "$KANBAN_PROFILE" kanban show "$task_id" 2>/dev/null \
          | grep -E "^  parents:" \
          | awk '{print $2}' \
          | tr -d ',' \
          || true
      )

      if [[ -z "$parent_id" ]]; then
        echo "[WARN] $task_id has no parent Dev task, skipping"
        continue
      fi

      # 4. 获取原始 Dev 任务的 title 和 body
      dev_title=$(
        hermes -p "$KANBAN_PROFILE" kanban show "$parent_id" 2>/dev/null \
          | grep -E "^  title:" \
          | sed 's/^  title:[[:space:]]*//' \
          || true
      )

      dev_body=$(
        hermes -p "$KANBAN_PROFILE" kanban show "$parent_id" 2>/dev/null \
          | sed -n '/^  body:/,$p' \
          | tail -n +2 \
          | sed 's/^    //' \
          || true
      )

      # 5. 检查重试次数
      retry_count=$(
        hermes -p "$KANBAN_PROFILE" kanban show "$parent_id" 2>/dev/null \
          | grep -c "<!-- $AUTO_RETRY_TAG" 2>/dev/null \
          | head -1 \
          | tr -cd '0-9' \
          || echo "0"
      )
      : "${retry_count:=0}"

      if [[ "$retry_count" -ge $MAX_RETRIES ]]; then
        echo "[WARN] $parent_id exceeded max retries ($MAX_RETRIES), skip auto-retry"
        hermes -p "$KANBAN_PROFILE" kanban comment "$parent_id" \
          "⚠️ 已自动重试 $MAX_RETRIES 次仍失败，请人工介入决策。" 2>/dev/null || true
        continue
      fi

      # 6. 提取原始 Step 编号
      step_prefix=$(echo "$dev_title" | grep -oE "Step-[0-9]+" | head -1 || echo "FIX")

      # 7. 获取文件路径
      file_path=$(echo "$dev_body" | grep "文件路径" | head -1 \
        | sed 's/.*文件路径.*[:：][[:space:]]*//' || true)

      # 8. 构建修复任务 body（时间戳用 $DATE 变量）
      ts=$($DATE '+%Y-%m-%d %H:%M')
      fix_body="## ${step_prefix} Dev 修复 #${retry_count}: 自动打回

<!-- $AUTO_RETRY_TAG: attempt $((retry_count + 1)) @ ${ts} -->

### 失败原因（来自 Tester）
${summary}

### 原始验收标准
$(echo "$dev_body" | grep -A50 "验收标准" | head -30 || true)

### 修复要求
请根据 Tester 的失败原因进行修复，修复后重新提交审查。

### 文件路径
${file_path:-（见原任务）}

### 反作弊约束
- Dev 不能自己判定 PASS，必须等 Tester 审查
- 只有修复被 Tester 判定 PASS 才算完成
"

      # 9. 创建修复任务
      fix_title="${step_prefix} Dev 修复 #${retry_count}: $(echo "$dev_title" | sed 's/Dev/Dev Fix/' || echo "fix")"
      fix_task_id=$(
        hermes -p "$KANBAN_PROFILE" kanban create \
          "$fix_title" \
          --assignee dev \
          --body "$fix_body" 2>&1 \
          | grep -oE 't_[a-f0-9]+' \
          || true
      )

      if [[ -n "$fix_task_id" ]]; then
        echo "[OK] Created fix task: $fix_task_id"

        # 10. 写入 tag（Dev 任务 — 防止重复）
        hermes -p "$KANBAN_PROFILE" kanban comment "$parent_id" \
          "<!-- $AUTO_RETRY_TAG: $fix_task_id -->" 2>/dev/null || true

        # 11. 写入 tag（Tester 任务 — 防止 cron 并发）
        hermes -p "$KANBAN_PROFILE" kanban comment "$task_id" \
          "<!-- $AUTO_RETRY_TAG: $fix_task_id -->" 2>/dev/null || true

        # 12. 链式 link
        hermes -p "$KANBAN_PROFILE" kanban link "$parent_id" "$fix_task_id" 2>/dev/null || true

        echo "[OK] Dev notified: $fix_task_id"
      else
        echo "[ERROR] Failed to create fix task for $parent_id"
      fi
    done
  fi

  # Round 1 之后 sleep 30 秒再跑 Round 2
  if [[ "$ROUND" -eq 1 ]]; then
    echo "[$($DATE '+%H:%M:%S')] Sleeping 30s before round 2..."
    sleep 30
  fi
done

echo "[$($DATE '+%H:%M:%S')] === auto-retry scan done ==="
