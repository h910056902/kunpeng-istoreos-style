# payload 溯源表（自动生成，勿手改）

> 全部取自真机 2026-09-28（只读抓取，字节保真：`wc -c` 前缀 + `cat` 按长度截取）。
> **判据一律用 `字节数:md5` 双断言** —— 见下表。

## 两条必须记住的固化约束

1. **EOF 换行**：`dispatcher.luci` 原文件末**有**换行；去掉它就从 54998 B 变 54997 B，
   md5 从 `db09b091…` 变 `88a47acd…`。`.gitattributes` 的 `eol` 只管行尾、**不管 EOF 换行**。
2. **`core.autocrlf`**：本机为 `true`。`*.luci` 若在 `.gitattributes` 里无规则，
   检出时会被 LF→CRLF 改写（54998 → 56465 B），md5 全错。故已登记 `*.luci text eol=lf`。

## 清单

| 文件 | 字节 | md5 | CR |
|---|---|---|---|
| `dispatcher.luci` | 54998 | `db09b091dd4fe21d61920c8b5f25f8d2` | 0 |
| `luci-static.links` | 546 | `06a0e15ba5aeba77a5c06de95a2ce652` | 0 |
| `shared-controller/istorerouter.lua` | 4467 | `3081b27df0a8d1ae94d386d3ffce27a5` | 0 |
| `shared-controller/quickstart.lua` | 6748 | `1f1b67c62aeb103c81164f12a4523f1e` | 0 |
| `shared-controller/systools.lua` | 6101 | `0e699b388529c378b94be718b0cb73e4` | 0 |
| `views/admin_status/nradio_8080_sysauth.htm` | 6222 | `a06356a29e370a048a9dcc842c9489cd` | 0 |
| `views/admin_status/nradio_cellular.htm` | 28342 | `c0fa6ab8afee33c9cb826bc91e4452b0` | 0 |
| `views/admin_status/nradio_details.htm` | 33204 | `25f9e3242fe0e1cd6196a31b4dfef880` | 0 |
| `views/admin_status/nradio_device.htm` | 14046 | `a9756e8e9066d759afabb5f41a6579fe` | 0 |
| `views/admin_status/nradio_sms.htm` | 9369 | `8b2cf29996d7d5305ccf73707b8d13e0` | 0 |
| `views/quickstart/home.htm` | 409 | `6370488723c57d656d6a2e9366bd0716` | 0 |
| `views/quickstart/main.htm` | 3425 | `86586d5345a348601d4a86e138ef0829` | 0 |
| `views/quickstart/wizard.htm` | 376 | `267e0eacc9d7a25414ff4b1916f0af14` | 0 |
| `views/themes/bootstrap/footer.htm` | 2214 | `404b0e4a8bc103874006dda9414fc8be` | 0 |
| `views/themes/bootstrap/header.htm` | 10741 | `1c3bfd1154d10fdc39d9fca61e06ed3f` | 0 |
| `views/themes/bootstrap/header_login.htm` | 5488 | `97d0072fee359cd5ce17d3424b2f71b9` | 0 |
| `views/themes/bootstrap/out_header_login.htm` | 335 | `77c2ce4f46b0097cccc2b0cba6e68e18` | 0 |
| `views/ttyd/overview.htm` | 10072 | `cf2d435b195de415f51b07eef13711bf` | 0 |

## 设备来源路径

| payload | 设备路径 |
|---|---|
| `dispatcher.luci` | `/overlay/nradio-apps/openwrt-luci-8080/www/cgi-bin/luci` |
| `shared-controller/*.lua` | `/usr/lib/lua/luci/controller/{istorerouter,quickstart,systools}.lua`（**80 口共用**）|
| `views/admin_status/*` | `/overlay/nradio-apps/openwrt-luci-8080/usr/lib/lua/luci/view/admin_status/` |
| `views/quickstart/*` | `.../view/quickstart/` |
| `views/themes/bootstrap/*` | `.../view/themes/bootstrap/` |
| `views/ttyd/overview.htm` | `.../view/ttyd/overview.htm` |
| `luci-static.links` | `.../www/luci-static/` 的软链布局 |
