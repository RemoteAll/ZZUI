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

Write-Host "== 1.3 size gate (hello = CUI baseline 303104 B; gallery = full-controls load) =="
# 两种产物口径不同，不能共用一个门槛：
#   hello   = 最小应用，真正的体积红线（CUI hello 296 KB 基线，只能收紧）
#   gallery = 加载全部控件的演示，体积随控件数增长（实测约 1.5 KB/控件），
#             它的意义是「全量装载的代价」，门槛按控件集增长单独设定。
$helloLimit = 303104
$galleryLimit = 327680
$exes = @(
    @{ path = 'zig-out/bin/zzui-hello-x64.exe'; limit = $helloLimit },
    @{ path = 'zig-out/bin/zzui-hello-x86.exe'; limit = $helloLimit },
    @{ path = 'zig-out/bin/zzui-gallery-x64.exe'; limit = $galleryLimit }
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

Write-Host "== 1.6 gallery (12 pages, all families) =="
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

    # 4 页逐页真渲染：每页都要有文字像素（证明该页控件真的画了）
    foreach ($pg in 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11) {
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
