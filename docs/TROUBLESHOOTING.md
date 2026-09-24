# 踩坑记录（TROUBLESHOOTING）

本文件记录在鲲鹏 C2000（NROS）8080 LuCI 实例上**实际踩到并已修复**的问题，
以及两个「看起来该做、实际不能做」的决策依据。

---

## 坑 1 —— Argon 配置段类型写错 → 全站配色失效（最隐蔽）

### 现象

页面能正常打开（HTTP 200），内容完整，但：

- 顶部导航条、卡片、按钮**全部失去主色**，退回灰白；
- 暗色模式不生效；
- 登录页 `:root` 里是空值：

```css
:root {
    --primary: ;          /* ← 空 */
    --dark-primary: ;     /* ← 空 */
    --blur-radius:px;     /* ← 没有数字，只有 px */
    --blur-opacity:;
}
```

### 根因

Argon 主题模板的读取代码是：

```lua
primary = uci:get_first('argon', 'global', 'primary')
```

`uci:get_first(conf, stype, opt)` 的**第二个参数是「段类型」（section type），不是段名**。
而写配置时很容易写成：

```uci
config argon 'global'      # ← 段类型 = argon，段名 = global（错误）
```

这样 `get_first('argon', 'global', ...)` 找不到「类型为 global 的段」→ 返回 `nil`
→ 模板渲染出 `--primary: ;`。

正确写法：

```uci
config global 'global'     # 段类型 = global，段名 = global
	option primary '#5e72e4'
	option dark_primary '#483d8b'
	option mode 'dark'
	option blur '4'
	option blur_dark '6'
	option transparency '0.5'
	option transparency_dark '0.45'
```

### 排查手法

从 SSH 侧 `uci get argon.global.primary` 是**正常的**（uci 只看段名，不看段类型），
所以很容易误判为「配置没问题」。真正要看的是渲染结果：

```sh
curl -s -H 'Cookie: sysauth=<...>' 'http://<lan>:8080/cgi-bin/luci/admin/status/details' \
  | grep -A7 ':root {'
```

只要看到 `--primary: ;` 就是本坑。

### 修复

改为 `config global 'global'` 后清缓存、重新登录（会话携带主题变量）即可。
`kp-style.sh` 选项 3 已内置**读回断言**：`uci -q get argon.global.primary` 不为
`#5e72e4` 就中止，避免再次落坑。

---

## 坑 2 —— LuCI 索引缓存陈旧 → 新装的 controller 页面 404

### 现象

手动解包安装 iStore 后，`/admin/store` 返回 302（节点存在），
但跟随重定向的 `/admin/store/pages` 返回 **404**。其它库存页面正常。

### 根因

LuCI 把 controller 索引缓存在 `/tmp/luci-indexcache`（本实例是
`/tmp/luci-indexcache-bootstrap`）。新装/改动的 controller 若未被索引到，
其子节点就不会进树 → 表现为「父节点在、子节点 404」。

### 修复

```sh
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache
```

`kp-style.sh` 的 `clear_luci_cache()` 在每个写操作后都会调用。

> 注意：清理索引缓存是**无副作用**操作（下次请求自动重建），
> 排查任何「节点找不到 / 新页面 404」都应先做这一步。

---

## 决策 A —— 为什么**不**把主题模板换成 Argon 2.2.9.4

参考项目 `guoguobuku/mt6000-istoreos` 锁定 Argon **2.2.9.4**。但直接换芯在本实例上**不可行**：

### 证据链

1. Argon 2.2.9.4 的 `footer.htm` 末尾是：

   ```html
   <script type="text/javascript">L.require('menu-argon')</script>
   ```

   即**侧栏菜单由 JS 运行时构建**（header 里 `<div id="mainmenu" style="display:none">`、
   `<div id="tabmenu" style="display:none">` 都是空的，服务端不渲染菜单）。

2. `L` 这个全局对象由 LuCI 的 `luci.js` 提供。而本实例：

   ```sh
   find / -name 'luci.js' -not -path '/proc/*'     # → 无任何命中
   ls /www/luci-static/resources/                  # → 无 luci.js
   ```

3. 结果：若把 1.8.4 模板换成 2.2.9.4，`L` 未定义 → `L.require('menu-argon')` 抛错
   → **侧栏导航整体不渲染**。此时页面仍返回 HTTP **200**，探活查不出来，
   用户拿到的是一个「能开、但点不动」的后台 —— 比现状更糟。

### 现行主题的菜单机制（对照）

本实例的 Argon 1.8.4 模板是**服务端渲染菜单**（`render_topmenu()` / `render_submenu()`
直接写 `<a class="menu" data-title="...">`），`menu-argon.js` 只负责展开动效，
不依赖 `luci.js`。因此现状是自洽且可用的。

### 结论

只做**配置层升级**（`/etc/config/argon`），主题模板保持不动。
若将来要上 2.2.9.4，前置条件是先把 LuCI 的 `luci.js` 运行时补齐，
并验证 `menu-argon` 模块可加载 —— 那是一次独立的、带完整回滚预案的改造。

---

## 决策 B —— 为什么服务入口用「菜单注入 + 首页卡片」，而不是 iframe 承载页

原设计考虑过为 1Panel 做同源 iframe 承载页。实测放弃，原因：

- 1Panel 自身**禁止被 iframe 嵌套**（响应头限制），承载页会白屏；
- 1Panel 的访问地址含**动态安全入口**（`/<8位随机串>`），且该值在
  `/usr/local/bin/1pctl` 里是**静态常量**（`ORIGINAL_PORT` / `ORIGINAL_ENTRANCE`）。

因此改为：菜单项 `target` 函数直接 `http.redirect()` 到目标地址，
地址由**解析 `/usr/local/bin/1pctl` 常量 + 请求 host 拼接**得到
（不执行 `1pctl`，因为它是 bash 脚本，CGI 环境不保证可用）。

首页卡片同理，并额外用 `docker ps` 实时输出容器计数。
