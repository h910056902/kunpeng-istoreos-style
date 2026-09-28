# 8080 实例 · 已实现功能盘点

> 对象：鲲鹏 C2000 U（NRadio，`nradio.in`）的**第二个 LuCI 实例**
> —— `http://192.168.66.1:8080/cgi-bin/luci`
>
> 盘点日期：2026-09-28　·　盘点方式：只读（读文件 / HTTP 取正文，不改动设备）

---

## 0. 这个 8080 实例是什么

设备上有**两套并行的 LuCI**：

| | 80 端口（官方） | 8080 端口（本仓库改造对象） |
|---|---|---|
| CGI | `/www/cgi-bin/luci`（135 B，转发壳） | `/overlay/nradio-apps/openwrt-luci-8080/www/cgi-bin/luci`（约 55 KB，**全套定制逻辑**） |
| docroot | `/www` | `/overlay/nradio-apps/openwrt-luci-8080/www`（**白名单式**，`luci-static/<name>` 必须有软链） |
| view 目录 | `/usr/lib/lua/luci/view` | 私有 `<instance>/usr/lib/lua/luci/view`（仅 `admin_status` / `quickstart` / `themes` / `ttyd`），其余回退共享 |
| 主题 | 原厂 | 强制 `bootstrap`（argon 软链指过去） |
| indexcache | `/tmp/luci-indexcache` | `/tmp/luci-indexcache-bootstrap`（独立，避免互相污染） |
| 鉴权模板 | 原厂 | `admin_status/nradio_8080_sysauth` |

8080 的 CGI 在 `createtree()` 前后包了一层，把 **官方控制器（`original_createtree()` 先跑）**
与 **一批自定义节点** 合并成一棵树。所有定制都用
`-- KP-XXX vN BEGIN/END`（Lua）/ `<!-- KP-XXX vN BEGIN/END -->`（htm）注释块圈起来，
**块内替换、幂等可重跑**。

---

## 1. 定制标记块总表（dispatcher 内）

| 标记 | 版本 | 作用 |
|---|---|---|
| `KP-ISTOREROUTER-MENU` | v2 | 注册 `admin/istorerouter` 节点，调 controller 的 `istorerouter_template()` 渲染 |
| `KP-ISTOREROUTER-VIEW` | v1 | 白名单：`istorerouter/{index,main,main_dev}.htm` 可从私有 view 取 |
| `KP-QUICKSTART-PATCH` | v2 | 补齐被 Go 后端 `,omitempty` 抹掉的字段 |
| `KP-QUICKSTART-PROXY` | v2 | quickstart 的 Go 后端反代 |
| `KP-QUICKSTART-VIEWNS` | v3 | quickstart 视图命名空间隔离 |
| `KP-QUICKSTART-VIEW` | v2 | quickstart 视图 overlay-with-fallback |
| `KP-CELLULAR-ENDPOINT` | v1 | 蜂窝/AT 指令端点（约 450 行，含 `^NRFREQLOCK` 锁频回读） |
| `KP-SERVICES-MARKER` | v1 | 侧栏「服务」聚合菜单（鲲鹏商店 / 1Panel / Docker） |
| `KP-PROCESSES-MARKER` | v1 | 系统进程页空白修复（仅 8080 实例） |
| `KP-NAS-PARENT-CGI` | v1 | 修复 `admin/nas` 整树 500（`Access Violation: no parent node`） |
| `KP-TTYD-VIEW-MARKER` | v1 | ttyd 终端页改用实例私有视图 |

---

## 2. dispatcher 注册的自定义菜单节点

| 节点 | 标题 | 说明 |
|---|---|---|
| `admin.nodes.istorerouter` | iStoreRouter | iStoreOS 风格路由管理 SPA，`order = 3`，leaf |
| `admin.nodes.quickstart` | 网络向导 | 8080 版首屏向导 |
| `admin.nodes.network_guide` | 网络设置 | 向导的「页面」入口 |
| `admin.nodes.kp_services` | 服务 | 聚合菜单（鲲鹏商店 / 1Panel / Docker） |
| `admin.nodes.nradio_plugins` | 插件 | 把设备上**原生**插件菜单聚成一个入口 |
| `admin.nodes.status` | 状态 | 内含「设备总览」（`admin_status/nradio_details`） |
| `admin.nodes.nas` | NAS | 修复过 parent node 问题 |

