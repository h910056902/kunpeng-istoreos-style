#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
鲲鹏 C2000 U —— 「iStoreOS 风格门户」一键安装器 (Windows)

做什么：
  1) 双击运行，弹窗询问路由器地址 / 密码（**不保存任何密码**）
  2) SSH 连上 192.168.66.1（默认），把内置的 portal v3 推上去
  3) 顺带部署自愈守卫 + cron（防 nr_webui 自更新覆写）
  4) 逐项自检并回报结果

设计约束（别改）：
  * 设备**无 base64/od/openssl/xxd** → 二进制只能走 printf 八进制
  * 设备**无 sftp** → 只能 exec_command + 分块写入
  * 大文件要**先 gzip**（14423B → 5273B），否则 SSH 通道会被撑断
  * 密码只存在内存里，落盘文件里一个字符都不留
"""

import base64
import gzip
import os
import sys
import threading
import time
import traceback

APP_TITLE = "鲲鹏 C2000 U · iStoreOS 风格门户安装器"
VERSION = "3.0"

DEFAULT_HOST = "192.168.66.1"
DEFAULT_USER = "root"

PORTAL_MD5 = "9360ce8c9b0421ebb39c11306949861f"
PORTAL_VER = "NRWEBUI_PORTAL=3.0"

PORTAL_DST = "/www/cgi-bin/portal"
MAIN_DST = ("/overlay/nradio-apps/openwrt-luci-8080/usr/lib/lua/luci/"
            "view/quickstart/main.htm")
GUARD_DST = "/usr/bin/kp-portal-guard.sh"
GOLD_DIR = "/root/kp-portal-gold"

# --- 8080 环境恢复（--restore / 界面「恢复 8080」）---
APP8080 = "/overlay/nradio-apps/openwrt-luci-8080"
MENU_D = "/usr/share/luci/menu.d"
RESTORE_CONFIGS = ["/etc/config/uhttpd", "/etc/config/istore",
                   "/etc/config/istorerouter", "/etc/config/kp_portal"]

CHUNK_BYTES = 700   # 每块原始字节数（八进制后 x4 字符，保守值防断流）
MAX_RETRY = 5


# ===========================================================================
#  payload 资源（打包进 exe）
# ===========================================================================
def resource_dir():
    """PyInstaller 单文件模式下资源被解到 _MEIPASS。"""
    if getattr(sys, "frozen", False):
        return getattr(sys, "_MEIPASS", os.path.dirname(sys.executable))
    return os.path.dirname(os.path.abspath(__file__))


def read_payload(name):
    p = os.path.join(resource_dir(), "payload", name)
    with open(p, "rb") as f:
        return f.read()


# ===========================================================================
#  1Panel / LuCI 无关的纯 SSH 文件下发
# ===========================================================================
class Deployer:
    def __init__(self, host, user, pw, log):
        self.host = host
        self.user = user
        self.pw = pw
        self.log = log          # log(str) 回调
        self.cli = None
        self.notes = []         # 自检结果 (name, ok, detail)

    # ---------- 连接 ----------
    def connect(self):
        import paramiko
        self.log("正在连接 %s:22 …" % self.host)
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        c.connect(self.host, 22, self.user, self.pw,
                  timeout=15, banner_timeout=25, auth_timeout=25)
        self.cli = c
        self.log("✓ SSH 已连接")

    def close(self):
        try:
            if self.cli:
                self.cli.close()
        except Exception:
            pass

    def _reconnect(self):
        try:
            if self.cli:
                self.cli.close()
        except Exception:
            pass
        import paramiko
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        c.connect(self.host, 22, self.user, self.pw,
                  timeout=15, banner_timeout=25, auth_timeout=25)
        self.cli = c

    # ---------- 执行 ----------
    def run(self, cmd, timeout=120):
        """执行并返回 stdout+stderr（strip）。"""
        _, o, e = self.cli.exec_command(cmd, timeout=timeout)
        so = o.read().decode("utf-8", "replace")
        se = e.read().decode("utf-8", "replace")
        return (so + se).strip()

    def run_safe(self, cmd, timeout=120, retries=MAX_RETRY):
        """断线自动重连。"""
        last = None
        for i in range(retries):
            try:
                return self.run(cmd, timeout=timeout)
            except Exception as ex:
                last = ex
                self.log("  · 通道异常，重连中 (%d/%d)…" % (i + 1, retries))
                time.sleep(1.5)
                try:
                    self._reconnect()
                except Exception as ex2:
                    last = ex2
        raise last

    # ---------- 二进制下发 ----------
    def push_file(self, data, remote_path, label=""):
        """gzip + printf 八进制分块推进，落地后校验 md5。"""
        import hashlib
        want_md5 = hashlib.md5(data).hexdigest()
        gz = gzip.compress(data, 9)

        self.log("推送 %s（%d B → gz %d B）…" % (label or remote_path,
                                                len(data), len(gz)))
        enc = "".join("\\%03o" % b for b in gz)
        step = CHUNK_BYTES * 4
        chunks = [enc[i:i + step] for i in range(0, len(enc), step)]

        tmpgz = "/tmp/kp-push.gz"
        self.run_safe("rm -f %s" % tmpgz)
        for i, c in enumerate(chunks):
            self.run_safe("printf '%s' >> %s" % (c, tmpgz), timeout=180)
            if (i + 1) % 5 == 0 or i + 1 == len(chunks):
                self.log("  · %d/%d 块" % (i + 1, len(chunks)))

        got_sz = self.run_safe("wc -c < %s" % tmpgz).strip()
        if got_sz != str(len(gz)):
            raise RuntimeError("推送尺寸不符：设备 %s / 本地 %d" % (got_sz, len(gz)))

        self.run_safe("gzip -dc %s > %s.kpnew" % (tmpgz, remote_path))
        got_md5 = self.run_safe("md5sum %s.kpnew | awk '{print $1}'"
                                % remote_path).strip()
        if got_md5 != want_md5:
            raise RuntimeError("md5 不符：%s != %s" % (got_md5, want_md5))

        self.run_safe("mv -f %s.kpnew %s && chmod 755 %s"
                      % (remote_path, remote_path, remote_path))
        self.log("  ✓ %s 已落地（md5 %s）" % (remote_path, got_md5))
        return got_md5

    # ---------- 8080 环境恢复 ----------
    def restore_8080(self, backup_dir):
        """
        把备份目录里的 8080 全量状态推回设备。
        backup_dir 结构（kp-8080-backup.py 产出）：
            app8080/...             → /overlay/nradio-apps/openwrt-luci-8080/...
            app8080.SYMLINKS        → 软链清单
            menu.d/...              → /usr/share/luci/menu.d/...
            config/<name>           → /etc/config/<name>
            MANIFEST.txt            → 校验清单
        """
        import hashlib

        self.backup_dir_ref = backup_dir
        man = os.path.join(backup_dir, "MANIFEST.txt")
        if not os.path.isfile(man):
            raise RuntimeError("备份目录无效：找不到 MANIFEST.txt")

        # 解析清单
        files, links = [], []
        for line in open(man, encoding="utf-8"):
            if line.startswith("#") or not line.strip():
                continue
            p = line.rstrip("\n").split("\t")
            if len(p) != 4:
                continue
            kind, rpath, h, size = p
            if kind == "symlink":
                links.append((rpath, h))
            elif kind == "file":
                files.append((rpath, h, int(size)))

        self.log("")
        self.log("【恢复 1/5】前置检查")
        host = self.run_safe("cat /proc/sys/kernel/hostname 2>/dev/null")
        self.log("  主机名 : %s" % host)
        if not self.run_safe("test -d /overlay/nradio-apps && echo YES"):
            raise RuntimeError("未发现 /overlay/nradio-apps —— 不是鲲鹏 8080 环境")
        self.log("  ✓ 环境 OK（备份含 %d 文件 / %d 软链）"
                 % (len(files), len(links)))

        # 备份设备现状
        self.log("")
        self.log("【恢复 2/5】备份设备现状")
        stamp = self.run_safe("date +%Y%m%d_%H%M%S")
        bak = "/root/kp-8080-restore-bak-%s" % stamp
        self.run_safe("mkdir -p %s" % bak)
        for d, name in [(APP8080, "app8080"), (MENU_D, "menu.d")]:
            self.run_safe("tar -czf %s/%s.tgz -C %s . 2>/dev/null || true"
                          % (bak, name, d))
        for c in RESTORE_CONFIGS:
            self.run_safe("[ -f %s ] && cp -f %s %s/%s.bak 2>/dev/null || true"
                          % (c, c, bak, os.path.basename(c)))
        self.log("  ✓ 现状已备份 → %s" % bak)

        # 映射本地备份文件 → 设备路径
        self.log("")
        self.log("【恢复 3/5】推送文件")
        ok = fail = 0
        plan = []
        for rpath, want_md5, _ in files:
            if rpath.startswith(APP8080 + "/"):
                rel = rpath[len(APP8080) + 1:]
                local = os.path.join(backup_dir, "app8080", rel)
            elif rpath.startswith(MENU_D + "/"):
                rel = rpath[len(MENU_D) + 1:]
                local = os.path.join(backup_dir, "menu.d", rel)
            elif rpath.startswith("/etc/config/"):
                local = os.path.join(backup_dir, "config",
                                     os.path.basename(rpath))
            else:
                continue
            plan.append((local, rpath, want_md5))

        for i, (local, rpath, want_md5) in enumerate(plan, 1):
            if not os.path.isfile(local):
                self.log("  ✗ 本地缺失，跳过 %s" % rpath)
                fail += 1
                continue
            data = open(local, "rb").read()
            # 本地先自校验（防备份本身坏了）
            if hashlib.md5(data).hexdigest() != want_md5:
                self.log("  ✗ 备份文件损坏，跳过 %s" % rpath)
                fail += 1
                continue
            self.run_safe("mkdir -p '%s'" % os.path.dirname(rpath))
            try:
                self.push_file(data, rpath, label="")
                ok += 1
            except Exception as e:
                self.log("  ✗ 推送失败 %s : %s" % (rpath, e))
                fail += 1
            if i % 10 == 0 or i == len(plan):
                self.log("  · %d/%d" % (i, len(plan)))
        self.log("  ✓ 推送完成：成功 %d / 失败 %d" % (ok, fail))

        # 重建软链
        self.log("")
        self.log("【恢复 4/5】重建软链")
        self._restore_symlinks(links, backup_dir)

        # 重启服务
        self.log("")
        self.log("【恢复 5/5】重启服务 + 验收")
        self.run_safe("rm -f /tmp/luci-indexcache; "
                      "rm -rf /tmp/luci-modulecache/*; "
                      "/etc/init.d/uhttpd restart >/dev/null 2>&1; "
                      "sleep 2; echo done")
        self.log("  ✓ uhttpd 已重启")
        self._accept_8080(bak, fail)

    def _restore_symlinks(self, links, backup_dir):
        """按 app8080.SYMLINKS 重建软链（先删后建，目标可能是绝对路径）。"""
        # 优先用备份里落盘的清单（含目标），MANIFEST 里也有
        symfile = os.path.join(backup_dir, "app8080.SYMLINKS")
        pairs = list(links)
        if os.path.isfile(symfile):
            pairs = []
            for line in open(symfile, encoding="utf-8"):
                if "\t" in line:
                    a, b = line.rstrip("\n").split("\t", 1)
                    pairs.append((a.strip(), b.strip()))

        made = 0
        for rel, target in pairs:
            # rel 形如 ./www/luci-static/nradio（相对 APP8080）
            r = rel
            if r.startswith("./"):
                r = r[2:]
            remote = APP8080 + "/" + r
            self.run_safe("mkdir -p '%s'" % os.path.dirname(remote))
            self.run_safe("rm -f '%s'; ln -s '%s' '%s'"
                          % (remote, target, remote))
            made += 1
        self.log("  ✓ 软链 %d 条已重建" % made)

    def _accept_8080(self, bak, push_fail):
        """8080 恢复后的验收。"""
        self.log("")
        self.log("  验收：")
        results = []

        # CGI md5 与备份一致
        man = None
        for line in open(os.path.join(self.backup_dir_ref, "MANIFEST.txt"),
                         encoding="utf-8"):
            if "/www/cgi-bin/luci\t" in line and line.startswith("file"):
                man = line.rstrip("\n").split("\t")[2]
                break
        cur = self.run_safe("md5sum %s/www/cgi-bin/luci | awk '{print $1}'"
                            % APP8080).strip()
        results.append(("8080 CGI md5", bool(man) and cur == man, cur))

        # KP 补丁标记齐全（应 ≥10）
        mk = self.run_safe(
            "grep -oE 'KP-[A-Z0-9-]+( v[0-9]+)?' %s/www/cgi-bin/luci "
            "2>/dev/null | sort -u | wc -l" % APP8080).strip()
        try:
            nk = int(mk)
        except ValueError:
            nk = 0
        results.append(("KP 补丁标记", nk >= 10, "%s 个" % nk))

        # 软链就位
        lk = self.run_safe(
            "ls -l %s/www/luci-static/ | grep -c '^l'" % APP8080).strip()
        try:
            nl = int(lk)
        except ValueError:
            nl = 0
        results.append(("luci-static 软链", nl >= 8, "%s 条" % nl))

        # 8080 监听
        listen = self.run_safe(
            "netstat -ltn 2>/dev/null | grep -c ':8080' || echo 0").strip()
        results.append(("8080 监听", listen not in ("0", ""), listen))

        # 8080 根路径可达
        code = self.run_safe(
            "curl -s -o /dev/null -w '%%{http_code}' http://%s:8080/"
            % self.host).strip()
        results.append(("8080 HTTP 根", code in ("200", "302"), code))

        # 未登录应为 403（登录墙）
        code2 = self.run_safe(
            "curl -s -o /dev/null -w '%%{http_code}' "
            "http://%s:8080/cgi-bin/luci/admin/istorerouter"
            % self.host).strip()
        results.append(("istorerouter 登录墙", code2 == "403", code2))

        for name, good, detail in results:
            self.log("  %s %-24s %s" % ("✓" if good else "✗", name, detail))
            self.notes.append((name, good, detail))

        self.notes.append(("推送失败数", push_fail == 0, str(push_fail)))
        self.log("")
        self.log("  回滚命令（设备上执行）：")
        self.log("    tar -xzf %s/app8080.tgz -C %s" % (bak, APP8080))
        self.log("    tar -xzf %s/menu.d.tgz  -C %s" % (bak, MENU_D))
        self.log("    /etc/init.d/uhttpd restart")

    # ---------- 软件源测试 ----------
    def test_feeds(self, backup_dir=None):
        """
        测设备上的软件源能不能用。三层递进：
          ① 连通性   —— curl 每个源的 Packages.gz，看 HTTP 码 / 大小 / 耗时
          ② 索引     —— `opkg update` 能不能把索引刷下来（这才是 opkg 真用到的）
          ③ 实际下载 —— 随便挑一个有界面的包，`opkg download` 真下下来证明链路通

        ② 是硬指标：①②只能说明 HTTP 通，索引下载失败 opkg 装不了任何东西。
        """
        self.log("")
        self.log("=" * 56)
        self.log("  软件源测试")
        self.log("=" * 56)

        # --- ① 源清单 + 连通性 ---
        self.log("")
        self.log("【1/3】源清单 + 连通性")
        raw = self.run_safe(
            "for f in /etc/opkg/distfeeds.conf /etc/opkg/customfeeds.conf "
            "/etc/opkg/compatfeeds.conf; do "
            "[ -f \"$f\" ] && { cat \"$f\"; echo; }; done")
        feeds = []
        for line in (raw or "").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            p = line.split()
            if len(p) >= 3 and p[0].startswith("src"):
                feeds.append((p[1], p[2]))

        if not feeds:
            self.log("  ✗ 没解析出任何源 —— 检查 /etc/opkg/*feeds.conf")
            self.notes.append(("软件源", False, "0 个"))
            return False

        ok_feeds = 0
        for name, url in feeds:
            probe = url.rstrip("/") + "/Packages.gz"
            out = self.run_safe(
                "curl -s -o /dev/null -w '%s|%s|%s' --max-time 25 '%s' "
                "2>/dev/null"
                % ("%{http_code}", "%{size_download}", "%{time_total}", probe),
                timeout=40).strip()
            parts = out.split("|")
            code = parts[0] if parts else "ERR"
            size = parts[1] if len(parts) > 1 else "?"
            secs = parts[2] if len(parts) > 2 else "?"
            good = code in ("200", "301", "302")
            if good:
                ok_feeds += 1
            try:
                pretty = "%.2f KB" % (int(size) / 1024.0)
            except ValueError:
                pretty = size
            self.log("  %s %-16s %-4s %-10s %ss" % (
                "✓" if good else "✗", name, code, pretty, secs))
        self.log("  → 连通 %d/%d" % (ok_feeds, len(feeds)))
        self.notes.append(("源连通性", ok_feeds == len(feeds),
                           "%d/%d" % (ok_feeds, len(feeds))))

        # --- ② opkg update（硬指标）---
        self.log("")
        self.log("【2/3】opkg update（索引刷新）")
        up = self.run_safe("opkg update 2>&1", timeout=300)
        fails = [l for l in (up or "").splitlines()
                 if ("Failed" in l or "error" in l.lower()
                     or "not found" in l.lower())]
        updated = [l for l in (up or "").splitlines()
                   if "Updated list of available packages" in l]
        for l in updated:
            self.log("  · %s" % l.replace("Updated list of available packages in ", ""))
        for l in fails[:8]:
            self.log("  ✗ %s" % l.strip())
        total = self.run_safe("opkg list 2>/dev/null | wc -l").strip()
        try:
            nt = int(total)
        except ValueError:
            nt = 0
        self.log("  → 索引更新 %d 个源，可用包 %d 个" % (len(updated), nt))
        self.notes.append(("opkg update", len(updated) >= len(feeds) and not fails,
                           "%d 源 / %d 包" % (len(updated), nt)))

        # --- ③ 实际下载一个包 ---
        self.log("")
        self.log("【3/3】实际下载测试")
        # 挑一个体积小、源里一定有的包
        for cand in ("zoneinfo-asia", "terminfo", "lua-md5", "cJSON"):
            got = self.run_safe(
                "cd /tmp && rm -f %s*.ipk && opkg download %s 2>&1 && "
                "ls -l %s*.ipk 2>/dev/null | wc -l" % (cand, cand, cand),
                timeout=180)
            if got and got.strip().endswith("1"):
                sz = self.run_safe(
                    "ls -l /tmp/%s*.ipk 2>/dev/null | awk '{print $5}'"
                    % cand).strip()
                try:
                    pretty = "%.1f KB" % (int(sz.split()[0]) / 1024.0)
                except Exception:
                    pretty = sz
                self.log("  ✓ opkg download %s 成功（%s）" % (cand, pretty))
                self.notes.append(("实际下载", True, "%s %s" % (cand, pretty)))
                self.run_safe("rm -f /tmp/%s*.ipk" % cand)
                break
            self.log("  · %s 下载未成功，换下一个" % cand)
        else:
            self.log("  ✗ 没挑到能下载的包")
            self.notes.append(("实际下载", False, "全部失败"))

        bad = [n for n, o, _ in self.notes if not o]
        self.log("")
        if not bad:
            self.log("  软件源全部可用 ✓")
        else:
            self.log("  有 %d 项未通过：%s" % (len(bad), ", ".join(bad)))
        return not bad

    # ---------- 插件恢复 ----------
    def restore_plugins(self, backup_dir, only=None):
        """
        按备份里的 plugins.txt 把用户后装的插件装回来。

        backup_dir 里的关键文件：
          plugins.names        包名，一行一个（恢复顺序 = 文件顺序）
          plugins.txt          包名 + 版本 + 安装时间（人读）
          feeds.txt            备份时的源清单（用于比对 / 缺源时提示）

        行为：
          1. 先 opkg update（否则 opkg 不知道源里有什么）
          2. 已装的跳过；未装的 `opkg install <名>`
          3. 不装依赖 —— opkg 自己会拉（`--force-depends` 反而容易装坏）
          4. 逐个报结果，最后统计
        """
        import hashlib  # noqa: F401
        self.log("")
        self.log("=" * 56)
        self.log("  插件恢复 ← %s" % backup_dir)
        self.log("=" * 56)

        names_file = os.path.join(backup_dir, "plugins.names")
        if not os.path.isfile(names_file):
            raise RuntimeError(
                "备份目录里没有 plugins.names —— 插件恢复需要它。\n"
                "请用新版 kp-8080-backup.py（会产出 plugins.names / "
                "plugins.txt / feeds.txt）重新备份。")
        with open(names_file, encoding="utf-8") as f:
            want = [l.strip() for l in f if l.strip() and
                    not l.startswith("#")]
        if only:
            only = set(only)
            want = [n for n in want if n in only]
        self.log("  待恢复包：%d 个" % len(want))
        if not want:
            self.notes.append(("插件清单", False, "空"))
            return False

        # --- 1) 刷索引 ---
        self.log("")
        self.log("【1/3】opkg update")
        up = self.run_safe("opkg update 2>&1", timeout=300)
        nup = len([l for l in (up or "").splitlines()
                   if "Updated list of available packages" in l])
        self.log("  → %d 个源已刷新" % nup)
        if nup == 0:
            self.log("  ⚠️ 一个源都没刷成 —— 恢复大概率会失败，先跑「软件源测试」")

        # --- 2) 分区：已装 / 待装 / 源里没有 ---
        self.log("")
        self.log("【2/3】比对现状")
        installed = set()
        cur = self.run_safe("opkg list-installed 2>/dev/null | cut -d' ' -f1")
        for l in (cur or "").splitlines():
            if l.strip():
                installed.add(l.strip())

        todo = [n for n in want if n not in installed]
        skipped = [n for n in want if n in installed]
        self.log("  已装（跳过）  : %d 个" % len(skipped))
        self.log("  待装          : %d 个" % len(todo))

        if not todo:
            self.log("")
            self.log("  所有插件都已就位，无需恢复 ✓")
            self.notes.append(("插件已装齐", True, "%d 个" % len(skipped)))
            return True

        # 源里是否可见（缺源会给一堆 "Unknown package"）
        avail = self.run_safe("opkg list 2>/dev/null | cut -d' ' -f1")
        availset = set(l.strip() for l in (avail or "").splitlines()
                       if l.strip())
        no_feed = [n for n in todo if n not in availset]
        if no_feed:
            self.log("  ⚠️ 源里找不到（会失败）：%d 个 → %s"
                     % (len(no_feed), ", ".join(no_feed[:10])))

        # --- 3) 安装 ---
        self.log("")
        self.log("【3/3】开始安装（%d 个，逐个来）" % len(todo))
        okc = 0
        fail = []
        # 分批：一次性喂太多包名会撑爆 exec 通道（实测 >2KB 命令就哑火）
        BATCH = 8
        for i in range(0, len(todo), BATCH):
            batch = todo[i:i + BATCH]
            self.log("  ── 第 %d-%d / %d 批"
                     % (i + 1, i + len(batch), len(todo)))
            for name in batch:
                out = self.run_safe(
                    "opkg install '%s' 2>&1" % name, timeout=420)
                low = (out or "").lower()
                good = ("unknown package" not in low
                        and "cannot install" not in low
                        and "not found" not in low
                        and ("configuring %s" % name.lower()) in low)
                if not good:
                    # 有些包装完不打 "Configuring"（比如纯元包），
                    # 复核一次是否真的进了已装列表
                    chk = self.run_safe(
                        "opkg list-installed 2>/dev/null | grep -c '^%s '" % name)
                    good = (chk.strip() == "1")
                if good:
                    okc += 1
                    self.log("    ✓ %s" % name)
                else:
                    fail.append(name)
                    reason = [l.strip() for l in (out or "").splitlines()
                              if l.strip()][-1:] or ["(无输出)"]
                    self.log("    ✗ %s — %s" % (name, reason[0][:88]))

        self.log("")
        self.log("  结果：成功 %d / 失败 %d / 跳过 %d"
                 % (okc, len(fail), len(skipped)))
        if fail:
            self.log("  失败清单：%s" % ", ".join(fail))
            with open(os.path.join(backup_dir, "plugins.restore-failed.txt"),
                      "w", encoding="utf-8") as f:
                f.write("# 这些包本次没装回去，可稍后重试\n")
                for n in fail:
                    f.write(n + "\n")
            self.log("  （已写 plugins.restore-failed.txt）")

        self.notes.append(("插件安装", len(fail) == 0,
                           "成功 %d / 失败 %d / 跳过 %d"
                           % (okc, len(fail), len(skipped))))

        # 复核：最终已装数
        final = self.run_safe("opkg list-installed 2>/dev/null | wc -l").strip()
        self.log("  设备当前已装包总数：%s" % final)
        return len(fail) == 0

    # ---------- 主流程 ----------
    def deploy(self):
        portal = read_payload("portal.lua")
        guard = read_payload("kp-portal-guard.sh")

        # --- 环境自检 ---
        self.log("")
        self.log("【1/6】环境自检")
        host = self.run_safe("cat /proc/sys/kernel/hostname 2>/dev/null")
        self.log("  主机名 : %s" % host)
        if not self.run_safe("test -d /overlay/nradio-apps && echo YES"):
            raise RuntimeError("未发现 /overlay/nradio-apps —— 这似乎不是鲲鹏 8080 环境")
        self.log("  ✓ 8080 环境存在")

        luci = self.run_safe(
            "test -f /overlay/nradio-apps/openwrt-luci-8080/www/cgi-bin/luci "
            "&& echo YES")
        self.notes.append(("8080 CGI 存在", bool(luci), luci or "缺失"))

        # --- 备份 ---
        self.log("")
        self.log("【2/6】备份现有文件")
        stamp = self.run_safe("date +%Y%m%d_%H%M%S")
        bak = "/root/kp-bak-%s" % stamp
        self.run_safe(
            "mkdir -p %s; "
            "[ -f %s ] && cp -f %s %s/portal.bak; "
            "[ -f %s ] && cp -f %s %s/main.htm.bak; "
            "ls %s" % (bak, PORTAL_DST, PORTAL_DST, bak,
                       MAIN_DST, MAIN_DST, bak, bak))
        self.log("  ✓ 备份目录 %s" % bak)

        # --- 部署 portal ---
        self.log("")
        self.log("【3/6】部署门户 portal v3")
        md5 = self.push_file(portal, PORTAL_DST, "portal v3")
        self.notes.append(("portal 部署", md5 == PORTAL_MD5,
                           "md5 %s" % md5))

        syn = self.run_safe(
            "lua -e \"local f,e=loadfile('%s'); "
            "print(f and 'OK' or ('FAIL '..tostring(e)))\" 2>&1" % PORTAL_DST)
        self.notes.append(("Lua 语法", syn.startswith("OK"), syn))
        self.log("  Lua 语法：%s" % syn)

        # --- 安装守卫 ---
        self.log("")
        self.log("【4/6】安装自愈守卫")
        self.push_file(guard, GUARD_DST, "kp-portal-guard.sh")
        self.run_safe("mkdir -p %s && cp -f %s %s/portal.v3"
                      % (GOLD_DIR, PORTAL_DST, GOLD_DIR))
        self.run_safe("[ -f %s ] && cp -f %s %s/main.htm"
                      % (MAIN_DST, MAIN_DST, GOLD_DIR))
        self.log("  ✓ 金样本 → %s/portal.v3" % GOLD_DIR)

        cron_line = "* * * * * %s >/dev/null 2>&1" % GUARD_DST
        has = self.run_safe("crontab -l 2>/dev/null | grep -c kp-portal-guard")
        if has.strip() == "0":
            self.run_safe(
                "{ crontab -l 2>/dev/null; echo '%s'; } | crontab -"
                % cron_line)
            self.run_safe("/etc/init.d/cron restart >/dev/null 2>&1 || true")
            self.log("  ✓ cron 已注册（每分钟自愈）")
        else:
            self.log("  ✓ cron 已存在（跳过）")

        g = self.run_safe("%s >/dev/null 2>&1; echo rc=$?" % GUARD_DST)
        self.notes.append(("守卫可执行", "rc=0" in g, g))

        # --- 清缓存重启 ---
        self.log("")
        self.log("【5/6】清缓存 + 重启 uhttpd")
        self.run_safe("rm -f /tmp/luci-indexcache; "
                      "rm -rf /tmp/luci-modulecache/*; "
                      "/etc/init.d/uhttpd restart >/dev/null 2>&1; "
                      "sleep 2; echo done")
        self.log("  ✓ 已重启")

        # --- 验收 ---
        self.log("")
        self.log("【6/6】验收自检")
        self._accept()

    def _accept(self):
        p = PORTAL_DST
        m = self.run_safe("md5sum %s | awk '{print $1}'" % p).strip()
        self.notes.append(("portal md5", m == PORTAL_MD5, m))

        v = self.run_safe("grep -o 'NRWEBUI_PORTAL=[0-9.]*' %s | head -1" % p)
        self.notes.append(("portal 版本", v.strip() == PORTAL_VER, v.strip()))

        code = self.run_safe(
            "curl -s -o /dev/null -w '%%{http_code}' "
            "-H 'Host: %s' http://127.0.0.1/cgi-bin/portal" % self.host).strip()
        self.notes.append(("门户 HTTP 200", code == "200", code))

        ir = self.run_safe(
            "curl -s -H 'Host: %s' http://127.0.0.1/cgi-bin/portal "
            "| grep -o 'http://[^\"]*istorerouter' | head -1" % self.host)
        ok_ir = "istorerouter" in ir
        self.notes.append(("弹层指向 iStoreRouter", ok_ir, ir.strip() or "未找到"))

        qs = self.run_safe(
            "curl -s -H 'Host: %s' http://127.0.0.1/cgi-bin/portal "
            "| grep -o 'http://[^\"]*quickstart/' | head -1" % self.host)
        self.notes.append(("高级设置指向 quickstart",
                           "quickstart" in qs, qs.strip() or "未找到"))

        n = self.run_safe(
            "curl -s -H 'Host: %s' http://127.0.0.1/cgi-bin/portal "
            "| grep -c 'istore os风格化' | head -1" % self.host)
        try:
            ok_n = int(n.strip()) >= 1
        except Exception:
            ok_n = False
        self.notes.append(("istore os风格化 卡片存在", ok_n, n.strip()))

        self.run_safe(
            "curl -s -o /dev/null -c /tmp/kpck "
            "--data 'luci_username=root&luci_password=admin' "
            "http://%s:8080/cgi-bin/luci/admin/status/details" % self.host)
        r8080 = self.run_safe(
            "curl -s -b /tmp/kpck -o /dev/null -w '%%{http_code}' "
            "http://%s:8080/cgi-bin/luci/admin/istorerouter" % self.host).strip()
        self.notes.append(("8080 iStoreRouter 可达", r8080 == "200", r8080))

        for name, ok, detail in self.notes:
            self.log("  %s %-26s %s" % ("✓" if ok else "✗", name, detail))

        bad = [n for n, ok, _ in self.notes if not ok]
        return len(bad) == 0


# ===========================================================================
#  UI
# ===========================================================================
def run_gui():
    import tkinter as tk
    from tkinter import ttk, messagebox, scrolledtext, filedialog

    root = tk.Tk()
    root.title("%s v%s" % (APP_TITLE, VERSION))
    root.geometry("780x620")
    root.minsize(700, 520)

    style = ttk.Style()
    try:
        style.theme_use("vista")
    except Exception:
        pass

    frm = ttk.Frame(root, padding=14)
    frm.pack(fill="both", expand=True)

    ttk.Label(frm, text="路由器地址").grid(row=0, column=0, sticky="w", pady=4)
    e_host = ttk.Entry(frm, width=24)
    e_host.insert(0, DEFAULT_HOST)
    e_host.grid(row=0, column=1, sticky="w", pady=4)

    ttk.Label(frm, text="SSH 用户名").grid(row=0, column=2, sticky="w",
                                          padx=(16, 0), pady=4)
    e_user = ttk.Entry(frm, width=12)
    e_user.insert(0, DEFAULT_USER)
    e_user.grid(row=0, column=3, sticky="w", pady=4)

    ttk.Label(frm, text="密码").grid(row=1, column=0, sticky="w", pady=4)
    e_pw = ttk.Entry(frm, width=24, show="●")
    e_pw.grid(row=1, column=1, sticky="w", pady=4)

    tip = ttk.Label(
        frm, foreground="#666",
        text="密码只在内存中使用，不会写入磁盘、不会保存在 exe 里")
    tip.grid(row=2, column=0, columnspan=4, sticky="w", pady=(0, 8))

    out = scrolledtext.ScrolledText(frm, height=20, wrap="word",
                                    font=("Consolas", 9))
    out.grid(row=4, column=0, columnspan=4, sticky="nsew", pady=(6, 8))
    frm.rowconfigure(4, weight=1)
    frm.columnconfigure(3, weight=1)

    status = ttk.Label(frm, text="就绪", foreground="#297ff3")
    status.grid(row=5, column=0, columnspan=4, sticky="w", pady=(0, 6))

    # ---- 按钮区（两行，避免挤成一条看不清）----
    bar = ttk.Frame(frm)
    bar.grid(row=6, column=0, columnspan=4, sticky="ew")

    btn_restore = ttk.Button(bar, text="恢复 8080 环境", width=16)
    btn_restore.grid(row=0, column=0, sticky="w", padx=(0, 8))

    btn_plug = ttk.Button(bar, text="恢复插件", width=12)
    btn_plug.grid(row=0, column=1, sticky="w", padx=(0, 8))

    btn_feed = ttk.Button(bar, text="测试软件源", width=12)
    btn_feed.grid(row=0, column=2, sticky="w", padx=(0, 8))

    btn = ttk.Button(bar, text="开始安装", width=14)
    btn.grid(row=0, column=3, sticky="e")
    bar.columnconfigure(3, weight=1)

    ALL_BTNS = (btn, btn_restore, btn_plug, btn_feed)

    def log(msg):
        out.insert("end", str(msg) + "\n")
        out.see("end")
        root.update_idletasks()

    done = {"ok": False}

    def _prep():
        """把所有按钮锁上，返回 (host, user, pw) 或 None。"""
        host = e_host.get().strip() or DEFAULT_HOST
        user = e_user.get().strip() or DEFAULT_USER
        pw = e_pw.get()
        if not pw:
            messagebox.showwarning("缺少密码", "请输入路由器 SSH 密码。")
            status.config(text="已取消")
            return None
        for b in ALL_BTNS:
            b.config(state="disabled")
        out.delete("1.0", "end")
        return host, user, pw

    def _unlock():
        for b in ALL_BTNS:
            b.config(state="normal")
        root.update_idletasks()

    def work():
        pre = _prep()
        if not pre:
            return
        host, user, pw = pre
        btn.config(text="安装中…")
        status.config(text="正在安装…", foreground="#297ff3")
        d = Deployer(host, user, pw, log)
        try:
            d.connect()
            d.deploy()
            ok = all(o for _, o, _ in d.notes)
            done["ok"] = ok
            log("")
            if ok:
                log("=" * 56)
                log("  安装完成 —— 全部自检通过")
                log("=" * 56)
                log("  门户入口 : http://%s/cgi-bin/portal" % host)
                log("  ├ istore os风格化 → 弹层内嵌 iStoreRouter")
                log("  └ 高级设置        → %s:8080/…/quickstart/" % host)
                log("")
                log("  自愈守卫已启用：nr_webui 自更新覆写门户后，")
                log("  一分钟内会自动打回 v3。")
                status.config(text="安装成功", foreground="#008236")
            else:
                log("=" * 56)
                log("  安装完成，但有项目未通过（见上方 ✗）")
                log("=" * 56)
                status.config(text="有项目未通过", foreground="#e6a23c")
        except Exception as ex:
            log("")
            log("!!! 失败：%s" % ex)
            log(traceback.format_exc())
            status.config(text="安装失败", foreground="#f56c6c")
        finally:
            d.close()
            btn.config(text="重新安装")
            _unlock()

    def work_restore():
        pre = _prep()
        if not pre:
            return
        host, user, pw = pre
        bdir = filedialog.askdirectory(
            title="选择备份目录（含 MANIFEST.txt，例如 kp-8080-backup-live）")
        if not bdir:
            status.config(text="已取消")
            _unlock()
            return
        btn_restore.config(text="恢复中…")
        status.config(text="正在恢复 8080…", foreground="#297ff3")
        log("=" * 56)
        log("  恢复 8080 环境 ← %s" % bdir)
        log("=" * 56)
        d = Deployer(host, user, pw, log)
        try:
            d.connect()
            d.restore_8080(bdir)
            ok = all(o for _, o, _ in d.notes)
            done["ok"] = ok
            log("")
            if ok:
                log("=" * 56)
                log("  恢复完成 —— 全部自检通过")
                log("=" * 56)
                log("  8080 已回到备份时的状态：")
                log("  %s:8080/cgi-bin/luci/admin/istorerouter" % host)
                status.config(text="恢复成功", foreground="#008236")
            else:
                log("=" * 56)
                log("  恢复完成，但有项目未通过（见上方 ✗）")
                log("=" * 56)
                status.config(text="有项目未通过", foreground="#e6a23c")
        except Exception as ex:
            log("")
            log("!!! 恢复失败：%s" % ex)
            log(traceback.format_exc())
            status.config(text="恢复失败", foreground="#f56c6c")
        finally:
            d.close()
            btn_restore.config(text="恢复 8080 环境")
            _unlock()

    def work_plugins():
        pre = _prep()
        if not pre:
            return
        host, user, pw = pre
        bdir = filedialog.askdirectory(
            title="选择备份目录（含 plugins.names，例如 kp-full-backup）")
        if not bdir:
            status.config(text="已取消")
            _unlock()
            return
        btn_plug.config(text="恢复中…")
        status.config(text="正在恢复插件…", foreground="#297ff3")
        d = Deployer(host, user, pw, log)
        try:
            d.connect()
            d.restore_plugins(bdir)
            ok = all(o for _, o, _ in d.notes)
            done["ok"] = ok
            log("")
            if ok:
                log("=" * 56)
                log("  插件已全部恢复 ✓")
                log("=" * 56)
                status.config(text="插件恢复成功", foreground="#008236")
            else:
                log("=" * 56)
                log("  插件恢复完成，但有失败项（见上方 ✗）")
                log("=" * 56)
                status.config(text="有失败项", foreground="#e6a23c")
        except Exception as ex:
            log("")
            log("!!! 插件恢复失败：%s" % ex)
            log(traceback.format_exc())
            status.config(text="插件恢复失败", foreground="#f56c6c")
        finally:
            d.close()
            btn_plug.config(text="恢复插件")
            _unlock()

    def work_feeds():
        pre = _prep()
        if not pre:
            return
        host, user, pw = pre
        btn_feed.config(text="测试中…")
        status.config(text="正在测试软件源…", foreground="#297ff3")
        d = Deployer(host, user, pw, log)
        try:
            d.connect()
            ok = d.test_feeds()
            done["ok"] = ok
            log("")
            if ok:
                log("=" * 56)
                log("  软件源全部可用 ✓")
                log("=" * 56)
                status.config(text="源可用", foreground="#008236")
            else:
                log("=" * 56)
                log("  有源不可用（见上方 ✗）")
                log("=" * 56)
                status.config(text="有源不可用", foreground="#e6a23c")
        except Exception as ex:
            log("")
            log("!!! 源测试失败：%s" % ex)
            log(traceback.format_exc())
            status.config(text="源测试失败", foreground="#f56c6c")
        finally:
            d.close()
            btn_feed.config(text="测试软件源")
            _unlock()

    def on_click():
        threading.Thread(target=work, daemon=True).start()

    def on_restore():
        threading.Thread(target=work_restore, daemon=True).start()

    def on_plugins():
        threading.Thread(target=work_plugins, daemon=True).start()

    def on_feeds():
        threading.Thread(target=work_feeds, daemon=True).start()

    btn.config(command=on_click)
    btn_restore.config(command=on_restore)
    btn_plug.config(command=on_plugins)
    btn_feed.config(command=on_feeds)
    e_pw.bind("<Return>", lambda _e: on_click())
    e_pw.focus_set()

    log("=" * 56)
    log("  %s v%s" % (APP_TITLE, VERSION))
    log("=" * 56)
    log("  默认目标：%s（SSH root）" % DEFAULT_HOST)
    log("  输入密码后点「开始安装」。")
    log("")
    log("  「恢复 8080 环境」→ 选备份目录（要含 MANIFEST.txt）")
    log("  「恢复插件」      → 选备份目录（要含 plugins.names）")
    log("  「测试软件源」    → 连通性 + opkg update + 实际下载")
    log("")

    root.mainloop()


# ===========================================================================
#  命令行（调试 / 无人值守：从环境变量取密码，绝不进 argv）
# ===========================================================================
def run_cli():
    host = os.environ.get("ROUTER_HOST", DEFAULT_HOST)
    user = os.environ.get("ROUTER_USER", DEFAULT_USER)
    pw = os.environ.get("ROUTER_PW")
    if not pw:
        print("CLI 模式需要环境变量 ROUTER_PW", file=sys.stderr)
        return 2

    # Windows 控制台默认 GBK，打不出 ✓/✗ 这类符号 —— 强制 UTF-8，
    # 失败则退化成 ASCII 标记，绝不能因为日志编码把整个安装搞挂。
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    def log(m):
        s = str(m)
        try:
            print(s)
        except UnicodeEncodeError:
            print(s.encode("ascii", "replace").decode("ascii"))
        except Exception:
            pass

    d = Deployer(host, user, pw, log)
    try:
        d.connect()

        # ---- 恢复模式 ----
        if "--restore-plugins" in sys.argv:
            i = sys.argv.index("--restore-plugins")
            if i + 1 >= len(sys.argv):
                print("--restore-plugins 需要跟一个备份目录", file=sys.stderr)
                return 2
            bdir = sys.argv[i + 1]
            log("=" * 56)
            log("  恢复插件（用户后装包）：%s" % os.path.abspath(bdir))
            log("=" * 56)
            d.restore_plugins(bdir)
        elif "--test-feeds" in sys.argv:
            d.test_feeds()
        elif "--restore" in sys.argv:
            i = sys.argv.index("--restore")
            if i + 1 >= len(sys.argv):
                print("--restore 需要跟一个备份目录", file=sys.stderr)
                return 2
            bdir = sys.argv[i + 1]
            log("=" * 56)
            log("  恢复 8080 环境：%s" % os.path.abspath(bdir))
            log("=" * 56)
            d.restore_8080(bdir)
        else:
            d.deploy()
    except Exception as ex:
        print("FAIL:", ex)
        traceback.print_exc()
        return 1
    finally:
        d.close()
    return 0 if all(o for _, o, _ in d.notes) else 1


def _fatal_no_gui(exc):
    """
    GUI 起不来时的兜底 —— **绝不能静默退出**。
    打包时若宿主 Python 没带 tkinter，PyInstaller 就不会打进去，
    exe 双击后立刻抛 ModuleNotFoundError 然后窗口一闪而过。
    这里把它变成一句能看懂的话：写日志 + 弹原生对话框 + 退到 CLI。
    """
    msg = (
        "图形界面无法启动：%s\n\n"
        "最常见原因：打包环境的 Python 没有 tkinter 模块。\n"
        "解决办法：用自带 tkinter 的 Python 重新打包 ——\n"
        "    python build_exe.py\n"
        "（build_exe.py 会自动检查 tkinter 并拒绝在缺失时打包）\n\n"
        "也可以改用命令行模式：\n"
        "    set ROUTER_PW=你的密码\n"
        "    %s --cli"
    ) % (exc, os.path.basename(sys.executable))

    # 1) 写日志文件（exe 旁边，方便排查）
    try:
        base = os.path.dirname(sys.executable) if getattr(sys, "frozen", False) \
            else os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(base, "kp_installer_error.log"), "w",
                  encoding="utf-8") as f:
            f.write(msg + "\n\n")
            traceback.print_exc(file=f)
    except Exception:
        pass

    # 2) 弹系统原生对话框（不依赖 tkinter）
    try:
        import ctypes
        ctypes.windll.user32.MessageBoxW(
            0, msg, "鲲鹏门户安装器 · 启动失败", 0x10 | 0x1000)
    except Exception:
        pass

    # 3) 控制台也打一份
    try:
        print(msg, file=sys.stderr)
    except Exception:
        pass

    return 3


_HEADLESS_FLAGS = ("--cli", "--restore", "--restore-plugins", "--test-feeds")

if __name__ == "__main__":
    # ⚠️ 这些旗标都必须走无 GUI 的 CLI —— 漏一个就会静默起 GUI：
    #    后台进程活着、0 输出、永不退出，看起来就像"卡死"（踩过）。
    if any(f in sys.argv for f in _HEADLESS_FLAGS):
        sys.exit(run_cli())
    try:
        run_gui()
    except ImportError as _e:
        # 典型：No module named 'tkinter'
        sys.exit(_fatal_no_gui(_e))
    except Exception as _e:
        sys.exit(_fatal_no_gui(_e))
