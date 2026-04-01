param(
    [string]$RepoUrl = $(if ($env:MDM_REPO_URL) { $env:MDM_REPO_URL } else { 'https://github.com/hades496/MediaDownloadManager.git' }),
    [string]$Branch = $(if ($env:MDM_BRANCH) { $env:MDM_BRANCH } else { 'main' }),
    [string]$TargetDir = $(if ($env:MDM_INSTALL_DIR) { $env:MDM_INSTALL_DIR } else { Join-Path $HOME 'MediaDownloadManager' }),
    [switch]$SkipAutostart,
    [bool]$ForceReset = $(if ([string]::IsNullOrWhiteSpace($env:MDM_FORCE_RESET)) { $false } elseif ($env:MDM_FORCE_RESET -match '^(?i:1|true|yes|on)$') { $true } else { $false })
)

$ErrorActionPreference = 'Stop'

function Write-Info($Message) {
    Write-Host "[MDM installer] $Message"
}

function Write-Warn($Message) {
    Write-Host "[MDM installer] WARN: $Message"
}

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $paths = @()
    if ($machinePath) { $paths += $machinePath }
    if ($userPath) { $paths += $userPath }
    $env:Path = $paths -join ';'
}

function Test-IsInteractiveSession {
    try {
        return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    }
    catch {
        return $true
    }
}

function Ensure-Winget {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw '未检测到 winget，请先在系统中启用 App Installer / winget 后再执行。'
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    Write-Info "正在安装 $DisplayName ..."
    winget install --id $Id -e --source winget --accept-package-agreements --accept-source-agreements --silent | Out-Host
}

function Ensure-Prerequisites {
    Ensure-Winget

    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        Install-WingetPackage -Id 'Git.Git' -DisplayName 'Git'
        Refresh-Path
    }

    if (-not (Get-Command python.exe -ErrorAction SilentlyContinue) -and -not (Get-Command py.exe -ErrorAction SilentlyContinue)) {
        Install-WingetPackage -Id 'Python.Python.3.12' -DisplayName 'Python 3.12'
        Refresh-Path
    }

    if (-not (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) {
        Install-WingetPackage -Id 'Gyan.FFmpeg' -DisplayName 'FFmpeg'
        Refresh-Path
    }

    if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) {
        try {
            Install-WingetPackage -Id 'GitHub.cli' -DisplayName 'GitHub CLI'
            Refresh-Path
        }
        catch {
            Write-Warn 'GitHub CLI 安装失败，将在认证阶段回退为 Token 输入方式。'
        }
    }
}

$script:GitHubHttpsRepoPattern = '^https?://github\.com/[^/]+/[^/]+(\.git)?$'
$script:GitHubScpRepoPattern = '^git' + [regex]::Escape([string][char]64) + 'github\.com:[^/]+/[^/]+(\.git)?$'
$script:GitHubSshRepoPattern = '^ssh://git' + [regex]::Escape([string][char]64) + 'github\.com/[^/]+/[^/]+(\.git)?$'
$script:GitHubCredentialedHttpsRepoPattern = '^https?://[^/@]+(?::[^@]*)?' + [regex]::Escape([string][char]64) + 'github\.com/[^/]+/[^/]+(\.git)?/?$'
$script:GitHubCredentialedHttpsSlugPattern = '^https?://[^/@]+(?::[^@]*)?' + [regex]::Escape([string][char]64) + 'github\.com/(?<slug>[^/]+/[^/]+?)(?<suffix>\.git)?/?$'

function Test-IsGitHubRepoUrl {
    param([string]$Url)

    return (-not [string]::IsNullOrWhiteSpace($Url)) -and (
        ($Url -match $script:GitHubHttpsRepoPattern) -or
        ($Url -match $script:GitHubScpRepoPattern) -or
        ($Url -match $script:GitHubSshRepoPattern)
    )
}

function Test-SupportsTokenFallback {
    param([string]$Url)

    return (-not [string]::IsNullOrWhiteSpace($Url)) -and ($Url -match $script:GitHubHttpsRepoPattern)
}

function Get-SanitizedRepoUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }

    return [regex]::Replace($Url.Trim(), '^(https?://)[^/@]+(?::[^@]*)?' + [regex]::Escape([string][char]64), '$1')
}

