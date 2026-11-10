# ZZUI · 项目指令

> 全项目通用规则见用户级《跨项目接续协议》（本机 `%APPDATA%\Code\User\prompts\跨项目接续协议.instructions.md`，模板在 `tools/continuity/templates/`，当前版本 2026.11.10.1）。
> **开工先读（存在则读，按序）**：`.github/copilot-instructions.md` → `docs/项目接续指南.md` → `docs/用户档案.md` → `docs/项目记忆.md` → `docs/决策记录.md` 最新节。
> **机器自愈（有则快跑）**：`tools/continuity/install-global-instruction.ps1`（幂等；打开项目时 `.vscode/tasks.json` 也会自动跑）。

## 项目现状（2026-11-10 里程碑 1-6 已落地）

- **定位**：ZigLang 的 UI 界面框构；**CUI（`G:\Code\C\CUI`）为移植蓝本，必须多平台**（用户口径）。
- 已实现：平台层抽象（`src/platform.zig` + `platform/win32.zig` + `platform/null.zig`）、立即模式核心（节点 / 栈布局 / 绘制指令 / 上一帧命中判定 / Tab 焦点 / 鼠标捕获 / 帧内文本池 / 文本换行 / 浮层层与点击优先级 / **裁剪与滚动视口** / **帧时间与悬停计时**）、软件光栅（BGRA、圆角、线段、裁剪）、**104 个控件**：`widgets`（heading / text / secondary / textInt / separator / button / switch / checkbox / radio / slider / input / dialog / menu / tooltip，14）+ `extras`（muted / badge / link / code / kbd / progress / meter / progressRing / spinner / skeleton / emptyState / card / metric / timelineItem / copyButton / passwordStrength，16）+ `controls`（chip / tabs / segmented / breadcrumb / pagination / rating / stepper / radioGroup / rangeSlider / navItem，10） + `overlay`（toast / popoverBegin+End / selectField+selectPopup / contextMenu / commandPalette，5） + `textedit`（textarea / search / number，3） + `table`（begin/row/cell/end + treeRow，2） + `charts`（sparkline / lineChart / barChart / donutChart / gauge，5） + `chrome`（menuBar / toolbar / statusBar / docTabs，4） + `disclosure`（banner / countdown / checklist / confirmPopover / expandableText / expandableCard / hoverCard，7） + `actions`（keyName / shortcutLabel / shortcutRecorder / confirmButton / inlineEdit / scrub / moneyInput / reactions，8） + `dials`（knob / fader / levelMeter，3） + `codeview`（codeBlock / jsonView / hexView / hexViewGoto，4） + `month`（monthCalendar，1） + `timeline`（timelineEditor，1） + `viz`（heatmap / calendarHeatmap / treemap / radarChart / funnel / sankey / waffle / splitBar / barList / activityRings / scatterChart / radialGauge / candlestick，13） + `curves`（curveEditor / curveEval / gradientEditor / gradientEval，4） + `grid`（dataGrid begin/row/cell/text/edit/end + filterBar + treeTable + treeSort + pathBar，16）、`examples/hello.zig`（最小样例）与 `examples/gallery.zig`（控件橱窗，**分 4 页**：Components / Forms / Data / Charts；`--once` / `--shot-N`）。
- 产物（实测）：`zzui-hello-x64.exe` **173,568 B（169.5 KB）**、x86 **174,592 B（170.5 KB）**、`zzui-gallery-x64.exe` **300,032 B（293.0 KB）**；体积门槛：**hello 303,104 B**（CUI 基线，只能收紧）/ **gallery 327,680 B**（全量装载，口径不同，见审计 §1.2）；单测 110 项。
- **体积口径**：指产物 `.exe` 字节数（`-Osmall` + `-fstrip` + `x86_64-windows-gnu` 不链 libc + `--subsystem windows`），**不是代码行数**。基线：空 GUI 程序 4.5 KB、最小 ZZUI 程序 146.5 KB（**框架占 hello 的 86%**）。详见 `docs/迁移审计.md` §1.1。
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

## 迁移完成度（务必先看）

- **CUI 全量未迁完**：实测 CUI 公开 API 467 个 / 51,486 行 C；ZZUI 已对位 **154 个（33.0%）**，控件类 **154/371（41.5%）**。
- 完整审计（已迁移清单、未迁移清单分 A/B/C 档、质量差异、盲区）：**docs/迁移审计.md**。
- 结论：**A 档全部 + B 档的网格/树表/可视化/曲线已落地**（十三族 104 个控件）；未做的是 B 档剩余（停靠 9 / 选择器 16）与 C 档重型组件（编辑器/终端/diff/markdown/emoji/位图/AI/开发面板）。

## 每轮收尾（务必）

① `docs/决策记录.md` 新增一节（**含用户原话**）；② 运行 `tools/continuity/sync-memory.ps1` 同步记忆（项目根运行或传 `-ProjectPath`）；③ 跑回归 `powershell -NoProfile -ExecutionPolicy Bypass -File tools/regression.ps1` 并如实汇报；④ 提交（有远端则推送）。
