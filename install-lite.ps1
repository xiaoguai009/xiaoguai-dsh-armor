# 小怪破甲 离线一键注入（不依赖 node / npm / pnpm）
# 直接把插件放进 .dsh\plugins，并同步到 profile 的 node_modules，改 package.json 与 cordis.patch.yml。
[CmdletBinding()]
param(
    [string]$DshHome = "",
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$pluginName  = 'xiaoguai-armor'
$pluginLabel = '小怪破甲'
$srcDir      = $PSScriptRoot

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn2{ param([string]$m) Write-Host "    [!] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "    [X] $m" -ForegroundColor Red }

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  $pluginLabel v0.4.3  离线一键注入" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan

# ---------- [1] 定位 .dsh ----------
Write-Step "定位 DeepSeek Harness 配置目录"

if (-not $DshHome) {
    if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME }
    else { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
}
$DshHome = [IO.Path]::GetFullPath($DshHome)
if (-not (Test-Path -LiteralPath $DshHome)) {
    Write-Err "未找到 DSH 配置目录：$DshHome"
    Write-Host "    请先安装并启动过一次 DeepSeek Harness，再运行本脚本。" -ForegroundColor Red
    if (-not $NoPause) { try { Read-Host "按回车退出" | Out-Null } catch {} }
    exit 1
}
Write-Ok "DSH 目录：$DshHome"

$profilesRoot = Join-Path $DshHome 'profiles'
if (-not (Test-Path -LiteralPath $profilesRoot)) {
    Write-Err "未找到 profiles 目录：$profilesRoot"
    if (-not $NoPause) { try { Read-Host "按回车退出" | Out-Null } catch {} }
    exit 1
}

$profileDirs = @(Get-ChildItem -LiteralPath $profilesRoot -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'node_modules' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'package.json')) })
if ($profileDirs.Count -eq 0) {
    Write-Err "$profilesRoot 下没有含 package.json 的 profile 目录"
    if (-not $NoPause) { try { Read-Host "按回车退出" | Out-Null } catch {} }
    exit 1
}
foreach ($p in $profileDirs) { Write-Ok "目标 profile：$($p.Name)  ($($p.FullName))" }

# ---------- [2] 校验安装包完整性 ----------
Write-Step "校验安装包"

$required = @('package.json','index.js','client.js','cordis.patch.yml',
              'prompts\xiaoguai.md','prompts\xiaoguai-mirror.md','prompts\xiaoguai-compat.md')
foreach ($rel in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $srcDir $rel) -PathType Leaf)) {
        Write-Err "安装包缺少文件：$rel"
        if (-not $NoPause) { try { Read-Host "按回车退出" | Out-Null } catch {} }
        exit 1
    }
}
Write-Ok "安装包完整（$($required.Count) 个必需文件）"

# ---------- [3] 复制插件到 .dsh\plugins ----------
Write-Step "部署插件文件"

$pluginsDir = Join-Path $DshHome 'plugins'
if (-not (Test-Path -LiteralPath $pluginsDir)) { New-Item -ItemType Directory -Path $pluginsDir -Force | Out-Null }
$destDir = Join-Path $pluginsDir $pluginName

if (Test-Path -LiteralPath $destDir) {
    Write-Warn2 "已存在旧版 $pluginName，先清理"
    Remove-Item -LiteralPath $destDir -Recurse -Force
}
robocopy $srcDir $destDir /E /NFL /NDL /NJH /NJS /NC /NS /XD .git | Out-Null
if ($LASTEXITCODE -ge 8) {
    Write-Err "复制失败（robocopy 退出码 $LASTEXITCODE）"
    if (-not $NoPause) { try { Read-Host "按回车退出" | Out-Null } catch {} }
    exit 1
}
Write-Ok "插件已部署到：$destDir"