function Repair-OriginRemoteIfNeeded {
    if (-not (Test-Path (Join-Path $TargetDir '.git'))) {
        return
    }

    $originUrlOutput = & git -C $TargetDir remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $originUrlOutput) {
        return
    }

    $originUrl = ($originUrlOutput | Select-Object -First 1).ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($originUrl) -or -not ($originUrl -match $script:GitHubCredentialedHttpsRepoPattern)) {
        return
    }

    $match = [regex]::Match($originUrl, $script:GitHubCredentialedHttpsSlugPattern)
    if (-not $match.Success) {
        return
    }

    $normalizedUrl = "https://github.com/$($match.Groups['slug'].Value)$($match.Groups['suffix'].Value)"
    if ([string]::IsNullOrWhiteSpace($normalizedUrl) -or $normalizedUrl -eq $originUrl) {
        return
    }

    & git -C $TargetDir remote set-url origin $normalizedUrl *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn '检测到历史凭证化 remote，但自动修复失败，将继续当前流程。'
    }
}

function Test-RepoHasTrackedChanges {
    $statusOutput = & git -C $TargetDir status --porcelain --untracked-files=no 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    return -not [string]::IsNullOrWhiteSpace((($statusOutput | Out-String).Trim()))
}

function Test-RepoHasUnmergedPaths {
    $unmergedOutput = & git -C $TargetDir diff --name-only --diff-filter=U 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    return -not [string]::IsNullOrWhiteSpace((($unmergedOutput | Out-String).Trim()))
}

function Repair-UnmergedStateIfNeeded {
    if (-not (Test-RepoHasUnmergedPaths)) {
        return
    }

    Write-Warn '检测到仓库存在未完成合并，正在自动清理冲突状态后继续更新...'

    & git -C $TargetDir merge --abort *> $null
    & git -C $TargetDir rebase --abort *> $null
    & git -C $TargetDir cherry-pick --abort *> $null

    & git -C $TargetDir reset --hard HEAD | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw '检测到未完成合并且自动清理失败，请先手动处理冲突后重试。'
    }

    if (Test-RepoHasUnmergedPaths) {
        throw '检测到未完成合并且无法自动恢复，请先手动处理冲突后重试。'
    }
}

function Ensure-GitHubAuth {
    param([Parameter(Mandatory = $true)][string]$Url)

    if (-not (Test-IsGitHubRepoUrl $Url)) {
        return $false
    }

    if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) {
        Write-Warn '未检测到 GitHub CLI，将在必要时回退为 Token 输入方式。'
        return $false
    }

    & gh.exe auth status *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Info '检测到 GitHub CLI 已登录，正在复用 gh 凭证...'
    }
    else {
        if (-not (Test-IsInteractiveSession)) {
            Write-Warn '当前无交互终端，将在必要时回退为 Token 输入方式。'
            return $false
        }

        Write-Info '检测到 GitHub 仓库，优先使用 GitHub CLI 登录...'
        & gh.exe auth login
        if ($LASTEXITCODE -ne 0) {
            Write-Warn 'GitHub CLI 登录未完成，将在必要时回退为 Token 输入方式。'
            return $false
        }
    }

    & gh.exe auth setup-git *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'gh auth setup-git 执行失败，将在必要时回退为 Token 输入方式。'
        return $false
    }

    return $true
}

function Get-GitHubToken {
    param([Parameter(Mandatory = $true)][string]$Url)

    if ($script:GitHubTokenPlain) {
        return $script:GitHubTokenPlain
    }

    if ($env:GITHUB_TOKEN) {
        $script:GitHubTokenPlain = $env:GITHUB_TOKEN
        return $script:GitHubTokenPlain
    }

    if (-not (Test-SupportsTokenFallback $Url)) {
        throw '当前仓库地址不支持 Token 回退，请改用 GitHub CLI 或提供可访问的 GitHub HTTPS 仓库地址。'
    }

    Write-Info 'GitHub CLI 认证不可用，回退为 Personal Access Token 访问。'
    Write-Info ''
    Write-Info '获取 Token 步骤：'
    Write-Info "1. 访问 https://github.com/settings/tokens"
    Write-Info "2. 点击 'Generate new token' → 'Generate new token (classic)'"
    Write-Info "3. 选择 'repo' 权限（访问私有仓库）"
    Write-Info "4. 点击 'Generate token' 并复制"
    Write-Info ''

    if (-not (Test-IsInteractiveSession)) {
        throw '当前环境没有交互终端，无法手动输入 Token；请先设置 GITHUB_TOKEN 环境变量后重试。'
    }

    $secureToken = Read-Host -Prompt '请输入你的GitHub Personal Access Token' -AsSecureString
    $tokenBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    try {
        $tokenPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($tokenBstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenBstr)
    }

    if ([string]::IsNullOrWhiteSpace($tokenPlain)) {
        throw 'Token不能为空，请重新运行并输入有效的GitHub Token。'
    }

    $script:GitHubTokenPlain = $tokenPlain
    $env:GITHUB_TOKEN = $tokenPlain
    return $script:GitHubTokenPlain
}

