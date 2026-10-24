# Dot-source this file, then call Ensure-XiaoguaiRuntime. No work runs on import.

function Get-XiaoguaiWindowsArchitecture {
    param([string]$Architecture)
    if (-not $Architecture) {
        $Architecture = $env:PROCESSOR_ARCHITEW6432
        if (-not $Architecture) { $Architecture = $env:PROCESSOR_ARCHITECTURE }
    }
    switch ($Architecture.ToUpperInvariant()) {
        'ARM64' { return 'arm64' }
        'AMD64' { return 'x64' }
        'X64'   { return 'x64' }
        'X86'   { return 'x86' }
        default { throw "无法识别 Windows 系统架构：$Architecture。" }
    }
}

function Invoke-XiaoguaiRuntimeCommand {
    param([string]$FilePath, [string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            ExitCode = $exitCode
            Output = ($output | ForEach-Object { $_.ToString() }) -join "`n"
        }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Get-XiaoguaiRuntimeCandidate {
    param([string]$Directory)
    if (-not $Directory) { return $null }
    $nodePath = Join-Path $Directory 'node.exe'
    $npmPath = Join-Path $Directory 'npm.cmd'
    if (-not (Test-Path -LiteralPath $nodePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $npmPath -PathType Leaf)) { return $null }
    $nodeResult = Invoke-XiaoguaiRuntimeCommand -FilePath $nodePath -Arguments @('--version')
    if ($nodeResult.ExitCode -ne 0 -or $nodeResult.Output.Trim() -notmatch '^v(\d+)\.\d+\.\d+$') {
        return $null
    }
    if ([int]$Matches[1] -lt 22) { return $null }
    $npmResult = Invoke-XiaoguaiRuntimeCommand -FilePath $npmPath -Arguments @('--version')
    if ($npmResult.ExitCode -ne 0 -or $npmResult.Output.Trim() -notmatch '^\d+\.\d+\.\d+$') {
        return $null
    }
    return [pscustomobject]@{
        NodePath = $nodePath
        NpmPath = $npmPath
        Version = $nodeResult.Output.Trim()
    }
}

function New-XiaoguaiRuntimeWorkDirectory {
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $path = Join-Path $tempRoot ('xiaoguai-runtime-work-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
    return $path
}

function Get-XiaoguaiExtendedPath {
    param([string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\')) { return '\\?\UNC\' + $fullPath.Substring(2) }
    return '\\?\' + $fullPath
}

function Remove-XiaoguaiRuntimeWorkDirectory {
    param([string]$Path)
    $rootFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if (-not $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($pathFull) -notmatch '^xiaoguai-runtime-work-[0-9a-f]{32}$') {
        throw '拒绝清理临时目录以外的运行环境工作目录。'
    }
    if (Test-Path -LiteralPath $pathFull) {
        try {
            [IO.Directory]::Delete((Get-XiaoguaiExtendedPath $pathFull), $true)
        } catch {
            Write-Warning "临时运行环境目录清理失败：$pathFull ($($_.Exception.Message))"
        }
    }
}

function Invoke-XiaoguaiRuntimeDownload {
    param([string]$Uri, [string]$Destination)
    $parsedUri = [uri]$Uri
    if ($parsedUri.Scheme -ne 'https' -or $parsedUri.Host -ne 'nodejs.org') {
        throw '运行时仅允许从 Node.js 官方 HTTPS 地址下载。'
    }
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $partial = $Destination + '.partial'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $partial -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $partial -PathType Leaf) -or
                (Get-Item -LiteralPath $partial).Length -eq 0) {
                throw '下载文件为空。'
            }
            Move-Item -LiteralPath $partial -Destination $Destination -Force -ErrorAction Stop
            return
        } catch {
            $downloadError = $_.Exception.Message
            if (Test-Path -LiteralPath $partial) {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            }
            if ($attempt -eq 3) {
                throw "运行环境下载失败：$Uri`n$downloadError`n请检查网络或代理后重新执行安装脚本。"
            }
            Write-Host "    下载失败，正在重试（$attempt/3）……" -ForegroundColor Yellow
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

function Get-XiaoguaiNodeRelease {
    param([string]$RuntimeRoot, [string]$Architecture)
    $workPath = New-XiaoguaiRuntimeWorkDirectory
    try {
        $indexPath = Join-Path $workPath 'index.json'
        Invoke-XiaoguaiRuntimeDownload -Uri 'https://nodejs.org/dist/index.json' -Destination $indexPath
        $releases = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $compatibleReleases = foreach ($releaseItem in $releases) {
            $versionMatch = [regex]::Match([string]$releaseItem.version, '^v(\d+)\.\d+\.\d+$')
            if ($releaseItem.lts -and $versionMatch.Success -and
                [int]$versionMatch.Groups[1].Value -ge 22 -and
                $releaseItem.files -contains "win-$Architecture-zip") { $releaseItem }
        }
        $release = $compatibleReleases |
            Sort-Object -Property @{ Expression = { [version]$_.version.Substring(1) }; Descending = $true } |
            Select-Object -First 1
        if (-not $release) { throw "Node.js 官方暂未提供符合要求的 Windows $Architecture LTS 压缩包。" }
        $versionText = [string]$release.version
        $archiveName = "node-$versionText-win-$Architecture.zip"
        $sumsPath = Join-Path $workPath 'SHASUMS256.txt'
        Invoke-XiaoguaiRuntimeDownload -Uri "https://nodejs.org/dist/$versionText/SHASUMS256.txt" -Destination $sumsPath
        $expectedHash = $null
        foreach ($line in (Get-Content -LiteralPath $sumsPath -Encoding UTF8)) {
            if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+)$' -and $Matches[2] -eq $archiveName) {
                $expectedHash = $Matches[1].ToUpperInvariant()
                break
            }
        }
        if (-not $expectedHash) { throw 'Node.js 官方校验清单中没有对应压缩包，已停止安装。' }
        return [pscustomobject]@{
            Version = $versionText
            ArchiveName = $archiveName
            DownloadUrl = "https://nodejs.org/dist/$versionText/$archiveName"
            Sha256 = $expectedHash
        }
    } finally {
        Remove-XiaoguaiRuntimeWorkDirectory -Path $workPath
    }
}

function Expand-XiaoguaiNodeArchive {
    param([string]$ArchivePath, [string]$Destination, [string]$DirectoryName)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $destinationFull = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    $destinationPrefix = $destinationFull + [IO.Path]::DirectorySeparatorChar
    $destinationLong = Get-XiaoguaiExtendedPath $destinationFull
    [IO.Directory]::CreateDirectory($destinationLong) | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ArchivePath))
    try {
        foreach ($entry in $archive.Entries) {
            $entryName = [string]$entry.FullName
            if (-not $entryName -or $entryName.StartsWith('/') -or $entryName.StartsWith('\') -or
                $entryName.Contains(':') -or $entryName.Contains([char]0)) {
                throw 'Node.js 压缩包包含异常路径，已停止解压。'
            }
            $isDirectory = $entryName.EndsWith('/') -or $entryName.EndsWith('\')
            $normalizedName = $entryName.Replace('\', '/')
            if ($isDirectory) { $normalizedName = $normalizedName.TrimEnd('/') }
            $segments = $normalizedName.Split('/')
            if ($segments.Count -lt 1 -or $segments[0] -ne $DirectoryName -or
                @($segments | Where-Object { -not $_ -or $_ -eq '.' -or $_ -eq '..' -or $_.Contains(':') }).Count -gt 0) {
                throw 'Node.js 压缩包包含异常路径，已停止解压。'
            }
            $relativePath = $normalizedName.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $targetPath = $destinationPrefix + $relativePath
            if (-not $targetPath.StartsWith($destinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Node.js 压缩包路径越出解压目录，已停止解压。'
            }
            $targetLong = Get-XiaoguaiExtendedPath $targetPath
            if ($isDirectory) {
                [IO.Directory]::CreateDirectory($targetLong) | Out-Null
                continue
            }
            $targetDirectory = [IO.Path]::GetDirectoryName($targetLong)
            [IO.Directory]::CreateDirectory($targetDirectory) | Out-Null
            $inputStream = $entry.Open()
            try {
                $outputStream = [IO.File]::Open($targetLong, [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $inputStream.CopyTo($outputStream) }
                finally { $outputStream.Dispose() }
            } finally {
                $inputStream.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Move-XiaoguaiRuntimeDirectory {
    param([string]$Source, [string]$Destination)
    $sourceFull = [IO.Path]::GetFullPath($Source)
    $destinationFull = [IO.Path]::GetFullPath($Destination)
    $sourceRoot = [IO.Path]::GetPathRoot($sourceFull)
    $destinationRoot = [IO.Path]::GetPathRoot($destinationFull)
    if ($sourceRoot.Equals($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
        [IO.Directory]::Move((Get-XiaoguaiExtendedPath $sourceFull),
            (Get-XiaoguaiExtendedPath $destinationFull))
        return
    }
    [IO.Directory]::CreateDirectory((Get-XiaoguaiExtendedPath $destinationFull)) | Out-Null
    foreach ($file in [IO.Directory]::GetFiles((Get-XiaoguaiExtendedPath $sourceFull), '*', [IO.SearchOption]::AllDirectories)) {
        $relative = $file.Substring((Get-XiaoguaiExtendedPath $sourceFull).Length).TrimStart('\', '/')
        $target = Join-Path $destinationFull $relative
        [IO.Directory]::CreateDirectory((Get-XiaoguaiExtendedPath ([IO.Path]::GetDirectoryName($target)))) | Out-Null
        [IO.File]::Copy((Get-XiaoguaiExtendedPath $file), (Get-XiaoguaiExtendedPath $target), $false)
    }
}

function Ensure-XiaoguaiRuntime {
    param([string]$RuntimeRoot)
    if (-not $RuntimeRoot) {
        if (-not $env:LOCALAPPDATA) { throw '未找到当前用户的 LOCALAPPDATA 目录。' }
        $RuntimeRoot = Join-Path $env:LOCALAPPDATA 'XiaoguaiArmor\runtime'
    }
    $RuntimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
    $architecture = Get-XiaoguaiWindowsArchitecture
    $candidate = $null
    $systemNode = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($systemNode) {
        $candidate = Get-XiaoguaiRuntimeCandidate -Directory ([IO.Path]::GetDirectoryName($systemNode.Source))
    }
    if (-not $candidate -and (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
        foreach ($cachedDirectory in (Get-ChildItem -LiteralPath $RuntimeRoot -Directory -Filter "node-v*-win-$architecture*" |
                Sort-Object LastWriteTime -Descending)) {
            $candidate = Get-XiaoguaiRuntimeCandidate -Directory $cachedDirectory.FullName
            if ($candidate) { break }
        }
    }
    if (-not $candidate) {
        Write-Host '    Node.js 或 npm 缺失、版本过旧或不可用，正在自动下载官方 LTS 运行环境……' -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $RuntimeRoot -Force -ErrorAction Stop | Out-Null
        $release = Get-XiaoguaiNodeRelease -RuntimeRoot $RuntimeRoot -Architecture $architecture
        $workPath = New-XiaoguaiRuntimeWorkDirectory
        try {
            $archivePath = Join-Path $workPath $release.ArchiveName
            Invoke-XiaoguaiRuntimeDownload -Uri $release.DownloadUrl -Destination $archivePath
            $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
            if ($actualHash -ne $release.Sha256) {
                throw 'Node.js 压缩包 SHA256 校验失败，已停止安装；请重新运行脚本下载。'
            }
            $directoryName = [IO.Path]::GetFileNameWithoutExtension($release.ArchiveName)
            $extractPath = Join-Path $workPath 'expanded'
            Expand-XiaoguaiNodeArchive -ArchivePath $archivePath -Destination $extractPath -DirectoryName $directoryName
            $sourcePath = Join-Path $extractPath $directoryName
            $candidate = Get-XiaoguaiRuntimeCandidate -Directory $sourcePath
            if (-not $candidate) { throw '下载的 Node.js 或 npm 未通过运行验证，已停止安装。' }
            $destinationPath = Join-Path $RuntimeRoot $directoryName
            if (Test-Path -LiteralPath $destinationPath) {
                $destinationPath = Join-Path $RuntimeRoot ($directoryName + '-' + [guid]::NewGuid().ToString('N'))
            }
            $sourceFull = [IO.Path]::GetFullPath($sourcePath)
            $destinationFull = [IO.Path]::GetFullPath($destinationPath)
            $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') +
                [IO.Path]::DirectorySeparatorChar
            $runtimePrefix = $RuntimeRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $sourceFull.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not $destinationFull.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw '运行环境路径检查失败，已停止安装。'
            }
            Move-XiaoguaiRuntimeDirectory -Source $sourceFull -Destination $destinationFull
            $candidate = Get-XiaoguaiRuntimeCandidate -Directory $destinationFull
            if (-not $candidate) { throw '运行环境缓存验证失败，请重新执行安装脚本。' }
        } finally {
            Remove-XiaoguaiRuntimeWorkDirectory -Path $workPath
        }
    }
    $nodeDirectory = [IO.Path]::GetDirectoryName($candidate.NodePath)
    $env:PATH = $nodeDirectory + [IO.Path]::PathSeparator + $env:PATH
    Write-Host "    Node.js $($candidate.Version) 与 npm 已就绪。" -ForegroundColor Green

    $pnpmPath = $null
    $systemPnpm = Get-Command pnpm.cmd -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($systemPnpm) {
        $pnpmResult = Invoke-XiaoguaiRuntimeCommand -FilePath $systemPnpm.Source -Arguments @('--version')
        if ($pnpmResult.ExitCode -eq 0 -and $pnpmResult.Output.Trim() -match '^\d+\.\d+\.\d+$') {
            $pnpmPath = $systemPnpm.Source
        }
    }
    if (-not $pnpmPath) {
        Write-Host '    pnpm 不可用，正在通过 npm 自动准备 pnpm@10……' -ForegroundColor Cyan
        $previousTimeout = $env:npm_config_fetch_timeout
        $previousRetries = $env:npm_config_fetch_retries
        try {
            $env:npm_config_fetch_timeout = '60000'
            $env:npm_config_fetch_retries = '1'
            $pnpmResult = Invoke-XiaoguaiRuntimeCommand -FilePath $candidate.NpmPath -Arguments @(
                'exec', '--yes', '--package=pnpm@10', '--', 'pnpm', '--version'
            )
            if ($pnpmResult.ExitCode -ne 0 -or $pnpmResult.Output.Trim() -notmatch '(?m)^10\.\d+\.\d+\s*$') {
                throw "自动准备 pnpm@10 失败：$($pnpmResult.Output)`n请检查 npm 网络或代理设置后重新执行安装脚本。"
            }
        } finally {
            $env:npm_config_fetch_timeout = $previousTimeout
            $env:npm_config_fetch_retries = $previousRetries
        }
    }
    return [pscustomobject]@{
        NodePath = $candidate.NodePath
        NpmPath = $candidate.NpmPath
        PnpmPath = $pnpmPath
    }
}
