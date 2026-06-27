#!/usr/bin/env python3
"""DevIsland 权限网关（Claude Code PermissionRequest hook）

只在 Claude Code 真的要向用户弹权限确认时触发（被 allow 规则 / acceptEdits
等自动放行的调用不会经过这里），把确认请求转发到 DevIsland 的动态岛上。

脚本把请求写到 ~/.devisland/requests/，等待用户在岛上点「允许/拒绝」，
再把决定以 JSON 输出给 Claude Code。

安全兜底：
- 未开启网关（无 gate.on 标记文件）   → 不干预，终端正常弹确认
- DevIsland 没在运行（心跳文件过期）  → 不干预
- 等待超时（用户没理会）              → 不干预
"""
import json
import os
import sys
import time
import uuid

BASE = os.path.expanduser("~/.devisland")
REQ_DIR = os.path.join(BASE, "requests")
GATE_FLAG = os.path.join(BASE, "gate.on")
ALIVE_FILE = os.path.join(BASE, "alive")

WAIT_SECONDS = 45            # 权限审批：短超时，别长时间阻塞会话（超时即兜底回终端）
QUESTION_WAIT_SECONDS = 300  # AskUserQuestion：本就该等用户作答（终端 TUI 也无限等），
                             # 只要 App 还活着就一直等到 5 分钟；45s 太短会把还在阅读/思考的
                             # 问题甩回终端，正是「多选时好时坏、像没上岛」的真因。
                             # 注意：必须同时 ≤ settings.json 里 hook 的 timeout，否则会被 Claude 杀掉。
POLL_INTERVAL = 0.2
TOUCH_INTERVAL = 3.0         # 等待期间每隔几秒刷新 request 文件 mtime，向 App 证明 hook 还在等


def app_is_alive():
    try:
        return time.time() - os.path.getmtime(ALIVE_FILE) < 10
    except OSError:
        return False


def main():
    if not os.path.exists(GATE_FLAG) or not app_is_alive():
        return  # 无输出 = 不干预，终端正常弹确认

    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return

    event = payload.get("hook_event_name")
    tool = payload.get("tool_name", "")
    # 处理两类事件：
    #  - PermissionRequest：权限审批（允许/拒绝）
    #  - PreToolUse 且工具是 AskUserQuestion：就地作答（岛上点选项）
    is_question = (event == "PreToolUse" and tool == "AskUserQuestion")
    if event != "PermissionRequest" and not is_question:
        return

    req_id = uuid.uuid4().hex
    os.makedirs(REQ_DIR, exist_ok=True)
    req_path = os.path.join(REQ_DIR, f"{req_id}.request.json")
    resp_path = os.path.join(REQ_DIR, f"{req_id}.response.json")

    request = {
        "id": req_id,
        "createdAt": time.time(),
        "kind": "question" if is_question else "permission",
        "sessionId": payload.get("session_id", ""),
        "cwd": payload.get("cwd", ""),
        "transcriptPath": payload.get("transcript_path", ""),
        "toolName": tool,
        "toolInput": payload.get("tool_input", {}),
    }
    tmp_path = req_path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(request, f)
    os.rename(tmp_path, req_path)

    decision = None
    deadline = time.time() + (QUESTION_WAIT_SECONDS if is_question else WAIT_SECONDS)
    last_touch = 0.0
    while time.time() < deadline:
        if is_question:
            # App 退出（心跳过期）→ 立即兜底交回终端，别傻等满 5 分钟
            if not app_is_alive():
                break
            now = time.time()
            if now - last_touch > TOUCH_INTERVAL:
                # 刷新 request 文件 mtime：本进程一旦被杀（会话结束/Ctrl+C），
                # mtime 不再更新，App 端按 mtime 过期撤掉孤儿卡片
                try:
                    os.utime(req_path, None)
                except OSError:
                    pass
                last_touch = now
        if os.path.exists(resp_path):
            time.sleep(0.05)
            try:
                with open(resp_path) as f:
                    candidate = json.load(f)
                if isinstance(candidate, dict):
                    decision = candidate
            except (json.JSONDecodeError, OSError):
                pass
            break
        time.sleep(POLL_INTERVAL)

    for p in (req_path, resp_path):
        try:
            os.remove(p)
        except FileNotFoundError:
            pass

    if not isinstance(decision, dict) or decision.get("behavior") == "skip":
        return  # 超时 / 前台不干预：终端照常处理

    if is_question:
        # 就地作答：把岛上选的答案以 updatedInput.answers 回填，跳过终端 TUI
        answers = decision.get("answers")
        if not isinstance(answers, dict):
            return
        questions = payload.get("tool_input", {}).get("questions", [])
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": {"questions": questions, "answers": answers},
            }
        }))
    else:
        if decision.get("behavior") not in ("allow", "deny"):
            return
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": decision,
            }
        }))


if __name__ == "__main__":
    main()
