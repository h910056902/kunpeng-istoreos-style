# kunpeng-istoreos-style

> 鲲鹏 C2000 系列（NROS 固件）**不刷机** 8080 LuCI 一键 iStoreOS 风格化。
> 思路参考 [guoguobuku/mt6000-istoreos](https://github.com/guoguobuku/mt6000-istoreos)
>（GL-iNet 路由器不刷机风格化），针对鲲鹏 NROS 固件的独立 LuCI 实例（8080 端口）重新实现。

## 它做什么

| 能力 | 说明 |
|---|---|
| Argon 主题升级 | 私有主题目录**换芯不换名**：Argon 1.8.4 → 2.2.9.4（锁定版本，2.3.1 登录按钮无中文匹配） |
| Argon 配置预烘焙 | 暗色模式 / 主色 / 模糊度写进 `/etc/config/argon`，**不装** luci-app-argon-config（避免污染 80 端口 NRadio 主界面菜单） |
| 设备总览卡片化 | 重做 `admin_status/nradio_details.htm`（登录后首页），现代卡片布局 |
| 入口注册 | 「鲲鹏商店 / 1Panel / Docker 容器」以同源承载页 + 菜单注入方式挂进 8080 侧边栏 |
| 全程可回滚 | 时间戳备份 → /tmp 语法校验 → 落盘 → 清缓存 → HTTP 探活，任一步失败自动回退 |

## 为什么安全（改不坏主界面）

8080 实例由独立 `uhttpd.openwrt8080` 服务，文档根在
`/overlay/nradio-apps/openwrt-luci-8080/www`，CGI 包装器复用主系统 Lua 库但把
视图/主题**隔离**在实例私有目录里，且强制 `mediaurlbase=/luci-static/bootstrap`
（仅实例内）。因此：

- 80 端口 NRadio 原厂界面与全局主题**零接触**；
- 不安装任何 luci 系 opkg 包（本固件 opkg 源没有 luci 源，装了必出事）；
- 不触碰应用商店补丁载体（`appcenter.htm` / `appcenter.lua`）。

详见 [docs/DESIGN.md](docs/DESIGN.md)（对 8080 实例安装器的逆向记录）。

## 使用

```sh
# 传到路由器后（凭据与传输方式自行处理，本仓库不含任何凭据）
sh kp-style.sh
```

菜单：`1 体检基线 → 2 备份 → 7 侦察导出 → （PC 侧生成 payload）→ 3 主题升级 →
4 总览部署 → 5 入口注册`，出问题 `6` 一键回滚。

## payload 目录

`payload/` 存放需要**根据真机侦察结果生成**的文件：

```
payload/
  admin_status/nradio_details.htm   # 设备总览卡片化页面（侦察后生成）
  admin_status/kp_store.htm         # 鲲鹏商店同源承载页
  admin_status/kp_1panel.htm        # 1Panel 同源承载页（动态探测端口）
  admin_status/kp_docker.htm        # Docker 容器承载页
  kp_register.lua                   # CGI 菜单注入补丁体（锚点断言 + marker 幂等）
```

侦察流程：路由器上跑菜单 `7` 拿到 `/tmp/kp-recon-*.tar.gz`，PC 侧分析真实
DOM / 包装器后生成 payload 再回传部署。

## 运行环境

- 鲲鹏 C2000 系列 NROS 固件（OpenWrt 21.02-SNAPSHOT / LuCI git-26.253 / busybox ash）
- 已通过「OpenWrt 原版 LuCI（8080）」组件装好 8080 实例
- 依赖命令：curl 与 wget（双栈下载）、tar、lua、uci、sha256sum（可选）

## 致谢

- [guoguobuku/mt6000-istoreos](https://github.com/guoguobuku/mt6000-istoreos)（wukongdaily 系脚本，Argon 2.2.9.4 版本锁定结论来源）
- [jerrykuku/luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon)
- [linkease/istore](https://github.com/linkease/istore)（iStoreOS）

## License

MIT
