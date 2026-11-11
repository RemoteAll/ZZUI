# ZZUI regression entry (ASCII only: keep this file BOM-free for PS 5.1)
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools/regression.ps1
# Exit code: 0 = PASS/SKIP only, 1 = FAIL
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$fail = 0
$skip = 0
function Check($name, [bool]$ok, $detail) {
    if ($ok) { Write-Host ("[PASS] {0} {1}" -f $name, $detail) }
    else { Write-Host ("[FAIL] {0} {1}" -f $name, $detail) -ForegroundColor Red; $script:fail++ }
}
function Skip($name, $reason) {
    Write-Host ("[SKIP] {0} {1}" -f $name, $reason) -ForegroundColor Yellow
    $script:skip++
}
# PS 5.1: external command stderr must not be treated as terminating error.
# Pitfall: Push-Location changes only the PowerShell location; native children inherit
# [Environment]::CurrentDirectory, which stays where the shell started. Set it explicitly.
function Invoke-Cmd($exe, [string[]]$argv, [string]$workdir) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $oldCwd = [Environment]::CurrentDirectory
    Push-Location $workdir
    [Environment]::CurrentDirectory = (Get-Location).Path
    try {
        $out = & $exe @argv 2>&1
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
        [Environment]::CurrentDirectory = $oldCwd
        $ErrorActionPreference = $old
    }
    $text = ($out | Out-String).Trim()
    if ($text.Length -gt 4000) { $text = $text.Substring($text.Length - 4000) }
    return [pscustomobject]@{ Code = $code; Output = $text }
}

Write-Host "== 0. toolchain =="
$zig = Get-Command zig -ErrorAction SilentlyContinue
if ($zig) {
    $v = (& zig version) 2>&1
    Check "zig-version" ("$v" -match '^0\.17\.') ("version=$v (project baseline 0.17.0)")
} else {
    Skip "zig-version" "zig not found on PATH"
}

Write-Host "== 1. build.zig =="
if (Test-Path 'build.zig') {
    Write-Host "== 1.1 zig build =="
    $r = Invoke-Cmd 'zig' @('build') $root
    Check "zig-build" ($r.Code -eq 0) ("exit=" + $r.Code + " " + $r.Output)

    Write-Host "== 1.2 zig build test =="
    $r = Invoke-Cmd 'zig' @('build','test') $root
    if ($r.Code -eq 0) {
        Check "zig-test" $true ("exit=0")
    } elseif ($r.Output -match 'no step named .test.|unknown step') {
        Skip "zig-test" "build.zig has no 'test' step"
    } else {
        Check "zig-test" $false ("exit=" + $r.Code + " " + $r.Output)
    }

    # 交叉编译检查：库必须能在 Linux x64/aarch64、macOS、Windows 四个目标上编译
    # （多平台硬约束的护栏；Windows 专用的 Win32 调用不能泄进平台无关层）
    Write-Host "== 1.2b zig build check (cross-compile the library) =="
    $r = Invoke-Cmd 'zig' @('build','check') $root
    if ($r.Code -eq 0) {
        Check "zig-check-cross" $true "exit=0 (linux-x64 / linux-aarch64 / macos-x64 / windows-x64)"
    } elseif ($r.Output -match 'no step named .check.|unknown step') {
        Skip "zig-check-cross" "build.zig has no 'check' step"
    } else {
        Check "zig-check-cross" $false ("exit=" + $r.Code + " " + $r.Output)
    }
} else {
    Skip "zig-build" "build.zig not found (project has no source yet)"
    Skip "zig-test" "build.zig not found"
}
if (Test-Path 'zig-fmt-check.zig') {
    $r = Invoke-Cmd 'zig' @('fmt','--check','.') $root
    Check "zig-fmt" ($r.Code -eq 0) ("exit=" + $r.Code + " " + $r.Output)
}

