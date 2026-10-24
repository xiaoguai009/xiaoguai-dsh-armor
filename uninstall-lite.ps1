# 小怪破甲 离线一键卸载
[CmdletBinding()]
param(
    [string]$DshHome = "",
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$pluginName  = 'xiaoguai-armor'
$pluginLabel = '小怪破甲'

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Err  { param([string]$m) Write-Host "    [X] $m" -ForegroundColor Red }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  $pluginLabel v0.4.3  离线一键卸载" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

if (-not $DshHome) {
    if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME }
    else { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
}
$DshHome = [IO.Path]::GetFullPath($DshHome)
if (-not (Test-Path -LiteralPath $DshHome)) {
    Write-Err "未找到 DSH 配置目录：$DshHome"
    if (-not $NoPause) { try { Read-Host "按回车退出" | Out-Null } catch {} }
    exit 1
}

$profilesRoot = Join-Path $DshHome 'profiles'
$profileDirs = @()
if (Test-Path -LiteralPath $profilesRoot) {
    $profileDirs = @(Get-ChildItem -LiteralPath $profilesRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'node_modules' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'package.json')) })
}

foreach ($pDir in $profileDirs) {
    $pName = $pDir.Name
    $pkgPath = Join-Path $pDir.FullName 'package.json'

    Write-Step "[$pName] 清理 package.json"
    $pkg = Get-Content -LiteralPath $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $changed = $false
    if ($pkg.dependencies -and $pkg.dependencies.PSObject.Properties.Name -contains $pluginName) {
        $pkg.dependencies.PSObject.Properties.Remove($pluginName)
        $changed = $true
    }
    if ($pkg.dsh -and $pkg.dsh.profile -and $pkg.dsh.profile.bundles) {
        $before = @($pkg.dsh.profile.bundles).Count
        $pkg.dsh.profile.bundles = @($pkg.dsh.profile.bundles | Where-Object { $_ -ne $pluginName })
        if (@($pkg.dsh.profile.bundles).Count -ne $before) { $changed = $true }
    }
    if ($changed) {
        $json = $pkg | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($pkgPath, $json + [Environment]::NewLine, $utf8NoBom)
        Write-Ok "已从 package.json 移除 $pluginName"
    } else {
        Write-Ok "package.json 无本插件条目"
    }

    Write-Step "[$pName] 清理 cordis.patch.yml"
    $patchPath = Join-Path $pDir.FullName 'cordis.patch.yml'
    if (Test-Path -LiteralPath $patchPath) {
        $content = [System.IO.File]::ReadAllText($patchPath, [System.Text.Encoding]::UTF8)
        $orig = $content
        $content = $content -replace "(?ms)^[ \t]*-[ \t]*insert:[ \t]*\r?\n[ \t]*-[ \t]*id:[ \t]*$([regex]::Escape($pluginName))[ \t]*(?:\r?\n|\z).*?(?=^[ \t]*-[ \t]*id:|^[ \t]*-[ \t]*insert:|\z)", ''
        $content = $content.Trim()
        [System.IO.File]::WriteAllText($patchPath, $content + [Environment]::NewLine, $utf8NoBom)
        if ($content -ne $orig.Trim()) { Write-Ok "已移除插件挂载块" } else { Write-Ok "patch 中无本插件块" }
    }

    Write-Step "[$pName] 清理 node_modules"
    $nmEntry = Join-Path $pDir.FullName "node_modules\$pluginName"
    if (Test-Path -LiteralPath $nmEntry) {
        $item = Get-Item -LiteralPath $nmEntry -Force
        if ($item.LinkType) { cmd.exe /c "rmdir `"$nmEntry`"" 2>$null | Out-Null }
        if (Test-Path -LiteralPath $nmEntry) { Remove-Item -LiteralPath $nmEntry -Recurse -Force }
        Write-Ok "已删除 node_modules\$pluginName"
    } else {
        Write-Ok "node_modules 中无本插件"
    }
}

Write-Step "删除插件目录"
$destDir = Join-Path (Join-Path $DshHome 'plugins') $pluginName
if (Test-Path -LiteralPath $destDir) {
    Remove-Item -LiteralPath $destDir -Recurse -Force
    Write-Ok "已删除：$destDir"
} else {
    Write-Ok "插件目录不存在，无需删除"
}

Write-Host ""
Write-Host "  $pluginLabel 卸载完成，请重启 DeepSeek Harness。" -ForegroundColor Green
Write-Host ""
if (-not $NoPause) { try { Read-Host "按回车退出" | Out-Null } catch {} }
exit 0