# portal-istoreos

> 鲲鹏 C2000 U（NRadio，OpenWrt 21.02.7）**80 端口门户重做成 iStoreOS 风格** 的一行安装补丁。

把设备上 `http://192.168.66.1/cgi-bin/portal`（`nr_webui` 门户）从「一堆小字 + 开关 +
一个 8080 按钮」**重新规划成 iStoreOS 风格的四卡片入口**，每张卡点进去都是**真正能用的目标页**。

---

## 一行命令安装

SSH 到设备（`root`），执行：

```sh
wget -qO /tmp/kp-portal.sh https://raw.githubusercontent.com/h910056902/kunpeng-istoreos-style/main/portal-istoreos/install.sh && sh /tmp/kp-portal.sh
```

无 `wget` 时用 `curl`：

```sh
curl -fsSL https://raw.githubusercontent.com/h910056902/kunpeng-istoreos-style/main/portal-istoreos/install.sh -o /tmp/kp-portal.sh && sh /tmp/kp-portal.sh
```

装完访问 `http://192.168.66.1/cgi-bin/portal`。

---

## 四张卡片（v3 的重新规划）

| 卡片 | 行为 | 目标 |
|---|---|---|
| **istore os风格化** `新` | 点开 → **弹层内嵌**（保留登录鉴权） | `http://<host>:8080/cgi-bin/luci/admin/istorerouter` |
| **高级设置** | → **新标签**直接打开 | `http://<host>:8080/cgi-bin/luci/admin/quickstart/` |
| **美化版界面** | → 当前标签 | `http://<host>:10086/` |
| **官方界面** | → 当前标签 | `http://<host>/cgi-bin/luci` |

要点：

- **链接全部按请求 Host 动态生成**（`os.getenv("HTTP_HOST")`），
  用 `192.168.66.1` 访问就得到 `192.168.66.1` 的链接，用 `nradio.in` 就得到 `nradio.in` 的链接；
  不存在硬编码 IP。
- 「istore os风格化」是 `<button onclick="openIR()">`，弹层用
  `<iframe src="about:blank">` **懒加载**（首次点开才设置 `src`），
  支持 `Esc` 关闭、点遮罩空白处关闭、点弹窗内部不关。
- **保留了 8080 的登录**：iframe 里是独立上下文，未登录会看到 LuCI 登录页，
  登录后才是 iStoreRouter SPA —— 这是刻意保留的鉴权边界，不是缺陷。

> v3 相比 v1.2 **删除了**「小字：已显示/已隐藏」开关和「进入 8080 界面」按钮，
> 也不再写 `/etc/config/kp_portal`。旧注入块若还在设备上，用
> `KP_CLEAN_NOSMALL=1 sh kp-portal.sh` 清理。

---

## 它改了什么

| # | 目标 | 改动 |
|---|---|---|
| 1 | `/www/cgi-bin/portal` | 整页重写为 iStoreOS 风格四卡片门户；`N R WEBUI_PORTAL=3.0` |
| 2 | （可选）`.../quickstart/main.htm` | **仅在你显式设 `KP_CLEAN_NOSMALL=1` 时**清除历史小字注入块 |

**8080 侧**（本仓库 `payload/cgi-bin_luci.patched.lua`）另含两处配套标记块：

| 标记 | 作用 |
|---|---|
| `KP-ISTOREROUTER-MENU v2` | 在 8080 的 `createtree()` 里注册 `admin/istorerouter` 节点（否则 8080 上该路由 404） |
| `KP-ISTOREROUTER-VIEW v1` | 让 `istorerouter/*.htm` 可从实例私有 view 目录取，缺失时回退共享视图 |

---

## 8080 实例已实现的功能（总览）

完整盘点见 **[`docs/FEATURES-8080.md`](docs/FEATURES-8080.md)**。速览：

| 模块 | 说明 | 标记 |
|---|---|---|
| iStoreRouter | iStoreOS 风格路由管理 SPA（路由状态 / 网络配置 / 存储 / 应用商店 / 远程访问 / 高级配置） | `KP-ISTOREROUTER-MENU v2` |
| 网络向导 quickstart | 8080 版首屏向导；含 **Go 后端字段补齐代理** 与 **视图命名空间隔离** | `KP-QUICKSTART-PATCH v2` / `-PROXY v2` / `-VIEWNS v3` |
| 系统便利工具 systools | iStoreOS 风格工具页（14 件工具，靠 `/luci-static/iform/1.1/` 前端） | — |
| 蜂窝/AT 端点 | 直接向 modem 发 AT 指令（含 `^NRFREQLOCK` 锁频回读） | `KP-CELLULAR-ENDPOINT v1` |
| 服务入口侧栏 | 鲲鹏商店 / 1Panel / Docker 聚合菜单 | `KP-SERVICES-MARKER v1` |
| 系统进程页修复 | 8080 下进程页空白修复 | `KP-PROCESSES-MARKER v1` |
| NAS 顶层容器 | 修复 `admin/nas` 整树 500（no parent node） | `KP-NAS-PARENT-CGI v1` |
| ttyd 终端页 | 改用实例私有视图（共享视图的判据/地址在 8080 不成立） | `KP-TTYD-VIEW-MARKER` |

---

## 为什么这么写（踩过的坑）

