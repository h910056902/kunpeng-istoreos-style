# kunpeng-istoreos-style

> 鲲鹏 C2000 系列（NROS 固件）**不刷机** 8080 LuCI 一键 iStoreOS 风格化。
> 思路参考 [guoguobuku/mt6000-istoreos](https://github.com/guoguobuku/mt6000-istoreos)
>（GL-iNet 路由器不刷机风格化），针对鲲鹏 NROS 固件的独立 LuCI 实例（8080 端口）重新实现。

## 它做什么

| 能力 | 说明 |
|---|---|
| Argon 配置层升级 | 暗色模式 / 主色 `#5e72e4` / 深色主色 `#483d8b` / 模糊度写进 `/etc/config/argon`；**段类型必须为 `global`**（见「踩坑」）。不装 luci-app-argon-config（会污染 80 端口菜单） |
| iStore 商店接入 | 手动解包安装 `luci-app-store` / `luci-taskd` / `taskd` / `script-utils` / `mount-utils`，`is-opkg` **下载→安装→卸载全链路实测通过** |
| 设备总览卡片化 | 重做登录后首页 `admin_status/nradio_details.htm`：现代卡片布局、暗色适配、实时计数（10s 自刷新逻辑原样保留） |
| 服务入口注册 | 侧栏新增「服务」菜单 + 首页服务入口卡片：**鲲鹏商店**（80 端口原厂）/ **1Panel 面板** / **Docker 容器**（安全入口自动解析） |
| 全程可回滚 | 时间戳备份 → `/tmp` 语法校验 → 原子落位 → 清缓存 → HTTP 探活，任一步失败自动回退 |

## 已验证（真机实测记录）

设备：鲲鹏 C2000 系列，NROS 2.3.0.n0.c1 / OpenWrt 21.02-SNAPSHOT / LuCI git-26.253.32058。

| 项 | 结果 |
|---|---|
| 页面探活 | `/admin/status/details`、`/admin/system/system`、`/admin/system/startup`、`/admin/store/pages`、`/admin/network/network`、`/admin/status/overview` 全部 **200** |
| 服务菜单跳转 | 鲲鹏商店 → `http://<lan>/cgi-bin/luci/nradioadv/system/appcenter`；1Panel / Docker → `http://<lan>:10090/<安全入口>[/containers]` |
| 主题配色 | `:root` 变量正确注入（`--primary:#5e72e4` 等），暗色模式生效 |
| iStore 插件链路 | `is-opkg update`（140 包）→ `install luci-app-autotimeset`（真实下载 + 中文包 + 依赖）→ `remove`（零残留） |
| taskd 任务机制 | procd 按任务拉起 `/usr/libexec/taskd`，`task_add/task_status/task_del` 实测正常 |
| 80 端口 NRadio 主界面 | `/` → **200**，零影响 |

## 为什么安全（改不坏主界面）

8080 实例由独立 `uhttpd.openwrt8080` 服务，文档根在
`/overlay/nradio-apps/openwrt-luci-8080/www`，CGI 包装器复用主系统 Lua 库但把
视图/主题**隔离**在实例私有目录里，且强制 `mediaurlbase=/luci-static/bootstrap`
（仅实例内）。因此：

- 80 端口 NRadio 原厂界面与全局主题**零接触**；
- 主系统 `/usr/lib/lua/luci` 仅被「读取」，实例私有改动全在 `/overlay/nradio-apps/openwrt-luci-8080/` 下；
- 不触碰应用商店补丁载体（`appcenter.htm` / `appcenter.lua`）。

详见 [docs/DESIGN.md](docs/DESIGN.md)（8080 实例逆向记录 + 主题升级可行性评估）。

## 踩坑与修复

见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。两个致命坑已修复并写进脚本断言：

1. **Argon 配置段类型**：必须是 `config global 'global'`（不是 `config argon 'global'`），
   否则 `uci:get_first('argon','global','primary')` 取到 nil，渲染出 `--primary: ;` 空值 → **全站配色失效**。
2. **LuCI 索引缓存陈旧**：新装/改动的 controller 不生效（表现为新页面 404）→ 需清 `/tmp/luci-indexcache*`。

## 使用

```sh
# 传到路由器后（凭据与传输方式自行处理，本仓库不含任何凭据）
sh kp-style.sh
```

菜单：`1 体检基线 → 2 备份 → 7 侦察导出 → （PC 侧生成 payload）→ 3 Argon 配置 →
4 总览部署 → 5 入口注册`，出问题 `6` 一键回滚。

> ⚠️ 本脚本设计为**在路由器上**运行（busybox ash）。PC 侧上传工具见 `tools/`——
> dropbear 无 SFTP 且单次 stdin 写入超限会被 reset，`tools/kp_put.py` 用原始字节分块 + 双校验解决。

## 目录结构

```
kp-style.sh                          # 设备侧七项菜单主脚本
payload/
  argon.uci                          # 预烘焙 Argon 配置（段类型 = global）
  admin_status/nradio_details.htm    # 设备总览卡片化页面（含服务入口卡片）
  kp_services.lua                    # 「服务」菜单注入体（marker: KP-SERVICES-MARKER）
  cgi-bin_luci.patched.lua           # 注入后的 CGI 包装器（构建产物，便于比对）
tools/                               # PC 侧工具
  kp_put.py                          # 分块上传（无 SFTP 场景）
  kp_fetch.py                        # LuCI 登录会话抓取器
  kp_tpl_check.py                    # LuCI 模板 <% %> Lua 语法校验
  build_wrapper.py                   # 生成注入后的 CGI 包装器（幂等）
docs/
  DESIGN.md                          # 8080 实例架构逆向 + 主题升级评估
  TROUBLESHOOTING.md                 # 踩坑记录
portal-istoreos/exe-installer/       # Windows 一键安装器（源码 + 成品 exe）
  kp_portal_installer.py             # 安装 + 恢复 8080 环境（GUI / CLI）
  build_exe.py                       # 打包成单文件 exe（带 tkinter 预检）
  payload/                           # 内嵌的 portal.lua(v3) + 自愈守卫
  鲲鹏门户安装器.exe                  # 已打包好的成品，双击即用
scripts/
  kp-8080-backup.py                  # 备份 8080 全量状态到 PC
```

## 备份与恢复 8080 环境

8080 实例不是 opkg 管理的 —— 全是手放的 `overlay` 文件 + 软链，
一旦被改坏（比如固件自更新覆写、误删软链）很难重建。所以提供了一对工具：

**① 备份（PC 侧）**

```bat
python scripts\kp-8080-backup.py --out D:\bak\8080 --tar
```

抓到：8080 docroot 全量文件、`luci-static` 软链、`menu.d`、UCI 配置
（uhttpd / istore / istorerouter / kp_portal / quickstart）、
**用户后装插件清单**（`plugins.txt` / `plugins.names` / `plugins.feed-status.txt`）、
**软件源配置**（`feeds/` + `feeds.txt`，含连通性快照）、`opkg list-installed`。
本机基准：**80 文件 / 1.3 MB**，tar.gz 约 **535 KB**，逐文件写 `MANIFEST.txt`。

**② 恢复（用 exe）**

双击 `portal-istoreos/exe-installer/鲲鹏门户安装器.exe` → 填地址密码 → 点「恢复 8080 环境」→ 选备份目录。

```bat
set ROUTER_PW=你的密码
鲲鹏门户安装器.exe --cli --restore "D:\bak\8080"
```

恢复会**先把设备现状再备份一次**到 `/root/kp-8080-restore-bak-<时间戳>/`，
再推送文件、重建软链、重启 uhttpd，最后 6 项验收。

> **真机破坏性实测**：故意把 CGI 打成垃圾、删掉 `main.htm` / `overview.htm`、
> 砍掉 5 条软链（9→4）、删 2 个 `menu.d`（4→2），再用 exe 恢复 ——
> **77/77 文件推送成功、0 失败**；独立核对 **77/77 文件 md5 与基线逐字节一致**，
> 17 个 KP 补丁标记、9 条软链、4 个 `menu.d` 全部回来，
> 登录后 `istorerouter` / `quickstart` 均 200。

**③ 恢复插件（`--restore-plugins`）**

把备份里的用户后装包（本机 134 个：Docker 全家桶 / python3 全家桶 /
OpenClash / 1Panel / iStore 系列 / quickstart / frpc / 51ddns / UNM …）
按清单装回来 —— 已装的跳过、缺的 `opkg install`，失败的写
`plugins.restore-failed.txt`：

```bat
鲲鹏门户安装器.exe --restore-plugins "D:\bak\8080"
```

> 判据是 `Installed-Time`（厂商 493 个包共用一个时间戳），**不是 opkg 的
> `Status`** —— `install user installed` 会把 busybox/kernel/dnsmasq 这些
> 固件包也算进去（本机实测 291 个，多 157 个不该动的）。
>
> **真机破坏性实测**：卸载 `zoneinfo-asia`（零反向依赖）→ 恢复 →
> 精确识别「133 跳过 + 1 待装」→ 装回 → 包总数回到 628 ✓

**④ 测试软件源（`--test-feeds`）**

三层递进：每个源 HTTP 连通性 → `opkg update` 索引刷新（opkg 真正依赖的）
→ 实际 `opkg download` 一个包验证下载链路：

```bat
鲲鹏门户安装器.exe --test-feeds
```

> 本机实测：**7/7 源 200**（aliyun openwrt_base/packages/routing +
> istore store/nasluci/meta/compat，0.2~0.4s）、7 源索引刷新共 **5715 包**、
> `zoneinfo-asia` 30.2 KB 下载成功 —— **全部可用**；134 个用户后装包
> **全部在源里可装，0 缺失**。

## 运行环境

- 鲲鹏 C2000 系列 NROS 固件（OpenWrt 21.02-SNAPSHOT / LuCI git-26.253 / busybox ash）
- 已通过「OpenWrt 原版 LuCI（8080）」组件装好 8080 实例
- 设备侧依赖：`curl` / `wget`（双栈下载）、`tar`、`lua`、`uci`
- PC 侧依赖：Python 3 + `paramiko`

## 致谢

- [guoguobuku/mt6000-istoreos](https://github.com/guoguobuku/mt6000-istoreos)（Argon 版本锁定与不刷机路线来源）
- [jerrykuku/luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon)
- [linkease/istore](https://github.com/linkease/istore)（iStoreOS）

## License

MIT

## 子项目：`portal-istoreos/` —— iStoreOS 风格门户（v3 四卡片）

把 80 端口门户 `http://<lan>/cgi-bin/portal` 重新规划成 **iStoreOS 风格四卡片入口**：

| 卡片 | 目标 |
|---|---|
| istore os风格化（弹层内嵌，保留登录） | `:8080/cgi-bin/luci/admin/istorerouter` |
| 高级设置（新标签） | `:8080/cgi-bin/luci/admin/quickstart/` |
| 美化版界面 | `:10086/` |
| 官方界面 | `/cgi-bin/luci` |

链接全部按请求 Host 动态生成（不硬编码 IP）。

**一行命令安装**（SSH 到设备，root）：

```sh
wget -qO /tmp/kp-portal.sh https://raw.githubusercontent.com/h910056902/kunpeng-istoreos-style/main/portal-istoreos/install.sh && sh /tmp/kp-portal.sh
```

回滚：`ROLLBACK=1 sh /tmp/kp-portal.sh`

详见 [portal-istoreos/README.md](portal-istoreos/README.md)；
**8080 实例全量功能盘点**见 [docs/FEATURES-8080.md](docs/FEATURES-8080.md)。

> v3 变更：删除「小字开关」与「进入 8080 界面」按钮，不再写 `/etc/config/kp_portal`；
> 新增 `KP-ISTOREROUTER-MENU v2` / `KP-ISTOREROUTER-VIEW v1` 两个 dispatcher 标记块，
> 修好 8080 上 `/admin/istorerouter` 的路由与渲染。
