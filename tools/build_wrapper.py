#!/usr/bin/env python
# build_wrapper.py —— 生成注入「服务」菜单后的 CGI 包装器（幂等，带 marker）
# 用法: python build_wrapper.py <原包装器> <服务块lua> <输出文件>
import sys

src_path, block_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path, encoding='utf-8').read()
block = open(block_path, encoding='utf-8').read()

MARK = 'KP-SERVICES-MARKER'
ANCHOR = 'luci.dispatcher.indexcache = "/tmp/luci-indexcache-bootstrap"'

if MARK in src:
    print('已注入过（marker 命中），输出原文')
    open(out_path, 'w', encoding='utf-8', newline='\n').write(src)
    sys.exit(0)

assert src.count(ANCHOR) == 1, 'anchor count = %d (expected 1)' % src.count(ANCHOR)
patched = src.replace(ANCHOR, block.rstrip('\n') + '\n\n' + ANCHOR, 1)
assert MARK in patched
open(out_path, 'w', encoding='utf-8', newline='\n').write(patched)
print('written %s (%d bytes, +%d)' % (out_path, len(patched.encode()), len(patched.encode()) - len(src.encode())))