function New-GitAskPassScript {
    $askPassPath = Join-Path ([System.IO.Path]::GetTempPath()) ("mdm-git-askpass-" + [Guid]::NewGuid().ToString('N') + '.cmd')
    $content = @'
@echo off
setlocal
set "PROMPT_TEXT=%*"
echo %PROMPT_TEXT% | findstr /I "Username" >nul
if not errorlevel 1 (
    echo git
) else (
    echo %GITHUB_TOKEN%
)
'@
    Set-Content -Path $askPassPath -Value $content -Encoding Ascii
    return $askPassPath
}

function Invoke-GitWithTokenAuth {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][scriptblock]$Operation
    )

    $null = Get-GitHubToken -Url $Url
    $askPassPath = New-GitAskPassScript
    try {
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:GIT_ASKPASS = $askPassPath
        return (& $Operation)
    }
    finally {
        Remove-Item -Path $askPassPath -Force -ErrorAction SilentlyContinue
        Remove-Item Env:GIT_ASKPASS -ErrorAction SilentlyContinue
        Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
        Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
        $script:GitHubTokenPlain = $null
    }
}

function Invoke-GitCloneCore {
    param([Parameter(Mandatory = $true)][string]$CloneUrl)

    & git clone --branch $Branch $CloneUrl $TargetDir | Out-Host
    return ($LASTEXITCODE -eq 0)
}

function Invoke-GitUpdateCore {
    & git -C $TargetDir fetch --all --tags --prune | Out-Host
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    & git -C $TargetDir checkout $Branch | Out-Host
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    & git -C $TargetDir reset --hard "origin/$Branch" | Out-Host
    return ($LASTEXITCODE -eq 0)
}

