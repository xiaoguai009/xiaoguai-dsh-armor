# 小怪 DSH 完美破甲 —— 一键上传 GitHub
# 用法：
#   .\push.ps1 -Token ghp_xxxxxxxxxxxx
#   .\push.ps1 -Token ghp_xxx -Repo xiaoguai-dsh-armor -Private
#   .\push.ps1 -Token ghp_xxx -Repo my-repo -Owner xiaoguai009
param(
    [Parameter(Mandatory=$true)][string]$Token,
    [string]$Owner = 'xiaoguai009',
    [string]$Repo  = 'xiaoguai-dsh-armor',
    [string]$Desc  = '小怪 DSH 完美破甲 v0.4.3 - DeepSeek Harness 本地提示词注入插件，双击 BAT 一键注入，离线可用',
    [switch]$Private
)

$ErrorActionPreference = 'Stop'
$repoDir = $PSScriptRoot

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn2{ param([string]$m) Write-Host "    [!] $m" -ForegroundColor Yellow }

$headers = @{
    Authorization          = "Bearer $Token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'xiaoguai-push'
}

# ---------- [1] 校验 token ----------
Write-Step '校验 GitHub Token'
try {
    $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -TimeoutSec 20
    Write-Ok "已登录：$($me.login)"
    if ($me.login -ne $Owner) {
        Write-Warn2 "Token 属于 $($me.login)，与 -Owner $Owner 不一致；自动改用 $($me.login)"
        $Owner = $me.login
    }
} catch {
    Write-Host "    [X] Token 无效或网络不通：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ---------- [2] 创建仓库（已存在则跳过） ----------
Write-Step "创建仓库 $Owner/$Repo"
$body = @{
    name        = $Repo
    description = $Desc
    private     = [bool]$Private
    has_issues  = $true
    has_wiki    = $false
    auto_init   = $false
} | ConvertTo-Json

$created = $false
try {
    $r = Invoke-RestMethod -Uri 'https://api.github.com/user/repos' -Method Post -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 30
    Write-Ok "仓库已创建：$($r.html_url)"
    $created = $true
} catch {
    $msg = $_.Exception.Message
    if ($msg -match '422|already exists') {
        Write-Warn2 "仓库已存在，直接推送"
    } else {
        Write-Host "    [X] 创建失败：$msg" -ForegroundColor Red
        exit 1
    }
}

# ---------- [3] 配置 remote 并推送 ----------
Write-Step '推送到 GitHub'
$remote = "https://$Owner`:$Token@github.com/$Owner/$Repo.git"
git -C $repoDir remote remove origin 2>$null
git -C $repoDir remote add origin $remote

$branch = (git -C $repoDir rev-parse --abbrev-ref HEAD).Trim()
Write-Ok "当前分支：$branch"

$env:GIT_TERMINAL_PROMPT = '0'
git -C $repoDir -c credential.helper= push -u origin $branch 2>&1 | ForEach-Object { "    $_" }
if ($LASTEXITCODE -ne 0) {
    Write-Host "    [X] 推送失败，退出码 $LASTEXITCODE" -ForegroundColor Red
    git -C $repoDir remote set-url origin "https://github.com/$Owner/$Repo.git"
    exit 1
}

# 推完把 token 从 remote URL 里摘掉，避免留在 .git/config
git -C $repoDir remote set-url origin "https://github.com/$Owner/$Repo.git"
Write-Ok '已移除 remote 中的 token'

# ---------- [4] 完成 ----------
Write-Host ''
Write-Host '================================================' -ForegroundColor Green
Write-Host '  上传完成' -ForegroundColor Green
Write-Host '================================================' -ForegroundColor Green
Write-Host "  仓库地址：https://github.com/$Owner/$Repo" -ForegroundColor White
Write-Host "  Clone   ：git clone https://github.com/$Owner/$Repo.git" -ForegroundColor White
Write-Host "  ZIP     ：https://github.com/$Owner/$Repo/archive/refs/heads/$branch.zip" -ForegroundColor White
Write-Host ''
Write-Host '  下一步（网页操作，可选）：' -ForegroundColor Yellow
Write-Host '    仓库页右侧 About → 填 Description、加 Topics：dsh, deepseek-harness, prompt-injection, plugin' -ForegroundColor Yellow
Write-Host ''
exit 0