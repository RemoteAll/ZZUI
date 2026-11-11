# ZZUI · 项目指令

> 全项目通用规则见用户级《跨项目接续协议》（本机 `%APPDATA%\Code\User\prompts\跨项目接续协议.instructions.md`，模板在 `tools/continuity/templates/`，当前版本 2026.11.10.1）。
> **开工先读（存在则读，按序）**：`.github/copilot-instructions.md` → `docs/项目接续指南.md` → `docs/用户档案.md` → `docs/项目记忆.md` → `docs/决策记录.md` 最新节。
> **机器自愈（有则快跑）**：`tools/continuity/install-global-instruction.ps1`（幂等；打开项目时 `.vscode/tasks.json` 也会自动跑）。

## 项目现状（2026-11-11 里程碑 1-6 已落地）

- **定位**：ZigLang 的 UI 界面框构；**CUI（`G:\Code\C\CUI`）为移植蓝本，必须多平台**（用户口径）。
- 已实现：平台层抽象（`src/platform.zig` + `platform/win32.zig` + `platform/null.zig`，带编译期后端契约断言）、立即模式核心（节点 / 栈布局 / 绘制指令 / 上一帧命中判定 / Tab 焦点 / 鼠标捕获 / 帧内文本池 / 文本换行 / 浮层层与点击优先级 / **裁剪与滚动视口** / **帧时间与悬停计时**）、软件光栅（BGRA、圆角、线段、裁剪）、**155 个控件**：`widgets`（heading / text / secondary / textInt / separator / button / switch / checkbox / radio / slider / input / dialog / menu / tooltip，14）+ `extras`（muted / badge / link / code / kbd / progress / meter / progressRing / spinner / skeleton / emptyState / card / metric / timelineItem / copyButton / passwordStrength，16）+ `controls`（chip / tabs / segmented / breadcrumb / pagination / rating / stepper / radioGroup / rangeSlider / navItem，10） + `overlay`（toast / popoverBegin+End / selectField+selectPopup / contextMenu / commandPalette，5） + `textedit`（textarea / search / number，3） + `table`（begin/row/cell/end + treeRow，2） + `charts`（sparkline / lineChart / barChart / donutChart / gauge，5） + `chrome`（menuBar / toolbar / statusBar / docTabs，4） + `disclosure`（banner / countdown / checklist / confirmPopover / expandableText / expandableCard / hoverCard，7） + `actions`（keyName / shortcutLabel / shortcutRecorder / confirmButton / inlineEdit / scrub / moneyInput / reactions，8） + `dials`（knob / fader / levelMeter，3） + `codeview`（codeBlock / jsonView / hexView / hexViewGoto，4） + `month`（monthCalendar，1） + `timeline`（timelineEditor，1） + `viz`（heatmap / calendarHeatmap / treemap / radarChart / funnel / sankey / waffle / splitBar / barList / activityRings / scatterChart / radialGauge / candlestick，13） + `curves`（curveEditor / curveEval / gradientEditor / gradientEval，4） + `grid`（dataGrid begin/row/cell/text/edit/end + filterBar + treeTable + treeSort + pathBar，16）+ `dock`（dock begin/item/separator/end，4）+ `dockspace`（begin/panelBegin/panelEnd/end + save/load，5）+ `pickers`（multiSelect / rangeCalendar / dateRangePicker / timePicker / wheelPicker / timeDial / rulerSlider / histogramSlider / signaturePad + dateToDays/dateFromDays / signaturePoints/signatureClear，9 控件 / 13 API）+ `upload`（dropzone / avatarUpload + pathHasExtension，2 控件 / 3 API）+ `photo`（imageViewer / cropper，2 控件）+ `media`（carousel / imageCompare / cardStack / counter / ticker，5 控件 / 10 API）+ `image`（**手写解码器**：BMP / TGA / PNG → BGRA，对位 `cui_image_load`；不使用 stb_image）+ `markdown`（markdown / applyTask，2）+ `diff`（diffView / compute，2）+ `flame`（flameGraph / sortSpans / spanRect，3）+ `trace`（traceView / sortSpans / waterfall，3）+ `editor`（codeEditor / gotoLine / select / find，4）+ `tour`（tour，1）+ `strings`（set / get，2）+ `regex`（search，1）+ `files`（fileBrowser / filePicker + 平台层 listDir，3）+ `regextester`（tester，1）+ `planning`（kanban begin/columnBegin/cardBegin/cardEnd/columnEnd/end + weekCalendar + gantt，3 控件 / 8 API）+ `terminal`（init/write/print/clear + terminal，1 控件 / 5 API）+ `social`（chatMessage / chatDivider / typingIndicator / comment / presence，5 控件）+ `graph`（commitGraph / depGraph，2 控件）、`examples/hello.zig`（最小样例）与 `examples/gallery.zig`（控件橱窗，**分 13 页**；`--once` / `--shot-N`）、`examples/pickers.zig`（选择器/上传/图片/媒体族单产物，**5 页** Inputs / Graphs / Upload / Photos / Media，`--once` / `--shot-N`）、`examples/docs.zig`（markdown + diff + flame + trace/waterfall + tour + regex + files + editor + planning + terminal + social + graph 十二族单产物，**12 页**，`--once` / `--shot-N`）。
- 新增 **`graph` 族**：`commitGraph`（提交泳道图：分叉 / 合并 / 并线 + refs 徽标 + 作者·日期·哈希 + 上下键与滚轮）与 `depGraph`（分层布局 + 每层重心排序 + 滚轮缩放 + 拖拽平移 + 键盘沿边移动 + `F` 适配 + 悬停高亮邻居），另导出 `commitLanes` 供复用；`cui_graph.c` 至此 **2/2**。docs 示例新增第 **12** 页 Graph。
- 新增 **`regex` 测试器**：`regextester`（1 控件：模式 + i/m/s 开关 + 可编辑样本高亮分组 + 摘要 + 命中列表；零堆分配，命中上限 16，签名缓存只在输入变化时重算），`cui_regex.c` 至此 **2/2**。
- 产物（实测，2026-11-11）：`zzui-hello-x64.exe` **186,368 B（182.0 KB）**、x86 **185,856 B（181.5 KB）**、`zzui-gallery-x64.exe` **335,872 B（328 KB）**、`zzui-pickers-x64.exe` **253,440 B（247.5 KB）**、`zzui-docs-x64.exe` **403,968 B（394.5 KB）**；体积门槛：**hello 303,104 B**（CUI 基线，只能收紧）/ **gallery 344,064 B** / **pickers 260,096 B** / **docs 414,592 B**（见审计 §1.2）；单测 **337 项**。
- **体积口径**：指产物 `.exe` 字节数（`-Osmall` + `-fstrip` + `x86_64-windows-gnu` 不链 libc + `--subsystem windows`），**不是代码行数**。基线：空 GUI 程序 4.5 KB、最小 ZZUI 程序 146.5 KB（**框架占 hello 的 86%**）。详见 `docs/迁移审计.md` §1.1。
- 远端：`https://github.com/RemoteAll/ZZUI.git`（remote 名 `origin`，分支 `main`）。
- 待办：**X11 / Cocoa 后端**（需 Linux/macOS 实机验证；地基已就位，用户已明确「1 还没搞好」暂不动）；**C 档其余**（emoji / AI / devtools 开发面板 / 节点图）；文本当前由平台层用系统字体画（核心不带 TTF 光栅器）。已完成：帧末回填尺寸（`PanelOpts.size_key` + `Context.knownSize`）、状态回收（状态池 LRU）、动画（`anim.zig`）、深色主题（`theme.setMode`）、markdown / diff / flame（含 trace / waterfall，`cui_flame.c` 6/6）/ **editor** / tour / strings / regex / files / **graph** 十一族。

