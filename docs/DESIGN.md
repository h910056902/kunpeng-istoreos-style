# 8080 LuCI 实例架构（逆向自 maye 安装器源码）

> 本文是对 `ssh-nradio-plugin-installer-lite.sh`（`install_openwrt_luci_8080` 函数族，
> 行 58595–59690+）的实读结论，作为本仓库所有改动的地形图。
> 来源：鲲鹏 C2000 U（NROS 2.3.0.n0.c1，OpenWrt 21.02-SNAPSHOT，LuCI git-26.253）。

## 一、目录布局

| 项 | 路径 / 值 |
|---|---|
| 实例根 | `/overlay/nradio-apps/openwrt-luci-8080/` |
| 文档根 | `<根>/www`（uhttpd.openwrt8080 的 `home`） |
| CGI 入口 | `<根>/www/cgi-bin/luci`（Lua 包装器，仅 `SERVER_PORT=8080` 时工作） |
| 私有视图目录 | `<根>/usr/lib/lua/luci/view` |
| 私有主题静态 | `<根>/www/luci-static/bootstrap/`（内容实为 **Argon v1.8.4** 风格） |
| index 缓存 | `/tmp/luci-indexcache-bootstrap` |
| uhttpd 段 | `uhttpd.openwrt8080`（`listen_http=$LAN_IP:8080`，`cgi_prefix=/cgi-bin`） |
| 公共静态 | `<根>/www/luci-static/<其他>` → **符号链接**到 `/www/luci-static/*`（bootstrap 除外） |

## 二、CGI 包装器工作机制（关键）

1. **复用主系统 LuCI 库**：`require "luci.cacheloader"` / `luci.sgi.cgi`，没有独立 LuCI 树；
2. **视图重定向**：monkey-patch `luci.template.parser.parse`，仅三个私有模板走私有视图目录：
   - `themes/bootstrap/*`（主题 header/footer 等）
   - `admin_status/nradio_details.htm`（**「设备总览」页**，登录后落点）
   - `admin_status/nradio_8080_sysauth.htm`（登录页）
   其余模板一律用主系统共享视图。
3. **主题强制**：`httpdispatch` 与 `createtree` 里把 `mediaurlbase` 硬置为
   `/luci-static/bootstrap`，并且**屏蔽**了 system 表单的 `_mediaurlbase` 字段
   → 8080 实例换主题不需要（也不允许）动全局 `luci.main.mediaurlbase`，
   **80 端口 NRadio 主界面天然安全**。
4. **菜单注入**：`inject_plugin_menu()` 聚合主树 `admin/services`、`admin/vpn` 下的插件 +
   一组预定义路由（ttyd/docker/openvpn/zerotier/openlist/mosdns/ddns-go 等），
   挂成「插件」菜单（order 55）；另把 `nradio`/`nradioadv` 顶层节点从树里**摘除**。
5. **设备总览挂载点**：`status.nodes.details = template("admin_status/nradio_details")`，
   标题「设备总览」，order 0。
6. **根路径 302**：`/`、`/admin`、`/nradio*`、`/nradioadv*` 一律 302 到
   `/cgi-bin/luci/admin/status/details`。

## 三、由此推导的改造安全边界

- ✅ **能改**：私有视图目录下的 htm、私有 `luci-static/bootstrap/` 静态资源、
  CGI 包装器（带锚点、带 marker 的增量补丁）。
- ❌ **不能动**：主系统 `/usr/lib/lua/luci`（80 与 8080 共用）、全局
  `luci.main.mediaurlbase`、`/www/luci-static/`（80 端口在用，8080 只链接引用）、
  商店补丁载体 `appcenter.htm` / `appcenter.lua`。
- ⚠️ 主题升级策略：**「换芯不换名」**——Argon 2.2.9.4 的静态资源与视图模板
  原地替换 `luci-static/bootstrap/` 与私有视图 `themes/bootstrap/`，
  包装器一行不用改（mediaurlbase 仍指向 bootstrap）。
- ⚠️ 不装 `luci-app-argon-config`：它是主 LuCI 的 CBI 应用，装了会污染 80 端口菜单；
  Argon 配置（暗色/壁纸/模糊）直接预烘焙进 `/etc/config/argon` 与静态资源。

## 四、与 Argon 2.2.9.4 的兼容性判断

- 8080 的 LuCI 是 git-26.253（master 代），Argon 2.2.9.4 面向 master 开发 → 兼容；
- ipk 为老式 gzip+tar 嵌套三件套，busybox `tar xzf` 可直接解开，无需 opkg；
- 资源 URL：Argon 视图用 `<%=media%>` 引用静态目录，media 由 mediaurlbase 推导，
  包装器强制为 `/luci-static/bootstrap` → 视图模板原样可用，无需改路径。
