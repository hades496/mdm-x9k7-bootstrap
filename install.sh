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
            sudo --preserve-env=GITHUB_TOKEN -H -u "$TARGET_USER" bash -lc "$wrapped"
        elif command_exists su; then
            su -m "$TARGET_USER" -c "$wrapped"
        else
            fail "当前操作需要切换到用户 ${TARGET_USER} 执行，但系统中既没有 sudo 也没有 su。"
        fi
    elif command_exists sudo; then
        sudo --preserve-env=GITHUB_TOKEN -H -u "$TARGET_USER" bash -lc "$wrapped"
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

has_interactive_tty() {
    exec 3<>/dev/tty >/dev/null 2>&1 || return 1
    exec 3>&-
    exec 3<&-
    return 0
}

run_as_target_shell_interactive() {
    local cmd="$1"
    local wrapped="export HOME='${TARGET_HOME}'; export PATH='/opt/homebrew/bin:/usr/local/bin:$PATH'; ${cmd}"

    if ! has_interactive_tty; then
        warn "当前无交互终端，将在必要时回退为 Token 输入方式。"
        return 1
    fi

    if [ "$(id -un)" = "$TARGET_USER" ]; then
        bash -lc "$wrapped" </dev/tty >/dev/tty 2>/dev/tty
    elif [ "${EUID}" -eq 0 ]; then
        if command_exists sudo; then
            sudo --preserve-env=GITHUB_TOKEN -H -u "$TARGET_USER" bash -lc "$wrapped" </dev/tty >/dev/tty 2>/dev/tty
        elif command_exists su; then
            su -m "$TARGET_USER" -c "$wrapped" </dev/tty >/dev/tty 2>/dev/tty
        else
            fail "当前操作需要切换到用户 ${TARGET_USER} 执行，但系统中既没有 sudo 也没有 su。"
        fi
    elif command_exists sudo; then
        sudo --preserve-env=GITHUB_TOKEN -H -u "$TARGET_USER" bash -lc "$wrapped" </dev/tty >/dev/tty 2>/dev/tty
    else
        fail "当前操作需要切换到用户 ${TARGET_USER} 执行，但系统中没有 sudo。"
    fi
}

try_install_github_cli() {
    if run_as_target_shell "command -v gh >/dev/null 2>&1"; then
        return 0
    fi

    case "$(uname -s)" in
        Darwin)
            log "尝试通过 Homebrew 安装 GitHub CLI (gh) ..."
            run_as_target_shell "brew install gh" || warn "GitHub CLI 安装失败，将在认证阶段回退为 Token 输入方式。"
            ;;
        Linux)
            log "尝试安装 GitHub CLI (gh) ..."
            if command_exists apt-get; then
                run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y gh || warn "GitHub CLI 安装失败，将在认证阶段回退为 Token 输入方式。"
            elif command_exists dnf; then
                run_root dnf install -y gh || warn "GitHub CLI 安装失败，将在认证阶段回退为 Token 输入方式。"
            elif command_exists yum; then
                run_root yum install -y gh || warn "GitHub CLI 安装失败，将在认证阶段回退为 Token 输入方式。"
            elif command_exists pacman; then
                run_root pacman -Sy --noconfirm gh || warn "GitHub CLI 安装失败，将在认证阶段回退为 Token 输入方式。"
            elif command_exists zypper; then
                run_root zypper --non-interactive install gh || warn "GitHub CLI 安装失败，将在认证阶段回退为 Token 输入方式。"
            else
                warn "当前 Linux 包管理器不支持自动安装 GitHub CLI，将在认证阶段回退为 Token 输入方式。"
            fi
            ;;
    esac
}

is_github_repo_url() {
    printf '%s\n' "$1" | grep -Eq '^(https?://github\.com/[^/]+/[^/]+(\.git)?|git@github\.com:[^/]+/[^/]+(\.git)?|ssh://git@github\.com/[^/]+/[^/]+(\.git)?)$'
}

supports_token_fallback() {
    printf '%s\n' "$1" | grep -Eq '^https?://github\.com/[^/]+/[^/]+(\.git)?$'
}

repo_has_tracked_changes() {
    local status_output
    status_output="$(run_as_target_shell "git -C '$TARGET_DIR' status --porcelain --untracked-files=no 2>/dev/null" || true)"
    [ -n "$status_output" ]
}

sanitize_repo_url() {
    local url="${1:-}"

    if [ -z "$url" ]; then
        printf '%s\n' ""
        return 0
    fi

    printf '%s\n' "$url" | sed -E 's#^((https?)://)[^/@]+(:[^@]*)?@#\1#'
}