# ---------- [4] 改 profile 的 package.json + cordis.patch.yml ----------
foreach ($pDir in $profileDirs) {
    $pName = $pDir.Name
    $pkgPath = Join-Path $pDir.FullName 'package.json'

    Write-Step "[$pName] 备份并写入 package.json"
    $bak = "$pkgPath.bak-xiaoguai-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $pkgPath -Destination $bak -Force
    Write-Ok "备份：$bak"

    $pkg = Get-Content -LiteralPath $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $pkg.dependencies) {
        $pkg | Add-Member -NotePropertyName 'dependencies' -NotePropertyValue ([pscustomobject]@{})
    }
    $depName = "file:../../plugins/$pluginName"
    if ($pkg.dependencies.PSObject.Properties.Name -contains $pluginName) {
        $pkg.dependencies.$pluginName = $depName
        Write-Ok "dependencies 已更新：$pluginName -> $depName"
    } else {
        $pkg.dependencies | Add-Member -NotePropertyName $pluginName -NotePropertyValue $depName -Force
        Write-Ok "dependencies 已添加：$pluginName -> $depName"
    }

    if ($pkg.dsh -and $pkg.dsh.profile -and $pkg.dsh.profile.bundles) {
        $pkg.dsh.profile.bundles = @($pkg.dsh.profile.bundles | Where-Object { $_ -ne $pluginName })
        Write-Ok "bundles 已排除 $pluginName（第三方插件不放进基础 bundle）"
    }

    $json = $pkg | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($pkgPath, $json + [Environment]::NewLine, $utf8NoBom)

    Write-Step "[$pName] 写入 cordis.patch.yml"
    $patchPath = Join-Path $pDir.FullName 'cordis.patch.yml'
    $content = ''
    if (Test-Path -LiteralPath $patchPath) {
        $content = [System.IO.File]::ReadAllText($patchPath, [System.Text.Encoding]::UTF8)
    }
    $content = $content -replace '^\s*\[\]\s*$', ''
    # 移除本插件旧的 insert 块，保证幂等
    $content = $content -replace "(?ms)^[ \t]*-[ \t]*insert:[ \t]*\r?\n[ \t]*-[ \t]*id:[ \t]*$([regex]::Escape($pluginName))[ \t]*(?:\r?\n|\z).*?(?=^[ \t]*-[ \t]*id:|^[ \t]*-[ \t]*insert:|\z)", ''
    $content = $content.Trim()

    if ($content -notmatch "(?m)^\s*-\s*id:\s*system-prompt") {
        $overlay = @"
- id: system-prompt
  config:
    includeHarnessIdentity: false
    personaPrefix: ""
    personaSuffix: Your working directory is {{cwd}}.
"@
        $content = if ($content.Length -gt 0) { "$content`n`n$overlay" } else { $overlay }
        Write-Ok "已写入 system-prompt 覆盖（关闭宿主身份）"
    } else {
        Write-Ok "system-prompt 覆盖已存在，保留"
    }

    $insertBlock = @"
- insert:
    - id: $pluginName
      name: '$pluginName'
      config:
        enabled: true
        autoApplyOnStart: true
"@
    $content = "$content`n`n$insertBlock"
    [System.IO.File]::WriteAllText($patchPath, $content.Trim() + [Environment]::NewLine, $utf8NoBom)
    Write-Ok "已挂载 $pluginName 到 patch 层"

    # ---------- [5] 同步到 node_modules（免 pnpm install） ----------
    Write-Step "[$pName] 同步到 node_modules"
    $nmDir = Join-Path $pDir.FullName 'node_modules'
    if (-not (Test-Path -LiteralPath $nmDir)) { New-Item -ItemType Directory -Path $nmDir -Force | Out-Null }
    $nmEntry = Join-Path $nmDir $pluginName
    if (Test-Path -LiteralPath $nmEntry) {
        $item = Get-Item -LiteralPath $nmEntry -Force
        if ($item.LinkType) { cmd.exe /c "rmdir `"$nmEntry`"" 2>$null | Out-Null }
        if (Test-Path -LiteralPath $nmEntry) { Remove-Item -LiteralPath $nmEntry -Recurse -Force }
    }
    Copy-Item -LiteralPath $destDir -Destination $nmEntry -Recurse -Force
    Write-Ok "已复制插件到：$nmEntry"
}

# ---------- [6] 兼容补丁（存在就执行，失败不影响） ----------
Write-Step "应用宿主兼容补丁"
$patcher = Join-Path $destDir 'scripts\lib\patcher.js'
$nodeExe = $null
foreach ($cand in @(
    (Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    (Join-Path $env:ProgramFiles 'nodejs\node.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')
)) {
    if ($cand -and (Test-Path -LiteralPath $cand -PathType Leaf)) { $nodeExe = $cand; break }
}
if ($nodeExe -and (Test-Path -LiteralPath $patcher)) {
    try {
        $tmpJs = Join-Path $env:TEMP ("xiaoguai-patch-" + [guid]::NewGuid().ToString('N') + ".mjs")
        $code = @"
import { pathToFileURL } from 'node:url';
const mod = await import(pathToFileURL(process.argv[2]).href);
const result = mod.applyAllPatches({ dshHome: process.argv[3] });
console.log(JSON.stringify(result));
"@
        [System.IO.File]::WriteAllText($tmpJs, $code, $utf8NoBom)
        & $nodeExe $tmpJs $patcher $DshHome | Out-Null
        Remove-Item -LiteralPath $tmpJs -Force -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -eq 0) { Write-Ok "兼容补丁已应用（node：$nodeExe）" }
        else { Write-Warn2 "兼容补丁未完全应用，不影响基础注入" }
    } catch {
        Write-Warn2 "兼容补丁跳过：$($_.Exception.Message)"
    }
} else {
    Write-Warn2 "未找到 node.exe 或 patcher.js，跳过兼容补丁（不影响基础注入）"
}

# ---------- [7] 完成 ----------
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  $pluginLabel 注入完成" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  下一步：完全退出并重启 DeepSeek Harness（网页版刷新页面）" -ForegroundColor White
Write-Host "  验证：输入框上方出现绿色状态条「$($pluginLabel)已激活」" -ForegroundColor Yellow
Write-Host "  激活词：小怪" -ForegroundColor Yellow
Write-Host "  卸载：双击「点我一键卸载.bat」" -ForegroundColor Yellow
Write-Host ""
if (-not $NoPause) { try { Read-Host "按回车退出" | Out-Null } catch {} }
exit 0