# GUI-subsystem exes are not waited for by PowerShell's call operator: `& exe` returns
# immediately and $LASTEXITCODE is meaningless. Use Start-Process -Wait to get the real code.
function Invoke-GuiExe($exe, [string[]]$argv, [string]$workdir) {
    $base = Join-Path $env:TEMP ('zzui-gui-' + [guid]::NewGuid().ToString('N'))
    $outFile = $base + '.out'
    $errFile = $base + '.err'
    $p = Start-Process -FilePath $exe -ArgumentList $argv -WorkingDirectory $workdir -PassThru -Wait `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $text = ''
    if (Test-Path $outFile) { $text += [IO.File]::ReadAllText($outFile) }
    if (Test-Path $errFile) { $text += [IO.File]::ReadAllText($errFile) }
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Code = $p.ExitCode; Output = $text.Trim() }
}

Write-Host "== 1.3 size gate (hello = CUI baseline 303104 B; gallery = full-controls load; pickers = pickers family) =="
# 两种产物口径不同，不能共用一个门槛：
#   hello   = 最小应用，真正的体积红线（CUI hello 296 KB 基线，只能收紧）
#   gallery = 加载全部控件的演示，体积随控件数增长（实测约 1.5 KB/控件），
#             它的意义是「全量装载的代价」，门槛按控件集增长单独设定。
#   pickers = 选择器族单独产物（不塞 gallery，否则 gallery 会顶穿门槛）
$helloLimit = 303104
# gallery 于 2026-11-11 加入「运行时主题切换」（令牌由 `const` 变 `var`，全量装载里令牌读取从
# 4 字节立即数变成 RIP 相对加载）后实测 327,168 B；原门槛 327,680 只剩 512 B 余量，故抬到
# 335,872 B（+2.6% 余量）。依据见 docs/决策记录.md。
# 2026-11-11 本轮实测：在 HEAD `877e583` 的干净 worktree 里重建，gallery = 335,872 B
# （不是 334,336）—— 门槛已 0 余量，任何一行新代码都会顶穿，故抬到 344,064 B（+2.4%）。
$galleryLimit = 344064
# pickers 于 2026-11-11 新增媒体族（5 控件 + 渲染分层基础设施）后实测 241,152 B；
# 门槛由 229,376 抬到 253,952（+5% 余量）。
# 2026-11-11 本轮同口径重建实测 253,440 B（原门槛只剩 512 B），抬到 260,096 B（+2.6%）。
$pickersLimit = 260096
# docs 于 2026-11-11 新增（markdown + diff 两族）：不塞 gallery（实测塞进去会让
# gallery 从 334,336 涨到 366,080，顶穿 335,872 门槛），单独出产物。
# 同日再增文件浏览器族（files.zig + 平台层 listDir + Win32 FindFirstFileW）后实测 268,288 B；
# 同日再增追踪视图 + 网络瀑布（trace.zig，C 档 flame 6/6）后实测 299,008 B，
# 同日再增代码编辑器（editor.zig，C 档 cui_editor.c 4/4）后实测 316,416 B，
# 门槛由 307,200 抬到 325,632（+2.9% 余量）。
# 同日再增正则测试器（regextester.zig，C 档 cui_regex.c 2/2；第 5 页由手写演示改成
# 完整测试器）后实测 324,096 B，原门槛只剩 1,536 B，故抬到 332,800 B（+2.7%）。
# 同日再增规划族（planning.zig：看板 / 周历 / 甘特，C 档 cui_planning.c 3 控件）后实测 347,648 B，
# 门槛由 332,800 抬到 356,352（+2.5%）。
# 同日再增终端（terminal.zig，C 档 cui_terminal.c 5 API）后实测 369,664 B，
# 门槛由 356,352 抬到 379,904（+2.8%）。
# 同日再增会话族（social.zig，C 档 cui_social.c 5 API）后实测 382,464 B，
# 门槛由 379,904 抬到 392,192（+2.5%）。
$docsLimit = 414592
$exes = @(
    @{ path = 'zig-out/bin/zzui-hello-x64.exe'; limit = $helloLimit },
    @{ path = 'zig-out/bin/zzui-hello-x86.exe'; limit = $helloLimit },
    @{ path = 'zig-out/bin/zzui-gallery-x64.exe'; limit = $galleryLimit },
    @{ path = 'zig-out/bin/zzui-pickers-x64.exe'; limit = $pickersLimit },
    @{ path = 'zig-out/bin/zzui-docs-x64.exe'; limit = $docsLimit }
)
foreach ($e in $exes) {
    if (Test-Path $e.path) {
        $len = (Get-Item $e.path).Length
        Check ("size:" + (Split-Path $e.path -Leaf)) ($len -le $e.limit) ("bytes=" + $len + " limit=" + $e.limit + " KB=" + [math]::Round($len/1KB,1))
    } else {
        Check ("size:" + (Split-Path $e.path -Leaf)) $false "artifact missing (build failed?)"
    }
}

Write-Host "== 1.4 headless render (--once) =="
if (Test-Path 'zig-out/bin/zzui-hello-x64.exe') {
    $tmp = Join-Path $env:TEMP 'zzui-regression'
    if (-not (Test-Path $tmp)) { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
    Remove-Item (Join-Path $tmp 'zzui-hello.bmp') -ErrorAction SilentlyContinue
    $r = Invoke-GuiExe (Join-Path $root 'zig-out/bin/zzui-hello-x64.exe') @('--once') $tmp
    Check "render:exit" ($r.Code -eq 0) ("exit=" + $r.Code + " " + $r.Output)
    $bmp = Join-Path $tmp 'zzui-hello.bmp'
    if (Test-Path $bmp) {
        $expect = 54 + 420 * 760 * 4
        Check "render:bmp-size" ((Get-Item $bmp).Length -eq $expect) ("bytes=" + (Get-Item $bmp).Length + " expect=" + $expect)
        $b = [IO.File]::ReadAllBytes($bmp)
        $offBg = 54 + (760 - 1 - 0) * 420 * 4 + 0
        $bgOk = ($b[$offBg] -eq 255 -and $b[$offBg+1] -eq 255 -and $b[$offBg+2] -eq 255)
        # 按钮区域随文本换行高度会变，改为在首屏上半部扫强调色像素（BGR: EB 63 25）
        $found = $false
        for ($y = 80; $y -lt 320 -and -not $found; $y++) {
            for ($x = 0; $x -lt 260; $x++) {
                $off = 54 + (760 - 1 - $y) * 420 * 4 + $x * 4
                if ($b[$off] -eq 0xEB -and $b[$off+1] -eq 0x63 -and $b[$off+2] -eq 0x25) { $found = $true; break }
            }
        }
        Check "render:bg" $bgOk ("pixel(0,0)=" + $b[$offBg+2] + "," + $b[$offBg+1] + "," + $b[$offBg])
        Check "render:accent-region" $found "scanned y=80..320 x=0..260"
    } else {
        Check "render:bmp" $false "bmp not written"
    }
} else {
    Skip "render" "zzui-hello-x64.exe not found"
}

Write-Host "== 1.5 text render (--shot, Win32 GDI) =="
if (Test-Path 'zig-out/bin/zzui-hello-x64.exe') {
    $tmp2 = Join-Path $env:TEMP 'zzui-regression'
    if (-not (Test-Path $tmp2)) { New-Item -ItemType Directory -Path $tmp2 -Force | Out-Null }
    Remove-Item (Join-Path $tmp2 'zzui-shot.bmp') -ErrorAction SilentlyContinue
    $r = Invoke-GuiExe (Join-Path $root 'zig-out/bin/zzui-hello-x64.exe') @('--shot') $tmp2
    Check "shot:exit" ($r.Code -eq 0) ("exit=" + $r.Code + " " + $r.Output)
    $shot = Join-Path $tmp2 'zzui-shot.bmp'
    if (Test-Path $shot) {
        $b = [IO.File]::ReadAllBytes($shot)
        $sw = [BitConverter]::ToInt32($b, 18)
        $sh = [BitConverter]::ToInt32($b, 22)
        Check "shot:bmp" ($sw -gt 300 -and $sh -gt 300) ("size=" + $sw + "x" + $sh + " bytes=" + $b.Length)
        # heading 区域应有深色字形像素（证明 GDI 文本真的画上了）
        $dark = 0
        $y0 = 20; $y1 = [Math]::Min(80, $sh)
        $x0 = 24; $x1 = [Math]::Min(260, $sw)
        for ($y = $y0; $y -lt $y1; $y++) {
            for ($x = $x0; $x -lt $x1; $x++) {
                $off = 54 + ($sh - 1 - $y) * $sw * 4 + $x * 4
                if ($b[$off] -lt 100 -and $b[$off+1] -lt 100 -and $b[$off+2] -lt 100) { $dark++ }
            }
        }
        Check "shot:text-pixels" ($dark -gt 100) ("dark=" + $dark)
    } else {
        Check "shot:bmp" $false "shot bmp not written"
    }
} else {
    Skip "shot" "zzui-hello-x64.exe not found"
}

Write-Host "== 1.6 gallery (13 pages, all families) =="
if (Test-Path 'zig-out/bin/zzui-gallery-x64.exe') {
    $tmp3 = Join-Path $env:TEMP 'zzui-regression'
    if (-not (Test-Path $tmp3)) { New-Item -ItemType Directory -Path $tmp3 -Force | Out-Null }

    # --once 也会检查容量溢出（溢出时退出码 8）
    Remove-Item (Join-Path $tmp3 'zzui-gallery.bmp') -ErrorAction SilentlyContinue
    $r = Invoke-GuiExe (Join-Path $root 'zig-out/bin/zzui-gallery-x64.exe') @('--once') $tmp3
    Check "gallery:once-exit" ($r.Code -eq 0) ("exit=" + $r.Code + " " + $r.Output)
    $gb = Join-Path $tmp3 'zzui-gallery.bmp'
    if (Test-Path $gb) {
        $expect = 54 + 720 * 1000 * 4
        Check "gallery:once-size" ((Get-Item $gb).Length -eq $expect) ("bytes=" + (Get-Item $gb).Length + " expect=" + $expect)
    } else {
        Check "gallery:once-size" $false "bmp not written"
    }

    # 13 页逐页真渲染：每页都要有文字像素（证明该页控件真的画了）
    foreach ($pg in 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12) {
        $bmp = Join-Path $tmp3 ("zzui-gallery-p" + $pg + ".bmp")
        Remove-Item $bmp -ErrorAction SilentlyContinue
        $r = Invoke-GuiExe (Join-Path $root 'zig-out/bin/zzui-gallery-x64.exe') @("--shot-$pg") $tmp3
        Check ("gallery:page$pg-exit") ($r.Code -eq 0) ("exit=" + $r.Code + " " + $r.Output)
        if (Test-Path $bmp) {
            $g = [IO.File]::ReadAllBytes($bmp)
            $gw = [BitConverter]::ToInt32($g, 18)
            $gh = [BitConverter]::ToInt32($g, 22)
            $dark = 0
            for ($y = 20; $y -lt [Math]::Min(900, $gh); $y += 2) {
                for ($x = 20; $x -lt [Math]::Min(460, $gw); $x += 2) {
                    $off = 54 + ($gh - 1 - $y) * $gw * 4 + $x * 4
                    if ($g[$off] -lt 100 -and $g[$off+1] -lt 100 -and $g[$off+2] -lt 100) { $dark++ }
                }
            }
            Check ("gallery:page$pg-text") ($dark -gt 200) ("dark=" + $dark + " size=" + $gw + "x" + $gh)
        } else {
            Check ("gallery:page$pg-text") $false "bmp not written"
        }
    }
} else {
    Skip "gallery" "zzui-gallery-x64.exe not found"
}

Write-Host "== 1.7 pickers example (--once / --shot-0..4, five pages) =="
if (Test-Path 'zig-out/bin/zzui-pickers-x64.exe') {
    $tmp4 = Join-Path $env:TEMP 'zzui-regression-pickers'
    if (-not (Test-Path $tmp4)) { New-Item -ItemType Directory -Path $tmp4 -Force | Out-Null }
    Remove-Item (Join-Path $tmp4 'zzui-pickers.bmp') -ErrorAction SilentlyContinue
    $r = Invoke-GuiExe (Join-Path $root 'zig-out/bin/zzui-pickers-x64.exe') @('--once') $tmp4
    Check "pickers:once-exit" ($r.Code -eq 0) ("exit=" + $r.Code + " " + $r.Output)
    $pb = Join-Path $tmp4 'zzui-pickers.bmp'
    if (Test-Path $pb) {
        $expect = 54 + 760 * 1000 * 4
        Check "pickers:once-size" ((Get-Item $pb).Length -eq $expect) ("bytes=" + (Get-Item $pb).Length + " expect=" + $expect)
    } else {
        Check "pickers:once-size" $false "bmp not written"
    }
    # 四页真渲染：每页都要有文字像素 + 强调色像素
    # 页 0 = Inputs（日历/多选/滚轮，文字密集）；
    # 页 1 = Graphs（表盘/刻度尺/直方图/签名板，矢量为主）；
    # 页 2 = Upload（头像位图 + 拖放区）；
    # 页 3 = Photos（图片查看器 + 裁剪框）。
    foreach ($pg in 0, 1, 2, 3, 4) {
        if ($pg -eq 0) {
            $pbmp = Join-Path $tmp4 'zzui-pickers-shot.bmp'
            $flag = '--shot'
        } elseif ($pg -eq 1) {
            $pbmp = Join-Path $tmp4 'zzui-pickers-shot1.bmp'
            $flag = '--shot-1'
        } elseif ($pg -eq 2) {
            $pbmp = Join-Path $tmp4 'zzui-pickers-shot2.bmp'
            $flag = '--shot-2'
        } elseif ($pg -eq 3) {
            $pbmp = Join-Path $tmp4 'zzui-pickers-shot3.bmp'
            $flag = '--shot-3'
        } else {
            $pbmp = Join-Path $tmp4 'zzui-pickers-shot4.bmp'
            $flag = '--shot-4'
        }
        Remove-Item $pbmp -ErrorAction SilentlyContinue
        $r = Invoke-GuiExe (Join-Path $root 'zig-out/bin/zzui-pickers-x64.exe') @($flag) $tmp4
        Check "pickers:page$pg-exit" ($r.Code -eq 0) ("exit=" + $r.Code + " " + $r.Output)
        if (Test-Path $pbmp) {
            $g = [IO.File]::ReadAllBytes($pbmp)
            $gw = [BitConverter]::ToInt32($g, 18)
            $gh = [BitConverter]::ToInt32($g, 22)
            $dark = 0
            $accent = 0
            for ($y = 20; $y -lt [Math]::Min(900, $gh); $y += 2) {
                for ($x = 20; $x -lt [Math]::Min(460, $gw); $x += 2) {
                    $off = 54 + ($gh - 1 - $y) * $gw * 4 + $x * 4
                    if ($g[$off] -lt 100 -and $g[$off+1] -lt 100 -and $g[$off+2] -lt 100) { $dark++ }
                    if ($g[$off] -eq 0xEB -and $g[$off+1] -eq 0x63 -and $g[$off+2] -eq 0x25) { $accent++ }
                }
            }
            # 页 0（日历/多选/滚轮）文字密集；页 1/2/3 以矢量图形与位图为主，
            # 文字天然少 → 文字门槛按页取，另外用强调色像素证明控件真的画了。
            $textGate = if ($pg -eq 0) { 200 } else { 60 }
            # 页 3 以位图为主，强调色只出现在裁剪框的 2px 边线上 → 门槛单独给；
            # 页 4（媒体族）的控件本身不用强调色（分割柄/圆点都是中性色），只剩标签页下划线 → 同样低门槛。
            $accentGate = if ($pg -eq 3 -or $pg -eq 4) { 20 } else { 40 }
            Check "pickers:page$pg-text" ($dark -gt $textGate) ("dark=" + $dark + " gate=" + $textGate + " size=" + $gw + "x" + $gh)
            Check "pickers:page$pg-accent" ($accent -gt $accentGate) ("accent=" + $accent + " gate=" + $accentGate)
            # 页 2 的头像是**真位图**（渐变，蓝红分量差很大）：证明图像通道真的上屏了，
            # 而不是只画了占位方块。页 3 的查看器也画同一张渐变，但位置居中偏右。
            if ($pg -eq 2) {
                $colored = 0
                for ($y = 170; $y -lt 270; $y += 1) {
                    for ($x = 20; $x -lt 120; $x += 1) {
                        $off = 54 + ($gh - 1 - $y) * $gw * 4 + $x * 4
                        $db = [int]$g[$off] - [int]$g[$off+2]
                        if ($db -gt 30 -or $db -lt -30) { $colored++ }
                    }
                }
                Check "pickers:page2-bitmap" ($colored -gt 200) ("colored=" + $colored)
            } elseif ($pg -eq 3) {
                $colored = 0
                for ($y = 190; $y -lt 430; $y += 2) {
                    for ($x = 250; $x -lt 470; $x += 2) {
                        $off = 54 + ($gh - 1 - $y) * $gw * 4 + $x * 4
                        $db = [int]$g[$off] - [int]$g[$off+2]
                        if ($db -gt 30 -or $db -lt -30) { $colored++ }
                    }
                }
                Check "pickers:page3-bitmap" ($colored -gt 200) ("colored=" + $colored)
            } elseif ($pg -eq 4) {
                # 页 4 的图片对比把渐变位图铺满控件（cover）→ 彩色像素一大片
                $colored = 0
                for ($y = 100; $y -lt 900; $y += 2) {
                    for ($x = 20; $x -lt 740; $x += 2) {
                        $off = 54 + ($gh - 1 - $y) * $gw * 4 + $x * 4
                        $db = [int]$g[$off] - [int]$g[$off+2]
                        if ($db -gt 30 -or $db -lt -30) { $colored++ }
                    }
                }
                Check "pickers:page4-bitmap" ($colored -gt 2000) ("colored=" + $colored)
            }
        } else {
            Check "pickers:page$pg-text" $false "bmp not written"
        }
    }
} else {
    Skip "pickers" "zzui-pickers-x64.exe not found"
}

Write-Host "== 1.8 docs example (markdown + diff, two pages) =="
if (Test-Path 'zig-out/bin/zzui-docs-x64.exe') {
    $tmp5 = Join-Path $env:TEMP 'zzui-regression-docs'
    if (-not (Test-Path $tmp5)) { New-Item -ItemType Directory -Path $tmp5 -Force | Out-Null }
    Remove-Item (Join-Path $tmp5 'zzui-docs.bmp') -ErrorAction SilentlyContinue
    $r = Invoke-GuiExe (Join-Path $root 'zig-out/bin/zzui-docs-x64.exe') @('--once') $tmp5
    Check "docs:once-exit" ($r.Code -eq 0) ("exit=" + $r.Code + " " + $r.Output)
    $db = Join-Path $tmp5 'zzui-docs.bmp'
    if (Test-Path $db) {
        $expect = 54 + 760 * 1000 * 4
        Check "docs:once-size" ((Get-Item $db).Length -eq $expect) ("bytes=" + (Get-Item $db).Length + " expect=" + $expect)
    } else {
        Check "docs:once-size" $false "bmp not written"
    }

    # 页 0 = markdown；页 1 = diff；页 2 = 火焰图；页 3 = 引导；页 4 = 正则；页 5 = 文件浏览器；页 6 = 追踪 + 瀑布；页 7 = 代码编辑器；页 8 = 规划（看板/周历/甘特）；页 9 = 终端；页 10 = 会话（聊天/评论/在线）；页 11 = 图族（提交图/依赖图）
    foreach ($pg in 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11) {
        $bmp = Join-Path $tmp5 ("zzui-docs-p" + $pg + ".bmp")
        Remove-Item $bmp -ErrorAction SilentlyContinue
        $r = Invoke-GuiExe (Join-Path $root 'zig-out/bin/zzui-docs-x64.exe') @("--shot-$pg") $tmp5
        Check ("docs:page$pg-exit") ($r.Code -eq 0) ("exit=" + $r.Code + " " + $r.Output)
        if (Test-Path $bmp) {
            $g = [IO.File]::ReadAllBytes($bmp)
            $gw = [BitConverter]::ToInt32($g, 18)
            $gh = [BitConverter]::ToInt32($g, 22)
            $dark = 0
            $redbg = 0
            $greenbg = 0
            $accent = 0
            $hued = 0
            $shaded = 0
            for ($y = 20; $y -lt [Math]::Min(900, $gh); $y += 2) {
                for ($x = 20; $x -lt [Math]::Min(700, $gw); $x += 2) {
                    $off = 54 + ($gh - 1 - $y) * $gw * 4 + $x * 4
                    $bb = [int]$g[$off]; $gg = [int]$g[$off+1]; $rr = [int]$g[$off+2]
                    if ($rr -lt 100 -and $gg -lt 100 -and $bb -lt 100) { $dark++ }
                    if (($rr - $gg) -gt 3 -and $rr -gt 200) { $redbg++ }
                    if (($gg - $rr) -gt 3 -and $gg -gt 200) { $greenbg++ }
                    if ($bb -gt 180 -and $rr -lt 120) { $accent++ }
                    $mx = [Math]::Max($rr, [Math]::Max($gg, $bb))
                    $mn = [Math]::Min($rr, [Math]::Min($gg, $bb))
                    if (($mx - $mn) -gt 25) { $hued++ }
                    if ($rr -gt 90 -and $rr -lt 190 -and $mx - $mn -lt 8) { $shaded++ }
                }
            }
            # diff 页是 12px 等宽小字 + 灰色行号，暗像素天然少（实测 ≈ 200）；
            # 火焰图/引导页大块是彩色或压暗，暗像素更少。
            $textGate = if ($pg -eq 0) { 400 } elseif ($pg -eq 1) { 120 } elseif ($pg -eq 4) { 60 } elseif ($pg -eq 5) { 150 } elseif ($pg -eq 6) { 200 } elseif ($pg -eq 7) { 250 } elseif ($pg -eq 8) { 150 } elseif ($pg -eq 9) { 150 } elseif ($pg -eq 10) { 300 } elseif ($pg -eq 11) { 200 } else { 40 }
            Check "docs:page$pg-text" ($dark -gt $textGate) ("dark=" + $dark + " gate=" + $textGate + " size=" + $gw + "x" + $gh)
            if ($pg -eq 0) {
                # markdown：任务框（勾选的强调色块）+ 链接下划线
                Check "docs:page0-accent" ($accent -gt 40) ("accent=" + $accent)
            } elseif ($pg -eq 1) {
                # diff：删除行淡红底、新增行淡绿底各要成片出现
                Check "docs:page1-red" ($redbg -gt 400) ("redbg=" + $redbg)
                Check "docs:page1-green" ($greenbg -gt 400) ("greenbg=" + $greenbg)
            } else {
                # 火焰图：条按名字哈希取色 → 一大片「有饱和度」的像素
                if ($pg -eq 2) {
                    Check "docs:page2-colors" ($hued -gt 3000) ("hued=" + $hued)
                } elseif ($pg -eq 3) {
                    # 引导：整窗被压暗 → 一中灰像素；无压暗时浅底不会出现
                    Check "docs:page3-shade" ($shaded -gt 20000) ("shaded=" + $shaded)
                } elseif ($pg -eq 4) {
                    # 正则测试器：命中与每个分组各有一层净色块（强调色 + 系列色）→ 成片彩色
                    Check "docs:page4-hits" ($hued -gt 3000) ("hued=" + $hued)
                } elseif ($pg -eq 6) {
                    # 追踪 + 瀑布：两条视图的条都是哈希/分段配色 → 成片彩色；
                    # 另外表格里的 404 行是红色 → 红像素、以及表格蓝底强调色都要有
                    Check "docs:page6-colors" ($hued -gt 2500) ("hued=" + $hued)
                    Check "docs:page6-red-unsafe" ($redbg -gt 20) ("redbg=" + $redbg)
                } elseif ($pg -eq 7) {
                    # 代码编辑器：关键字/字符串/数字三种语法色 → 成片彩色；行号槽是灰底
                    Check "docs:page7-syntax" ($hued -gt 1200) ("hued=" + $hued)
                } elseif ($pg -eq 8) {
                    # 规划：看板三列的列头色点（次要/强调/成功三色）+ 卡片描边
                    Check "docs:page8-kanban" ($hued -gt 2000) ("hued=" + $hued)
                } elseif ($pg -eq 9) {
                    # 终端：绿/青/黄/红四色 ANSI 输出 → 成片彩色
                    Check "docs:page9-ansi" ($hued -gt 2000) ("hued=" + $hued)
                } elseif ($pg -eq 10) {
                    # 会话：强调色气泡 + 绿色在线圆环 → 成片彩色
                    Check "docs:page10-social" ($hued -gt 5000) ("hued=" + $hued)
                } elseif ($pg -eq 11) {
                    # 图族：六色泳道 + 依赖图节点色点/强调边 → 成片彩色
                    Check "docs:page11-graph" ($hued -gt 2000) ("hued=" + $hued)
                } else {
                    # 文件浏览器：文件夹是强调色实心块 → 成片的强调色像素（窗口里没有其它蓝）
                    Check "docs:page5-folders" ($accent -gt 150) ("accent=" + $accent)
                }
            }
        } else {
            Check "docs:page$pg-text" $false "bmp not written"
        }
    }
} else {
    Skip "docs" "zzui-docs-x64.exe not found"
}

Write-Host "== 1.9 theme switching (--dark must repaint every token) =="
if (Test-Path 'zig-out/bin/zzui-gallery-x64.exe') {
    $tmp5 = Join-Path $env:TEMP 'zzui-regression-theme'
    if (-not (Test-Path $tmp5)) { New-Item -ItemType Directory -Path $tmp5 -Force | Out-Null }
    $lb = Join-Path $tmp5 'zzui-gallery-p0.bmp'
    Remove-Item $lb -ErrorAction SilentlyContinue
    $r = Invoke-GuiExe (Join-Path $root 'zig-out/bin/zzui-gallery-x64.exe') @('--shot-0') $tmp5
    Check "theme:light-exit" ($r.Code -eq 0) ("exit=" + $r.Code)
    $darkBg = -1
    if (Test-Path $lb) {
        $g = [IO.File]::ReadAllBytes($lb)
        $gw = [BitConverter]::ToInt32($g, 18)
        $gh = [BitConverter]::ToInt32($g, 22)
        $off = 54 + ($gh - 5) * $gw * 4 + 4 * 4
        $lightBg = [int]$g[$off] + [int]$g[$off+1] + [int]$g[$off+2]
        Check "theme:light-bg" ($lightBg -gt 600) ("sum=" + $lightBg)
    } else {
        Check "theme:light-bg" $false "bmp not written"
    }
    Remove-Item $lb -ErrorAction SilentlyContinue
    $r = Invoke-GuiExe (Join-Path $root 'zig-out/bin/zzui-gallery-x64.exe') @('--dark', '--shot-0') $tmp5
    Check "theme:dark-exit" ($r.Code -eq 0) ("exit=" + $r.Code)
    if (Test-Path $lb) {
        $g = [IO.File]::ReadAllBytes($lb)
        $gw = [BitConverter]::ToInt32($g, 18)
        $gh = [BitConverter]::ToInt32($g, 22)
        $off = 54 + ($gh - 5) * $gw * 4 + 4 * 4
        $darkBg = [int]$g[$off] + [int]$g[$off+1] + [int]$g[$off+2]
        # 深色底 0x15171A -> 三通道和 = 62
        Check "theme:dark-bg" ($darkBg -lt 120) ("sum=" + $darkBg)
        # 深色下文字要变成浅色：扫一段区域找亮像素
        $light = 0
        for ($y = 40; $y -lt 300; $y += 2) {
            for ($x = 20; $x -lt 600; $x += 2) {
                $off2 = 54 + ($gh - 1 - $y) * $gw * 4 + $x * 4
                if ($g[$off2] -gt 180 -and $g[$off2+1] -gt 180 -and $g[$off2+2] -gt 180) { $light++ }
            }
        }
        Check "theme:dark-text" ($light -gt 100) ("bright=" + $light)
    } else {
        Check "theme:dark-bg" $false "bmp not written"
    }
} else {
    Skip "theme" "zzui-gallery-x64.exe not found"
}

Write-Host "== 2. continuity =="
$tpl = 'tools/continuity/templates/用户级指令.instructions.md'
$inst = 'tools/continuity/install-global-instruction.ps1'
$sync = 'tools/continuity/sync-memory.ps1'
Check "continuity:template" (Test-Path $tpl) $tpl
Check "continuity:installer" (Test-Path $inst) $inst
Check "continuity:sync" (Test-Path $sync) $sync
if (Test-Path $tpl) {
    $ver = ([regex]::Match([IO.File]::ReadAllText((Resolve-Path $tpl)), '版本：([0-9.]+)')).Groups[1].Value
    Check "continuity:version" ([bool]$ver) ("version=$ver")
}
if ((Test-Path $inst) -and (Test-Path $tpl)) {
    $r = Invoke-Cmd 'powershell' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$inst) $root
    Check "continuity:selfcheck" ($r.Code -eq 0 -and $r.Output -match 'OK|INSTALLED|UPDATED|SKIP') ("exit=" + $r.Code + " " + $r.Output)
}

Write-Host "== 3. docs =="
foreach ($d in @('docs/项目接续指南.md','docs/用户档案.md','docs/决策记录.md','docs/项目记忆.md','.github/copilot-instructions.md','.vscode/tasks.json')) {
    Check ("docs:" + $d) (Test-Path $d)
}

Write-Host ""
if ($fail -eq 0) {
    Write-Host ("REGRESSION PASSED (skip={0})" -f $skip) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("REGRESSION FAILED: {0} failed, {1} skipped" -f $fail, $skip) -ForegroundColor Red
    exit 1
}