## 技术基线（沿用同级 Zig 项目已验证口径）

- **Zig 0.17.0**（本机 `zig version` 实测）；`@cImport` 已移除、`std.time.milliTimestamp` 已删、`**` 数组重复改 `@splat` 等版本差异先查 `G:\Code\Zig\skills\zig-0-17\SKILL.md`。
- 编码风格参考 `G:\Code\Zig\skills\zig-tiger-style\SKILL.md`；`G:\Code\Zig\skills` 是**参考库，不复制进本仓库**。
- **主题是运行时令牌**：`theme.zig` 的 22 个颜色令牌是 `var`（调用点直接写 `theme.bg`），由 `theme.setMode(.light|.dark)` / `toggle()` **整包替换**；尺寸令牌仍是 `const`。给控件加颜色时**不要再硬编码 `t.Color.hex(...)`**（深色下会变死白/死黑），用令牌或 `theme.withAlpha`；反色浮层（toast）用成对的 `overlay_bg`/`overlay_fg`，**不要拿 `theme.text` 当底**。
- **动效与空闲节流**：`anim.zig` 提供按 id 的轨道池（`hover` / `toggle` / `step` / `mix`），**只插值颜色，不做几何位移**；新建轨道首次直接对齐目标（不会开窗全体淡入）。**靠帧时间驱动的控件必须调 `ui.requestFrame()`**（`anim.step` 会自动调）——否则 `App.next` 的空闲节流会让它在鼠标不动时冻在动画中途。
- **跨帧状态池一律「固定容量 + LRU 淘汰」**（`tips` / `scrolls` / `tracks`）：池满不能静默丢弃（tooltip 全失效）也不能落回槽 0（两个滚动区串偏移）；`focus` 池 128、溢出会置 `ui.overflowed`。**列表项/日历格/滚轮行不做 Tab 停靠点**（`interact` 而不是 `interactEx(..., true)`），否则 dense 页面会把焦点池占满、Tab 变成逐格爬。
- Windows 图形/工具类目标默认 **Win7+、GUI 子系统、不链 libc（不引入 UCRT）**；需要 `-lc` 时先论证并写决策记录。
- 构建命令统一 `zig build`；缓存目录 `.zig-cache/`、产物 `zig-out/` 均不入库。