repair_origin_remote_if_needed() {
    local origin_url normalized_url

    if ! run_as_target_shell "[ -d '$TARGET_DIR/.git' ]"; then
        return 0
    fi

    origin_url="$(run_as_target_shell "git -C '$TARGET_DIR' remote get-url origin 2>/dev/null || true")"
    if [ -z "$origin_url" ]; then
        return 0
    fi

    if ! printf '%s\n' "$origin_url" | grep -Eq '^https?://[^/@]+(:[^@]*)?@github\.com/[^/]+/[^/]+(\.git)?/?$'; then
        return 0
    fi

    normalized_url="$(printf '%s\n' "$origin_url" | sed -E 's#^https?://[^/@]+(:[^@]*)?@github\.com/([^/]+/[^/]+)(\.git)?/?$#https://github.com/\2\3#')"
    if [ -z "$normalized_url" ] || [ "$normalized_url" = "$origin_url" ]; then
        return 0
    fi

    if ! run_as_target_shell "git -C '$TARGET_DIR' remote set-url origin '$normalized_url'"; then
        warn "检测到历史凭证化 remote，但自动修复失败，将继续当前流程。"
    fi

    return 0
}

prepare_github_auth() {
    local repo_url="$1"

    if ! is_github_repo_url "$repo_url"; then
        return 1
    fi

    if ! run_as_target_shell "command -v gh >/dev/null 2>&1"; then
        warn "未检测到 GitHub CLI，将在必要时回退为 Token 输入方式。"
        return 1
    fi

    if run_as_target_shell "gh auth status >/dev/null 2>&1"; then
        log "检测到 GitHub CLI 已登录，正在复用 gh 凭证..."
    else
        log "检测到 GitHub 仓库，优先使用 GitHub CLI 登录..."
        if ! run_as_target_shell_interactive "gh auth login"; then
            warn "GitHub CLI 登录未完成，将在必要时回退为 Token 输入方式。"
            return 1
        fi
    fi

    if ! run_as_target_shell "gh auth setup-git >/dev/null 2>&1"; then
        warn "gh auth setup-git 执行失败，将在必要时回退为 Token 输入方式。"
        return 1
    fi

    return 0
}

prompt_github_token() {
    local repo_url="$1"

    if [ -n "${GITHUB_TOKEN:-}" ]; then
        export GITHUB_TOKEN
        return 0
    fi

    supports_token_fallback "$repo_url" || fail "当前仓库地址不支持 Token 回退，请改用 GitHub CLI 或提供可访问的 GitHub HTTPS 仓库地址。"

    log "GitHub CLI 认证不可用，回退为 Personal Access Token 访问。"
    log ""
    log "获取 Token 步骤："
    log "1. 访问 https://github.com/settings/tokens"
    log "2. 点击 'Generate new token' → 'Generate new token (classic)'"
    log "3. 选择 'repo' 权限（访问私有仓库）"
    log "4. 点击 'Generate token' 并复制"
    log ""

    has_interactive_tty || fail "当前环境没有交互终端，无法手动输入 Token；请先设置 GITHUB_TOKEN 环境变量后重试。"

    read -r -p "请输入你的GitHub Personal Access Token: " -s GITHUB_TOKEN </dev/tty
    echo "" >/dev/tty

    if [ -z "$GITHUB_TOKEN" ]; then
        fail "Token不能为空，请重新运行并输入有效的GitHub Token。"
    fi

    export GITHUB_TOKEN
}

create_git_askpass_script() {
    local script_path

    script_path="$(mktemp "${TMPDIR:-/tmp}/mdm-git-askpass.XXXXXX")" || fail "无法创建临时 Git 凭证脚本。"
    cat <<'EOF' >"$script_path"
#!/bin/sh
case "$1" in
    *Username*|*username*)
        printf '%s\n' "${GITHUB_USERNAME:-git}"
        ;;
    *)
        printf '%s\n' "${GITHUB_TOKEN:-}"
        ;;
esac
EOF
    chmod 755 "$script_path"
    printf '%s\n' "$script_path"
}

run_git_with_token_auth() {
    local repo_url="$1"
    local git_cmd="$2"
    local askpass_script status

    prompt_github_token "$repo_url"
    askpass_script="$(create_git_askpass_script)"

    if run_as_target_shell "export GIT_TERMINAL_PROMPT=0; export GIT_ASKPASS='$askpass_script'; ${git_cmd}"; then
        status=0
    else
        status=$?
    fi

    rm -f "$askpass_script" || true
    unset GITHUB_TOKEN || true
    return "$status"
}