function Clone-Or-UpdateRepo {
    $parent = Split-Path -Parent $TargetDir
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (Test-Path (Join-Path $TargetDir '.git')) {
        Write-Info '检测到已有仓库，正在更新...'
        Repair-OriginRemoteIfNeeded
        Repair-UnmergedStateIfNeeded
        $originUrl = ''
        $originUrlOutput = & git -C $TargetDir remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0 -and $originUrlOutput) {
            $originUrl = ($originUrlOutput | Select-Object -First 1).ToString().Trim()
        }

        $didStash = $false
        if ($ForceReset) {
            Write-Warn '已启用强制覆盖更新：将丢弃本地未提交改动与未跟踪文件。'
            & git -C $TargetDir reset --hard HEAD | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw '强制覆盖前清理本地改动失败。'
            }
            & git -C $TargetDir clean -fd | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw '强制覆盖前清理未跟踪文件失败。'
            }
        }
        elseif (Test-RepoHasTrackedChanges) {
            Write-Warn '检测到本地已跟踪文件有改动，自动暂存（git stash）后继续更新...'
            & git -C $TargetDir stash push -m 'mdm-installer-auto-stash' --quiet | Out-Host
            if ($LASTEXITCODE -eq 0) {
                $didStash = $true
            }
            else {
                throw '自动暂存本地修改失败，请手动执行 git stash 或提交改动后重试。'
            }
        }

        $authReady = $false
        if (Test-IsGitHubRepoUrl $originUrl) {
            $authReady = Ensure-GitHubAuth -Url $originUrl
        }

        & git -C $TargetDir fetch --all --tags --prune | Out-Host
        if ($LASTEXITCODE -ne 0) {
            if (Test-SupportsTokenFallback $originUrl) {
                if ($authReady) {
                    Write-Warn '使用 GitHub CLI 方式执行 fetch 失败，可能是远端认证或网络问题，回退为 Token 输入方式重试...'
                }
                if (-not (Invoke-GitWithTokenAuth -Url $originUrl -Operation { Invoke-GitUpdateCore })) {
                    throw '仓库更新失败，请查看上方 git 原始错误；若提示分支不存在、无法快进或访问受限，请先处理后重试。'
                }
            }
            else {
                throw 'git fetch 失败，请查看上方 git 原始错误并检查远端访问权限。'
            }
            if ($didStash) {
                & git -C $TargetDir stash pop --quiet | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    Write-Warn '自动恢复暂存的本地修改失败，请手动执行 git stash pop 恢复。'
                }
            }
            return
        }

        & git -C $TargetDir checkout $Branch | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw 'git checkout 失败，请检查目标分支是否存在，或先处理本地改动后重试。'
        }

        & git -C $TargetDir reset --hard "origin/$Branch" | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw 'git reset --hard 失败，请查看上方 git 原始错误。'
        }

        if ($didStash) {
            & git -C $TargetDir stash pop --quiet | Out-Host
            if ($LASTEXITCODE -ne 0) {
                Write-Warn '自动恢复暂存的本地修改失败，请手动执行 git stash pop 恢复。'
            }
        }
        return
    }

    if ((Test-Path $TargetDir) -and ((Get-ChildItem -Force -Path $TargetDir | Measure-Object).Count -gt 0)) {
        throw "目标目录已存在且非空: $TargetDir"
    }

    if (Test-Path $TargetDir) {
        Remove-Item -Recurse -Force $TargetDir
    }

    $authReady = $false
    if (Test-IsGitHubRepoUrl $RepoUrl) {
        $authReady = Ensure-GitHubAuth -Url $RepoUrl
    }

    Write-Info "正在克隆项目到 $TargetDir ..."
    if (-not (Invoke-GitCloneCore -CloneUrl $RepoUrl)) {
        if (Test-SupportsTokenFallback $RepoUrl) {
            if ($authReady) {
                Write-Warn '使用 GitHub CLI 方式拉取失败，回退为 Token 输入方式重试...'
            }
            if (Test-Path $TargetDir) {
                Remove-Item -Recurse -Force $TargetDir
            }
            if (-not (Invoke-GitWithTokenAuth -Url $RepoUrl -Operation { Invoke-GitCloneCore -CloneUrl $RepoUrl })) {
                throw '仓库克隆失败，请检查仓库地址、分支或访问权限。'
            }
        }
        else {
            throw '仓库克隆失败，请检查仓库地址、分支或访问权限。'
        }
    }

    Repair-OriginRemoteIfNeeded
}

function Start-ProjectNow {
    Write-Info '开始启动项目...'
    $command = "cd /d \"$TargetDir\" && set MDM_NONINTERACTIVE=1 && set MDM_NO_BROWSER=1 && call start.bat"
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $command -Wait -NoNewWindow
}

function Configure-Autostart {
    $startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    $autostartCmd = Join-Path $startupDir 'MediaDownloadManager_Autostart.cmd'
    $content = @"
@echo off
cd /d "$TargetDir"
set MDM_NONINTERACTIVE=1
set MDM_NO_BROWSER=1
call start.bat
"@
    New-Item -ItemType Directory -Path $startupDir -Force | Out-Null
    Set-Content -Path $autostartCmd -Value $content -Encoding UTF8
    Write-Info "已写入 Windows 自启动脚本: $autostartCmd"
}

function Show-Summary {
    Write-Host ''
    Write-Host '====================================='
    Write-Host 'MediaDownloadManager 一键安装完成'
    Write-Host '-------------------------------------'
    Write-Host ("仓库地址: " + (Get-SanitizedRepoUrl -Url $RepoUrl))
    Write-Host "安装目录: $TargetDir"
    Write-Host '立即启动: 已执行'
    Write-Host ("开机自启: " + ($(if ($SkipAutostart) { '已跳过' } else { '已配置（登录后自动启动）' })))
    Write-Host '访问地址: http://127.0.0.1:8080'
    Write-Host ("停止服务: cd /d `"$TargetDir`" && stop.bat")
    Write-Host '====================================='
}

Ensure-Prerequisites
Clone-Or-UpdateRepo
Start-ProjectNow
if (-not $SkipAutostart) {
    Configure-Autostart
}
Show-Summary
