# 8080 LuCI 实例 —— 一键校验 / 按需修复

鲲鹏 C2000 U（NRadio，OpenWrt 21.02-SNAPSHOT）上那套 **8080 口 LuCI 实例**的
「实现事实」固化件：**功能清单 + 判据表 + 校验修复脚本 + 全量物料**。

> 这套实例不是原厂给的，是二次开发出来的：8080 口有**自己的 dispatcher**、
> **自己的私有 view 目录**、**自己的 luci-static 白名单**，还挂了 3 个跨实例共享控制器。
> 时间一长最容易出的问题就是「**悄悄漂移**」——某个视图被覆盖、软链被删、缓存没清。
> 本目录的作用就是把「应该是什么样」写死成 **77 条判据**，一条命令全查一遍。

---

## 一、设备上一行命令

```sh
cd /tmp && { curl -fsSL --connect-timeout 10 -o kp8080.sh "https://raw.githubusercontent.com/h910056902/kunpeng-istoreos-style/${KP_REF:-main}/8080/install.sh" || wget -q -T 15 -O kp8080.sh "https://raw.githubusercontent.com/h910056902/kunpeng-istoreos-style/${KP_REF:-main}/8080/install.sh"; } && sh kp8080.sh
```

**默认 = 只读全量校验**，不改动设备上任何文件；跑完打印功能清单 + 汇总。
要修复再加 `--fix`。指定其它分支：`KP_REF=<branch> sh kp8080.sh`。

`install.sh` 只是一层薄引导（拉 `kp-8080.sh` + `manifest.tsv` 到 `/tmp/kp8080-boot`，
带体积下界校验与 `sh -n` 语法自检），逻辑全在 `kp-8080.sh` 里。

---

## 二、开关矩阵

| 命令 | 动作 | 是否改设备 |
| --- | --- | --- |
| `sh kp8080.sh` | 只读全量校验 + 功能清单 | ❌ |
| `sh kp8080.sh --fix` | 低风险幂等修复（`gate=auto`）| ✅ 软链/清缓存/uhttpd 开关 |
| `KP_DEPLOY=1 sh kp8080.sh --fix --deploy` | 追加 deploy 级修复 | ✅ 恢复 dispatcher / 私有视图 |
| `KP_DEPLOY=1 KP_DEPLOY_SHARED=1 sh kp8080.sh --fix --controllers` | 追加 shared 级 | ⚠️ 3 个共享控制器，**80 口也用**，影响面最大 |
| `KP_DEPLOY=1 sh kp8080.sh --portal` | 装回 80 口门户 v3（四卡片）| ✅ 覆盖 `/www/cgi-bin/portal` |
| `sh kp8080.sh --backup` | 只做备份到 `/root/kp-8080-bak/<时间戳>` | ✅ 只写备份 |
| `sh kp8080.sh --list` | 列已有备份 | ❌ |
| `ROLLBACK=1 sh kp8080.sh` | 从最近备份回滚 | ✅ |
| `sh kp8080.sh --only M-06` | 只跑某一条判据 | 视该条 gate 而定 |
| `sh kp8080.sh --help` | 用法 | ❌ |

**修复闸门（三级授权，绝不越权）**

| gate | 条数 | 含义 |
| --- | --- | --- |
| `auto` | 28 | `--fix` 即可自动修（幂等、低风险）|
| `deploy` | 39 | 必须 `KP_DEPLOY=1` + `--deploy` |
| `shared` | 3 | 必须再加 `KP_DEPLOY_SHARED=1` + `--controllers`（80 口共用）|
| `manual` | 7 | 脚本不动手，只给提示 |

---

## 三、判据表 `manifest.tsv`

12 列 **TAB** 分隔（`desc` 是最后一列，内部不允许再有 TAB）：

```
id | group | feature | kind | subject | pattern | expect | level | gate | fix | fixarg | desc
```

* `feature` 为空 ⇒ 纯技术判据；**非空**（54 条）⇒ 同时是「8080 已实现功能清单」的一行
  （报告末尾会按 group 分组打印，并标注该项当轮结果）。
* `level` = 不通过时的严重级别：`FAIL` 72 / `WARN` 4 / `INFO` 1。
* `kind`（17 种判定器）：`filehash fileexists dir dircount text_count pair substr symlink
  menu_node http_code http_body static_code uci_get cache_pair loopback_code
  portal_card_count portal_body`。