`menu.d` 里与本实例相关的定义：`luci-app-istorerouter.json`、`luci-app-quickstart.json`
（另有 `luci-app-51ddns.json`、`luci-app-unblockneteasemusic.json`）。

---

## 3. 各功能模块明细

### 3.1 iStoreRouter（核心）

- **入口**：`/cgi-bin/luci/admin/istorerouter`
- **形态**：Vue SPA（`/luci-static/istorerouter/{index.js,style.css,i18n/zh-cn.json}`）
- **控制器**：`/usr/lib/lua/luci/controller/istorerouter.lua`
  - `user_id()` 读 `/etc/.app_store.id` → `arch` / `uid`；`/etc/.app_store.version` → `version`
  - `get_params()` → `prefix` / `id` / `model` / `cache_tag`
  - `istorerouter_template()` → `render("istorerouter/main", get_params())` ← **8080 走这条**
  - `index()` 带 `pgrep quickstart` 守卫（守护没跑会 `redirect_fallback`）
- **实用功能（SPA 内）**：路由状态 / 网络配置 / 存储管理 / 应用商店 / 远程访问 / 高级配置
- **踩坑**：见 `portal-istoreos/README.md` 第 2 条（`template()` 绕过 controller → 500 被 200 包着内联）

### 3.2 网络向导 quickstart

- **入口**：`/cgi-bin/luci/admin/quickstart/`（及其 `network_guide` / `quickwifi` 子页）
- **三个补丁块**：字段补齐（`PATCH v2`）、Go 后端反代（`PROXY v2`）、视图命名空间隔离（`VIEWNS v3`）
- **控制器**：`luci.controller.quickstart`，`index()` 同样带 `pgrep quickstart` 守卫

### 3.3 系统便利工具 systools

- **入口**：`/cgi-bin/luci/admin/system/systools/pages`
- **控制器**：`/usr/lib/lua/luci/controller/systools.lua`（经典 Lua controller，4 条路由）
  - `admin/system/systools` → `redirect_index`（`dependent = true`）
  - `admin/system/systools/pages` → `systools_index` → `render("systools/main", {prefix})`
  - `admin/system/systools/form` → `systools_form` → 返回 JSON `{error, scope, success, result:{data, schema}}`
  - `admin/system/systools/submit` → `systools_submit` → 起异步任务
- **前端**：iStoreOS `iform` SPA —— `/luci-static/iform/1.1/{index.js,style.css}`，
  读 `window.IstoreosFormConfig` 的 `getApi`/`submitApi`/`logApi`
- **后端任务**：`/etc/init.d/tasks`（procd，`extra_commands` 有 `task_add`/`task_del`/`task_status`）
  → 每条任务 spawn 一个 `/usr/libexec/taskd`
- **踩坑**：8080 白名单 docroot 缺 `iform` 软链 → JS 404 → **页面空白**（不报错）。

### 3.4 蜂窝 / AT 指令端点

- 标记 `KP-CELLULAR-ENDPOINT v1`（dispatcher 内约 450 行）
- 经 `ubus` 向 modem 发 AT：`{"cmd":..., "wait":..., "at_log_level":0, "block":1}`
- 含 `^NRFREQLOCK` / `^LTEFREQLOCK` 锁频与回读解析
- shell 单引号用 `'"'"'` 技巧转义（否则 ubus 收到畸形 JSON）

### 3.5 服务入口侧栏（iStoreOS 风格）

- 标记 `KP-SERVICES-MARKER v1`
- 三个入口：**鲲鹏商店** / **1Panel** / **Docker**
- 1Panel 地址**直接解析** `/usr/local/bin/1pctl` 的 `ORIGINAL_PORT` / `ORIGINAL_ENTRANCE`，
  不执行 bash（CGI 环境下 `1pctl` 可能不可用）
- 主机名优先取 `SERVER_NAME`，为空才回退 `ip addr show br-lan`

### 3.6 ttyd 终端 / 进程页 / NAS

