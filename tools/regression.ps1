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
# PS 5.1: external command stderr must not be treated as terminating error
function Invoke-Cmd($exe, [string[]]$argv, [string]$workdir) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $workdir
    $out = & $exe @argv 2>&1
    $code = $LASTEXITCODE
    Pop-Location
    $ErrorActionPreference = $old
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