1. **`SERVER_PORT` 守卫会让「代理环境」下的 8080 访问变成 404** ⭐
   8080 那份 CGI 的第一段就是：

   ```lua
   if os.getenv("SERVER_PORT") ~= "8080" then
       io.write("Status: 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot Found\n")
       return
   end
   ```

   症状：**路由器本机 `curl` 200，带代理的电脑浏览器 404 `Not Found`**。
   原因：电脑上的代理把 `:8080` 的请求转发到非 8080 端口（或经端口重映射），
   CGI 读到 `SERVER_PORT=80` → 走守卫分支返回 404 → uhttpd 渲染自己的错误页。
   **修法不是改路由器**，而是把 `192.168.*` 加进代理绕过列表（或临时关代理）。
   80 端口的 portal 没有这个守卫，所以不受影响 —— 这会造成
   「门户能开、内嵌页 404」的错觉。

2. **`luci.dispatcher.template(path)` 绕过 controller → 报错被 200 包着内联** ⭐
   给 8080 挂 `admin/istorerouter` 时，若写成
   `target = luci.dispatcher.template("istorerouter/main")`，
   就**跳过了 controller 的 `get_params()`** → 模板里 `<%=id.arch%>` / `<%=model%>` 全 nil
   → 第 28 行 `id.arch` 抛 `attempt to index global 'id' (a nil value)`
   → dispatcher 捕获异常，但**此时 HTTP 头已发出（200）**，错误文本被当模板输出
   内联进 `arch:"Status: 500 Internal Server Error..."` → `window.device_id` 变垃圾 → SPA 启动即崩。
   **外部表现为 200，肉眼完全看不出失败**。
   正确写法是调 controller 的渲染函数：
   `pcall(require, "luci.controller.istorerouter")` 后调 `ctl.istorerouter_template()`。

3. **8080 的 `luci-static` 是白名单 docroot**
   8080 私有 docroot 只认 `/overlay/nradio-apps/openwrt-luci-8080/www/luci-static/` 下**有软链**的资源。
   即使 80 端口有 `/www/luci-static/iform`，8080 没软链就是 **404**
   → systools 的 iform SPA 起不来 → **页面空白**（而不是报错）。
   修法：`ln -s /www/luci-static/iform /overlay/.../www/luci-static/iform`。

4. **`uci set` 不能创建新配置文件**
   `uci set kp_portal.ui.hide_small=0` 直接报 `Entry not found`（rc=1）。
   必须先 `touch /etc/config/kp_portal`，再 `uci set`。

5. **固件没有 `base64` / `od` / `openssl` / `xxd`**
   二进制或精确文本传输只能走 `printf '\NNN'` 或 heredoc。

6. **`hexdump -C` 的 `*` 是重复行压缩标记**
   连续两行以上内容相同 → 只打一行 + 一个 `*`（POSIX 行为）。
   直接按行拼 hex 会**少字节**（14063 → 13871）。必须按**偏移量**还原。
   结尾有一个**裸偏移行**（如 `000036ef`）表示 EOF，不是垃圾。

7. **busybox ash 不支持 `trap ... ERR`**
   只有 `EXIT` / `INT` / `TERM` 可靠。

8. **`raw.githubusercontent.com` 有约 5 分钟 CDN 缓存**
   刚推送完立刻装可能拿到旧版；等 5 分钟或加 `?t=<时间戳>`。

9. **git 仓库必须是 public，否则 raw 一律 404**
   `raw.githubusercontent.com` 对**私有仓库的匿名请求返回 404**（不是 403），
   看起来像「文件不存在」，极易误判。本安装器托管在**公开仓库**
   `h910056902/kunpeng-istoreos-style`。判据：
   `curl -s -o /dev/null -w '%{http_code}\n' https://api.github.com/repos/<owner>/<repo>` → `200`。

10. **本改动不碰 80 端口官方视图**
    `/usr/lib/lua/luci/view/quickstart/main.htm`（官方）保持原样，避免影响原厂界面。

---

## 回滚

```sh
ROLLBACK=1 sh /tmp/kp-portal.sh
```

会从 `/root/kp-bak-<时间戳>/` 取**最近一次**备份恢复 `portal`（与 `main.htm`，若有），
清 LuCI 缓存并重启 uhttpd。也可手工：

```sh
cp /root/kp-bak-*/portal.bak /www/cgi-bin/portal
rm -f /tmp/luci-indexcache; rm -rf /tmp/luci-modulecache/*
/etc/init.d/uhttpd restart
```

---

## 仓库结构

```
portal-istoreos/
├── README.md                       # 本文件
├── install.sh                      # 一行命令入口（拉 kp-portal.sh + payload 并执行）
├── kp-portal.sh                    # 真正干活的补丁器（幂等 + 备份 + 回滚）
└── payload/
    └── portal.lua                  # v3 门户（md5 9360ce8c…，14423 B）
```

`install.sh` 只做下载 + 转交；`kp-portal.sh` 是唯一有写操作的地方，
每次运行都会先备份，可用 `ROLLBACK=1` 撤销。

---

## 验证清单

```sh
# 1) portal 部署正确
md5sum /www/cgi-bin/portal
#   → 9360ce8c9b0421ebb39c11306949861f

# 2) 四张卡片都在
grep -c 'class="opt ' /www/cgi-bin/portal
#   → 4

# 3) 高级设置指向 8080 quickstart
grep -o 'quickstart/' /www/cgi-bin/portal | head -1

# 4) 弹层目标是 iStoreRouter
grep -o 'admin/istorerouter' /www/cgi-bin/portal | head -1

# 5) 80 端口官方视图未被改动
md5sum /usr/lib/lua/luci/view/quickstart/main.htm
```

浏览器侧：进门户 → 点「istore os风格化」→ 弹层应是 **iStoreRouter**
（未登录先出登录页，登录后进 SPA）；「高级设置」应在**新标签**打开 quickstart。
