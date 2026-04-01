#!/bin/bash
set -euo pipefail

REPO_URL_DEFAULT="https://github.com/hades496/MediaDownloadManager.git"
REPO_URL="${MDM_REPO_URL:-$REPO_URL_DEFAULT}"
BRANCH="${MDM_BRANCH:-main}"
SKIP_AUTOSTART="${MDM_SKIP_AUTOSTART:-0}"
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"
TARGET_DIR_DEFAULT="${TARGET_HOME}/MediaDownloadManager"
TARGET_DIR="${MDM_INSTALL_DIR:-$TARGET_DIR_DEFAULT}"

log() {
    echo "[MDM installer] $*"
}

warn() {
    echo "[MDM installer] WARN: $*" >&2
}

fail() {
    echo "[MDM installer] ERROR: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_root() {
    if [ "${EUID}" -eq 0 ]; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    else
        fail "当前操作需要 sudo，请先安装 sudo 或以 root 身份执行。"
    fi
}

run_as_target_shell() {
    local cmd="$1"
    local wrapped="export HOME='${TARGET_HOME}'; export PATH='/opt/homebrew/bin:/usr/local/bin:$PATH'; ${cmd}"
    if [ "$(id -un)" = "$TARGET_USER" ]; then
        bash -lc "$wrapped"
    elif [ "${EUID}" -eq 0 ]; then
        if command_exists sudo; then
            sudo -H -u "$TARGET_USER" bash -lc "$wrapped"
        elif command_exists su; then
            su - "$TARGET_USER" -c "$wrapped"
        else
            fail "当前操作需要切换到用户 ${TARGET_USER} 执行，但系统中既没有 sudo 也没有 su。"
        fi
    elif command_exists sudo; then
        sudo -H -u "$TARGET_USER" bash -lc "$wrapped"
    else
        fail "当前操作需要切换到用户 ${TARGET_USER} 执行，但系统中没有 sudo。"
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --repo-url)
                REPO_URL="$2"
                shift 2
                ;;
            --branch)
                BRANCH="$2"
                shift 2
                ;;
            --target-dir)
                TARGET_DIR="$2"
                shift 2
                ;;
            --skip-autostart)
                SKIP_AUTOSTART=1
                shift
                ;;
            *)
                fail "未知参数: $1"
                ;;
        esac
    done
}

ensure_brew_shellenv() {
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
}

ensure_homebrew() {
    if command_exists brew; then
        ensure_brew_shellenv
        return 0
    fi

    log "未检测到 Homebrew，开始安装..."
    run_as_target_shell 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    ensure_brew_shellenv
    command_exists brew || fail "Homebrew 安装完成后仍不可用。"
}

install_macos_dependencies() {
    ensure_homebrew
    log "通过 Homebrew 安装 Git / Python / FFmpeg ..."
    run_as_target_shell "brew install git python@3.11 ffmpeg"
    ensure_brew_shellenv
}

install_linux_dependencies() {
    if command_exists apt-get; then
        log "通过 apt 安装 Git / Python / FFmpeg ..."
        run_root apt-get update
        run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y git curl ffmpeg python3 python3-pip python3-venv
        return 0
    fi

    if command_exists dnf; then
        log "通过 dnf 安装 Git / Python / FFmpeg ..."
        run_root dnf install -y git curl ffmpeg python3 python3-pip
        return 0
    fi

    if command_exists yum; then
        log "通过 yum 安装 Git / Python / FFmpeg ..."
        run_root yum install -y git curl python3 python3-pip ffmpeg || fail "yum 环境下安装 ffmpeg 失败，请先启用对应软件源后重试。"
        return 0
    fi

    if command_exists pacman; then
        log "通过 pacman 安装 Git / Python / FFmpeg ..."
        run_root pacman -Sy --noconfirm git curl ffmpeg python python-pip
        return 0
    fi

    if command_exists zypper; then
        log "通过 zypper 安装 Git / Python / FFmpeg ..."
        run_root zypper --non-interactive install git curl ffmpeg python3 python3-pip
        return 0
    fi

    fail "未识别的 Linux 发行版包管理器，请手动安装 git / curl / python3 / ffmpeg 后再执行。"
}

prompt_github_token() {
    # 检查仓库是否是私有仓库（URL包含github.com且没有token）
    if [[ "$REPO_URL" == *"github.com"* && "$REPO_URL" != *"@github.com"* ]]; then
        log "检测到GitHub私有仓库，需要Personal Access Token进行访问。"
        log ""
        log "获取Token步骤："
        log "1. 访问 https://github.com/settings/tokens"
        log "2. 点击 'Generate new token' → 'Generate new token (classic)'"
        log "3. 选择 'repo' 权限（访问私有仓库）"
        log "4. 点击 'Generate token' 并复制"
        log ""
        
        read -p "请输入你的GitHub Personal Access Token: " -s GITHUB_TOKEN
        echo ""
        
        if [ -z "$GITHUB_TOKEN" ]; then
            fail "Token不能为空，请重新运行并输入有效的GitHub Token。"
        fi
        
        # 将token嵌入到URL中
        REPO_URL="${REPO_URL/github.com/${GITHUB_TOKEN}@github.com}"
        log "已配置私有仓库访问，正在克隆..."
    fi
}

