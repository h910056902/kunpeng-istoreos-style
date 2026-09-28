#!/bin/sh
# 离线验证：manifest 字段对齐 + 文件类判据（用本地 payload 副本）
# 目的：在碰真机前抓出「空字段被折叠导致错位」这类解析 bug
set -u
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
MAN="$REPO_DIR/manifest.tsv"
PAY="$REPO_DIR/payload"
FAKE="/tmp/kp8080fake"
TAB="$(printf '\t')"

echo "=== 1. 原始文件：空字段统计 ==="
awk -F'\t' '
	/^[[:space:]]*#/ { next } NF < 12 { next }
	{ n++; for (i=1;i<=12;i++) if ($i=="") e[i]++ }
	END { printf "总行数=%d\n", n
	      for (i=1;i<=12;i++) if (e[i]+0 > 0) printf "  第%d列空值 %d 处\n", i, e[i]+0 }
' "$MAN"

echo
echo "=== 2. normalize 后（空→'-'）逐行列数 ==="
awk -F'\t' '
	/^[[:space:]]*#/ { next } NF < 12 { next }
	{ for (i=1;i<=12;i++) if ($i=="") $i="-"
	  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12 }
' "$MAN" > /tmp/kpnorm.tsv
awk -F'\t' 'NF!=12{bad++; printf "  BAD(%d列): %.110s\n", NF, $0} END{printf "  总行=%d  列数异常=%d\n", NR, bad+0}' /tmp/kpnorm.tsv

echo
echo "=== 3. sh read 后字段是否仍对齐（关键！）==="
n=0
while IFS="$TAB" read -r id group feature kind subject pattern expect level gate fix fixarg desc; do
	n=$((n+1))
	case "$n" in
		1|2|3|15|16|77)
			printf 'row%-3s id=[%s] grp=[%s] feat=[%s] kind=[%s]\n             pat=[%s]\n             exp=[%s] lvl=[%s] gate=[%s] fix=[%s] fixarg=[%s]\n             desc=[%s]\n' \
				"$n" "$id" "$group" "$feature" "$kind" "$pattern" "$expect" "$level" "$gate" "$fix" "$fixarg" "$desc"
			;;
	esac
done < /tmp/kpnorm.tsv
echo "  read 循环读到: $n 行"

echo
echo "=== 4. 关键行完整性断言 ==="
grep -q "^D-01${TAB}file${TAB}8080 CGI 包装器（dispatcher）${TAB}filehash${TAB}/overlay/nradio-apps/openwrt-luci-8080/www/cgi-bin/luci${TAB}-${TAB}54998:db09b091dd4fe21d61920c8b5f25f8d2${TAB}FAIL${TAB}deploy${TAB}deploy${TAB}disp${TAB}" /tmp/kpnorm.tsv \
	&& echo "  [OK] D-01 字段完全对齐（含空 pattern 位）" || echo "  [NG] D-01 错位"
grep -q "^M-16${TAB}marker${TAB}进程页 TOP 垫片${TAB}substr${TAB}" /tmp/kpnorm.tsv \
	&& echo "  [OK] M-16 字段对齐" || echo "  [NG] M-16 错位"

echo
echo "=== 5. 文件类判据实测（本地 payload 副本）==="
echo "-- dispatcher 指纹 --"
printf '  expect 54998:db09b091dd4fe21d61920c8b5f25f8d2\n'
printf '  actual %s:%s\n' "$(wc -c < "$PAY/dispatcher.luci" | tr -d ' ')" "$(md5sum "$PAY/dispatcher.luci" | awk '{print $1}')"

echo "-- pair 型（由 BEGIN→END / START→END 派生）--"
DISP="$PAY/dispatcher.luci"

# 从主脚本抽出 derive_end_anchor，保证测的就是线上那套逻辑
derive_end_anchor() {
	_a="$1"; _tail=''
	case "$_a" in
		*'$') _tail='$'; _a="${_a%?}" ;;
	esac
	_e="$(printf '%s' "$_a" | sed 's/BEGIN$/END/')"
	[ "$_e" = "$_a" ] && _e="$(printf '%s' "$_a" | sed 's/START$/END/')"
	printf '%s%s' "$_e" "$_tail"
}
# 与主脚本一致性自检
if grep -q 'derive_end_anchor' "$REPO_DIR/kp-8080.sh"; then
	echo "  [OK] 主脚本含 derive_end_anchor（已同步修复）"
