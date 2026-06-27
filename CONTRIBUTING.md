# Contributing to DevIsland

感谢参与!这里是参与方式。

## Reporting bugs / 报 bug
开 issue,附:复现步骤、期望 vs 实际、环境(macOS 版本 / Swift 版本 / 涉及的 AI 工具如 Claude Code / Codex)、相关日志。

岛上批准 / 就地作答相关的问题,贴上 `~/.devisland/requests/` 里的请求 JSON(脱敏后)很有帮助。

## Development / 本地开发
```bash
git clone git@github.com:swifter09/DevIsland.git
cd DevIsland
swift run          # 直接跑;或 ./scripts/build_app.sh 打包 .app
```

启用 hook 链路测试:`./scripts/install_hooks.sh` 后在菜单面板打开「岛上批准」,新开一个 Claude Code 会话。

## Pull requests
1. Fork 并开分支(`feat/...` 或 `fix/...`)。
2. 一个 PR 聚焦一件事;附上动机和验证方式。
3. 跑通 CI(`swift build`)再提。
4. 描述里说明你**测了什么、结果如何**——尤其涉及 hook / 文件 IPC 的改动,说明你怎么验证端到端通了。

## Scope / 范围
开新功能前先开 issue 讨论,避免做了不被合并。Bug 修复直接 PR 即可。

新增 AI 工具监控是最受欢迎的贡献方向:实现 `SessionMonitor` 协议并在 `SessionStore.startMonitoring()` 注册。

## Code style
跟随仓库现有风格(注释密度、命名、SwiftUI 写法);保持改动最小化。
