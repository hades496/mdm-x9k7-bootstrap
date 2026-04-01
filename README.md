# MediaDownloadManager Public Bootstrap

公开 bootstrap 仓库只分发安装入口脚本：

- macOS / Linux：`install.sh`
- Windows：`install.ps1`

主项目仓库仍是：`https://github.com/hades496/MediaDownloadManager.git`

## 认证说明

当仓库地址是 GitHub 时，安装脚本会优先尝试复用 GitHub CLI：`gh auth status` → `gh auth login` → `gh auth setup-git`。

若当前环境没有交互终端，请预先设置 `GITHUB_TOKEN` 环境变量。仅在 `gh` 不可用或认证失败时回退为手动输入 Token。

## 一键安装 / 更新

### macOS

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/hades496/mdm-x9k7-bootstrap/main/install.sh)"
```

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/hades496/mdm-x9k7-bootstrap/main/install.sh | bash
```

### Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$tmp = Join-Path $env:TEMP 'mdm-install.ps1'; irm https://raw.githubusercontent.com/hades496/mdm-x9k7-bootstrap/main/install.ps1 -OutFile $tmp; & $tmp"
```

## 强制覆盖更新

### macOS

```bash
MDM_FORCE_RESET=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/hades496/mdm-x9k7-bootstrap/main/install.sh)"
```

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/hades496/mdm-x9k7-bootstrap/main/install.sh | MDM_FORCE_RESET=1 bash
```

### Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:MDM_FORCE_RESET='1'; $tmp = Join-Path $env:TEMP 'mdm-install.ps1'; irm https://raw.githubusercontent.com/hades496/mdm-x9k7-bootstrap/main/install.ps1 -OutFile $tmp; & $tmp"
```

需要更多参数时，请参考主仓库中的 `docs/ONE_CLICK_SETUP.md`。
