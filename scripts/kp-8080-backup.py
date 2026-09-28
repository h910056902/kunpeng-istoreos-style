#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
kp-8080-backup.py —— 备份鲲鹏 C2000 U 的 8080 LuCI 完整状态

备份内容（这是让 8080 能"原样复活"的最小充分集）：
  1. 8080 docroot 全量树   /overlay/nradio-apps/openwrt-luci-8080/   （68 文件 / 1.3 MB）
       · www/cgi-bin/luci            ← 带 10 处 KP-* 补丁的 CGI
       · www/luci-static/**          ← bootstrap/argon 主题 + 资源
       · usr/lib/lua/luci/view/**    ← 私有视图（quickstart/nradio/ttyd/themes）
       · 所有软链（nradio/resources/istore/istorerouter/quickstart/iform/…）
  2. menu.d 注册表           /usr/share/luci/menu.d/*.json
  3. 相关 UCI 配置           uhttpd（main + openwrt8080 两实例）
                             istore / istorerouter / kp_portal
  4. 已装插件清单            opkg list-installed（628 个包的全量快照）
  5. 清单文件                MANIFEST.txt（每个文件的 md5 + 权限 + 软链目标）

用法：
    ROUTER_PW=密码 python kp-8080-backup.py                 # 默认输出到 ./kp-8080-backup-<时间戳>/
    ROUTER_PW=密码 python kp-8080-backup.py --out DIR
    ROUTER_PW=密码 python kp-8080-backup.py --tar           # 额外打一个 .tar.gz
"""

import argparse
import base64
import hashlib
import os
import posixpath
import sys
import tarfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rtr_lib import Rtr  # noqa: E402

APP8080 = "/overlay/nradio-apps/openwrt-luci-8080"
MENU_D = "/usr/share/luci/menu.d"
CONFIGS = [
    "/etc/config/uhttpd",       # 两个实例：main(80) + openwrt8080
    "/etc/config/istore",
    "/etc/config/istorerouter",
    "/etc/config/kp_portal",
    "/etc/config/quickstart",
]

# 厂商预装包的 Installed-Time 基准（本机实测 1747797524 = 2025-05-21 11:18:44）
# 493 个 rom 层包共用这一个时间戳；之后装的都是用户包。
# 运行时仍会动态探测（取出现次数最多的那个值），不硬依赖这个常量。
FW_EPOCH_FALLBACK = 1747797524
PKG_TIMEOUT_EPOCH = 1750000000   # > 此值一律视为用户后装

# 软件源配置文件
FEED_FILES = [
    "/etc/opkg/distfeeds.conf",
    "/etc/opkg/customfeeds.conf",
    "/etc/opkg/compatfeeds.conf",
]


# ---------------------------------------------------------------------------
#  低层：从设备取文件的可靠通道
# ---------------------------------------------------------------------------
#  设备**没有 base64 / od / openssl / xxd**，但有 uuencode? 不确定。
#  最稳的是 **gzip + 十六进制**：gzip 一定有（opkg/busybox 都带），
#  hexdump -v -e '1/1 "%02x"' 输出纯 hex 流，本地解回来。
#  （不用 hexdump -C：它的 `*` 重复行压缩会少字节 —— 踩过。）
# ---------------------------------------------------------------------------
HEXDUMP_FMT = "'1/1 \"%02x\"'"


class Backup:
    def __init__(self, router, outdir, log):
        self.r = router
        self.out = outdir
        self.log = log
        self.manifest = []      # (kind, path, md5_or_target, mode)
        self.failed = []

    # ---------------- 工具 ----------------
    def sh(self, cmd, t=180):
        # rtr_lib.Rtr 的接口是 safe()（带断线重连），不是 run_safe()
        try:
            return self.r.safe(cmd, t=t)
        except TypeError:
            return self.r.safe(cmd, timeout=t)

    def fetch_file(self, remote, local):
        """把设备上的一个文件原样取回本地（走 gzip+hex）。"""
        tmpgz = "/tmp/kp-bk.$$.gz"
        # 用 gzip -c 压到 stdout，再 hexdump 成纯 hex
        cmd = ("gzip -c '%s' 2>/dev/null | hexdump -v -e %s"
               % (remote, HEXDUMP_FMT))
        try:
            out = self.sh(cmd, t=180)
        except Exception as e:
            self.failed.append((remote, "fetch: %s" % e))
            return False
        hexs = "".join(out.split())
        if not hexs:
            self.failed.append((remote, "空内容"))
            return False
        try:
            gz = bytes.fromhex(hexs)
        except ValueError as e:
            self.failed.append((remote, "hex 解析失败: %s" % e))
            return False
        import gzip as _gzip
        try:
            data = _gzip.decompress(gz)
        except Exception:
            # 可能设备 gzip 不可用 → 退化成直接把原文 hexdump（无压缩）
            cmd2 = ("hexdump -v -e %s '%s'" % (HEXDUMP_FMT, remote))
            out2 = self.sh(cmd2, t=180)
            h2 = "".join(out2.split())
            if not h2:
                self.failed.append((remote, "gzip 与裸 hexdump 都失败"))
                return False
            try:
                data = bytes.fromhex(h2)
            except ValueError as e:
                self.failed.append((remote, "裸 hex 解析失败: %s" % e))
                return False

        os.makedirs(os.path.dirname(local), exist_ok=True)
        with open(local, "wb") as f:
            f.write(data)
        md5 = hashlib.md5(data).hexdigest()
        self.manifest.append(("file", remote, md5, len(data)))
        return True

    # ---------------- 主流程 ----------------
    def run(self):
        self.log("== [1/6] 备份 8080 docroot 全量 ==")
        self._backup_tree()

        self.log("")
        self.log("== [2/6] 备份 menu.d 注册表 ==")
        self._backup_menud()

        self.log("")
        self.log("== [3/6] 备份 UCI 配置 ==")
        self._backup_configs()

        self.log("")
        self.log("== [4/6] 备份插件清单（可恢复）==")
        self._backup_plugins()

        self.log("")
        self.log("== [5/6] 备份软件源配置 ==")
        self._backup_feeds()

        self.log("")
        self.log("== [6/6] 写清单 ==")
        self._write_manifest()

    # ---------------- 步骤 ----------------
    def _backup_tree(self):
        """递归列出 + 回抽 8080 全量文件（含软链记录）。"""
        # 1) 文件清单（相对路径）
        files = self.sh("cd %s && find . -type f | sort" % APP8080)
        flist = [l.strip() for l in files.splitlines() if l.strip().startswith("./")]
        self.log("  发现 %d 个文件" % len(flist))

        # 2) 软链清单（相对路径 -> 目标）
        links = self.sh("cd %s && find . -type l | sort | while read p; do "
                        "printf '%%s\\t%%s\\n' \"$p\" \"$(readlink \"$p\")\"; done"
                        % APP8080)
        llist = []
        for line in links.splitlines():
            if "\t" in line:
                p, t = line.split("\t", 1)
                llist.append((p.strip(), t.strip()))
        self.log("  发现 %d 个软链" % len(llist))

        # 3) 回抽每个文件
        ok = 0
        for i, rel in enumerate(flist, 1):
            remote = posixpath.normpath(posixpath.join(APP8080, rel))
            local = os.path.join(self.out, "app8080", rel.lstrip("./"))
            if self.fetch_file(remote, local):
                ok += 1
            if i % 10 == 0 or i == len(flist):
                self.log("    %d/%d" % (i, len(flist)))
        self.log("  ✓ 回抽成功 %d/%d" % (ok, len(flist)))

        # 4) 记录软链
        for rel, target in llist:
            self.manifest.append(("symlink", rel, target, 0))
        with open(os.path.join(self.out, "app8080.SYMLINKS"), "w",
                  encoding="utf-8") as f:
            for rel, target in llist:
                f.write("%s\t%s\n" % (rel, target))
        self.log("  ✓ 软链清单已存 app8080.SYMLINKS")

    def _backup_menud(self):
        out = self.sh("cd %s && find . -type f -name '*.json' | sort" % MENU_D)
        for rel in [l.strip().lstrip("./") for l in out.splitlines()
                    if l.strip().endswith(".json")]:
            remote = posixpath.join(MENU_D, rel)
            local = os.path.join(self.out, "menu.d", rel)
            if self.fetch_file(remote, local):
                self.log("  ✓ menu.d/%s" % rel)

    def _backup_configs(self):
        for c in CONFIGS:
            if not self.sh("test -f '%s' && echo YES" % c):
                self.log("  · 跳过（不存在）%s" % c)
                continue
            local = os.path.join(self.out, "config", os.path.basename(c))
            if self.fetch_file(c, local):
                self.log("  ✓ %s" % c)
        # uci show 全量（含未落盘的默认值，便于比对）
        for sec in ["uhttpd", "istore", "istorerouter", "kp_portal"]:
            txt = self.sh("uci show %s 2>/dev/null" % sec)
            if txt:
                p = os.path.join(self.out, "config", "%s.ucishow.txt" % sec)
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, "w", encoding="utf-8") as f:
                    f.write(txt + "\n")
                self.log("  ✓ %s.ucishow.txt" % sec)

    def _detect_fw_epoch(self):
        """动态探测厂商预装包的 Installed-Time 基准（取出现最多的值）。"""
        out = self.sh("awk '/^Installed-Time:/{print $2}' /usr/lib/opkg/status "
                      "| sort | uniq -c | sort -rn | head -1", t=60)
        parts = (out or "").split()
        if len(parts) >= 2 and parts[1].isdigit():
            return int(parts[1])
        return FW_EPOCH_FALLBACK

    def _backup_plugins(self):
        """
        抓「用户后装的包」清单 —— 这是插件恢复的唯一依据。

        ⚠️ 判据用 Installed-Time，**不用 Status**：
           本机 Status 有三种值，`install user installed` 有 291 个，
           但它把 busybox / kernel / dnsmasq 这些固件包也算进去了，
           拿它当"用户装的"会多恢复 157 个不该动的包。
           而 493 个厂商包共用同一个 Installed-Time，一目了然。
        """
        # 全量快照（人读 + 兜底）
        txt = self.sh("opkg list-installed 2>/dev/null")
        with open(os.path.join(self.out, "opkg-list-installed.txt"), "w",
                  encoding="utf-8") as f:
            f.write(txt + "\n")
        total = len([l for l in txt.splitlines() if l.strip()])

        fw = self._detect_fw_epoch()
        self.log("  · 已装包 %d 个；厂商基准 Installed-Time = %d" % (total, fw))

        # 用户后装包：包名 + 版本 + 安装时间
        raw = self.sh(
            "awk '/^Package:/{p=$2} /^Version:/{v=$2} "
            "/^Installed-Time:/{if($2>%d) print p\"\\t\"v\"\\t\"$2}' "
            "/usr/lib/opkg/status | sort" % PKG_TIMEOUT_EPOCH, t=90)

        pkgs = []
        for line in (raw or "").splitlines():
            parts = line.split("\t")
            if len(parts) >= 3 and parts[0].strip():
                pkgs.append((parts[0].strip(), parts[1].strip(),
                             parts[2].strip()))

        p = os.path.join(self.out, "plugins.txt")
        with open(p, "w", encoding="utf-8") as f:
            f.write("# 鲲鹏 C2000 U · 用户后装插件清单\n")
            f.write("# 时间: %s\n" % time.strftime("%Y-%m-%d %H:%M:%S"))
            f.write("# 主机: %s\n" % self.r.host)
            f.write("# 判据: Installed-Time > %d（厂商基准 %d）\n"
                    % (PKG_TIMEOUT_EPOCH, fw))
            f.write("# 格式: <包名>\\t<版本>\\t<安装时间>\n")
            f.write("#\n")
            for name, ver, ts in pkgs:
                f.write("%s\t%s\t%s\n" % (name, ver, ts))
        self.log("  ✓ 用户后装包 %d 个 → plugins.txt" % len(pkgs))

        # 精简版：只有包名，一行一个 —— 给恢复流程直接消费
        p2 = os.path.join(self.out, "plugins.names")
        with open(p2, "w", encoding="utf-8") as f:
            for name, _, _ in pkgs:
                f.write(name + "\n")
        self.log("  ✓ 包名列表 → plugins.names")

        # 每组包在源里能不能找到（决定恢复是否要联网 / 是否需要离线 ipk）
        #
        # ⚠️ 两个坑：
        #  ① **不能把 134 个包名拼进命令行**（`for p in 'a' 'b' …`）——
        #     命令长约 2KB 时 dropbear 那条通道会静默失败，结果集为空但不报错。
        #     正确做法：让设备自己从 status 读，写进 /tmp 再用 awk 做集合运算。
        #  ② **设备没有 `comm`**（busybox 未编入）→ 用 awk 两文件法代替。
        if pkgs:
            out = self.sh(
                "awk '/^Package:/{p=$2} /^Installed-Time:/{"
                "if($2>%d) print p}' /usr/lib/opkg/status | sort -u "
                "> /tmp/kp-bk-user.txt; "
                "opkg list 2>/dev/null | cut -d' ' -f1 | sort -u "
                "> /tmp/kp-bk-feed.txt; "
                "awk 'NR==FNR{f[$1]=1;next} ($1 in f){print $1}' "
                "/tmp/kp-bk-feed.txt /tmp/kp-bk-user.txt > /tmp/kp-bk-feed.txt2; "
                "awk 'NR==FNR{f[$1]=1;next} !($1 in f){print $1}' "
                "/tmp/kp-bk-feed.txt /tmp/kp-bk-user.txt > /tmp/kp-bk-local.txt; "
                "echo 'FEEDN='$(wc -l < /tmp/kp-bk-feed.txt2); "
                "echo 'LOCALN='$(wc -l < /tmp/kp-bk-local.txt)"
                % PKG_TIMEOUT_EPOCH, t=300)
            feed, local = [], []
            for line in (out or "").splitlines():
                line = line.strip()
                if line.startswith("FEEDN="):
                    n_feed = line[6:]
                elif line.startswith("LOCALN="):
                    n_local = line[7:]
            feed = [l.strip() for l in
                    self.sh("cat /tmp/kp-bk-feed.txt2", t=30).splitlines()
                    if l.strip()]
            local = [l.strip() for l in
                     self.sh("cat /tmp/kp-bk-local.txt", t=30).splitlines()
                     if l.strip()]

            with open(os.path.join(self.out, "plugins.feed-status.txt"), "w",
                      encoding="utf-8") as f:
                f.write("# 源里可装（opkg install 能恢复）：%d 个\n" % len(feed))
                for n in feed:
                    f.write("FEED\t%s\n" % n)
                f.write("\n# 源里找不到（需要离线 ipk 才能恢复）：%d 个\n"
                        % len(local))
                for n in local:
                    f.write("LOCAL\t%s\n" % n)
            self.log("  ✓ 源里可装 %d 个 / 源里没有 %d 个 → plugins.feed-status.txt"
                     % (len(feed), len(local)))
            if local:
                self.log("    ⚠️ 源里没有的：%s" % ", ".join(local[:12]))

        # KP 补丁标记清单（关键：证明 CGI 是打过补丁的那版）
        markers = self.sh(
            "grep -oE 'KP-[A-Z0-9-]+( v[0-9]+)?' "
            "%s/www/cgi-bin/luci 2>/dev/null | sort -u" % APP8080)
        with open(os.path.join(self.out, "KP-MARKERS.txt"), "w",
                  encoding="utf-8") as f:
            f.write(markers + "\n")
        self.log("  ✓ KP 补丁标记 %d 个 → KP-MARKERS.txt"
                 % len([l for l in markers.splitlines() if l.strip()]))

    def _backup_feeds(self):
        """备份软件源配置（恢复时按它重建源，或者在别的设备上复现）。"""
        got = 0
        for c in FEED_FILES:
            if not self.sh("test -f '%s' && echo YES" % c, t=30):
                continue
            local = os.path.join(self.out, "feeds", os.path.basename(c))
            if self.fetch_file(c, local):
                got += 1
                self.log("  ✓ %s" % c)

        # 解析出源清单（名称 + URL + 类型），并测连通性
        #
        # ⚠️ 必须**逐文件 cat 并补换行**：这些 feeds.conf 末尾普遍没有换行，
        #    直接 `cat /etc/opkg/*feeds.conf` 会把上一个文件的最后一行和下一
        #    个文件的第一行粘成一行（实测 `…/compat` + `# add your custom…`
        #    → `…/compat# add your…`，URL 尾部多一个 `#`，误判成合法源）。
        lines = self.sh(
            "for f in /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf "
            "/etc/opkg/compatfeeds.conf; do "
            "[ -f \"$f\" ] && { cat \"$f\"; echo; }; done", t=30)
        feeds = []
        for line in (lines or "").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 3 and parts[0].startswith("src"):
                feeds.append((parts[1], parts[2], parts[0]))

        p = os.path.join(self.out, "feeds.txt")
        with open(p, "w", encoding="utf-8") as f:
            f.write("# 鲲鹏 C2000 U · 软件源清单\n")
            f.write("# 时间: %s\n" % time.strftime("%Y-%m-%d %H:%M:%S"))
            f.write("# 格式: <名称>\\t<类型>\\t<URL>\n")
            f.write("#\n")
            for name, url, kind in feeds:
                f.write("%s\t%s\t%s\n" % (name, kind, url))
        self.log("  ✓ 软件源 %d 个 → feeds.txt" % len(feeds))
        for name, url, _ in feeds:
            self.log("    · %s → %s" % (name, url))

        # 顺手测一遍连通性（不阻塞备份）
        self.log("  · 源连通性（HTTP 状态 | 大小 | 耗时）")
        for name, url, _ in feeds:
            probe = url.rstrip("/") + "/Packages.gz"
            out = self.sh(
                "curl -s -o /dev/null -w '%s|%s|%s' --max-time 20 '%s' 2>/dev/null"
                % ("%{http_code}", "%{size_download}", "%{time_total}", probe),
                t=40)
            self.log("    %-16s %s" % (name, (out or "FAIL").strip()))

    def _write_manifest(self):
        p = os.path.join(self.out, "MANIFEST.txt")
        with open(p, "w", encoding="utf-8") as f:
            f.write("# 鲲鹏 8080 LuCI 状态备份清单\n")
            f.write("# 时间: %s\n" % time.strftime("%Y-%m-%d %H:%M:%S"))
            f.write("# 主机: %s\n" % self.r.host)
            f.write("# 格式: <kind>\\t<path>\\t<md5|symlink_target>\\t<size>\n")
            f.write("#\n")
            for kind, path, h, size in self.manifest:
                f.write("%s\t%s\t%s\t%s\n" % (kind, path, h, size))
            if self.failed:
                f.write("\n# ⚠️ 失败项\n")
                for path, why in self.failed:
                    f.write("# FAIL %s : %s\n" % (path, why))
        self.log("  ✓ MANIFEST.txt（%d 条）" % len(self.manifest))
        if self.failed:
            self.log("  ⚠️ 有 %d 项失败（见 MANIFEST.txt 尾部）" % len(self.failed))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    ap.add_argument("--tar", action="store_true", help="额外打包 .tar.gz")
    ap.add_argument("--host", default=None)
    a = ap.parse_args()

    stamp = time.strftime("%Y%m%d_%H%M%S")
    out = a.out or ("kp-8080-backup-%s" % stamp)
    os.makedirs(out, exist_ok=True)

    def log(m):
        print(m)
        sys.stdout.flush()

    log("=" * 60)
    log("  鲲鹏 C2000 U · 8080 LuCI 状态备份")
    log("=" * 60)
    log("  输出目录 : %s" % os.path.abspath(out))
    log("")

    r = Rtr(host=a.host) if a.host else Rtr()
    log("  已连接 %s" % r.host)
    log("")

    b = Backup(r, out, log)
    try:
        b.run()
    finally:
        r.close()

    if a.tar:
        tarp = out.rstrip("/\\") + ".tar.gz"
        with tarfile.open(tarp, "w:gz") as tf:
            tf.add(out, arcname=os.path.basename(out))
        log("")
        log("  ✓ 已打包 %s (%.1f KB)"
            % (tarp, os.path.getsize(tarp) / 1024.0))

    log("")
    log("=" * 60)
    log("  备份完成：%d 个文件%s"
        % (len([m for m in b.manifest if m[0] == "file"]),
           "，%d 项失败" % len(b.failed) if b.failed else "，无失败"))
    log("=" * 60)
    return 1 if b.failed else 0


if __name__ == "__main__":
    sys.exit(main())
