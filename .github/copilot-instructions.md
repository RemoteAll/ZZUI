# ZZUI · 项目指令

> 全项目通用规则见用户级《跨项目接续协议》（本机 `%APPDATA%\Code\User\prompts\跨项目接续协议.instructions.md`，模板在 `tools/continuity/templates/`，当前版本 2026.11.10.1）。
> **开工先读（存在则读，按序）**：`.github/copilot-instructions.md` → `docs/项目接续指南.md` → `docs/用户档案.md` → `docs/项目记忆.md` → `docs/决策记录.md` 最新节。
> **机器自愈（有则快跑）**：`tools/continuity/install-global-instruction.ps1`（幂等；打开项目时 `.vscode/tasks.json` 也会自动跑）。

## 项目现状（2026-11-10 里程碑 1 已落地）

- **定位**：ZigLang 的 UI 界面框架；**CUI（`G:\Code\C\CUI`）为移植蓝本，必须多平台**（用户口径）。
- 已实现：平台层抽象（`src/platform.zig` + `platform/win32.zig` + `platform/null.zig`）、立即模式核心（节点 / 栈布局 / 绘制指令 / 上一帧命中判定 / Tab 焦点 / 鼠标捕获 / 帧内文本池 / **文本换行**）、软件光栅（BGRA、圆角、线段）、**10 个控件**（heading / text / secondary / separator / button / switch / checkbox / radio / slider / **input**）、`examples/hello.zig` 与 `--once` / `--shot` 两种无人工出图。
- 产物（实测）：`zzui-hello-x64.exe` **134,656 B（131.5 KB）**、x86 **135,680 B（132.5 KB）**；体积门槛 303,104 B（CUI hello 基线）写在 `tools/regression.ps1`，只能收紧。
- 远端：`https://github.com/RemoteAll/ZZUI.git`（remote 名 `origin`，分支 `main`）。
- 待办：Cocoa / X11 后端、帧末统一布局、状态回收与动画、深色主题；文本当前由平台层用系统字体画（核心不带 TTF 光栅器）。

## 技术基线（沿用同级 Zig 项目已验证口径）

- **Zig 0.17.0**（本机 `zig version` 实测）；`@cImport` 已移除、`std.time.milliTimestamp` 已删、`**` 数组重复改 `@splat` 等版本差异先查 `G:\Code\Zig\skills\zig-0-17\SKILL.md`。
- 编码风格参考 `G:\Code\Zig\skills\zig-tiger-style\SKILL.md`；`G:\Code\Zig\skills` 是**参考库，不复制进本仓库**。
- Windows 图形/工具类目标默认 **Win7+、GUI 子系统、不链 libc（不引入 UCRT）**；需要 `-lc` 时先论证并写决策记录。
- 构建命令统一 `zig build`；缓存目录 `.zig-cache/`、产物 `zig-out/` 均不入库。

## 硬约束

- **不要用 PowerShell 改源码**（`Get-Content -Raw` + `WriteAllText` 会按 GBK 解码破坏 UTF-8）；一律用编辑工具。
- 含中文的 `.ps1` 必须 **UTF-8 with BOM**（PS 5.1 按 GBK 读无 BOM 文件会语法报错）；纯 ASCII 脚本可无 BOM。
- 提交信息一律中文，用 `git commit -F <UTF-8 文件>`；**不要** `git commit -m "中文"`（PS 5.1 会转 gb2312）。
- **体积优先（用户硬性要求）**：所有最终产物（exe / 静态库）体积要尽可能小；新增依赖、模板/泛型实例化前先估体积影响；每个产物都要有体积上限并写进回归。基线：CUI 的 `examples/hello`（C 版）本机实测 **296.0 KB**（`zig cc -Os`、无 LTO），ZZUI 当前 x64 为 **108.5 KB**。
- **必须多平台（用户硬性要求）**：平台差异只能存在于 `src/platform/*`；core / render / widgets **不得引用 Win32 或其他平台 API**。新增平台 = 在 `platform.zig` 加一个联合成员并实现同一组方法。
- **日志/审计只记有意义事件**；新增周期行为先算 CPU/内存/IO/带宽开销（见用户级指令「资源与带宽惯例」）。

## 每轮收尾（务必）

① `docs/决策记录.md` 新增一节（**含用户原话**）；② 运行 `tools/continuity/sync-memory.ps1` 同步记忆（项目根运行或传 `-ProjectPath`）；③ 跑回归 `powershell -NoProfile -ExecutionPolicy Bypass -File tools/regression.ps1` 并如实汇报；④ 提交（有远端则推送）。