else
	echo "  [NG] 主脚本不含 derive_end_anchor！"
fi

pair_check() {
	_o="$1"
	_e="$(derive_end_anchor "$_o")"
	_no=$(grep -cE -- "$_o" "$DISP" 2>/dev/null); [ -z "$_no" ] && _no=0
	_ne=$(grep -cE -- "$_e" "$DISP" 2>/dev/null); [ -z "$_ne" ] && _ne=0
	_ok='NG'; [ "$_no" = 1 ] && [ "$_ne" = 1 ] && _ok='OK'
	printf '  [%s] open=%s close=%s  %s\n     END锚点=%s\n' "$_ok" "$_no" "$_ne" "$2" "$_e"
}
pair_check '^[[:space:]]*-- KP-TTYD-VIEW-MARKER-BEGIN$' 'KP-TTYD-VIEW-MARKER (sfx)'
pair_check '^[[:space:]]*-- KP-CELLULAR-MENU-BEGIN$' 'KP-CELLULAR-MENU (sfx)'
pair_check '^[[:space:]]*-- KP-QUICKSTART-MENU-BEGIN$' 'KP-QUICKSTART-MENU (sfx)'
pair_check '^[[:space:]]*-- KP-ISTOREROUTER-MENU v[0-9]+ BEGIN$' 'KP-ISTOREROUTER-MENU (vN)'
pair_check '^[[:space:]]*-- KP-NAS-PARENT-CGI v[0-9]+ BEGIN$' 'KP-NAS-PARENT-CGI (vN)'
pair_check '^[[:space:]]*-- KP-CELLULAR-ENDPOINT v[0-9]+ START' 'KP-CELLULAR-ENDPOINT (START)'
pair_check '^[[:space:]]*-- KP-QUICKSTART-PATCH v[0-9]+ START' 'KP-QUICKSTART-PATCH (START)'
pair_check '^[[:space:]]*-- KP-QUICKSTART-PROXY v[0-9]+ START' 'KP-QUICKSTART-PROXY (START)'
pair_check '^[[:space:]]*-- KP-QUICKSTART-VIEWNS v[0-9]+ START' 'KP-QUICKSTART-VIEWNS (START)'

echo "-- 计数型 --"
c() { _n=$(grep -cE -- "$1" "$DISP" 2>/dev/null); [ -z "$_n" ] && _n=0; printf '%s' "$_n"; }
printf '  SERVER_PORT 守卫      = %s (期望 1)\n' "$(c '^if os[.]getenv[(]"SERVER_PORT"[)] ~= "8080" then$')"
printf '  indexcache 隔离行     = %s (期望 1)\n' "$(c '^luci[.]dispatcher[.]indexcache = "/tmp/luci-indexcache-bootstrap"$')"
printf '  KP-QUICKSTART-VIEW(边界)= %s (期望 2)\n' "$(c 'KP-QUICKSTART-VIEW([ :]|$)')"
printf '  KP-QUICKSTART-VIEW(裸)  = %s (对照，会误得 4)\n' "$(grep -cF 'KP-QUICKSTART-VIEW' "$DISP" 2>/dev/null)"
printf '  KP-TOP-SHIM (substr)  = %s (期望 1)\n' "$(grep -cF 'KP-TOP-SHIM' "$DISP" 2>/dev/null)"
for n in nradio_plugins status quickstart network_guide istorerouter kp_services; do
	printf '  admin.nodes.%-15s= %s\n' "$n" "$(c "admin[.]nodes[.]$n[[:space:]]*=")"
done

echo "-- 视图文件指纹（对比 payload PROVENANCE 表）--"
fail=0
for f in $(find "$PAY/views" -type f | sort); do
	rel="${f#$PAY/views/}"
	sz="$(wc -c < "$f" | tr -d ' ')"; md="$(md5sum "$f" | awk '{print $1}')"
	if grep -q "| \`views/$rel\` | $sz | \`$md\` |" "$PAY/PROVENANCE.md"; then
		printf '  [OK] %-46s %d\n' "$rel" "$sz"
	else
		printf '  [NG] %-46s %d %s  ← PROVENANCE 不符\n' "$rel" "$sz" "$md"; fail=$((fail+1))
	fi
done
printf '  视图指纹不符项 = %d\n' "$fail"

rm -f /tmp/kpnorm.tsv
