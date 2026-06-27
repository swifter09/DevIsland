#!/bin/bash
# 安装 DevIsland 权限网关 hook 到 Claude Code
# - 复制 hook 脚本到 ~/.devisland/hooks/
# - 把 PreToolUse hook 配置合并进 ~/.claude/settings.json（先备份）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$HOME/.devisland"
HOOK_CMD="$BASE/hooks/devisland-gate.py"

mkdir -p "$BASE/hooks" "$BASE/requests"
cp "$ROOT/hooks/devisland-gate.py" "$HOOK_CMD"
chmod +x "$HOOK_CMD"

# 装进所有 Claude Code 配置目录（支持 CLAUDE_CONFIG_DIR 多 profile 用法，
# 如 ~/.claude-work / ~/.claude-personal）
for dir in "$HOME/.claude" "$HOME"/.claude-*; do
    [ -d "$dir" ] || continue
    SETTINGS="$dir/settings.json"
    python3 - "$SETTINGS" "$HOOK_CMD" <<'PY'
import json, os, shutil, sys

settings_path, hook_cmd = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(settings_path), exist_ok=True)

settings = {}
if os.path.exists(settings_path):
    shutil.copy(settings_path, settings_path + ".devisland.bak")
    with open(settings_path) as f:
        settings = json.load(f)

hooks = settings.setdefault("hooks", {})

# PermissionRequest：权限审批，不加 matcher（所有工具的确认都转发到岛上）
perm = hooks.setdefault("PermissionRequest", [])
if not any(hook_cmd in json.dumps(e) for e in perm):
    perm.append({
        "hooks": [{"type": "command", "command": hook_cmd, "timeout": 120}],
    })

# PreToolUse + AskUserQuestion：就地作答（清理本脚本的旧 PreToolUse 项后重建）
# timeout=600：问题类要等用户在岛上作答（脚本内 QUESTION_WAIT_SECONDS=300），
# 这个 Claude 侧硬超时必须更大，否则 hook 会被提前杀掉、问题被甩回终端。
pre = [e for e in hooks.get("PreToolUse", []) if hook_cmd not in json.dumps(e)]
pre.append({
    "matcher": "AskUserQuestion",
    "hooks": [{"type": "command", "command": hook_cmd, "timeout": 600}],
})
hooks["PreToolUse"] = pre

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
print("已写入:", settings_path)
PY
done

echo ""
echo "安装完成。生效条件（三者缺一 hook 都会直接放行，不影响正常使用）："
echo "  1. 新开的 Claude Code 会话（已有会话需重启）"
echo "  2. DevIsland 正在运行"
echo "  3. 在 DevIsland 菜单里打开了「岛上批准」开关"
