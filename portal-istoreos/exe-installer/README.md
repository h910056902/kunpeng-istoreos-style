# exe-installer —— 鲲鹏门户 Windows 一键安装器

把 `portal-istoreos` 的部署流程包成**一个双击即用的 exe**，无需 Python、无需命令行。

## 用法

1. 双击 `dist/鲲鹏门户安装器.exe`
2. 填路由器地址（默认 `192.168.66.1`）和 SSH 密码
3. 点「开始安装」→ 看实时日志 + 11 项验收结果

**密码只在内存里用**：不写盘、不存 exe、不进命令行参数。

## CLI 模式（自动化 / 排障）

```bat
set ROUTER_PW=你的密码
鲲鹏门户安装器.exe --cli
```

可选环境变量：`ROUTER_HOST`（默认 `192.168.66.1`）、`ROUTER_USER`（默认 `root`）。
退出码 `0` = 全部验收通过。

## 它做了什么

| 步骤 | 动作 |
|---|---|
| 1 | 环境自检（确认 `/overlay/nradio-apps` 存在 —— 是鲲鹏 8080 环境） |
| 2 | 备份现有 `portal` / `main.htm` 到 `/root/kp-bak-<时间戳>/` |
| 3 | 推送 portal v3 → `/www/cgi-bin/portal`（gzip + printf 八进制，落地校验 md5） |
| 4 | 装自愈守卫 `/usr/bin/kp-portal-guard.sh` + 金样本 + cron（每分钟自检） |
| 5 | 清 LuCI 缓存 + 重启 uhttpd |
| 6 | 11 项验收（md5 / 版本 / HTTP / 弹层目标 / 卡片 / 8080 可达 …） |

## 重新构建

```bat
pip install paramiko pyinstaller
python build_exe.py
```

`build_exe.py` 会先把 `../portal-istoreos/` 下的权威源同步到 `payload/`，
再调用 PyInstaller 打成单文件、无控制台的 exe。

### ⚠️ 打包前必须确认宿主 Python 带 tkinter

**托管版 Python（如 `~/.workbuddy/binaries/python/...`）通常不带 tkinter。**
用它打包 → 打出的 exe 双击就报：

```
ModuleNotFoundError: No module named 'tkinter'
```

（本次真实踩过：13.3 MB 的包完全没打进 `tkinter` / `tk86t.dll` / `tcl86t.dll`。）

`build_exe.py` 现在**预检三个模块**（tkinter / PyInstaller / paramiko），
缺任何一个直接拒绝打包并给出提示。本机可用的打包解释器：

```
C:\Users\91005\AppData\Local\Microsoft\WindowsApps\python.exe   # 3.10.11，自带 tkinter 8.6
```

验证产物是否真的带了 GUI 运行时（**别只看"进程存活"**）：

```bat
python -c "d=open(r'dist\鲲鹏门户安装器.exe','rb').read(); print('tk86t.dll', d.count(b'tk86t.dll'), 'tcl86t.dll', d.count(b'tcl86t.dll'), 'tkinter', d.count(b'tkinter'))"
```

期望：`tk86t.dll 1  tcl86t.dll 1  tkinter 8`。全 0 就是废包。

> 判据提示：**「进程存活 6 秒」不能证明 GUI 起来了** —— Tk 初始化前崩溃的进程
> 也可能还没退出。要枚举窗口标题确认（PyInstaller onefile 的 Tk 跑在**子进程**里，
> 按父进程 PID 枚举窗口会找不到）。

## 传输机制（为什么这么写）

固件上没有 `base64` / `od` / `openssl` / `xxd`，也没有 `sftp`，所以：

1. **先 gzip**（14423 B → 5273 B）—— 不压缩的话 SSH 通道会在半途断掉
2. 再转成 `printf '\NNN'` **八进制**分块（每块 700 B）追加写入
3. 设备侧 `gzip -dc` 解压
4. **落地后比对 md5**，不符就报错

通道断了会自动重连重试（最多 5 次）—— 实测传大文件时偶发 `EOFError`。
