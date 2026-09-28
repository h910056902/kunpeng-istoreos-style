#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
构建「鲲鹏 C2000 U · iStoreOS 风格门户安装器」exe

用法：
    python build_exe.py

产物：
    dist/鲲鹏门户安装器.exe   （单文件、无控制台、双击即用）
"""

import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
PORTAL_DIR = os.path.join(SKILL, "portal-istoreos")

NAME = "KunpengPortalInstaller"
EXE_CN = "鲲鹏门户安装器.exe"


def log(m):
    print(">>", m)


def sync_payload():
    """把 portal-istoreos 里的权威源同步到 payload/。"""
    pdir = os.path.join(HERE, "payload")
    os.makedirs(pdir, exist_ok=True)
    pairs = [
        (os.path.join(PORTAL_DIR, "payload", "portal.lua"),
         os.path.join(pdir, "portal.lua")),
        (os.path.join(PORTAL_DIR, "kp-portal-guard.sh"),
         os.path.join(pdir, "kp-portal-guard.sh")),
    ]
    for src, dst in pairs:
        if not os.path.isfile(src):
            raise SystemExit("缺少源文件: %s" % src)
        shutil.copyfile(src, dst)
        log("payload ← %s (%d B)" % (os.path.basename(src),
                                     os.path.getsize(dst)))


def main():
    sync_payload()

    sep = ";" if os.name == "nt" else ":"
    args = [
        sys.executable, "-m", "PyInstaller",
        "--noconfirm",
        "--clean",
        "--onefile",
        "--windowed",
        "--name", NAME,
        "--add-data", "payload%s%s" % (sep, "payload"),
        "--hidden-import", "paramiko",
        "--exclude-module", "numpy",
        "--exclude-module", "matplotlib",
        "--exclude-module", "pandas",
        "--exclude-module", "PIL",
        "--exclude-module", "scipy",
        "--exclude-module", "tkinter.test",
        os.path.join(HERE, "kp_portal_installer.py"),
    ]
    log("运行 PyInstaller …")
    r = subprocess.run(args, cwd=HERE)
    if r.returncode != 0:
        raise SystemExit("PyInstaller 失败 (rc=%d)" % r.returncode)

    built = os.path.join(HERE, "dist", NAME + (".exe" if os.name == "nt" else ""))
    if not os.path.isfile(built):
        raise SystemExit("未找到产物: %s" % built)

    final = os.path.join(HERE, "dist", EXE_CN)
    if os.path.abspath(built) != os.path.abspath(final):
        if os.path.exists(final):
            os.remove(final)
        shutil.move(built, final)

    size = os.path.getsize(final) / 1024.0 / 1024.0
    log("✓ 产物: %s (%.1f MB)" % (final, size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
