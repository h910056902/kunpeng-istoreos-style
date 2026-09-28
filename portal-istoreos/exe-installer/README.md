# exe-installer —— 鲲鹏门户 Windows 一键安装器

把 `portal-istoreos` 的部署流程包成**一个双击即用的 exe**，无需 Python、无需命令行。
同时具备**备份 / 恢复 8080 环境**的能力（见下）。

## 用法（安装）

1. 双击 `dist/鲲鹏门户安装器.exe`
2. 填路由器地址（默认 `192.168.66.1`）和 SSH 密码
3. 点「开始安装」→ 看实时日志 + 11 项验收结果

**密码只在内存里用**：不写盘、不存 exe、不进命令行参数。

## 用法（恢复 8080 环境）

1. 先用 `scripts/kp-8080-backup.py` 在电脑上生成一份备份目录
   （里面有 `MANIFEST.txt`，例如 `kp-8080-backup-live`）
2. 双击 exe → 填地址和密码 → 点「恢复 8080 环境」
3. 在弹出的目录选择框里选那份备份目录 → 自动把 8080 打回备份时的状态

恢复流程会**先把设备当前状态再备份一次**到
`/root/kp-8080-restore-bak-<时间戳>/`，然后才推送文件——回滚也可以再回滚。

## CLI 模式（自动化 / 排障）

```bat
set ROUTER_PW=你的密码
鲲鹏门户安装器.exe --cli                          :: 安装
鲲鹏门户安装器.exe --cli --restore "D:\path\kp-8080-backup-live"
鲲鹏门户安装器.exe --restore-plugins "D:\path\kp-full-backup"
鲲鹏门户安装器.exe --test-feeds
```

可选环境变量：`ROUTER_HOST`（默认 `192.168.66.1`）、`ROUTER_USER`（默认 `root`）。
退出码 `0` = 全部验收通过。

> `--restore` / `--restore-plugins` / `--test-feeds` **不必再带 `--cli`**，
> 它们本身就走无 GUI 通道。

## 它做了什么

### 安装（`--cli` 不带 `--restore`）

| 步骤 | 动作 |
|---|---|
| 1 | 环境自检（确认 `/overlay/nradio-apps` 存在 —— 是鲲鹏 8080 环境） |
| 2 | 备份现有 `portal` / `main.htm` 到 `/root/kp-bak-<时间戳>/` |
| 3 | 推送 portal v3 → `/www/cgi-bin/portal`（gzip + printf 八进制，落地校验 md5） |
| 4 | 装自愈守卫 `/usr/bin/kp-portal-guard.sh` + 金样本 + cron（每分钟自检） |
| 5 | 清 LuCI 缓存 + 重启 uhttpd |
| 6 | 11 项验收（md5 / 版本 / HTTP / 弹层目标 / 卡片 / 8080 可达 …） |

### 恢复 8080（`--restore <dir>`）

| 步骤 | 动作 |
|---|---|
| 1 | 读 `MANIFEST.txt` → 文件清单 + 软链清单 |
| 2 | 把设备**当前** 8080 状态备份到 `/root/kp-8080-restore-bak-<时间戳>/`（`tar -czf`） |
| 3 | 逐个推送备份里的文件（同样 gzip + 八进制通道，逐个校验 md5） |
| 4 | 按 `app8080.SYMLINKS` 重建 `luci-static/` 软链 |
| 5 | 重启 `uhttpd.openwrt8080` |
| 6 | 6 项验收：CGI md5 / KP 标记数 / 软链数 / 8080 监听 / 门户 HTTP / 登录墙 403 |

实测：**77/77 文件推送成功、0 失败**；CGI md5、`main.htm` md5、19 个 KP 补丁标记、
9 条软链、`istorerouter` 与 `quickstart` 认证后均 200 全部对得上。

### 恢复插件（`--restore-plugins <dir>`）

按备份里的 `plugins.names`（用户后装包清单）把插件装回来：

| 步骤 | 动作 |
|---|---|
| 1 | `opkg update` 刷新源索引 |
| 2 | 比对：已装的跳过、待装的列出来、源里没有的提前预警 |
| 3 | 逐个 `opkg install`（分批，防命令超长撑爆通道），逐个报 ✓/✗ |
| 4 | 汇总成功/失败/跳过；失败的写入 `plugins.restore-failed.txt` |

- 「用户后装包」的判据是 **`Installed-Time` > 1750000000**（厂商 493 个包共用
  `1747797524` 这一个时间戳）。**不能用 `Status`** —— `install user installed`
  有 291 个，把 busybox/kernel/dnsmasq 这些固件包也算进去了。
- 实测（真机）：卸掉 `zoneinfo-asia` → 恢复 → 精确识别"133 跳过 + 1 待装"，
  装回后包总数回到 628 ✓
- 全量基准：134 个用户后装包（Docker 全家桶 / python3 全家桶 / OpenClash /
  1Panel / iStore 系列 / quickstart / frpc / 51ddns / UNM …），
  **全部在源里可装**（7 源 5715 包，0 缺失）。

### 测试软件源（`--test-feeds`）

三层递进，逐层报结果：

| 层 | 测什么 | 为什么 |
|---|---|---|
| ① 连通性 | curl 每个源的 `Packages.gz`（HTTP 码/大小/耗时） | 网络通不通 |
| ② 索引 | `opkg update`，数成功刷新的源 + 索引里包总数 | **opkg 真正依赖的是这个**；HTTP 通 ≠ 索引可用 |
| ③ 实际下载 | `opkg download` 一个小包 | 证明下载链路完整（含 https/证书/落盘） |

实测（真机）：7/7 源 200（0.2~0.4s）、7 源索引刷新、5715 包、
`zoneinfo-asia` 30.2 KB 下载成功 —— **全部可用**。

## 配套备份脚本

```bat
:: 生成备份（默认写到 .\kp-8080-backup-live）
python scripts\kp-8080-backup.py
:: 或指定输出目录 / 打 tar 包
python scripts\kp-8080-backup.py --out D:\bak\8080 --tar
```

备份内容：8080 docroot 全量文件、`luci-static` 软链、`menu.d`、UCI 配置
（uhttpd / istore / istorerouter / kp_portal / quickstart）、
**用户后装插件清单**（`plugins.txt` / `plugins.names` / `plugins.feed-status.txt`）、
**软件源配置**（`feeds/` + `feeds.txt`，含连通性快照）、`opkg list-installed`。
以本机为准约 **80 文件 / 1.3 MB**，tar.gz 约 **535 KB**。

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