**分组（77 条）**：`file` 20 / `marker` 16 / `http` 11 / `symlink` 10 / `menu` 6 /
`cfg` 6 / `portal` 4 / `static` 4。

---

## 四、物料 `payload/`

全部**从设备逐字节抄录并 md5 对账**（见 `payload/PROVENANCE.md`）：

| 文件 | 体积 | md5 |
| --- | --- | --- |
| `dispatcher.luci` | 54998 | `db09b091dd4fe21d61920c8b5f25f8d2` |
| `shared-controller/istorerouter.lua` | 4467 | `3081b27df0a8d1ae94d386d3ffce27a5` |
| `shared-controller/quickstart.lua` | 6748 | `1f1b67c62aeb103c81164f12a4523f1e` |
| `shared-controller/systools.lua` | 6101 | `0e699b388529c378b94be718b0cb73e4` |
| `views/**` | 13 个 | 见 `PROVENANCE.md` |
| `luci-static.links` | 10 行 | 9 软链 + 1 实目录（bootstrap）|

`kp-8080.sh` 优先用本地 `payload/`；本地缺失时才按 `KP_RAW_BASE` 从仓库拉
（带体积下界 + md5 校验）。所以**只在真的 `--fix/--deploy` 要落盘时才联网**。

---

## 五、铁律 / 踩过的坑

1. **`SERVER_PORT` 门禁** —— 8080 dispatcher 开头就判断 `SERVER_PORT ~= "8080"` 则回
   `404 Not Found`。**经代理的 PC 浏览器**访问 `:8080` 会命中这条假 404；设备本地
   `curl http://192.168.66.1:8080/...` 才 200。PC 上跑请 `KP_ON_PC=1`（强制 `--noproxy '*'`）。
2. **实例只绑 LAN** —— `uhttpd.openwrt8080.listen_http` = `192.168.66.1:8080`，
   **没有 0.0.0.0、也没有 127.0.0.1**。探活用 `127.0.0.1:8080` 恒为 `000`（假阴性）。
3. **模板报错被 HTTP 200 包着** —— LuCI 编译视图失败时错误会**内联进正文**，
   状态码照样 200。所以必须 `grep` 正文（`http_body` 类判据），不能只看状态码。
4. **改 dispatcher 只需清 indexcache** —— `luci.dispatcher.indexcache = "/tmp/luci-indexcache-bootstrap"`。
   清 `/tmp/luci-indexcache*` 即可，**不要重启 uhttpd**（会扰动 80 口门户）。
5. **`BEGIN`→`END` 派生锚点必须锚定行尾** —— `KP-QUICKSTART-*` 里 `QUICKSTART` 含子串
   `START`，用 `s/BEGIN/END/;s/START/END/` 会把 `KP-QUICKSTART-PATCH` 改成
   `KP-QUICK-END-PATCH`，导致 4 个族的 close 计数恒为 0（假阴性）。故先摘掉尾部 `$`
   再用 `BEGIN$` / `START$` 锚定。
6. **`set -u` 但绝不 `set -e`** —— `grep -c` 无命中返回 1，`-e` 会把整个脚本误杀；
   一切判定读**输出值**，不读返回码。
7. **落盘必须原子** —— 同目录临时名 + `mv` 替换，**严禁 `cp src dst`**（就地截断，
   断电/断连即半截文件）。
8. **busybox `read` 的 IFS 会折叠空字段** —— 判据表里有空 `feature`/`desc`，
   直接 `IFS='\t' read` 会把列错位；所以先经 `awk` 把所有空字段补成 `-`（`normalize_manifest`）。
9. **`*.luci` 必须 `text eol=lf`** —— 本仓库 `core.autocrlf=true`，若 `.gitattributes`
   漏了这条，checkout 会把 54998 B 的 dispatcher 变成 CRLF 的 56465 B，md5 校验必失败。
10. **无 SFTP** —— 官方精简固件没有 `sftp-server` 子系统，只能
    `exec_command` + heredoc / `printf '\NNN'` 传文件，并用 md5 对账。

---

## 六、实测记录

见 [`TESTLOG.md`](./TESTLOG.md)（真机跑出的逐条结果）。