| 模块 | 问题 | 处理 |
|---|---|---|
| ttyd 终端页 | 共享视图的「运行判据」与终端地址在 8080 下不成立 | `KP-TTYD-VIEW-MARKER` 改用私有视图，缺失静默回退 |
| 系统进程页 | 8080 下空白 | `KP-PROCESSES-MARKER v1` 修复 |
| `admin/nas` | 整树 HTTP 500（`no parent node`） | `KP-NAS-PARENT-CGI v1` 补父容器 |

---

## 4. 静态资源软链清单（8080 私有 docroot）

`/overlay/nradio-apps/openwrt-luci-8080/www/luci-static/` 下**必须**有软链，否则 404：

| 软链 | 指向 |
|---|---|
| `argon` | `bootstrap`（argon 主题 → bootstrap，做 iStoreOS 观感） |
| `bootstrap` | 实体目录 |
| `iform` | `/www/luci-static/iform`（systemtools SPA） |
| `istore` | `/www/luci-static/istore` |
| `istorerouter` | `/www/luci-static/istorerouter` |
| `linkeasefile` | `/www/luci-static/linkeasefile` |
| `natpierce` | `/www/luci-static/natpierce` |
| `nradio` | `/www/luci-static/nradio` |
| `quickstart` | `/www/luci-static/quickstart` |
| `resources` | `/www/luci-static/resources` |

> 典型故障：`istorerouter` / `iform` / `quickstart` 少一个 → 对应 SPA **空白**（HTTP 200，JS 404）。

---

## 5. 80 端口门户（portal v3）

`/www/cgi-bin/portal` —— 四卡片 iStoreOS 风格入口，详见
[`portal-istoreos/README.md`](../portal-istoreos/README.md)。

| 卡片 | 目标 |
|---|---|
| istore os风格化（弹层内嵌，保留登录） | `:8080/cgi-bin/luci/admin/istorerouter` |
| 高级设置（新标签） | `:8080/cgi-bin/luci/admin/quickstart/` |
| 美化版界面 | `:10086/` |
| 官方界面 | `/cgi-bin/luci` |

---

## 6. 已知坑（跨模块）

1. **`SERVER_PORT ~= "8080"` → 404**：8080 CGI 首段守卫。带代理的机器把 `:8080`
   请求转成非 8080 端口时会命中，表现为「**curl 200 / 浏览器 404**」。
   → 把 `192.168.*` 加进代理绕过列表。
2. **报错被 200 包着内联**：模板内抛错时 HTTP 头已发出，错误文本混进正文，
   外部看是 200。**必须登录取正文**才能发现。
3. **匿名访问无法区分「路由不存在」**：未登录时 `/admin/istorerouter` 与
   `/admin/zzz-nonexistent` 都返回 403，鉴权在路由之前。必须带 cookie 测。
4. **白名单 docroot**：8080 的 `luci-static` 只认私有目录里**有软链**的资源。
5. **`luci-indexcache` 两份**：80 用 `/tmp/luci-indexcache`，8080 用
   `/tmp/luci-indexcache-bootstrap`；改完 htm/lua 要**两份都清**（或至少清对那份）。

---

## 7. 快速验收

```sh
# 登录 8080（在设备本机执行，避开代理）
curl -s -c /tmp/cj -o /dev/null 'http://127.0.0.1:8080/cgi-bin/luci/admin/status/details'
curl -s -b /tmp/cj -c /tmp/cj -o /dev/null -X POST \
  'http://127.0.0.1:8080/cgi-bin/luci/admin/status/details' \
  -d 'luci_username=root&luci_password=admin'

# 关键页状态码 + 体积 + 是否混入 500
for u in admin/istorerouter admin/system/systools/pages; do
  curl -s -b /tmp/cj -o /tmp/r -w "$u → %{http_code} " "http://127.0.0.1:8080/cgi-bin/luci/$u"
  echo "$(wc -c < /tmp/r)B 500=$(grep -c 'Internal Server Error' /tmp/r)"
done

# istorerouter 的注入变量必须是真值（不是 Status: 500...）
curl -s -b /tmp/cj 'http://127.0.0.1:8080/cgi-bin/luci/admin/istorerouter' \
  | grep -oE '(arch|uid|version):"[^"]*"'
```

期望：`istorerouter` 约 3999 B / `500=0`，且 `arch:"aarch64_cortex-a53"`、
`uid:"eaac6e3c4d16c50b6a04e8aea2c615ff"`、`version:"0.2.1-r1"`。
