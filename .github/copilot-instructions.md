# ZZUI · 项目指令

> 全项目通用规则见用户级《跨项目接续协议》（本机 `%APPDATA%\Code\User\prompts\跨项目接续协议.instructions.md`，模板在 `tools/continuity/templates/`，当前版本 2026.11.09.2）。
> **开工先读（存在则读，按序）**：`.github/copilot-instructions.md` → `docs/项目接续指南.md` → `docs/用户档案.md` → `docs/项目记忆.md` → `docs/决策记录.md` 最新节。
> **机器自愈（有则快跑）**：`tools/continuity/install-global-instruction.ps1`（幂等；打开项目时 `.vscode/tasks.json` 也会自动跑）。

## 项目现状（2026-11-10）

- `g:\Code\Zig\ZZUI` 是**全新空仓库**（`git init` 后仅有 `.git`），本轮只做「接续基建装备」，**尚无任何业务代码与 `build.zig`**。
- 项目定位（UI 库 / 界面组件 / 与 ZZCOM 的关系）**待用户确认**，确认后补进本节与 `docs/项目接续指南.md`，不得凭猜测落文。

## 技术基线（沿用同级 Zig 项目已验证口径）

- **Zig 0.17.0**（本机 `zig version` 实测）；`@cImport` 已移除、`std.time.milliTimestamp` 已删、`**` 数组重复改 `@splat` 等版本差异先查 `G:\Code\Zig\skills\zig-0-17\SKILL.md`。
- 编码风格参考 `G:\Code\Zig\skills\zig-tiger-style\SKILL.md`；`G:\Code\Zig\skills` 是**参考库，不复制进本仓库**。
- Windows 图形/工具类目标默认 **Win7+、GUI 子系统、不链 libc（不引入 UCRT）**；需要 `-lc` 时先论证并写决策记录。
- 构建命令统一 `zig build`；缓存目录 `.zig-cache/`、产物 `zig-out/` 均不入库。

## 硬约束

- **不要用 PowerShell 改源码**（`Get-Content -Raw` + `WriteAllText` 会按 GBK 解码破坏 UTF-8）；一律用编辑工具。
- 含中文的 `.ps1` 必须 **UTF-8 with BOM**（PS 5.1 按 GBK 读无 BOM 文件会语法报错）；纯 ASCII 脚本可无 BOM。
- 提交信息一律中文，用 `git commit -F <UTF-8 文件>`；**不要** `git commit -m "中文"`（PS 5.1 会转 gb2312）。
- 日志/审计只记有意义事件；新增周期行为先算 CPU/内存/IO/带宽开销（见用户级指令「资源与带宽惯例」）。

## 每轮收尾（务必）

① `docs/决策记录.md` 新增一节（**含用户原话**）；② 运行 `tools/continuity/sync-memory.ps1` 同步记忆（项目根运行或传 `-ProjectPath`）；③ 跑回归 `powershell -NoProfile -ExecutionPolicy Bypass -File tools/regression.ps1` 并如实汇报；④ 提交（有远端则推送）。