clone_or_update_repo() {
    local parent_dir update_cmd origin_url auth_ready
    parent_dir="$(dirname "$TARGET_DIR")"
    run_as_target_shell "mkdir -p '$parent_dir'"

    if run_as_target_shell "[ -d '$TARGET_DIR/.git' ]"; then
        log "检测到已有仓库，正在更新..."
        repair_origin_remote_if_needed || true
        origin_url="$(run_as_target_shell "git -C '$TARGET_DIR' remote get-url origin 2>/dev/null || true")"

        local did_stash=0
        if repo_has_tracked_changes; then
            warn "检测到本地已跟踪文件有改动，自动暂存（git stash）后继续更新..."
            if run_as_target_shell "git -C '$TARGET_DIR' stash push -m 'mdm-installer-auto-stash' --quiet"; then
                did_stash=1
            else
                fail "自动暂存本地修改失败，请手动执行 git stash 或提交改动后重试。"
            fi
        fi

        auth_ready=0
        if is_github_repo_url "$origin_url" && prepare_github_auth "$origin_url"; then
            auth_ready=1
        fi

        update_cmd="git -C '$TARGET_DIR' fetch --all --tags --prune && git -C '$TARGET_DIR' checkout '$BRANCH' && git -C '$TARGET_DIR' reset --hard 'origin/$BRANCH'"

        if ! run_as_target_shell "git -C '$TARGET_DIR' fetch --all --tags --prune"; then
            if supports_token_fallback "$origin_url"; then
                if [ "$auth_ready" = "1" ]; then
                    warn "使用 GitHub CLI 方式执行 fetch 失败，可能是远端认证或网络问题，回退为 Token 输入方式重试..."
                fi
                run_git_with_token_auth "$origin_url" "$update_cmd" || fail "仓库更新失败，请查看上方 git 原始错误；若提示分支不存在、无法快进或访问受限，请先处理后重试。"
                if [ "$did_stash" = "1" ]; then
                    run_as_target_shell "git -C '$TARGET_DIR' stash pop --quiet" || warn "自动恢复暂存的本地修改失败，请手动执行 git stash pop 恢复。"
                fi
                return 0
            fi
            fail "git fetch 失败，请查看上方 git 原始错误并检查远端访问权限。"
        fi

        if ! run_as_target_shell "git -C '$TARGET_DIR' checkout '$BRANCH'"; then
            fail "git checkout 失败，请检查目标分支是否存在，或先处理本地改动后重试。"
        fi

        if ! run_as_target_shell "git -C '$TARGET_DIR' reset --hard 'origin/$BRANCH'"; then
            fail "git reset --hard 失败，请查看上方 git 原始错误。"
        fi

        if [ "$did_stash" = "1" ]; then
            run_as_target_shell "git -C '$TARGET_DIR' stash pop --quiet" || warn "自动恢复暂存的本地修改失败，请手动执行 git stash pop 恢复。"
        fi

        return 0
    fi

    if run_as_target_shell "[ -e '$TARGET_DIR' ] && [ -n \"\$(ls -A '$TARGET_DIR' 2>/dev/null)\" ]"; then
        fail "目标目录 '$TARGET_DIR' 已存在且非空，无法自动 clone。"
    fi

    auth_ready=0
    if is_github_repo_url "$REPO_URL" && prepare_github_auth "$REPO_URL"; then
        auth_ready=1
    fi

    log "正在克隆项目到 $TARGET_DIR ..."
    if ! run_as_target_shell "rm -rf '$TARGET_DIR' && git clone --branch '$BRANCH' '$REPO_URL' '$TARGET_DIR'"; then
        if supports_token_fallback "$REPO_URL"; then
            if [ "$auth_ready" = "1" ]; then
                warn "使用 GitHub CLI 方式拉取失败，回退为 Token 输入方式重试..."
            fi
            run_git_with_token_auth "$REPO_URL" "rm -rf '$TARGET_DIR' && git clone --branch '$BRANCH' '$REPO_URL' '$TARGET_DIR'" || fail "仓库克隆失败，请检查仓库地址、分支或访问权限。"
        else
            fail "仓库克隆失败，请检查仓库地址、分支或访问权限。"
        fi
    fi
}

start_project_now() {
    log "开始启动项目..."
    run_as_target_shell "cd '$TARGET_DIR' && export MDM_NONINTERACTIVE=1 MDM_NO_BROWSER=1 && bash start.sh"
}

configure_macos_autostart() {
    run_as_target_shell "mkdir -p '${TARGET_HOME}/Library/LaunchAgents' '$TARGET_DIR/logs'"
    cat <<EOF | run_as_target_shell "cat > '${TARGET_HOME}/Library/LaunchAgents/com.hades496.mediadownloadmanager.plist'"
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
        run_as_target_shell "launchctl unload '${TARGET_HOME}/Library/LaunchAgents/com.hades496.mediadownloadmanager.plist' >/dev/null 2>&1 || true"
    fi

    log "已写入 macOS 自启动配置: ${TARGET_HOME}/Library/LaunchAgents/com.hades496.mediadownloadmanager.plist（将在下次登录时自动启动）"
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
        log "已启用 Linux systemd 开机自启服务（将在下次开机时自动启动）。"
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
仓库地址: $(sanitize_repo_url "${REPO_URL}")
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

    try_install_github_cli
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
