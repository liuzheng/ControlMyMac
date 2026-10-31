# 使用 Touch ID 为 macOS 的 sudo 提权

本指南说明如何让 macOS Terminal 中的 `sudo` 优先使用 Touch ID，而不是每次都输入登录密码。它适用于需要在 shell 中执行管理员命令的场景，例如安装 ControlMyMac、注册 LaunchAgent 或修改系统配置。

ControlMyMac 不会替用户启动 Terminal、调用 `sudo` 或执行系统命令。需要提权时，建议使用本文配置的 Terminal `sudo`，不要使用未知脚本或把密码写入命令、环境变量或日志。

> 本文根据[用户提供的参考文章](https://blog.cashwu.com/blog/2026/macos-touch-id-sudo)整理并重新表述。请以当前 macOS 版本的行为为准，并在修改 PAM 配置前准备可恢复的 root shell。

## 前提条件

- Mac 具有 Touch ID 硬件，例如带 Touch ID 的 MacBook 或 Magic Keyboard。
- 在“系统设置”→“Touch ID 与密码”中至少登记了一枚指纹。
- 你正在 Mac 的本地 Terminal 会话中操作。通过 SSH 登录时，远端会话通常无法访问这台 Mac 的实体指纹传感器，仍应准备使用密码。
- 你知道如何恢复 PAM 配置。配置文件写错可能导致 `sudo` 无法初始化。

## 先打开备援 root shell

修改 `/etc/pam.d/` 下的文件前，先打开另一个 Terminal 窗口并执行：

```bash
sudo -i
```

完成认证后保持这个 root shell 不要关闭。它是恢复通道：如果主窗口中的 `sudo` 因 PAM 配置错误失效，可以在这个窗口中修复文件。确认新的配置已经测试成功后，再执行 `exit` 关闭备援 shell。

## macOS Sonoma 14 及更新版本：使用 `sudo_local`

这是首选方法。`sudo_local` 用来保存本地 sudo PAM 配置，系统更新时比直接编辑 `/etc/pam.d/sudo` 更不容易被覆盖。

### 1. 复制配置模板

在普通 Terminal 窗口中执行：

```bash
sudo cp -p /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local
```

如果模板文件不存在，请不要创建一个猜测内容的 PAM 配置；改为使用下文的旧系统方法，或先确认当前 macOS 版本和系统提供的模板。

### 2. 编辑配置

```bash
sudo nano /etc/pam.d/sudo_local
```

找到被注释的 Touch ID 行：

```text
#auth       sufficient     pam_tid.so
```

删除行首的 `#`，使其成为：

```text
auth       sufficient     pam_tid.so
```

保存并退出编辑器。`sufficient` 表示 Touch ID 验证成功时可以结束当前认证流程；如果 Touch ID 不可用或验证失败，macOS 仍可能回退到密码验证。

## 旧版 macOS：直接编辑 `sudo`

如果系统没有 `/etc/pam.d/sudo_local.template`，可以编辑 sudo 的主 PAM 配置：

```bash
sudo nano /etc/pam.d/sudo
```

将这一行放在其他 `auth` 行之前：

```text
auth       sufficient     pam_tid.so
```

`pam_tid.so` 应放在认证部分的前面，让系统先尝试 Touch ID。直接修改 `/etc/pam.d/sudo` 的缺点是，macOS 大版本更新可能恢复该文件的默认内容；升级后如果 Touch ID 失效，需要重新检查并添加配置。能使用 `sudo_local` 时，不要选择这种方法。

## 清除 sudo 缓存并验证

`sudo` 默认会在一段时间内缓存当前终端的认证结果。刚输入过密码后立即测试，可能不会再次显示 Touch ID，这不一定表示配置失败。使用下面的命令清除当前终端的缓存：

```bash
sudo -k
sudo ls /var/root
```

第二条命令应触发 Touch ID 提示。也可以关闭当前终端并打开新的 Terminal 窗口后再测试。新窗口的主要作用是使用不同的 TTY，从而避开原来的 sudo 认证缓存。

测试成功后，回到备援 root shell 或另一个 Terminal 窗口，再确认一次 `sudo` 仍能工作。确认无误后关闭 root shell：

```bash
exit
```

## iTerm2 或 tmux 中不弹 Touch ID

如果 Apple Terminal 中可以使用 Touch ID，但在 iTerm2 或 tmux 中只能输入密码，问题可能来自终端会话重新挂载后与 Touch ID 会话脱离。可以尝试安装 `pam-reattach`：

```bash
brew install pam-reattach
brew --prefix
```

把下面这一行放在 `pam_tid.so` **之前**。根据 `brew --prefix` 的结果，把路径替换为实际的绝对路径：

```text
auth       optional       /opt/homebrew/lib/pam/pam_reattach.so
auth       sufficient     pam_tid.so
```

Intel Mac 通常使用：

```text
auth       optional       /usr/local/lib/pam/pam_reattach.so
auth       sufficient     pam_tid.so
```

先确认文件确实存在：

```bash
ls -l "$(brew --prefix)/lib/pam/pam_reattach.so"
```

然后把准确的路径复制到 `/etc/pam.d/sudo_local` 或 `/etc/pam.d/sudo` 中。PAM 配置不会展开 `$(brew --prefix)`，所以不能把这个 shell 表达式直接写进配置文件。

> 路径错误可能使 sudo 报 `unable to initialize PAM: No such file or directory`。`optional` 不能修复“模块文件无法加载”的错误。修改前务必保留备援 root shell，并先在 Apple Terminal 中确认基本配置正常。

## 恢复 sudo

### 有备援 root shell

在仍然打开的 root shell 中编辑配置文件，删除或注释掉你新增的行：

```bash
# macOS Sonoma 14+
nano /etc/pam.d/sudo_local

# 没有 sudo_local 时
nano /etc/pam.d/sudo
```

保存后在另一个窗口执行 `sudo -k` 和测试命令。确认恢复后关闭 root shell。

### 没有备援 root shell

如果 `sudo` 已经坏掉，可以暂时启用 root 账户，再使用未经过 `sudo` 的 root shell 修复文件：

```bash
dsenableroot
su root
```

在 root shell 中修复对应的 PAM 文件：

```bash
vim /etc/pam.d/sudo_local
# 或者：vim /etc/pam.d/sudo
```

退出 root shell，并验证 sudo：

```bash
exit
sudo -k
sudo ls /var/root
```

如果 root 账户原本是关闭的，并且是本次操作临时启用的，修复完成后关闭它：

```bash
dsenableroot -d
```

如果 root 账户原本已经启用，不要盲目执行 `dsenableroot -d`，应恢复它原来的状态。若 `su` 也无法写入系统路径，可能需要从 macOS Recovery 环境修复；不要为了绕过系统保护而关闭 SIP。

## 关闭 Touch ID sudo

编辑你实际使用的配置文件，把新增行删除或加上 `#`：

- Sonoma 14 及更新版本：`/etc/pam.d/sudo_local`
- 没有 `sudo_local` 时：`/etc/pam.d/sudo`

然后打开新 Terminal 窗口，或运行 `sudo -k` 后确认 sudo 恢复为密码验证。

## 与 ControlMyMac 的关系

ControlMyMac 的构建和安装边界如下：

```bash
make build     # 普通用户运行，不要加 sudo
make bundle    # 普通用户运行，不要加 sudo
make install   # 构建完成后，安装脚本会通过 sudo 请求管理员权限
make uninstall # 通过 sudo 卸载 App 和 LaunchAgent
```

不要使用 `sudo make`。这样会让 `.build` 或 `build` 中的构建产物归 root 所有。只有写入 `/Applications`、管理 LaunchAgent 或清理旧系统级残留时才需要管理员权限；Airflow 依赖仍会降权后安装到当前登录用户的目录。

## 安全边界

- Touch ID 只改变 sudo 的认证方式，不会扩大当前用户原本拥有的 sudo 权限。
- Touch ID 需要本机实体传感器；SSH 会话和 Apple Watch 解锁不能替代终端 sudo 的 Touch ID 验证。
- 不要把密码写入 shell 历史、脚本、环境变量、DAG、任务日志或截图。
- 修改 PAM 文件前保留备援 root shell，成功验证后立即关闭它。
