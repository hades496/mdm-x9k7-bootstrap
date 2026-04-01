param(
    [string]$RepoUrl = $(if ($env:MDM_REPO_URL) { $env:MDM_REPO_URL } else { 'https://github.com/hades496/MediaDownloadManager.git' }),
    [string]$Branch = $(if ($env:MDM_BRANCH) { $env:MDM_BRANCH } else { 'main' }),
    [string]$TargetDir = $(if ($env:MDM_INSTALL_DIR) { $env:MDM_INSTALL_DIR } else { Join-Path $HOME 'MediaDownloadManager' }),
    [switch]$SkipAutostart
)

$ErrorActionPreference = 'Stop'

function Write-Info($Message) {
    Write-Host "[MDM installer] $Message"
}

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $paths = @()
    if ($machinePath) { $paths += $machinePath }
    if ($userPath) { $paths += $userPath }
    $env:Path = $paths -join ';'
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
}

function Get-GitHubToken {
    # 检查仓库是否是私有仓库（URL包含github.com且没有token）
    if ($RepoUrl -like '*github.com*' -and $RepoUrl -notlike '*@github.com*') {
        Write-Info "检测到GitHub私有仓库，需要Personal Access Token进行访问。"
        Write-Info ""
        Write-Info "获取Token步骤："
        Write-Info "1. 访问 https://github.com/settings/tokens"
        Write-Info "2. 点击 'Generate new token' → 'Generate new token (classic)'"
        Write-Info "3. 选择 'repo' 权限（访问私有仓库）"
        Write-Info "4. 点击 'Generate token' 并复制"
        Write-Info ""
        
        $script:GitHubToken = Read-Host -Prompt "请输入你的GitHub Personal Access Token" -AsSecureString
        $tokenPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($GitHubToken))
        
        if ([string]::IsNullOrWhiteSpace($tokenPlain)) {
            throw "Token不能为空，请重新运行并输入有效的GitHub Token。"
        }
        
        # 将token嵌入到URL中
        $script:RepoUrl = $RepoUrl -replace 'github.com', "$tokenPlain@github.com"
        Write-Info "已配置私有仓库访问，正在克隆..."
    }
}

function Clone-Or-UpdateRepo {
    $parent = Split-Path -Parent $TargetDir
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (Test-Path (Join-Path $TargetDir '.git')) {
        Write-Info '检测到已有仓库，正在更新...'
        git -C $TargetDir fetch --all --tags --prune | Out-Host
        git -C $TargetDir checkout $Branch | Out-Host
        git -C $TargetDir pull --ff-only origin $Branch | Out-Host
        return
    }

    if ((Test-Path $TargetDir) -and ((Get-ChildItem -Force -Path $TargetDir | Measure-Object).Count -gt 0)) {
        throw "目标目录已存在且非空: $TargetDir"
    }

    if (Test-Path $TargetDir) {
        Remove-Item -Recurse -Force $TargetDir
    }

    # 提示输入GitHub Token（如果是私有仓库）
    Get-GitHubToken

    Write-Info "正在克隆项目到 $TargetDir ..."
    git clone --branch $Branch $RepoUrl $TargetDir | Out-Host
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
    Write-Host "仓库地址: $RepoUrl"
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