## 硬约束

- **不要用 PowerShell 改源码**（`Get-Content -Raw` + `WriteAllText` 会按 GBK 解码破坏 UTF-8）；一律用编辑工具。
- 含中文的 `.ps1` 必须 **UTF-8 with BOM**（PS 5.1 按 GBK 读无 BOM 文件会语法报错）；纯 ASCII 脚本可无 BOM。
- 提交信息一律中文，用 `git commit -F <UTF-8 文件>`；**不要** `git commit -m "中文"`（PS 5.1 会转 gb2312）。
- **体积优先（用户硬性要求）**：所有最终产物（exe / 静态库）体积要尽可能小；新增依赖、模板/泛型实例化前先估体积影响；每个产物都要有体积上限并写进回归。基线：CUI 的 `examples/hello`（C 版）本机实测 **296.0 KB**（`zig cc -Os`、无 LTO），ZZUI 当前 x64 为 **108.5 KB**。
- **必须多平台（用户硬性要求）**：平台差异只能存在于 `src/platform/*`；core / render / widgets **不得引用 Win32 或其他平台 API**。新增平台 = 在 `platform.zig` 加一个联合成员并实现同一组方法（**编译期契约断言**会检查 10 个方法 + `input` 字段，漏一个直接报错）。护栏：`zig build check` 把库交叉编译到 linux-x64 / linux-aarch64 / macos-x64 / windows-x64；`bmpfile` 平台无关（Windows 走 Win32 不链 libc，其他走 `std.Io`）。
- **日志/审计只记有意义事件**；新增周期行为先算 CPU/内存/IO/带宽开销（见用户级指令「资源与带宽惯例」）。

## 迁移完成度（务必先看）

- **CUI 全量未迁完**：实测 CUI 公开 API 467 个 / 51,486 行 C；ZZUI 已对位 **234 个（50.1%）**，控件类 **234/371（63.1%）**。
- 完整审计（已迁移清单、未迁移清单分 A/B/C 档、质量差异、盲区）：**docs/迁移审计.md**。
- 结论：**A 档 + B 档 + `cui_image.c` 全部落地**（三十二族 155 个控件；`cui_pickers.c` 15/15、`cui_photo.c` 2/2、`cui_media.c` 10/10、`cui_image.c` 1/1、**`cui_markdown.c` 2/2、`cui_diff.c` 2/4**（未做 `view_rows` / `words`）、**`cui_flame.c` 6/6**（flame graph + `trace_view_ex` / `trace_sort` / `waterfall_ex`）、**`cui_editor.c` 4/4**（未做撤销重做 / 剪贴板）、**`cui_tour.c` 1/1、`cui_strings.c` 2/2、`cui_regex.c` 2/2**（`regex.search` + `regextester.tester`）、**`cui_files.c` 3/3**（侧边栏 places / 可输入路径栏未做）、**`cui_planning.c` 8/8**（看板/周历/甘特）、**`cui_terminal.c` 5/5**（ANSI 解析 + 折行视口 + 历史 + 选区）、**`cui_social.c` 5/5**（气泡/分隔/打字/评论串/在线头像）、**`cui_graph.c` 2/2**（提交泳道图 + 分层依赖图））；未做的只剩 C 档其余（emoji/AI/开发面板/节点图）。
- **图片解码口径**：`image.zig` 零堆分配（像素缓冲由调用方给）；PNG 要一次性 IDAT 连续 + ≥ 64 KB inflate 窗口（`pngScratchSize`）；JPEG/GIF **明确不支持**（返回 `error.Unsupported`）。体积按格式付费（实测）：BMP +1,024 B、PNG +13,312 B。

## 每轮收尾（务必）

① `docs/决策记录.md` 新增一节（**含用户原话**）；② 运行 `tools/continuity/sync-memory.ps1` 同步记忆（项目根运行或传 `-ProjectPath`）；③ 跑回归 `powershell -NoProfile -ExecutionPolicy Bypass -File tools/regression.ps1` 并如实汇报；④ 提交（有远端则推送）。
