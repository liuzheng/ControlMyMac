# Using Touch ID for sudo on macOS

This guide shows how to make `sudo` in macOS Terminal prefer Touch ID instead of asking for the login password every time. It is useful when a shell command needs administrator privileges, such as installing ControlMyMac, registering a LaunchAgent, or changing a system setting.

ControlMyMac does not open Terminal, call `sudo`, or execute system commands on the user's behalf. When elevation is required, use the Terminal `sudo` workflow described here. Never use unknown scripts or put a password in a command, environment variable, or log.

> This guide is a rephrased version of the [reference article provided by the user](https://blog.cashwu.com/blog/2026/macos-touch-id-sudo). Follow the behavior of the macOS version currently installed on your Mac, and prepare a recovery root shell before editing PAM configuration.

## Requirements

- Your Mac has Touch ID hardware, such as a MacBook with Touch ID or a Touch ID Magic Keyboard.
- At least one fingerprint is registered in **System Settings → Touch ID & Password**.
- You are working in a local Terminal session. An SSH session normally cannot access the physical fingerprint sensor on the Mac, so keep password authentication available.
- You understand how to recover a PAM configuration. A syntax or module-path error can make `sudo` fail to initialize.

## Open a recovery root shell first

Before editing a file under `/etc/pam.d/`, open a second Terminal window and run:

```bash
sudo -i
```

Complete authentication and keep this root shell open. It is your recovery path: if `sudo` stops working in the main window because of a PAM error, use this shell to repair the file. After the new configuration has been tested successfully, run `exit` to close the recovery shell.

## macOS Sonoma 14 and later: use `sudo_local`

This is the preferred method. `sudo_local` is intended for local sudo PAM settings and is less likely to be overwritten by a system update than a direct edit to `/etc/pam.d/sudo`.

### 1. Copy the template

Run this in the regular Terminal window:

```bash
sudo cp -p /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local
```

If the template does not exist, do not invent a PAM configuration. Confirm the macOS version and system-provided files first, or use the legacy method below only when `sudo_local` is unavailable.

### 2. Edit the configuration

```bash
sudo nano /etc/pam.d/sudo_local
```

Find the commented Touch ID line:

```text
#auth       sufficient     pam_tid.so
```

Remove the leading `#` so it becomes:

```text
auth       sufficient     pam_tid.so
```

Save and exit. `sufficient` means that a successful Touch ID check can complete the authentication stack. If Touch ID is unavailable or fails, macOS may still fall back to password authentication.

## Older macOS versions: edit `sudo` directly

If `/etc/pam.d/sudo_local.template` is not present, edit the main sudo PAM configuration:

```bash
sudo nano /etc/pam.d/sudo
```

Add this line before the other `auth` lines:

```text
auth       sufficient     pam_tid.so
```

Place `pam_tid.so` near the start of the authentication section so Touch ID is attempted first. Directly editing `/etc/pam.d/sudo` can be undone by a major macOS update. If Touch ID stops working after an upgrade, inspect the file and add the line again. Use `sudo_local` instead whenever the system provides it.

## Clear the sudo cache and test

`sudo` caches a successful authentication for a period of time, and the cache is associated with the current terminal. If you recently entered a password, a test may not show Touch ID even when the PAM configuration is correct. Clear the cache in the current terminal:

```bash
sudo -k
sudo ls /var/root
```

The second command should trigger a Touch ID prompt. You can also close the terminal and open a new Terminal window. The important effect of a new window is that it normally uses a different TTY and therefore avoids the previous sudo authentication cache.

After the test succeeds, verify once more from the recovery shell or another Terminal window that `sudo` still works. Then close the recovery shell:

```bash
exit
```

## Touch ID does not appear in iTerm2 or tmux

If Touch ID works in Apple Terminal but iTerm2 or tmux only asks for a password, the terminal session may have been reattached without the session context needed by Touch ID. You can try installing `pam-reattach`:

```bash
brew install pam-reattach
brew --prefix
```

Add the following line **before** the `pam_tid.so` line. Replace the path with the actual absolute path reported by your Homebrew installation:

```text
auth       optional       /opt/homebrew/lib/pam/pam_reattach.so
auth       sufficient     pam_tid.so
```

Intel Macs commonly use:

```text
auth       optional       /usr/local/lib/pam/pam_reattach.so
auth       sufficient     pam_tid.so
```

Confirm that the module exists first:

```bash
ls -l "$(brew --prefix)/lib/pam/pam_reattach.so"
```

Then copy the exact path into `/etc/pam.d/sudo_local` or `/etc/pam.d/sudo`. PAM configuration does not expand `$(brew --prefix)`, so do not put that shell expression directly in the configuration file.

> A wrong module path can make sudo fail with `unable to initialize PAM: No such file or directory`. `optional` does not fix a module that cannot be loaded. Keep the recovery root shell open and confirm the basic Apple Terminal configuration first.

## Recover sudo

### If the recovery root shell is still open

In that root shell, edit the configuration and remove or comment out the line you added:

```bash
# macOS Sonoma 14+
nano /etc/pam.d/sudo_local

# When sudo_local is unavailable
nano /etc/pam.d/sudo
```

Save the file, then run `sudo -k` and a test command from another window. Close the root shell after sudo is working again.

### If no recovery root shell is available

If `sudo` is broken, temporarily enable the root account and use a root shell that does not depend on `sudo`:

```bash
dsenableroot
su root
```

Repair the relevant PAM file from that root shell:

```bash
vim /etc/pam.d/sudo_local
# Or: vim /etc/pam.d/sudo
```

Exit the root shell and verify sudo:

```bash
exit
sudo -k
sudo ls /var/root
```

If the root account was disabled before this recovery and you enabled it only for this procedure, disable it again after the repair:

```bash
dsenableroot -d
```

If the root account was already enabled, do not blindly run `dsenableroot -d`; restore its previous state instead. If `su` also cannot write to the system path, macOS Recovery may be required. Do not disable SIP merely to bypass system protection.

## Disable Touch ID for sudo

Edit the configuration file you actually changed and remove or comment out the added lines:

- macOS Sonoma 14 and later: `/etc/pam.d/sudo_local`
- When `sudo_local` is unavailable: `/etc/pam.d/sudo`

Open a new Terminal window, or run `sudo -k`, and confirm that sudo has returned to password authentication.

## Relationship to ControlMyMac

ControlMyMac has the following build and installation boundary:

```bash
make build     # Run as the regular user; do not add sudo
make bundle    # Run as the regular user; do not add sudo
make install   # The installation script asks for administrator access through sudo
make uninstall # Uses sudo to remove the app and LaunchAgents
```

Do not run `sudo make`. That can leave `.build` or `build` artifacts owned by root. Administrator access is needed only for writing to `/Applications`, managing LaunchAgents, or cleaning up old system-level files. Airflow dependencies are installed as the target login user in that user's directories.

## Security boundaries

- Touch ID changes the sudo authentication method; it does not grant permissions that the user did not already have.
- Touch ID requires a physical sensor. SSH sessions and Apple Watch unlock do not replace Touch ID authentication for terminal sudo.
- Do not put passwords in shell history, scripts, environment variables, DAGs, task logs, or screenshots.
- Keep a recovery root shell open while editing PAM files, and close it as soon as verification succeeds.