clone_or_update_repo() {
    local parent_dir
    parent_dir="$(dirname "$TARGET_DIR")"
    run_as_target_shell "mkdir -p '$parent_dir'"

    if run_as_target_shell "[ -d '$TARGET_DIR/.git' ]"; then
        log "检测到已有仓库，正在更新..."
        run_as_target_shell "git -C '$TARGET_DIR' fetch --all --tags --prune && git -C '$TARGET_DIR' checkout '$BRANCH' && git -C '$TARGET_DIR' pull --ff-only origin '$BRANCH'"
        return 0
    fi

    if run_as_target_shell "[ -e '$TARGET_DIR' ] && [ -n \"\$(ls -A '$TARGET_DIR' 2>/dev/null)\" ]"; then
        fail "目标目录 '$TARGET_DIR' 已存在且非空，无法自动 clone。"
    fi

    # 提示输入GitHub Token（如果是私有仓库）
    prompt_github_token

    log "正在克隆项目到 $TARGET_DIR ..."
    run_as_target_shell "rm -rf '$TARGET_DIR' && git clone --branch '$BRANCH' '$REPO_URL' '$TARGET_DIR'"
}

start_project_now() {
    log "开始启动项目..."
    run_as_target_shell "cd '$TARGET_DIR' && export MDM_NONINTERACTIVE=1 MDM_NO_BROWSER=1 && bash start.sh"
}

configure_macos_autostart() {
    local launch_agents_dir plist_path
    launch_agents_dir="${TARGET_HOME}/Library/LaunchAgents"
    plist_path="${launch_agents_dir}/com.hades496.mediadownloadmanager.plist"

    run_as_target_shell "mkdir -p '$launch_agents_dir' '$TARGET_DIR/logs'"
    cat <<EOF | run_as_target_shell "cat > '$plist_path'"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hades496.mediadownloadmanager</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${TARGET_DIR}/start.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${TARGET_DIR}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>${TARGET_HOME}</string>
        <key>MDM_NONINTERACTIVE</key>
        <string>1</string>
        <key>MDM_NO_BROWSER</key>
        <string>1</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${TARGET_DIR}/logs/autostart.launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>${TARGET_DIR}/logs/autostart.launchd.err.log</string>
</dict>
</plist>
EOF

    if command_exists launchctl; then
        run_as_target_shell "launchctl unload '$plist_path' >/dev/null 2>&1 || true"
        if ! run_as_target_shell "launchctl load '$plist_path'"; then
            warn "launchctl 立即加载失败，但自启动配置文件已写入，后续登录系统时仍可生效。"
        fi
    fi

    log "已写入 macOS 自启动配置: $plist_path"
}

configure_linux_autostart() {
    local service_path
    service_path="/etc/systemd/system/mediadownloadmanager.service"

    if command_exists systemctl && [ -d /run/systemd/system ]; then
        log "写入 systemd 开机自启服务..."
        cat <<EOF | run_root tee "$service_path" >/dev/null
[Unit]
Description=MediaDownloadManager
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${TARGET_USER}
WorkingDirectory=${TARGET_DIR}
Environment=HOME=${TARGET_HOME}
Environment=MDM_NONINTERACTIVE=1
Environment=MDM_NO_BROWSER=1
ExecStart=/bin/bash ${TARGET_DIR}/start.sh
ExecStop=/bin/bash ${TARGET_DIR}/stop.sh
TimeoutStartSec=600
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
        run_root systemctl daemon-reload
        run_root systemctl enable mediadownloadmanager.service
        run_root systemctl restart mediadownloadmanager.service
        log "已启用 Linux systemd 开机自启服务。"
        return 0
    fi

    warn "当前 Linux 未检测到可用的 systemd，回退为 @reboot crontab。"
    if ! command_exists crontab; then
        fail "当前环境既没有可用的 systemd，也没有 crontab，无法自动配置开机自启。"
    fi
    run_as_target_shell "(crontab -l 2>/dev/null | grep -v 'MediaDownloadManager/start.sh'; echo '@reboot cd \"$TARGET_DIR\" && MDM_NONINTERACTIVE=1 MDM_NO_BROWSER=1 bash start.sh >> logs/autostart.cron.log 2>&1') | crontab -"
}

summarize() {
    cat <<EOF

=====================================
MediaDownloadManager 一键安装完成
-------------------------------------
仓库地址: ${REPO_URL}
安装目录: ${TARGET_DIR}
立即启动: 已执行
开机自启: $( [ "$SKIP_AUTOSTART" = "1" ] && echo "已跳过" || echo "已配置" )
访问地址: http://127.0.0.1:8080
停止服务: cd ${TARGET_DIR} && bash stop.sh
=====================================
EOF
}

main() {
    parse_args "$@"

    case "$(uname -s)" in
        Darwin)
            install_macos_dependencies
            ;;
        Linux)
            install_linux_dependencies
            ;;
        *)
            fail "当前脚本仅支持 macOS / Linux。"
            ;;
    esac

    clone_or_update_repo
    start_project_now

    if [ "$SKIP_AUTOSTART" != "1" ]; then
        case "$(uname -s)" in
            Darwin)
                configure_macos_autostart
                ;;
            Linux)
                configure_linux_autostart
                ;;
        esac
    fi

    summarize
}

main "$@"
