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
        self.log("== [1/5] 备份 8080 docroot 全量 ==")
        self._backup_tree()

        self.log("")
        self.log("== [2/5] 备份 menu.d 注册表 ==")
        self._backup_menud()

        self.log("")
        self.log("== [3/5] 备份 UCI 配置 ==")
        self._backup_configs()

        self.log("")
        self.log("== [4/5] 备份插件清单 ==")
        self._backup_opkg()

        self.log("")
        self.log("== [5/5] 写清单 ==")
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

    def _backup_opkg(self):
        txt = self.sh("opkg list-installed 2>/dev/null")
        p = os.path.join(self.out, "opkg-list-installed.txt")
        with open(p, "w", encoding="utf-8") as f:
            f.write(txt + "\n")
        n = len([l for l in txt.splitlines() if l.strip()])
        self.log("  ✓ 已装插件 %d 个 → opkg-list-installed.txt" % n)

        # KP 补丁标记清单（关键：证明 CGI 是打过补丁的那版）
        markers = self.sh(
            "grep -oE 'KP-[A-Z0-9-]+( v[0-9]+)?' "
            "%s/www/cgi-bin/luci 2>/dev/null | sort -u" % APP8080)
        p2 = os.path.join(self.out, "KP-MARKERS.txt")
        with open(p2, "w", encoding="utf-8") as f:
            f.write(markers + "\n")
        self.log("  ✓ KP 补丁标记 %d 个 → KP-MARKERS.txt"
                 % len([l for l in markers.splitlines() if l.strip()]))

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
