#!/bin/sh
# ============================================================
# xray-node 一键安装脚本（小白版）
#
# 小白用法（root 用户）：
#   1. SSH 连上你的服务器
#   2. 粘贴下面这一行，回车：
#      curl -fsSL -o /tmp/xray-install.sh https://raw.githubusercontent.com/imthnio/VPS-dajianjiedian/main/install.sh && sh /tmp/xray-install.sh
#   3. 按提示回答几个问题（看不懂就一路回车用默认），装完自动给你节点链接
#
# 装完之后，想看所有节点随时输入：  jiedian
# 输入 shanjiedian 进入节点管理：查看节点、删除单个节点，或全部卸载
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}[注意]${NC} %s\n" "$1"; }
err()  { printf "${RED}[出错]${NC} %s\n" "$1"; }
step() { printf "\n${CYAN}${BOLD}%s${NC}\n" "$1"; }
die()  { err "$1"; exit 1; }

ask() { # ask "提示文字" "默认值" 变量名
  _p="$1"; _d="$2"; _v="$3"
  if [ -n "$_d" ]; then
    printf "%s [默认 %s]: " "$_p" "$_d"
  else
    printf "%s: " "$_p"
  fi
  read -r _a
  if [ -z "$_a" ]; then _a="$_d"; fi
  # 不能直接 eval "$_v=$_a"：输入里的 $(...) 或反引号会被执行。
  # 用单引号包裹并转义输入里的单引号，保证原样赋值、什么都不执行。
  _a_esc=$(printf "%s" "$_a" | sed "s/'/'\\\\''/g")
  eval "$_v='$_a_esc'"
}

rand_hex() { # rand_hex 字节数 -> 十六进制串
  od -An -tx1 -N"$1" /dev/urandom 2>/dev/null | tr -d ' \n'
}

port_in_use() { # port_in_use <端口> <tcp|udp>
  _pi_port="$1"; _pi_proto="$2"
  if command -v ss >/dev/null 2>&1; then
    if [ "$_pi_proto" = "udp" ]; then _pi_list=$(ss -uln 2>/dev/null); else _pi_list=$(ss -ltn 2>/dev/null); fi
  elif command -v netstat >/dev/null 2>&1; then
    if [ "$_pi_proto" = "udp" ]; then _pi_list=$(netstat -uln 2>/dev/null); else _pi_list=$(netstat -ltn 2>/dev/null); fi
  else
    # 与 wait_for_port 一致：极简系统没有 ss/netstat 时从 /proc 查。
    # 以前这里直接 return 2，调用方把“查不了”当成“空闲”，可能选中已被占用的端口；
    # 随后 wait_for_port 的 /proc 回退又会看到别人的监听，误报安装成功。
    _pi_hex=$(printf '%04X' "$_pi_port" 2>/dev/null) || return 2
    if [ "$_pi_proto" = "udp" ]; then
      _pi_files="/proc/net/udp /proc/net/udp6"; _pi_state=07
    else
      _pi_files="/proc/net/tcp /proc/net/tcp6"; _pi_state=0A
    fi
    _pi_checked=0
    for _pi_file in $_pi_files; do
      [ -r "$_pi_file" ] || continue
      _pi_checked=1
      awk -v port="$_pi_hex" -v state="$_pi_state" '
        NR > 1 { split($2, addr, ":"); if (toupper(addr[2]) == port && toupper($4) == state) found = 1 }
        END { exit !found }
      ' "$_pi_file" && return 0
    done
    # /proc 可读且未命中：确认空闲。都读不到才返回 2（未知）。
    [ "$_pi_checked" = "1" ] && return 1
    return 2
  fi
  printf '%s\n' "$_pi_list" | grep -Eq ":${_pi_port}[[:space:]]"
}

rand_port() { # rand_port <tcp|udp|both> -> 随机一个空闲端口 20000-59999
  _rp_proto="$1"
  _try=0
  while [ "$_try" -lt 50 ]; do
    _try=$((_try + 1))
    # 用 /dev/urandom 取随机数：awk 的 srand() 在 gawk 等实现里按秒播种，
    # 一秒内连调 50 次会拿到 50 个相同的"随机"端口，重试就形同虚设了
    _p=$(od -An -tu2 -N2 /dev/urandom 2>/dev/null | tr -d ' ')
    if [ -n "$_p" ]; then
      _p=$((20000 + _p % 40000))
    else
      _p=$(awk 'BEGIN{srand(); print int(20000+rand()*40000)}')
    fi
    _used=0
    case "$_rp_proto" in
      tcp|both) port_in_use "$_p" tcp && _used=1 ;;
    esac
    case "$_rp_proto" in
      udp|both) port_in_use "$_p" udp && _used=1 ;;
    esac
    if [ "$_used" -eq 0 ]; then printf "%s" "$_p"; return 0; fi
  done
  return 1
}

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    tr 'A-Z' 'a-z' < /proc/sys/kernel/random/uuid | tr -d '\n'
  else
    rand_hex 16 | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
  fi
}

b64url() { # 标准输入 -> base64url（去换行、去 =）
  base64 2>/dev/null | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

get_ip() { # get_ip 4|6 -> 打印公网 IP，失败返回非零
  _v="$1"
  if [ "$_v" = "6" ]; then _f="-6"; else _f="-4"; fi
  for _u in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com"; do
    _ip=$(curl -fsSL --max-time 10 $_f "$_u" 2>/dev/null | tr -d ' \r\n')
    # 检测网站偶尔返回非 IP 的垃圾（比如限流提示页）：长得不像 IP 就换下一个
    if [ -n "$_ip" ] && _valid_ip "$_v" "$_ip"; then
      printf "%s" "$_ip"; return 0
    fi
  done
  return 1
}

_valid_ip() { # _valid_ip 4|6 <串>：长得像对应版本的 IP 才返回 0
  if [ "$1" = "6" ]; then
    _v6="$2"
    case "$_v6" in
      \[*\]) _v6=${_v6#\[}; _v6=${_v6%\]} ;;
    esac
    # 检测网站失败时可能返回带冒号的网页文字。只要有冒号就当成 IPv6 的话，
    # 节点链接是一串垃圾，安装却显示成功。
    case "$_v6" in
      *[!0-9A-Fa-f:]*) return 1 ;;
      *[0-9A-Fa-f]*) ;;
      *) return 1 ;;
    esac
    case "$_v6" in
      *:*) ;;
      *) return 1 ;;
    esac
    case "$_v6" in *:::*) return 1 ;; esac
    _v6_once=${_v6#*::}
    case "$_v6" in
      *::*) case "$_v6_once" in *::*) return 1 ;; esac ;;
    esac
    # 每一段 1-4 位十六进制。有 :: 时显式段最多 7 段；没有 :: 时必须正好 8 段。
    _v6_ok_side() {
      _vs="$1"
      _vs_n=0
      [ -n "$_vs" ] || return 0
      _vs_rest=$_vs
      while [ -n "$_vs_rest" ]; do
        _vs_g=${_vs_rest%%:*}
        case "$_vs_g" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
        [ "${#_vs_g}" -le 4 ] || return 1
        _vs_n=$((_vs_n + 1))
        case "$_vs_rest" in
          *:*) _vs_rest=${_vs_rest#*:} ;;
          *) _vs_rest="" ;;
        esac
      done
      return 0
    }
    case "$_v6" in
      *::*)
        _v6_ok_side "${_v6%%::*}" || return 1
        _v6_left_n=$_vs_n
        _v6_ok_side "${_v6#*::}" || return 1
        _v6_total=$((_v6_left_n + _vs_n))
        [ "$_v6_total" -ge 1 ] && [ "$_v6_total" -le 7 ]
        ;;
      *)
        _v6_ok_side "$_v6" || return 1
        [ "$_vs_n" -eq 8 ]
        ;;
    esac
  else
    case "$2" in *:*|''|*[!0-9.]*|.*|*.) return 1 ;; esac
    [ "$(printf "%s" "$2" | tr -cd '.' | wc -c)" -eq 3 ] || return 1
    # 每段必须是 0-255 的数字：之前 999.1.1.1、1.2.3.256 这种也能通过，
    # 手动输错 IP 会直接写进节点链接，节点就废了
    _v4_rest="$2."
    _v4_n=0
    while [ -n "$_v4_rest" ]; do
      _v4_o=${_v4_rest%%.*}; _v4_rest=${_v4_rest#*.}
      _v4_n=$((_v4_n + 1))
      [ "$_v4_n" -gt 4 ] && return 1
      case "$_v4_o" in ''|*[!0-9]*) return 1 ;; esac
      [ "${#_v4_o}" -gt 3 ] && return 1
      # 去掉前导 0 再比大小（"08" 在 sh 算术里会被当成非法八进制）
      _v4_on=$(printf "%s" "$_v4_o" | sed 's/^0*//')
      [ -z "$_v4_on" ] && _v4_on=0
      if [ "$_v4_on" -gt 255 ] 2>/dev/null; then return 1; fi
    done
    [ "$_v4_n" -eq 4 ]
  fi
}

# gh_api_dl <仓库> <文件名> <输出路径>
# 走 GitHub API 下载 release 文件：api.github.com 比 github.com 稳得多，
# API 返回 302 跳到 release-assets，下得快。成功返回 0，失败返回非零。
gh_api_dl() {
  _gh_repo="$1"; _gh_asset="$2"; _gh_out="$3"
  _gh_rel=$(curl -fsSL --max-time 20 "https://api.github.com/repos/${_gh_repo}/releases/latest" 2>/dev/null) || return 1
  [ -n "$_gh_rel" ] || return 1
  _gh_aid=$(printf "%s\n" "$_gh_rel" | grep -B10 -F "\"name\": \"${_gh_asset}\"" | grep '"id"' | tail -1 | grep -o '[0-9][0-9]*' | head -1)
  [ -n "$_gh_aid" ] || return 1
  curl -fSL --progress-bar --connect-timeout 20 --speed-time 30 --speed-limit 1000 --retry 2 --retry-delay 3 \
    -H "Accept: application/octet-stream" \
    -o "$_gh_out" "https://api.github.com/repos/${_gh_repo}/releases/assets/${_gh_aid}"
}

# pick_dldir: 选一个磁盘上的下载目录（/tmp 可能是内存盘，大文件下载会爆内存）
# 优先 /var/tmp，其次 $HOME，最后才 /tmp。打印目录路径，失败返回非零。
pick_dldir() {
  for _cand in /var/tmp "$HOME" /tmp; do
    if [ -d "$_cand" ] && [ -w "$_cand" ]; then
      _dd="${_cand}/xray-node-dl"
      if mkdir -p "$_dd" 2>/dev/null; then
        printf "%s" "$_dd"
        return 0
      fi
    fi
  done
  return 1
}

# mark_our_bin <名字>: 记录这个内核是脚本自己下载安装的，卸载时才删
# （用户机器上本来就有的不删，避免误删）
mark_our_bin() {
  mkdir -p /etc/xray-node 2>/dev/null
  grep -qx "$1" /etc/xray-node/our_bins 2>/dev/null || echo "$1" >> /etc/xray-node/our_bins
}

# wait_for_port <端口> <tcp|udp> <超时秒>: 等端口进入监听，成功返回 0
wait_for_port() {
  _wp="$1"; _wproto="${2:-tcp}"; _wtimeout="${3:-15}"
  _wtry=0
  while [ "$_wtry" -lt "$_wtimeout" ]; do
    if command -v ss >/dev/null 2>&1; then
      if [ "$_wproto" = "udp" ]; then
        ss -uln 2>/dev/null | grep -q ":${_wp} " && return 0
      else
        ss -ltn 2>/dev/null | grep -q ":${_wp} " && return 0
      fi
    elif command -v netstat >/dev/null 2>&1; then
      if [ "$_wproto" = "udp" ]; then
        netstat -uln 2>/dev/null | grep -q ":${_wp} " && return 0
      else
        netstat -ltn 2>/dev/null | grep -q ":${_wp} " && return 0
      fi
    else
      # 极简系统可能没有 ss/netstat；从内核套接字表检查，不能把“无法检查”当作成功。
      _wp_hex=$(printf '%04X' "$_wp")
      if [ "$_wproto" = "udp" ]; then
        _wp_files="/proc/net/udp /proc/net/udp6"; _wp_state=07
      else
        _wp_files="/proc/net/tcp /proc/net/tcp6"; _wp_state=0A
      fi
      for _wp_file in $_wp_files; do
        [ -r "$_wp_file" ] || continue
        awk -v port="$_wp_hex" -v state="$_wp_state" '
          NR > 1 { split($2, addr, ":"); if (toupper(addr[2]) == port && toupper($4) == state) found = 1 }
          END { exit !found }
        ' "$_wp_file" && return 0
      done
    fi
    sleep 1
    _wtry=$((_wtry + 1))
  done
  return 1
}

# 小内存机器不装 iptables-persistent。开机只恢复本脚本添加的端口规则，
# 不回放整张 iptables 快照，以免清掉安装后其他程序或用户添加的规则。
_save_fw_light() {
  cat > /usr/local/bin/xray-node-fw-restore <<'FWEOF' || return 1
#!/bin/sh
NODES_DIR=${XRAY_NODE_DIR:-/etc/xray-node/nodes}
_restore_failed=0
for _fw in "$NODES_DIR"/*/fw_info; do
  [ -f "$_fw" ] || continue
  while read -r _port _proto _ufw _fwl _ipt _family; do
    case "$_port" in ''|*[!0-9]*) continue ;; esac
    case "$_proto" in tcp|udp) ;; *) continue ;; esac
    # 旧版两列 fw_info 默认记录脚本添加的规则。
    [ "$_ipt" = "1" ] || [ -z "$_ufw$_fwl$_ipt" ] || continue
    if [ "$_family" = "6" ]; then _bin=ip6tables; else _bin=iptables; fi
    command -v "$_bin" >/dev/null 2>&1 || { _restore_failed=1; continue; }
    "$_bin" -C INPUT -p "$_proto" --dport "$_port" -j ACCEPT >/dev/null 2>&1 ||
      "$_bin" -I INPUT -p "$_proto" --dport "$_port" -j ACCEPT >/dev/null 2>&1 ||
      _restore_failed=1
  done < "$_fw"
done
exit "$_restore_failed"
FWEOF
  chmod 700 /usr/local/bin/xray-node-fw-restore || return 1
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    cat > /etc/systemd/system/xray-node-fw.service <<'FWEOF' || return 1
[Unit]
Description=Restore xray-node firewall rules
After=network-pre.target
Before=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/xray-node-fw-restore
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
FWEOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable xray-node-fw.service >/dev/null 2>&1 || return 1
    rm -f /etc/xray-node/rules.v4 /etc/xray-node/rules.v6
    info "本脚本添加的防火墙规则已设为开机恢复"
    return 0
  fi
  if command -v rc-update >/dev/null 2>&1 && [ -d /etc/init.d ]; then
    cat > /etc/init.d/xray-node-fw <<'FWEOF' || return 1
#!/sbin/openrc-run
description="Restore xray-node firewall rules"
depend() { before net; }
start() {
  /usr/local/bin/xray-node-fw-restore
}
FWEOF
    chmod +x /etc/init.d/xray-node-fw || return 1
    rc-update add xray-node-fw default >/dev/null 2>&1 || return 1
    rm -f /etc/xray-node/rules.v4 /etc/xray-node/rules.v6
    info "本脚本添加的防火墙规则已设为开机恢复"
    return 0
  fi
  warn "防火墙规则这次已加上，但没有开机服务管理器；重启后需手动运行 xray-node-fw-restore"
  return 1
}

_save_fw() { # _save_fw <4|6>：把刚加的 iptables 规则存盘，重启后还在
  # ufw / firewalld 自己会持久化，不用管；只有纯 iptables 需要手动存。
  # 尽力而为：实在存不了就明确告诉用户，不拦主流程。
  # 小内存机器走轻量存盘，避免 apt 把仅有的几十 MB 内存吃光。
  if [ "$LOW_MEM" = "1" ]; then
    _save_fw_light || warn "防火墙规则没能设为开机恢复，重启后可能需要重新放行端口"
    return 0
  fi
  if [ "$1" = "6" ]; then _fw_svc=ip6tables; _fw_save_bin=ip6tables-save
  else _fw_svc=iptables; _fw_save_bin=iptables-save; fi
  if [ -f /etc/alpine-release ] && [ -f "/etc/init.d/$_fw_svc" ]; then
    # Alpine：IPv4 和 IPv6 分别由对应的 OpenRC 服务恢复
    rc-update add "$_fw_svc" default >/dev/null 2>&1
    if "/etc/init.d/$_fw_svc" save >/dev/null 2>&1; then
      info "iptables 规则已存盘（重启后仍有效）"
    fi
    return 0
  fi
  if command -v netfilter-persistent >/dev/null 2>&1; then
    if netfilter-persistent save >/dev/null 2>&1; then
      info "iptables 规则已存盘（重启后仍有效）"
    fi
    return 0
  fi
  if command -v "$_fw_save_bin" >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    # Debian/Ubuntu：装 iptables-persistent 来存盘（_apt_do 会处理 dpkg 锁占用）
    # DEBIAN_FRONTEND 必须设：iptables-persistent 装时会弹 debconf 提问（是否保存当前规则），
    # 不设的话在小白的终端上会突然蹦出个看不懂的提问，把人卡住
    export DEBIAN_FRONTEND=noninteractive
    if _apt_do "正在安装 iptables-persistent（让防火墙规则重启后还在）" 300 -- install -y -qq iptables-persistent; then
      if command -v netfilter-persistent >/dev/null 2>&1 \
        && netfilter-persistent save >/dev/null 2>&1; then
        info "iptables 规则已存盘（重启后仍有效）"
      fi
    else
      warn "iptables-persistent 没装上：防火墙规则重启后会丢失，重启后重跑一次一键脚本即可恢复"
    fi
    unset DEBIAN_FRONTEND
    return 0
  fi
  warn "这台机器只有纯 iptables 且无法自动存盘：防火墙规则重启后会丢失，重启后重跑一次一键脚本即可恢复"
}

write_helper_cmds() { # 写入/刷新 jiedian 和 shanjiedian 两个命令（安装和更新都会调）
cat > /usr/local/bin/jiedian <<'JDEOF'
#!/bin/sh
# 输入 jiedian，显示所有已安装节点的信息和链接
_n=0
for _d in /etc/xray-node/nodes/*/; do
  [ -f "${_d}node.txt" ] || continue
  _n=1
  printf "\n==================== 节点 %s ====================\n" "$(basename "$_d")"
  cat "${_d}node.txt"
done
if [ "$_n" = "0" ]; then
  echo "还没安装节点，请先运行一键安装脚本"
fi
exit 0
JDEOF
chmod 700 /usr/local/bin/jiedian
cat > /usr/local/bin/shanjiedian <<'XZEOF'
#!/bin/sh
# 输入 shanjiedian，进入节点管理：查看节点、删除单个节点，或全部卸载
NODES_DIR=/etc/xray-node/nodes

# _node_info <节点id>：从 node.txt 里读出"协议，端口"
_node_info() {
  _ni_proto=$(grep -m1 '^协议: ' "$NODES_DIR/$1/node.txt" 2>/dev/null | sed 's/^协议: //')
  _ni_port=$(grep -m1 '^端口: ' "$NODES_DIR/$1/node.txt" 2>/dev/null | sed 's/^端口: //')
  printf "%s，端口 %s" "$_ni_proto" "$_ni_port"
}

# _fw_save：iptables 规则改动后存盘（删规则后也要存，否则重启后删掉的规则又回来了）
# 安装时如果装过 iptables-persistent，这里 netfilter-persistent 肯定在；Alpine 走自带服务
_fw_save() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1
  elif [ -f /etc/alpine-release ]; then
    if [ "$1" = "6" ]; then _fs_svc=ip6tables; else _fs_svc=iptables; fi
    [ -f "/etc/init.d/$_fs_svc" ] && "/etc/init.d/$_fs_svc" save >/dev/null 2>&1
  fi
  # 小内存模式的恢复器按现存节点的 fw_info 工作，无需保存整张规则表。
}

# _del_fw_rules <fw_info路径>：撤销该节点我们亲手加的防火墙规则（用户手写的不碰）
_del_fw_rules() {
  [ -f "$1" ] || return 0
  _fipt_touched=0
  while read -r _fport _fproto _fufw _ffwl _fipt _ffamily; do
    [ -n "$_fport" ] && [ -n "$_fproto" ] || continue
    # 老版本 fw_info 只有"端口 协议"两列：按老行为尽量清干净
    _oldfmt=0
    if [ -z "$_fufw$_ffwl$_fipt" ]; then _fufw=1; _ffwl=1; _fipt=1; _oldfmt=1; fi
    if [ "$_fufw" = "1" ] && command -v ufw >/dev/null 2>&1; then
      ufw delete allow "$_fport"/"$_fproto" >/dev/null 2>&1
    fi
    if [ "$_ffwl" = "1" ] && command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --remove-port="$_fport"/"$_fproto" >/dev/null 2>&1
      firewall-cmd --reload >/dev/null 2>&1
    fi
    if [ "$_ffamily" = "6" ]; then _fipbin=ip6tables; else _fipbin=iptables; fi
    if [ "$_fipt" = "1" ] && command -v "$_fipbin" >/dev/null 2>&1; then
      _fipt_touched=1
      _fipt_family="${_ffamily:-4}"
      if [ "$_oldfmt" = "1" ]; then
        while "$_fipbin" -C INPUT -p "$_fproto" --dport "$_fport" -j ACCEPT >/dev/null 2>&1; do
          "$_fipbin" -D INPUT -p "$_fproto" --dport "$_fport" -j ACCEPT >/dev/null 2>&1 || break
        done
      else
        # 新格式：这条规则是我们加的，只删一条；用户后来手加的相同规则不动
        "$_fipbin" -D INPUT -p "$_fproto" --dport "$_fport" -j ACCEPT >/dev/null 2>&1
      fi
    fi
    echo "已撤销端口 $_fport/$_fproto 的防火墙放行"
  done < "$1"
  # iptables 删了规则也要存盘，不然重启后删掉的规则又回来了
  [ "$_fipt_touched" = "1" ] && _fw_save "$_fipt_family"
}

# _stop_remove_svc <节点id>：停掉并删除该节点的服务，不碰其它节点
_stop_remove_svc() {
  _x_id="$1"
  _x_core=$(tr -d ' \r\n' < "$NODES_DIR/$_x_id/core" 2>/dev/null)
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    case "$_x_core" in
      sing-box) _x_unit="singbox-node@${_x_id}" ;;
      hysteria) _x_unit="hysteria-node@${_x_id}" ;;
      *) _x_unit="xray-node@${_x_id}" ;;
    esac
    systemctl stop "$_x_unit" >/dev/null 2>&1
    systemctl disable "$_x_unit" >/dev/null 2>&1
    rm -f "/etc/systemd/system/${_x_unit}.service"
  fi
  if command -v rc-service >/dev/null 2>&1; then
    rc-service "xray-node-${_x_id}" stop >/dev/null 2>&1
    rc-update del "xray-node-${_x_id}" default >/dev/null 2>&1
    rm -f "/etc/init.d/xray-node-${_x_id}"
  fi
  # 兜底：按该节点的配置文件路径精确杀进程，不碰其它节点的进程
  pkill -f "/etc/xray-node/nodes/${_x_id}/config.json" >/dev/null 2>&1
  pkill -f "/etc/xray-node/nodes/${_x_id}/config.yaml" >/dev/null 2>&1
  sleep 1
}

# _del_node <节点id> [skip_confirm]：删除单个节点（服务+防火墙+配置），其它节点不受影响
_del_node() {
  _d_id="$1"
  [ -d "$NODES_DIR/$_d_id" ] || { echo "节点 $_d_id 不存在"; return 1; }
  if [ "$2" != "skip_confirm" ]; then
    printf "确定删除节点 %s（%s）吗？删掉后这个节点就不能用了。[y/N]: " "$_d_id" "$(_node_info "$_d_id")"
    read -r _ans
    case "$_ans" in y|Y|yes|YES) ;; *) echo "已取消"; return 0 ;; esac
  fi
  echo "正在删除节点 $_d_id…"
  _stop_remove_svc "$_d_id"
  [ -d /run/systemd/system ] && systemctl daemon-reload >/dev/null 2>&1
  _del_fw_rules "$NODES_DIR/$_d_id/fw_info"
  rm -rf "$NODES_DIR/$_d_id"
  echo "节点 $_d_id 已删除，其它节点不受影响。"
}

# _uninstall_all：删除全部节点并卸载干净（含内核、命令、配置）
_uninstall_all() {
  echo "正在删除全部节点并卸载…"
  for _d in "$NODES_DIR"/*/; do
    [ -d "$_d" ] || continue
    _del_node "$(basename "$_d")" skip_confirm
  done
  # _svc_install 建的 systemd 模板（xray-node@.service / singbox-node@.service）
  # 不是按节点实例建的，上面的循环删不掉，不清会残留在系统里
  if [ -d /run/systemd/system ]; then
    systemctl disable xray-node-fw.service >/dev/null 2>&1
    systemctl stop xray-node-fw.service >/dev/null 2>&1
  fi
  if command -v rc-update >/dev/null 2>&1; then
    rc-service xray-node-fw stop >/dev/null 2>&1
    rc-update del xray-node-fw default >/dev/null 2>&1
  fi
  rm -f /etc/systemd/system/xray-node@.service /etc/systemd/system/singbox-node@.service \
    /etc/systemd/system/hysteria-node@.service /etc/systemd/system/xray-node-fw.service
  rm -f /etc/init.d/xray-node-fw /etc/sysctl.d/99-xray-node-overcommit.conf
  if [ -f /xray-node.swap ]; then
    swapoff /xray-node.swap >/dev/null 2>&1
    rm -f /xray-node.swap
    # 粘在别的行末尾时只拆掉 swap 这一段，不能整行删掉（那一行可能是根分区）
    _fs_file=${XRAY_FSTAB:-/etc/fstab}
    if [ -f "$_fs_file" ] && [ -w "$_fs_file" ]; then
      _fs_tmp=$(mktemp 2>/dev/null) || _fs_tmp=""
      if [ -n "$_fs_tmp" ] && awk '
        BEGIN { key = "/xray-node.swap none swap sw 0 0" }
        {
          i = index($0, key)
          if (i == 0) { print; next }
          if (i == 1) next
          pre = substr($0, 1, i - 1)
          if (pre != "") print pre
        }
      ' "$_fs_file" > "$_fs_tmp"; then
        cat "$_fs_tmp" > "$_fs_file"
      fi
      rm -f "$_fs_tmp"
    fi
  fi
  [ -d /run/systemd/system ] && systemctl daemon-reload >/dev/null 2>&1
  # 只删脚本自己下载安装的内核（our_bins 里记着），用户机器上本来就有的不碰
  # 注意：必须在删 /etc/xray-node 之前读
  if [ -f /etc/xray-node/our_bins ]; then
    while read -r _b; do
      case "$_b" in
        xray|sing-box|hysteria) rm -f "/usr/local/bin/$_b" && echo "已删除脚本安装的 $_b" ;;
      esac
    done < /etc/xray-node/our_bins
  fi
  # 删掉配置、节点、日志
  rm -rf /etc/xray-node
  rm -f /var/log/xray-node-*.log
  rm -f /etc/sysctl.d/99-xray-node-bbr.conf
  rm -f /usr/local/bin/jiedian
  rm -f /usr/local/bin/shanjiedian /usr/local/bin/xiezai
  rm -f /usr/local/bin/xray-node-fw-restore
  echo "卸载完成：所有节点、配置、开机自启、防火墙规则都已清除干净。"
}

echo "==================== 节点管理 ===================="
_n_count=0
_n_ids=""
for _d in "$NODES_DIR"/*/; do
  [ -f "${_d}node.txt" ] || continue
  _n_id=$(basename "$_d")
  # 编号会跳号（删过的不重用）。必须按节点编号删，不能按菜单序号删，
  # 否则列表里第 2 项可能是节点 5，输入 2 会把还在用的节点删掉。
  case "$_n_id" in ''|*[!0-9]*) continue ;; esac
  _n_count=$((_n_count + 1))
  _n_ids="$_n_ids $_n_id"
  printf "  节点 %s：%s\n" "$_n_id" "$(_node_info "$_n_id")"
done
if [ "$_n_count" = "0" ]; then
  echo "没有已安装的节点。"
  exit 0
fi
printf "  0) 取消\n"
printf "  all) 删除全部节点并卸载干净\n"
printf "请输入要删除的节点编号（上面显示的数字）: "
read -r _sel
case "$_sel" in
  0|"") echo "已取消" ;;
  all|ALL)
    printf "确定删除全部 %s 个节点并卸载干净吗？[y/N]: " "$_n_count"
    read -r _ans2
    case "$_ans2" in y|Y|yes|YES) _uninstall_all ;; *) echo "已取消" ;; esac
    ;;
  *)
    case "$_sel" in ''|*[!0-9]*) echo "输入不对，已取消" ;;
      *)
        _found=0
        for _cand in $_n_ids; do
          if [ "$_cand" = "$_sel" ]; then
            _found=1
            _del_node "$_sel"
            break
          fi
        done
        [ "$_found" = "1" ] || echo "没有这个节点编号，已取消"
        ;;
    esac
    ;;
esac
XZEOF
chmod 700 /usr/local/bin/shanjiedian
# 旧版的 xiezai 是"一键全删"，改名后把它删掉，免得留着误导人
rm -f /usr/local/bin/xiezai
for _hy_node in /etc/xray-node/nodes/*/; do
  [ -f "${_hy_node}core" ] && [ -f "${_hy_node}node.txt" ] || continue
  [ "$(tr -d ' \r\n' < "${_hy_node}core")" = "hysteria" ] || continue
  # 旧节点只修分享链接和文字提示；证书、密码、端口和服务不变。
  if grep -q '^hysteria2://.*pinSHA256=' "${_hy_node}node.txt" &&
     ! grep -q '^hysteria2://.*[?&]insecure=' "${_hy_node}node.txt"; then
    sed -e '/^hysteria2:\/\//s/?sni=/?insecure=1\&sni=/' \
      -e 's/客户端不要打开“跳过证书验证”。如果导入后证书锁定是空的，把上面的指纹填进去。/官方 Hysteria2 客户端：自签证书须同时启用 insecure 和证书指纹锁定；如果指纹为空，填入上面的值。/' \
      "${_hy_node}node.txt" > "${_hy_node}node.txt.tmp" &&
      mv -f "${_hy_node}node.txt.tmp" "${_hy_node}node.txt"
    chmod 600 "${_hy_node}node.txt" 2>/dev/null
  fi
done
}

_hy_export_env() { # 给没有 systemd 的启动方式用。和 unit 文件里的 Environment 保持一致。
  export HYSTERIA_DISABLE_UPDATE_CHECK=1
  export HYSTERIA_LOG_LEVEL=warn
  if [ "$LOW_MEM" = "1" ]; then
    export GOGC=30
    if [ "$SWAP_OK" != "1" ] && [ -n "$MEM_MB" ]; then
      _hy_gomem=$((MEM_MB / 3))
      [ "$_hy_gomem" -lt 16 ] && _hy_gomem=16
      [ "$_hy_gomem" -gt 32 ] && _hy_gomem=32
      export GOMEMLIMIT="${_hy_gomem}MiB"
    fi
  fi
}

_svc_install() { # _svc_install <节点id>：按该节点的 core 装好开机自启服务并启动（systemd 模板实例 / OpenRC 独立脚本 / 兜底后台）
  _si_id="$1"
  _si_core=$(tr -d ' \r\n' < /etc/xray-node/nodes/"$_si_id"/core 2>/dev/null)
  _si_cfg=/etc/xray-node/nodes/"$_si_id"/config.json
  _si_unit_env=""
  _si_openrc_env=""
  case "$_si_core" in
    hysteria)
      _si_cfg=/etc/xray-node/nodes/"$_si_id"/config.yaml
      _si_bin="$HY_BIN"; _si_args="server -c $_si_cfg"
      _si_tpl=/etc/systemd/system/hysteria-node@.service; _si_unit="hysteria-node@${_si_id}"
      # 关掉官方程序的更新检查，小内存机器上这一下会多占内存、还可能卡住启动
      _si_unit_env="Environment=HYSTERIA_DISABLE_UPDATE_CHECK=1
Environment=HYSTERIA_LOG_LEVEL=warn"
      _si_openrc_env="export HYSTERIA_DISABLE_UPDATE_CHECK=1
export HYSTERIA_LOG_LEVEL=warn"
      if [ "$LOW_MEM" = "1" ]; then
        _si_unit_env="${_si_unit_env}
Environment=GOGC=30"
        _si_openrc_env="${_si_openrc_env}
export GOGC=30"
        if [ "$SWAP_OK" != "1" ] && [ -n "$MEM_MB" ]; then
          _hy_gomem=$((MEM_MB / 3))
          [ "$_hy_gomem" -lt 16 ] && _hy_gomem=16
          [ "$_hy_gomem" -gt 32 ] && _hy_gomem=32
          _si_unit_env="${_si_unit_env}
Environment=GOMEMLIMIT=${_hy_gomem}MiB"
          _si_openrc_env="${_si_openrc_env}
export GOMEMLIMIT=${_hy_gomem}MiB"
        fi
      fi
      ;;
    sing-box) _si_bin="$SB_BIN"; _si_args="run -c $_si_cfg"; _si_tpl=/etc/systemd/system/singbox-node@.service; _si_unit="singbox-node@${_si_id}" ;;
    *)        _si_bin="$XRAY_BIN"; _si_args="-config $_si_cfg"; _si_tpl=/etc/systemd/system/xray-node@.service; _si_unit="xray-node@${_si_id}" ;;
  esac
  SVC_UNIT="$_si_unit"
  _si_svc="xray-node-${_si_id}"
  [ "$LOW_MEM" = "1" ] && drop_page_cache
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    # 每次都重写模板。只在文件不存在时写一次的话，旧模板没有小内存环境变量，
    # 64MB 机器更新内核后新进程照旧被打爆，端口起不来。
    case "$_si_core" in
      hysteria) _si_tpl_bin="$HY_BIN"; _si_tpl_args="server -c /etc/xray-node/nodes/%i/config.yaml"; _si_tpl_desc="Hysteria2 node %i" ;;
      sing-box) _si_tpl_bin="$SB_BIN"; _si_tpl_args="run -c /etc/xray-node/nodes/%i/config.json"; _si_tpl_desc="sing-box node %i" ;;
      *)        _si_tpl_bin="$XRAY_BIN"; _si_tpl_args="-config /etc/xray-node/nodes/%i/config.json"; _si_tpl_desc="Xray node %i" ;;
    esac
    cat > "$_si_tpl" <<EOF
[Unit]
Description=${_si_tpl_desc}
After=network.target
[Service]
Type=simple
User=root
${_si_unit_env}
ExecStart=${_si_tpl_bin} ${_si_tpl_args}
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$_si_unit" >/dev/null 2>&1
    systemctl restart "$_si_unit" >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet "$_si_unit"; then
      info "节点 $_si_id 服务已启动，并设为开机自启"
    else
      warn "节点 $_si_id 服务好像没起来，运行 systemctl status $_si_unit 看看原因"
    fi
  elif command -v rc-service >/dev/null 2>&1; then
    cat > /etc/init.d/${_si_svc} <<RCEOF
#!/sbin/openrc-run
${_si_openrc_env}
name="${_si_svc}"
description="${_si_svc} proxy service"
command="${_si_bin}"
command_args="${_si_args}"
command_background="yes"
pidfile="/run/${_si_svc}.pid"
output_log="/var/log/${_si_svc}.log"
error_log="/var/log/${_si_svc}.log"
retry="SIGTERM/5/SIGKILL/5"
depend() { need net; }
start_pre() {
    # 进程已死但 pidfile 还在（比如被 OOM 杀掉），先清理，否则 OpenRC 会误判
    if [ -f "\$pidfile" ]; then
        _ppid=\$(cat "\$pidfile" 2>/dev/null)
        if [ -n "\$_ppid" ] && ! kill -0 "\$_ppid" 2>/dev/null; then
            rm -f "\$pidfile"
        fi
    fi
    checkpath -f -m 0644 -o root:root "\$output_log"
}
RCEOF
    chmod +x /etc/init.d/${_si_svc}
    rc-update add "$_si_svc" default >/dev/null 2>&1
    # 先清掉可能残留的旧状态，再启动（比 restart 更稳）
    rc-service "$_si_svc" zap >/dev/null 2>&1
    rc-service "$_si_svc" start >/dev/null 2>&1
    sleep 1
    if rc-service "$_si_svc" status >/dev/null 2>&1; then
      info "节点 $_si_svc 已启动，并设为开机自启"
    else
      warn "节点 $_si_svc 好像没起来，运行 rc-service $_si_svc status 看看原因"
    fi
  else
    warn "没找到 systemd/OpenRC，改用后台方式启动（重启后需手动再跑一次脚本）"
    if [ "$_si_core" = "hysteria" ]; then
      _hy_export_env
    fi
    pkill -f "$_si_cfg" >/dev/null 2>&1
    # shellcheck disable=SC2086 — _si_args 故意拆成多个参数
    nohup $_si_bin $_si_args >/var/log/xray-node-${_si_id}.log 2>&1 &
    sleep 1
    info "节点 $_si_id 已在后台启动"
  fi
}

_svc_restart() { # _svc_restart <节点id>：重写服务模板后再重启（更新模式用）
  # 走 _svc_install：它会重写 systemd/OpenRC 模板。只 systemctl restart 的话，
  # 64MB 机器上的旧单元没有 GOMEMLIMIT，新内核一起就可能被打爆。
  _svc_install "$1"
}

_node_port() { # _node_port <节点id> -> "端口 协议"（从该节点的 fw_info 第一行读）
  read -r _np_port _np_proto _np_rest < /etc/xray-node/nodes/"$1"/fw_info 2>/dev/null
  [ -n "$_np_port" ] || return 1
  [ -n "$_np_proto" ] || _np_proto="tcp"
  printf "%s %s" "$_np_port" "$_np_proto"
}

_ver_num() { # _ver_num <字符串> -> 提取其中的第一个版本号，如 "Xray 26.3.27 (…)" -> "26.3.27"
  printf "%s" "$1" | sed 's/^[^0-9]*//; s/[^0-9.].*//; s/\.*$//'
}

_latest_tag() { # _latest_tag <owner/repo> -> 打印最新 release 版本号（去 v 前缀），失败返回非零
  _lt_tag=$(curl -fsSL --max-time 20 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//; s/".*//; s/^v//')
  # 必须是版本号的样子：tag 格式万一变了（比如 "nightly"），
  # 不能把整行垃圾当版本号吐出去，否则版本比较永远对不上、每次更新都重复下载
  case "$_lt_tag" in ''|*[!0-9a-zA-Z.-]*) return 1 ;; esac
  printf "%s" "$_lt_tag"
}

# _cached_ver_ok <二进制路径> <owner/repo> [已知最新版本]：
# 缓存安装包里的内核已是最新版返回 0；连不上 API 拿不到"最新"时返回 0
# （不断网折腾，照旧用缓存）；包里版本读不出来返回 1（重新下载）
_cached_ver_ok() {
  _cvo_ver=$(_ver_num "$("$1" version 2>/dev/null | head -1)")
  [ -n "$_cvo_ver" ] || return 1
  if [ -n "$3" ]; then
    _cvo_latest="$3"
  else
    _cvo_latest=$(_latest_tag "$2") || return 0
  fi
  [ "$_cvo_ver" = "$_cvo_latest" ]
}

_read_meminfo_kb() { # _read_meminfo_kb MemTotal: -> 数字（kB）
  awk -v k="$1" '$1==k {print $2; exit}' /proc/meminfo 2>/dev/null
}

# 容器里的 MemTotal 经常是宿主机的内存，真正的上限在 cgroup。
# 不限制时这个文件是一个超大整数或 max，不能拿去运算（shell 算术会溢出）。
_cgroup_mem_mb() {
  for _cgf in /sys/fs/cgroup/memory.max \
              /sys/fs/cgroup/memory/memory.limit_in_bytes \
              /sys/fs/cgroup/memory.limit_in_bytes; do
    [ -r "$_cgf" ] || continue
    _cgv=$(tr -d ' \r\n' < "$_cgf" 2>/dev/null)
    case "$_cgv" in ''|max|*[!0-9]*) continue ;; esac
    [ "${#_cgv}" -le 12 ] || continue
    [ "$_cgv" -ge 1048576 ] || continue
    printf '%s' $((_cgv / 1024 / 1024))
    return 0
  done
  return 1
}

_disk_free_mb() { # _disk_free_mb <路径> -> 该路径所在磁盘剩余 MB
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024)}'
}

_fstype() { # _fstype <挂载点>
  awk -v m="$1" '$2==m {print $3; exit}' /proc/mounts 2>/dev/null
}

drop_page_cache() {
  sync
  if [ -w /proc/sys/vm/drop_caches ]; then
    printf '3\n' > /proc/sys/vm/drop_caches 2>/dev/null
  fi
}

# 上次安装失败会把几十 MB 的安装包留在临时目录。1GB 硬盘上这些残留会让下一次装直接写满。
recover_disk_space() {
  rm -rf /var/tmp/xray-node-dl "$HOME/xray-node-dl" /tmp/xray-node-dl 2>/dev/null
  rm -f /usr/local/bin/sing-box.new /usr/local/bin/xray.new /usr/local/bin/hysteria.new 2>/dev/null
  _rdf=$(_disk_free_mb /)
  if [ "$LOW_MEM" = "1" ] || { [ -n "$_rdf" ] && [ "$_rdf" -lt 200 ]; }; then
    rm -f /var/cache/apt/archives/*.deb 2>/dev/null
  fi
}

# 往 fstab 追加 swap 行。文件最后如果没有换行，直接 >> 会把上一行粘死
# （常见是根分区那一行），重启时根分区挂不上。
_fstab_append_swap() {
  _fs_file=${XRAY_FSTAB:-/etc/fstab}
  if [ ! -f "$_fs_file" ]; then
    _fs_dir=$(dirname "$_fs_file")
    [ -w "$_fs_dir" ] || return 0
    touch "$_fs_file" 2>/dev/null || return 0
  fi
  [ -w "$_fs_file" ] || return 0
  _fs_key='/xray-node.swap none swap sw 0 0'
  if grep -q '/xray-node\.swap' "$_fs_file" 2>/dev/null; then
    grep -q '^/xray-node\.swap[[:space:]]' "$_fs_file" 2>/dev/null && return 0
    _fs_tmp=$(mktemp 2>/dev/null) || return 0
    if awk -v key="$_fs_key" '
      {
        i = index($0, key)
        if (i == 0) { print; next }
        if (i == 1) { print; next }
        pre = substr($0, 1, i - 1)
        if (pre != "") print pre
        print key
      }
    ' "$_fs_file" > "$_fs_tmp"; then
      cat "$_fs_tmp" > "$_fs_file"
    fi
    rm -f "$_fs_tmp"
    return 0
  fi
  if [ -s "$_fs_file" ] && [ -n "$(tail -c 1 "$_fs_file" 2>/dev/null)" ]; then
    printf '\n' >> "$_fs_file"
  fi
  printf '%s\n' "$_fs_key" >> "$_fs_file"
}

# 64MB / 128MB 的 NAT：Go 程序启动时会多申请一段内存，默认策略直接拒绝；
# 再加一块放在硬盘上的虚拟内存，Hysteria2 才起得来。tmpfs 上的 swap 等于拿内存当内存，不用。
prepare_low_memory() {
  LOW_MEM=0
  SWAP_OK=0
  MEM_MB=""
  _tot_kb=$(_read_meminfo_kb "MemTotal:")
  _cg_mb=$(_cgroup_mem_mb) || _cg_mb=""
  if [ -n "$_tot_kb" ]; then
    MEM_MB=$((_tot_kb / 1024))
  fi
  if [ -n "$_cg_mb" ]; then
    if [ -z "$MEM_MB" ] || [ "$_cg_mb" -lt "$MEM_MB" ]; then
      MEM_MB="$_cg_mb"
    fi
  fi
  # 只看机器的内存上限。临时剩下的可用内存很少时，不去改大机器的系统设置。
  if [ -n "$MEM_MB" ] && [ "$MEM_MB" -le 192 ]; then LOW_MEM=1; fi
  # 先清残留安装包，再决定要不要做 swap（磁盘数字才准）
  recover_disk_space
  [ "$LOW_MEM" = "1" ] || return 0
  info "这台机器大约 ${MEM_MB:-很少}MB 内存。先准备虚拟内存，否则 Hysteria2 起不来。"
  if [ -w /proc/sys/vm/overcommit_memory ]; then
    _oc=$(tr -d ' \r\n' < /proc/sys/vm/overcommit_memory 2>/dev/null)
    if [ "$_oc" != "1" ]; then
      if sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 \
        || printf '1\n' > /proc/sys/vm/overcommit_memory 2>/dev/null; then
        mkdir -p /etc/sysctl.d 2>/dev/null
        printf 'vm.overcommit_memory=1\n' > /etc/sysctl.d/99-xray-node-overcommit.conf 2>/dev/null
        info "已放开内存申请限制（小内存机器需要这一步）"
      fi
    fi
  fi
  _swap_kb=$(_read_meminfo_kb "SwapTotal:")
  _swap_kb=${_swap_kb:-0}
  if [ "$_swap_kb" -ge 65536 ]; then
    SWAP_OK=1
    info "虚拟内存已经有了，直接用"
    return 0
  fi
  _root_type=$(_fstype /)
  case "$_root_type" in
    tmpfs|devtmpfs)
      warn "系统盘在内存里，没法再加虚拟内存"
      return 0
      ;;
  esac
  _free=$(_disk_free_mb /)
  [ -n "$_free" ] || _free=0
  _sw=0
  if [ "$_free" -ge 220 ]; then _sw=128
  elif [ "$_free" -ge 120 ]; then _sw=64
  fi
  if [ "$_sw" -eq 0 ]; then
    warn "磁盘只剩大约 ${_free}MB，腾不出虚拟内存。安装会继续，内存实在不够时会失败。"
    return 0
  fi
  _swapf=/xray-node.swap
  if [ -f "$_swapf" ]; then
    if swapon "$_swapf" >/dev/null 2>&1; then
      SWAP_OK=1
      info "已启用原来的虚拟内存文件"
      return 0
    fi
    swapoff "$_swapf" >/dev/null 2>&1
    rm -f "$_swapf"
  fi
  info "正在做 ${_sw}MB 虚拟内存（做完就能装 Hysteria2）…"
  _made=0
  if command -v fallocate >/dev/null 2>&1 && fallocate -l "${_sw}M" "$_swapf" 2>/dev/null; then
    _made=1
  else
    rm -f "$_swapf"
    _i=0
    _made=1
    while [ "$_i" -lt "$_sw" ]; do
      if ! dd if=/dev/zero of="$_swapf" bs=1048576 count=1 seek="$_i" conv=notrunc >/dev/null 2>&1; then
        _made=0
        break
      fi
      _i=$((_i + 1))
      if [ $((_i % 8)) -eq 0 ]; then sync; fi
    done
  fi
  if [ "$_made" != "1" ]; then
    rm -f "$_swapf"
    warn "虚拟内存文件没做成，继续安装"
    return 0
  fi
  chmod 600 "$_swapf" 2>/dev/null
  if mkswap "$_swapf" >/dev/null 2>&1 && swapon "$_swapf" >/dev/null 2>&1; then
    SWAP_OK=1
    _fstab_append_swap
    info "虚拟内存已开启（${_sw}MB），重启后也会自动挂上"
  else
    rm -f "$_swapf"
    warn "这台机器不允许开启虚拟内存（不少 NAT 容器都这样）。继续安装，程序会尽量省着内存用。"
  fi
}

_latest_hysteria_ver() { # 打印 hysteria 最新版本号（不带 v），失败返回非零
  _hv=$(curl -fsSL --max-time 20 "https://api.github.com/repos/apernet/hysteria/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//; s/".*//; s|.*/||; s/^v//')
  case "$_hv" in ''|*[!0-9A-Za-z.-]*) return 1 ;; esac
  printf '%s' "$_hv"
}

_hysteria_local_ver() { # _hysteria_local_ver <二进制>
  "$1" version 2>/dev/null | sed -n 's/^Version:[[:space:]]*v\{0,1\}//p' | head -1 | tr -d ' \r\n'
}

_hy_asset() {
  case "$MACH" in
    amd64) printf '%s' hysteria-linux-amd64 ;;
    arm64) printf '%s' hysteria-linux-arm64 ;;
    armv7) printf '%s' hysteria-linux-arm ;;
    *) return 1 ;;
  esac
}

dl_hysteria() { # 下载官方 Hysteria2。它是静态的小程序，64MB 内存装得下；sing-box 1.14 解压后约 80MB，装不上。
  step "[下载] 获取 Hysteria2 内核…"
  _hy_asset=$(_hy_asset) || die "这个 CPU 架构没有对应的 Hysteria2 程序：$(uname -m)"
  _hy_latest=$(_latest_hysteria_ver) || _hy_latest=""
  if [ "$FORCE_DL" != "1" ] && [ -x "$HY_BIN" ]; then
    _hy_have=$(_hysteria_local_ver "$HY_BIN")
    if [ -n "$_hy_have" ] && { [ -z "$_hy_latest" ] || [ "$_hy_have" = "$_hy_latest" ]; }; then
      info "Hysteria2 已存在，直接用现有的：v${_hy_have}"
      return 0
    fi
  fi
  recover_disk_space
  _hy_free=$(_disk_free_mb /usr/local)
  if [ -z "$_hy_free" ]; then _hy_free=$(_disk_free_mb /); fi
  if [ -n "$_hy_free" ] && [ "$_hy_free" -lt 40 ]; then
    die "磁盘剩余大约 ${_hy_free}MB，装不下 Hysteria2（大约还要 40MB）。1GB 硬盘请先删掉不用的文件再重跑。"
  fi
  rm -f "${HY_BIN}.new"
  _dl_ok=0
  info "尝试下载：${_hy_asset}"
  if gh_api_dl "apernet/hysteria" "$_hy_asset" "${HY_BIN}.new"; then
    _dl_ok=1
  else
    warn "API 路线失败，换 github.com 直链试试…"
    rm -f "${HY_BIN}.new"
    _url="https://github.com/apernet/hysteria/releases/latest/download/${_hy_asset}"
    info "尝试下载：$_url"
    if curl -fSL --progress-bar --connect-timeout 20 --speed-time 30 --speed-limit 1000 --retry 2 --retry-delay 3 -o "${HY_BIN}.new" "$_url"; then
      _dl_ok=1
    fi
  fi
  if [ "$_dl_ok" != "1" ]; then
    rm -f "${HY_BIN}.new"
    die "Hysteria2 下载失败：到 GitHub 的网络不稳定，稍等几分钟后重跑脚本试试"
  fi
  # 小于 1MB 的多半是错误页，不是内核
  _hy_sz=$(wc -c < "${HY_BIN}.new" 2>/dev/null | tr -d ' ')
  if [ -z "$_hy_sz" ] || [ "$_hy_sz" -lt 1000000 ]; then
    rm -f "${HY_BIN}.new"
    die "下载到的 Hysteria2 文件不完整，请重跑脚本"
  fi
  chmod 0755 "${HY_BIN}.new" || { rm -f "${HY_BIN}.new"; die "安装 Hysteria2 失败"; }
  drop_page_cache
  _hy_run=$("${HY_BIN}.new" version 2>&1)
  _hy_rc=$?
  if [ "$_hy_rc" -ne 0 ]; then
    rm -f "${HY_BIN}.new"
    die "下载的 Hysteria2 内核跑不起来（退出码 ${_hy_rc}）。内存大约 ${MEM_MB:-未知}MB。系统说：$(printf '%s' "$_hy_run" | tr '\n' ' ' | cut -c1-300)"
  fi
  mv -f "${HY_BIN}.new" "$HY_BIN"
  mark_our_bin "hysteria"
  _hy_have=$(_hysteria_local_ver "$HY_BIN")
  info "Hysteria2 安装成功：v${_hy_have:-未知}"
}

_ensure_unzip() {
  command -v unzip >/dev/null 2>&1 && return 0
  warn "缺少 unzip，正在安装…"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    _apt_do "正在安装 unzip" 300 -- install -y -qq unzip || true
    unset DEBIAN_FRONTEND
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache unzip >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q unzip >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q unzip >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed unzip >/dev/null 2>&1 || true
  fi
  command -v unzip >/dev/null 2>&1 || die "装不上 unzip，请手动安装 unzip 后重试"
}

dl_xray() { # 下载并安装 Xray 内核；FORCE_DL=1 时即使已存在也强制下载最新版
  step "[下载] 获取 Xray 内核…"
  _ensure_unzip
  case "$MACH" in
    amd64) XARCH="64" ;;
    arm64) XARCH="arm64-v8a" ;;
    armv7) XARCH="arm32-v7a" ;;
  esac
  if [ "$FORCE_DL" != "1" ] && [ -x "$XRAY_BIN" ] && "$XRAY_BIN" version >/dev/null 2>&1; then
    info "Xray 已存在，直接用现有的：$($XRAY_BIN version 2>/dev/null | head -1)"
  else
    DL_DIR=$(pick_dldir) || die "找不到可写的下载目录"
    # 磁盘上已有完整可用的包就直接用（上次下载完但被中断的情况，不用重新下载）；
    # 更新模式（FORCE_DL=1）不走这里，必须拉最新版。
    # 但缓存的包可能是几个月前的旧版本：验一下版本，旧了就重新下，别装个过期内核
    _reuse=0
    if [ "$FORCE_DL" != "1" ] && [ -s "$DL_DIR/xray.zip" ] && unzip -t -q "$DL_DIR/xray.zip" >/dev/null 2>&1; then
      rm -rf "$DL_DIR/xray-ver" && mkdir -p "$DL_DIR/xray-ver"
      if unzip -o -q "$DL_DIR/xray.zip" -d "$DL_DIR/xray-ver" xray 2>/dev/null \
         && [ -x "$DL_DIR/xray-ver/xray" ] \
         && _cached_ver_ok "$DL_DIR/xray-ver/xray" "XTLS/Xray-core"; then
        _reuse=1
        info "安装包已在本地且是最新版，直接使用（跳过下载）"
      else
        info "本地安装包不是最新版，重新下载…"
      fi
      rm -rf "$DL_DIR/xray-ver"
    fi
    if [ "$_reuse" = "0" ]; then
      rm -f "$DL_DIR/xray.zip"
      _xasset="Xray-linux-${XARCH}.zip"
      _dl_ok=0
      # 路线 A：GitHub API（api.github.com 稳，302 跳到 release-assets 下得快）
      info "尝试下载：GitHub API"
      if gh_api_dl "XTLS/Xray-core" "$_xasset" "$DL_DIR/xray.zip"; then
        _dl_ok=1
      else
        warn "API 路线失败，换 github.com 直链试试…"
        rm -f "$DL_DIR/xray.zip"
        # 路线 B：github.com 直链（版本直链优先，/latest/download 兜底）
        _xver=$(_latest_tag "XTLS/Xray-core") || _xver=""
        for _url in \
          ${_xver:+https://github.com/XTLS/Xray-core/releases/download/v${_xver}/Xray-linux-${XARCH}.zip} \
          "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XARCH}.zip" \
        ; do
          [ -z "$_url" ] && continue
          info "尝试下载：$_url"
          if curl -fSL --progress-bar --connect-timeout 20 --speed-time 30 --speed-limit 1000 --retry 2 --retry-delay 3 -o "$DL_DIR/xray.zip" "$_url"; then
            _dl_ok=1
            break
          fi
          warn "这个地址下载失败，换下一个地址试试…"
          rm -f "$DL_DIR/xray.zip"
        done
      fi
      [ "$_dl_ok" -eq 1 ] || die "Xray 下载失败：到 GitHub 的网络不稳定，稍等几分钟后重跑脚本试试"
    fi
    # 完整性校验：包坏了直接报错，不往下装半截文件
    unzip -t -q "$DL_DIR/xray.zip" >/dev/null 2>&1 || die "下载的安装包已损坏，请重跑脚本重新下载"
    rm -rf "$DL_DIR/xray-dl" && mkdir -p "$DL_DIR/xray-dl"
    unzip -o "$DL_DIR/xray.zip" -d "$DL_DIR/xray-dl" xray || die "解压失败"
    [ -s "$DL_DIR/xray-dl/xray" ] || die "解压后没找到 xray 文件"
    # 先装到临时名、验明能跑再原子替换：更新模式下旧内核一直可用，直到新内核确认没问题
    install -m 0755 "$DL_DIR/xray-dl/xray" "${XRAY_BIN}.new" || die "安装 Xray 失败"
    if ! "${XRAY_BIN}.new" version >/dev/null 2>&1; then
      rm -f "${XRAY_BIN}.new"
      die "下载的 Xray 内核跑不起来，安装包可能有问题"
    fi
    mv -f "${XRAY_BIN}.new" "$XRAY_BIN"
    mark_our_bin "xray"
    rm -rf "$DL_DIR"
    info "Xray 安装成功：$($XRAY_BIN version 2>/dev/null | head -1)"
  fi
}

dl_singbox() { # 下载并安装 sing-box 内核；FORCE_DL=1 时即使已存在也强制下载最新版
  step "[下载] 获取 sing-box 内核…"
  if [ "$LOW_MEM" = "1" ]; then
    warn "sing-box 解压后大约 80MB，这台机器大约 ${MEM_MB:-很少}MB 内存，有可能装不上。装不上的话，协议请选 6（Hysteria2）。"
  fi
  if [ "$FORCE_DL" != "1" ] && [ -x "$SB_BIN" ] && "$SB_BIN" version >/dev/null 2>&1; then
    info "sing-box 已存在，直接用现有的：$($SB_BIN version 2>/dev/null | head -1)"
  else
    DL_DIR=$(pick_dldir) || die "找不到可写的下载目录"
    _ver=$(_latest_tag "SagerNet/sing-box") \
      || die "获取 sing-box 最新版本失败，检查服务器能否访问 api.github.com"
    # 磁盘上已有完整可用的包就直接用（上次下载完但被中断的情况，不用重新下载）；
    # 更新模式（FORCE_DL=1）不走这里，必须拉最新版。
    # 但缓存的包可能是几个月前的旧版本：验一下版本，旧了就重新下，别装个过期内核
    _reuse=0
    if [ "$FORCE_DL" != "1" ] && [ -s "$DL_DIR/sb.tar.gz" ] && tar tzf "$DL_DIR/sb.tar.gz" >/dev/null 2>&1; then
      rm -rf "$DL_DIR/sb-ver" && mkdir -p "$DL_DIR/sb-ver"
      _sb_ver_inner=$(tar tzf "$DL_DIR/sb.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)
      if [ -n "$_sb_ver_inner" ] \
         && tar xzf "$DL_DIR/sb.tar.gz" -C "$DL_DIR/sb-ver" 2>/dev/null \
         && [ -x "$DL_DIR/sb-ver/${_sb_ver_inner}/sing-box" ] \
         && _cached_ver_ok "$DL_DIR/sb-ver/${_sb_ver_inner}/sing-box" "SagerNet/sing-box" "$_ver"; then
        _reuse=1
        info "安装包已在本地且是最新版，直接使用（跳过下载）"
      else
        info "本地安装包不是最新版，重新下载…"
      fi
      rm -rf "$DL_DIR/sb-ver"
    fi
    if [ "$_reuse" = "0" ]; then
      rm -f "$DL_DIR/sb.tar.gz"
      _dl_ok=0
      # 候选包名：Alpine 先 musl 再 generic；其它系统先 generic 再 glibc。
      # generic 是官方长期提供的传统包，兼容性最稳；显式 libc 后缀包作兜底
      # （防官方某天改名或下掉某一版）
      if [ -f /etc/alpine-release ]; then
        _sb_cands="sing-box-${_ver}-linux-${MACH}-musl.tar.gz sing-box-${_ver}-linux-${MACH}.tar.gz"
      else
        _sb_cands="sing-box-${_ver}-linux-${MACH}.tar.gz sing-box-${_ver}-linux-${MACH}-glibc.tar.gz"
      fi
      for _cand in $_sb_cands; do
        info "尝试下载：${_cand}"
        # 路线 A：GitHub API（api.github.com 稳，302 跳到 release-assets 下得快）
        if gh_api_dl "SagerNet/sing-box" "$_cand" "$DL_DIR/sb.tar.gz"; then
          _dl_ok=1
          break
        fi
        warn "API 路线失败，换 github.com 直链试试…"
        rm -f "$DL_DIR/sb.tar.gz"
        # 路线 B：github.com 版本直链兜底
        _url="https://github.com/SagerNet/sing-box/releases/download/v${_ver}/${_cand}"
        if curl -fSL --progress-bar --connect-timeout 20 --speed-time 30 --speed-limit 1000 --retry 2 --retry-delay 3 -o "$DL_DIR/sb.tar.gz" "$_url"; then
          _dl_ok=1
          break
        fi
        warn "这个包名下载失败，换下一个包名试试…"
        rm -f "$DL_DIR/sb.tar.gz"
      done
      [ "$_dl_ok" -eq 1 ] || die "sing-box 下载失败：到 GitHub 的网络不稳定，稍等几分钟后重跑脚本试试"
    fi
    # 完整性校验：包坏了直接报错，不往下装半截文件
    tar tzf "$DL_DIR/sb.tar.gz" >/dev/null 2>&1 || die "下载的安装包已损坏，请重跑脚本重新下载"
    rm -rf "$DL_DIR/sb-dl" && mkdir -p "$DL_DIR/sb-dl"
    tar xzf "$DL_DIR/sb.tar.gz" -C "$DL_DIR/sb-dl" || die "解压失败"
    # 包内顶层目录名跟包名走（不同候选包名目录名不同），动态探测，不写死
    _sb_inner=$(tar tzf "$DL_DIR/sb.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)
    [ -n "$_sb_inner" ] && [ -s "$DL_DIR/sb-dl/${_sb_inner}/sing-box" ] \
      || die "解压后没找到 sing-box 文件"
    # 先装到临时名、验明能跑再原子替换：更新模式下旧内核一直可用，直到新内核确认没问题
    install -m 0755 "$DL_DIR/sb-dl/${_sb_inner}/sing-box" "${SB_BIN}.new" || die "安装 sing-box 失败"
    drop_page_cache
    _sb_run=$("${SB_BIN}.new" version 2>&1)
    if [ $? -ne 0 ]; then
      rm -f "${SB_BIN}.new"
      rm -rf "$DL_DIR"
      die "下载的 sing-box 内核跑不起来。内存大约 ${MEM_MB:-未知}MB。系统说：$(printf '%s' "$_sb_run" | tr '\n' ' ' | cut -c1-300)"
    fi
    mv -f "${SB_BIN}.new" "$SB_BIN"
    mark_our_bin "sing-box"
    rm -rf "$DL_DIR"
    info "sing-box 安装成功：$($SB_BIN version 2>/dev/null | head -1)"
  fi
}

# ---------- 1. 必须是 root ----------
if [ "$(id -u)" -ne 0 ]; then
  die "请用 root 用户运行（root 下直接运行，或在命令前加 sudo）"
fi
umask 077
# 旧版本可能把节点链接和密码写成全机可读；升级时也一并收紧。
for _sec_dir in /etc/xray-node /etc/xray-node/nodes /etc/xray-node/nodes/*/; do
  [ -d "$_sec_dir" ] && chmod 700 "$_sec_dir"
done
for _sec_file in /etc/xray-node/nodes/*/config.json /etc/xray-node/nodes/*/node.txt \
  /etc/xray-node/nodes/*/fw_info /etc/xray-node/nodes/*/core \
  /etc/xray-node/nodes/*/key.pem /etc/xray-node/nodes/*/cert.pem \
  /etc/xray-node/our_bins /etc/xray-node/node.txt /etc/xray-node/core /etc/xray-node/fw_info; do
  [ -f "$_sec_file" ] && chmod 600 "$_sec_file"
done

printf "\n${BOLD}==============================================${NC}\n"
printf "${BOLD}   Xray 节点一键安装（小白版）${NC}\n"
printf "${BOLD}==============================================${NC}\n"
printf "全程中文提问，看不懂就一路回车用默认。\n"

# ---------- 2b. 架构与路径（更新模式也要用，提前确定） ----------
mkdir -p /usr/local/bin 2>/dev/null  # 极简系统可能连这个目录都没有
XRAY_BIN="/usr/local/bin/xray"
SB_BIN="/usr/local/bin/sing-box"
HY_BIN="/usr/local/bin/hysteria"
LOW_MEM=0
SWAP_OK=0
MEM_MB=""
SVC_UNIT=""
case "$(uname -m)" in
  x86_64|amd64) MACH="amd64" ;;
  aarch64|arm64) MACH="arm64" ;;
  armv7l|armv7) MACH="armv7" ;;
  *) die "不支持的 CPU 架构：$(uname -m)" ;;
esac

# 64MB NAT 要在装任何大程序之前做完：放开内存申请，并尽量加一块虚拟内存
prepare_low_memory

# 上次安装如果在写出 node.txt 之前失败，目录和服务会留下，但 shanjiedian 看不到。
# 服务开着 Restart=on-failure 就会一直占端口；64MB 机器上还会把后来的更新拖进回滚。
_drop_partial_node() {
  _dp_id="$1"
  _dp_dir="$2"
  [ -n "$_dp_id" ] && [ -n "$_dp_dir" ] && [ -d "$_dp_dir" ] || return 0
  [ -f "$_dp_dir/node.txt" ] && return 0
  case "$_dp_id" in ''|*[!0-9]*) return 0 ;; esac
  _dp_core=$(tr -d ' \r\n' < "$_dp_dir/core" 2>/dev/null)
  _dp_sd=${XRAY_SYSTEMD_RUN:-/run/systemd/system}
  if command -v systemctl >/dev/null 2>&1 && [ -d "$_dp_sd" ]; then
    case "$_dp_core" in
      sing-box) _dp_units="singbox-node@${_dp_id}" ;;
      hysteria) _dp_units="hysteria-node@${_dp_id}" ;;
      xray) _dp_units="xray-node@${_dp_id}" ;;
      *) _dp_units="xray-node@${_dp_id} singbox-node@${_dp_id} hysteria-node@${_dp_id}" ;;
    esac
    for _dp_unit in $_dp_units; do
      systemctl stop "$_dp_unit" >/dev/null 2>&1
      systemctl disable "$_dp_unit" >/dev/null 2>&1
      systemctl reset-failed "$_dp_unit" >/dev/null 2>&1
    done
  fi
  if command -v rc-service >/dev/null 2>&1; then
    rc-service "xray-node-${_dp_id}" stop >/dev/null 2>&1
    rc-update del "xray-node-${_dp_id}" default >/dev/null 2>&1
    rm -f "/etc/init.d/xray-node-${_dp_id}"
  fi
  pkill -f "${_dp_dir%/}/config.json" >/dev/null 2>&1
  pkill -f "${_dp_dir%/}/config.yaml" >/dev/null 2>&1
  rm -rf "$_dp_dir"
}

_reap_partial_nodes() {
  _nodes_root=${XRAY_NODES_DIR:-/etc/xray-node/nodes}
  for _rp in "$_nodes_root"/*/; do
    [ -d "$_rp" ] || continue
    [ -f "${_rp}node.txt" ] && continue
    _reap_id=$(basename "$_rp")
    _drop_partial_node "$_reap_id" "$_rp"
    [ -d "$_rp" ] || warn "已清掉上次没装完的节点 ${_reap_id}"
  done
  rmdir "$_nodes_root" 2>/dev/null || true
}

_abort_partial_node() {
  [ -n "${NODE_DIR:-}" ] && [ -n "${NODE_ID:-}" ] || return 0
  [ -d "$NODE_DIR" ] && [ ! -f "$NODE_DIR/node.txt" ] || return 0
  _drop_partial_node "$NODE_ID" "$NODE_DIR"
  rmdir "${XRAY_NODES_DIR:-/etc/xray-node/nodes}" 2>/dev/null || true
}

_reap_partial_nodes

# ---------- 2c. 老版本迁移：单节点布局 -> 多节点布局 ----------
# 老版本只有一个节点（/etc/xray-node/node.txt + xray/sing-box 单服务）。
# 转为"每个节点独立目录 + 独立服务"，旧节点配置原样保留；
# 先停旧服务、再起新服务，中间只断几秒。
if [ -f /etc/xray-node/node.txt ] && [ ! -d /etc/xray-node/nodes ]; then
  step "[迁移] 检测到老版本单节点，正在转为多节点管理（旧节点保留）…"
  _m_core=$(tr -d ' \r\n' < /etc/xray-node/core 2>/dev/null)
  case "$_m_core" in xray|sing-box) ;; *) _m_core="xray" ;; esac
  if [ "$_m_core" = "xray" ]; then
    _m_cfg=/usr/local/etc/xray/config.json
  else
    _m_cfg=/usr/local/etc/sing-box/config.json
  fi
  if [ ! -f "$_m_cfg" ]; then
    die "找不到老节点的配置文件（$_m_cfg），旧节点资料已保留；请先检查旧安装再重试"
  else
    _m_port=$(sed -n 's/^端口: //p' /etc/xray-node/node.txt | head -1)
    _m_proto=tcp
    case "$(sed -n 's/^协议: //p' /etc/xray-node/node.txt | head -1)" in
      hy2|hysteria2|tuic|TUIC) _m_proto=udp ;;
    esac
    if [ -f /etc/xray-node/fw_info ]; then
      read -r _m_fw_port _m_fw_proto _m_rest < /etc/xray-node/fw_info
      case "$_m_fw_port" in *[!0-9]*|'') ;; *)
        _m_port=$_m_fw_port
        case "$_m_fw_proto" in tcp|udp) _m_proto=$_m_fw_proto ;; esac
        ;;
      esac
    fi
    _m_manager=""
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      _m_manager=systemd
    elif command -v rc-service >/dev/null 2>&1; then
      _m_manager=openrc
    fi
    case "$_m_port" in *[!0-9]*|'') _m_port="" ;; esac
    if [ -z "$_m_port" ] || [ "$_m_port" -lt 1 ] || [ "$_m_port" -gt 65535 ] ||
       [ -z "$_m_manager" ] ||
       { ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1 &&
         [ ! -r /proc/net/tcp ] && [ ! -r /proc/net/udp ]; }; then
      die "无法可靠核验老节点的端口或服务管理方式，旧节点保持原状；请检查后再重试"
    else
      # 先复制；只有新服务确认可用后才删除旧配置和旧服务。
      mkdir -p /etc/xray-node/nodes/1 || die "无法创建新节点目录，旧节点未受影响"
      cp -p "$_m_cfg" /etc/xray-node/nodes/1/config.json &&
        cp -p /etc/xray-node/node.txt /etc/xray-node/nodes/1/node.txt ||
        { rm -rf /etc/xray-node/nodes/1; rmdir /etc/xray-node/nodes 2>/dev/null; die "复制旧节点资料失败，旧节点未受影响"; }
      [ ! -f /etc/xray-node/fw_info ] || cp -p /etc/xray-node/fw_info /etc/xray-node/nodes/1/fw_info ||
        { rm -rf /etc/xray-node/nodes/1; rmdir /etc/xray-node/nodes 2>/dev/null; die "复制旧防火墙记录失败，旧节点未受影响"; }
      printf '%s\n' "$_m_core" > /etc/xray-node/nodes/1/core ||
        { rm -rf /etc/xray-node/nodes/1; rmdir /etc/xray-node/nodes 2>/dev/null; die "写入内核标记失败，旧节点未受影响"; }
      if [ "$_m_manager" = systemd ]; then
        systemctl stop "$_m_core" >/dev/null 2>&1
      else
        rc-service "$_m_core" stop >/dev/null 2>&1
      fi
      pkill -f "$_m_cfg" >/dev/null 2>&1
      sleep 1
      _svc_install 1
      _m_new_ok=1
      if [ "$_m_manager" = systemd ]; then
        case "$_m_core" in sing-box) _m_new_unit=singbox-node@1 ;; *) _m_new_unit=xray-node@1 ;; esac
        systemctl is-active --quiet "$_m_new_unit" || _m_new_ok=0
      else
        rc-service xray-node-1 status >/dev/null 2>&1 || _m_new_ok=0
      fi
      wait_for_port "$_m_port" "$_m_proto" 15 || _m_new_ok=0
      if [ "$_m_new_ok" = 1 ]; then
        if [ "$_m_manager" = systemd ]; then
          systemctl disable "$_m_core" >/dev/null 2>&1
          rm -f "/etc/systemd/system/${_m_core}.service"
          systemctl daemon-reload >/dev/null 2>&1
        else
          rc-update del "$_m_core" default >/dev/null 2>&1
          rm -f "/etc/init.d/${_m_core}"
        fi
        rm -f "$_m_cfg" /etc/xray-node/node.txt /etc/xray-node/fw_info /etc/xray-node/core
        rmdir /usr/local/etc/xray /usr/local/etc/sing-box 2>/dev/null
        info "迁移完成：老节点已转为节点 1，端口 $_m_port/$_m_proto 监听正常"
      else
        if [ "$_m_manager" = systemd ]; then
          systemctl stop "$_m_new_unit" >/dev/null 2>&1
          systemctl disable "$_m_new_unit" >/dev/null 2>&1
          systemctl start "$_m_core" >/dev/null 2>&1
        else
          rc-service xray-node-1 stop >/dev/null 2>&1
          rc-update del xray-node-1 default >/dev/null 2>&1
          rm -f /etc/init.d/xray-node-1
          rc-service "$_m_core" start >/dev/null 2>&1
        fi
        rm -rf /etc/xray-node/nodes/1
        rmdir /etc/xray-node/nodes 2>/dev/null
        die "新服务未能正常监听，已尝试恢复旧节点；请检查旧服务状态后再重试"
      fi
    fi
  fi
fi

# 已经装过节点：更新（默认）/ 添加新节点 / 节点管理 / 取消
# 注意：选 2 添加新节点不会动旧节点，旧节点继续用；想删节点选 3 或直接输 shanjiedian
UPDATE_MODE=0
FORCE_DL=0
_NODE_COUNT=0
if [ -d /etc/xray-node/nodes ]; then
  for _nd in /etc/xray-node/nodes/*/; do
    [ -f "${_nd}node.txt" ] && _NODE_COUNT=$((_NODE_COUNT + 1))
  done
fi
if [ "$_NODE_COUNT" -gt 0 ]; then
  printf "\n检测到这台机器已经装了 %s 个节点。\n" "$_NODE_COUNT"
  printf "  1) 更新内核（推荐：所有节点配置不变，只把 Xray/sing-box/Hysteria2 内核升到最新版）\n"
  printf "  2) 添加新节点（再搭一个，旧节点不受影响、继续用）\n"
  printf "  3) 节点管理（查看所有节点、删除某个节点）\n"
  printf "  4) 取消，什么都不做\n"
  ask "请选择" "1" _um
  case "$_um" in
    2) info "进入添加新节点流程（旧节点不受影响）" ;;
    3) write_helper_cmds; sh /usr/local/bin/shanjiedian; exit 0 ;;
    4|n|N|no|NO) echo "已取消"; exit 0 ;;
    *) UPDATE_MODE=1 ;;
  esac
fi

# 旧版小内存模式保存了整张 iptables 快照。更新或加节点时改为只恢复本脚本的规则。
if [ -f /etc/xray-node/rules.v4 ] || [ -f /etc/xray-node/rules.v6 ]; then
  _save_fw_light || warn "旧版防火墙恢复服务迁移失败，重启前请检查防火墙规则"
fi

# 新节点编号：已有最大编号 + 1（删掉的编号不重用，避免和以前的节点搞混）
NODE_ID=1
for _nd in /etc/xray-node/nodes/*/; do
  [ -d "$_nd" ] || continue
  _nn=$(basename "$_nd")
  case "$_nn" in ''|*[!0-9]*) continue ;; esac
  [ "$_nn" -ge "$NODE_ID" ] && NODE_ID=$((_nn + 1))
done
NODE_DIR=/etc/xray-node/nodes/$NODE_ID
# 注意：目录在这里先不建，留到更新模式之后——更新模式不需要新目录，
# 提前建会在每次更新时留下一个空编号目录，节点编号越跳越大

# ---------- 2. 装依赖（缺啥装啥，都有就直接跳过） ----------
step "[准备] 检查系统工具…"
_dep_log="/tmp/xray-dep-apt.log"
# _apt_do <描述> <单次超时秒> -- <apt-get 参数…>
# 刚开机的机器常被系统自动更新占着 dpkg 锁：不等锁就硬装会白白超时失败。
# 这里检测到锁就等 20 秒重试并报进度，而不是静默卡死。
# 注意：这个函数定义在 if 外面——后面存 iptables 规则时也要用它装 iptables-persistent，
# 放里面会导致"依赖本来就齐"时函数根本没定义、调用直接报错。
_apt_do() {
  _ad="$1"; _ato="$2"; shift 2
  [ "$1" = "--" ] && shift
  _an=0
  while [ "$_an" -lt 10 ]; do
    printf "%s…\n" "$_ad"
    # DPkg::Lock::Timeout=120：锁被系统自动更新占着时，120 秒拿不到就快速失败，
    # 走下面的排队重试。不设的话老版本 apt 会静默等锁（-qq 还把等待提示吞了），
    # 单次尝试卡满整个超时、重试逻辑还检测不到——看着就像"卡住不动"。
    # 心跳：apt 的输出被吞掉了，单次尝试最长 $_ato 秒；每 30 秒报一次"还在装"，
    # 免得小白以为卡死。
    ( timeout "$_ato" apt-get -o DPkg::Lock::Timeout=120 "$@" >"$_dep_log" 2>&1
      echo "$?" >"$_dep_log.rc" ) &
    _apt_pid=$!
    _apt_waited=0
    while kill -0 "$_apt_pid" 2>/dev/null; do
      sleep 2
      _apt_waited=$((_apt_waited + 2))
      if kill -0 "$_apt_pid" 2>/dev/null && [ "$((_apt_waited % 30))" = "0" ]; then
        printf "还在安装中，已等待 %s 秒（机器慢时会久一点，正常）…\n" "$_apt_waited"
      fi
    done
    wait "$_apt_pid" 2>/dev/null
    _apt_rc=$(cat "$_dep_log.rc" 2>/dev/null); rm -f "$_dep_log.rc"
    if [ "$_apt_rc" = "0" ]; then return 0; fi
    # 超时杀在 dpkg 中间，或下一次 apt 已报 interrupted：先修复再重试。
    # 这条路径也必须计入 _an，否则会在反复 interrupted 时死循环。
    if [ "$_apt_rc" = "124" ] || grep -qi "dpkg was interrupted" "$_dep_log" 2>/dev/null; then
      _an=$((_an + 1))
      printf "检测到安装被打断或超时，正在修复（%s/10）…\n" "$_an"
      timeout 120 dpkg --configure -a >"$_dep_log" 2>&1 || true
      continue
    fi
    if grep -qi "could not get lock\|unable to lock\|waiting for.*lock" "$_dep_log" 2>/dev/null; then
      _an=$((_an + 1))
      printf "系统自动更新正占着软件源，20 秒后重试（%s/10）…\n" "$_an"
      sleep 20
    else
      return 1
    fi
  done
  return 1
}
# _dep_fail：装失败时把吞掉的报错吐出来，而不是只留一句"装不上"
_dep_fail() {
  warn "这一步没成功，最后看到的报错："
  tail -n 5 "$_dep_log" 2>/dev/null | sed 's/^/  /'
}
# unzip 只有 Xray 的 zip 包才要。小内存机器上为了 Hysteria2 先 apt 装 unzip，
# 很容易在选协议之前就把内存吃光。缺 unzip 时留到下载 Xray 再装。
_need_install=0
command -v curl >/dev/null 2>&1 || _need_install=1
if [ "$_need_install" -eq 1 ]; then
  printf "缺少 curl，正在自动安装（每一步都有进度提示，不会卡住不动）…\n"
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    _apt_do "正在更新软件源" 60 -- update -qq \
      || warn "软件源更新失败，用已有索引继续装（多数情况不影响）"
    _apt_do "正在安装 curl" 300 -- install -y -qq curl ca-certificates \
      || _dep_fail
  elif command -v apk >/dev/null 2>&1; then
    printf "正在安装 curl…\n"
    timeout 300 apk add --no-cache curl ca-certificates >"$_dep_log" 2>&1 || _dep_fail
  elif command -v dnf >/dev/null 2>&1; then
    printf "正在安装 curl…\n"
    timeout 300 dnf install -y -q curl ca-certificates >"$_dep_log" 2>&1 || _dep_fail
  elif command -v yum >/dev/null 2>&1; then
    printf "正在安装 curl…\n"
    timeout 300 yum install -y -q curl ca-certificates >"$_dep_log" 2>&1 || _dep_fail
  elif command -v pacman >/dev/null 2>&1; then
    printf "正在安装 curl…\n"
    timeout 300 pacman -Sy --noconfirm --needed curl ca-certificates >"$_dep_log" 2>&1 || _dep_fail
  fi
  rm -f "$_dep_log"
  unset DEBIAN_FRONTEND
else
  info "curl 已有，直接跳过安装"
fi
command -v curl >/dev/null 2>&1 || die "装不上 curl，请手动安装 curl 后重试"
info "系统工具就绪"

# ---------- U. 更新模式：只升级内核，节点配置原样保留 ----------
# 重跑一键命令选"1"进到这里：不问问题、不改配置，只把各节点用的内核升到最新版。
if [ "$UPDATE_MODE" = "1" ]; then
  step "[更新] 检查已安装的内核版本…"
  # 收集所有节点用到的内核（去重）
  _u_cores=""
  for _ud in /etc/xray-node/nodes/*/; do
    [ -f "${_ud}core" ] || continue
    _uc=$(tr -d ' \r\n' < "${_ud}core" 2>/dev/null)
    case "$_uc" in
      xray|sing-box|hysteria)
        case " $_u_cores " in *" $_uc "*) ;; *) _u_cores="$_u_cores $_uc" ;; esac
        ;;
    esac
  done
  if [ -z "$_u_cores" ]; then
    warn "找不到已安装节点用的内核信息，改走添加新节点流程。"
    UPDATE_MODE=0
  else
    _u_any_fail=0
    for _ucore in $_u_cores; do
      # 每个内核独立处理：一个失败不影响另一个（子 shell 里 die 只退出子 shell）
      (
      if [ "$_ucore" = "xray" ]; then
        _u_repo="XTLS/Xray-core"; _u_bin="$XRAY_BIN"
      elif [ "$_ucore" = "hysteria" ]; then
        _u_repo="apernet/hysteria"; _u_bin="$HY_BIN"
      else
        _u_repo="SagerNet/sing-box"; _u_bin="$SB_BIN"
      fi
      # 首次安装时会复用机器上已有的内核；那可能属于其他服务，不能覆盖升级。
      if ! grep -qx "$_ucore" /etc/xray-node/our_bins 2>/dev/null; then
        warn "$_ucore 是机器上原有的内核，跳过升级，避免影响其他服务"
        exit 0
      fi
      _u_inst=""
      if [ -x "$_u_bin" ]; then
        if [ "$_ucore" = "hysteria" ]; then
          _u_inst=$(_hysteria_local_ver "$_u_bin")
        else
          _u_inst=$(_ver_num "$("$_u_bin" version 2>/dev/null | head -1)")
        fi
      fi
      if [ "$_ucore" = "hysteria" ]; then
        _u_latest=$(_latest_hysteria_ver) || _u_latest=""
      else
        _u_latest=$(_latest_tag "$_u_repo") || _u_latest=""
      fi
      if [ -z "$_u_latest" ]; then
        warn "连不上 api.github.com，$_ucore 检查更新失败，跳过（节点不受影响，继续正常使用）。"
        exit 0
      fi
      if [ -n "$_u_inst" ] && [ "$_u_inst" = "$_u_latest" ]; then
        info "$_ucore 已经是最新版（v${_u_inst}），无需更新。"
        exit 0
      fi
      if [ -n "$_u_inst" ]; then
        info "$_ucore 当前版本 v${_u_inst}，最新版本 v${_u_latest}，开始升级…"
      else
        warn "$_ucore 内核文件丢失或已损坏，直接下载最新版 v${_u_latest}（节点配置保留）。"
      fi
      # 每次升级用独立备份路径；上次失败留下的备份不会被覆盖。
      _u_backup=""
      if [ -x "$_u_bin" ]; then
        _u_backup=$(mktemp "${_u_bin}.bak.XXXXXX") ||
          die "$_ucore 无法创建备份文件，升级已取消"
        cp -a "$_u_bin" "$_u_backup" ||
          { rm -f "$_u_backup"; die "$_ucore 旧内核备份失败，升级已取消"; }
        info "旧内核备份：$_u_backup"
      fi
      FORCE_DL=1
      if [ "$_ucore" = "xray" ]; then dl_xray
      elif [ "$_ucore" = "hysteria" ]; then dl_hysteria
      else dl_singbox
      fi
      FORCE_DL=0
      # 重启所有用这个内核的节点（子 shell 里改 FORCE_DL 不影响外面）
      step "[更新] 重启 $_ucore 的节点服务…"
      _u_failed=""
      for _ud2 in /etc/xray-node/nodes/*/; do
        [ -f "${_ud2}core" ] || continue
        _uc2=$(tr -d ' \r\n' < "${_ud2}core" 2>/dev/null)
        [ "$_uc2" = "$_ucore" ] || continue
        _u_id=$(basename "$_ud2")
        _svc_restart "$_u_id"
        # 读出该节点端口，硬检查真的在监听
        _u_port=""; _u_proto="tcp"
        if _u_pp=$(_node_port "$_u_id"); then set -- $_u_pp; _u_port="$1"; _u_proto="$2"; fi
        if [ -n "$_u_port" ] && wait_for_port "$_u_port" "$_u_proto" 15; then
          info "节点 $_u_id 升级成功：端口 $_u_port/$_u_proto 监听正常，配置未变"
        else
          warn "节点 $_u_id 更新后端口没监听（端口：${_u_port:-未知}）"
          _u_failed="$_u_failed $_u_id"
        fi
      done
      if [ -n "$_u_failed" ]; then
        _u_rb_bad=""
        if [ -n "$_u_backup" ] && [ -f "$_u_backup" ]; then
          warn "新内核启动后有节点端口没监听，正在回滚到旧版本…"
          # 不能 cp 到正在运行的可执行文件：其他节点可能正运行新版，会触发 ETXTBSY。
          # 在同一目录先写临时文件，再原子替换路径，并保留备份直到全部恢复成功。
          rm -f "${_u_bin}.rollback"
          cp -a "$_u_backup" "${_u_bin}.rollback" ||
            die "回滚文件写入失败，备份仍在 $_u_backup，请手动恢复"
          mv -f "${_u_bin}.rollback" "$_u_bin" ||
            die "回滚替换失败，备份仍在 $_u_backup，请手动恢复"
          # 所有共享此内核的节点都要切回旧版本，不能只重启刚才失败的节点。
          for _rd in /etc/xray-node/nodes/*/; do
            [ -f "${_rd}core" ] || continue
            [ "$(tr -d ' \r\n' < "${_rd}core" 2>/dev/null)" = "$_ucore" ] || continue
            _rid=$(basename "$_rd")
            _svc_restart "$_rid"
            sleep 1
            _r_port=""; _r_proto="tcp"
            if _r_pp=$(_node_port "$_rid"); then set -- $_r_pp; _r_port="$1"; _r_proto="$2"; fi
            if [ -n "$_r_port" ] && wait_for_port "$_r_port" "$_r_proto" 15; then
              info "节点 $_rid 已回滚到旧版本，恢复正常"
            else
              _u_rb_bad="$_u_rb_bad $_rid"
              warn "节点 $_rid 回滚后端口仍未监听，请手动检查该节点的服务状态"
            fi
          done
        else
          _u_rb_bad="$_u_failed"
          warn "没有旧内核备份，无法回滚，请手动检查节点${_u_failed}的服务状态"
        fi
        if [ -z "$_u_rb_bad" ]; then
          rm -f "$_u_backup"
          die "$_ucore 新版本在这台机器上跑不起来，已回滚到旧版本，节点不受影响"
        else
          die "$_ucore 新版本跑不起来，且节点${_u_rb_bad}仍未恢复监听；备份路径：${_u_backup:-无}，请手动检查"
        fi
      fi
      [ -z "$_u_backup" ] || rm -f "$_u_backup"
      info "$_ucore 升级完成"
      ) || _u_any_fail=1
    done
    # 刷新 jiedian / shanjiedian（脚本可能修过它们）
    write_helper_cmds
    info "jiedian / shanjiedian 命令已同步为最新版"
    printf "\n"
    sh /usr/local/bin/jiedian
    if [ "$_u_any_fail" = "1" ]; then
      printf "\n${YELLOW}${BOLD}更新结束：部分内核更新失败（上面有说明），其它节点不受影响。${NC}\n"
      exit 1
    else
      printf "\n${GREEN}${BOLD}更新完成！${NC}节点链接、端口、密码都没变，直接继续用。\n"
    fi
    exit 0
  fi
fi
# 更新模式上面已经退出；新节点目录在完成输入和下载后再建，避免失败时留下空编号。

# ---------- 3. 问：IPv4 还是 IPv6 ----------
step "[1/4] 节点里填你服务器的哪个公网地址？"
printf "  1) IPv4 地址（服务器有公网 IPv4 就选这个，大多数情况都是）\n"
printf "  2) IPv6 地址（只有纯 IPv6、没有 IPv4 的服务器才选这个）\n"
printf "不知道选哪个就回车用默认 1。\n"
ask "请选择" "1" _ipver
case "$_ipver" in
  2) IPVER=6 ;;
  *) IPVER=4 ;;
esac
printf "正在检测公网 IP…\n"
if ! SERVER_IP=$(get_ip "$IPVER"); then
  warn "自动检测 IP 失败，请手动输入。"
  _iptry=0
  SERVER_IP=""
  while [ "$_iptry" -lt 3 ]; do
    _iptry=$((_iptry + 1))
    ask "请输入你的服务器公网 IPv$IPVER 地址" "" SERVER_IP
    if [ -z "$SERVER_IP" ]; then
      warn "IP 不能为空"
    elif _valid_ip "$IPVER" "$SERVER_IP"; then
      break
    else
      warn "「$SERVER_IP」不像个 IPv$IPVER 地址，检查一下再输"
    fi
    SERVER_IP=""
  done
  [ -z "$SERVER_IP" ] && die "没有 IP 装不了，先去查一下你的服务器 IP 再来"
fi
info "服务器 IP：$SERVER_IP"
# 用户经常把 IPv6 连方括号一起粘贴。这里先剥掉，下面再加一层，避免链成 [[地址]]。
case "$SERVER_IP" in
  \[*\]) SERVER_IP=${SERVER_IP#\[}; SERVER_IP=${SERVER_IP%\]} ;;
esac
# 按实际地址格式决定链接里是否加方括号（IPv6 必须加 []）
case "$SERVER_IP" in
  *:*) LINK_IP="[$SERVER_IP]" ;;
  *)   LINK_IP="$SERVER_IP" ;;
esac

# ---------- 4. 问：协议 ----------
step "[2/4] 选一个协议"
printf "  1) VLESS + REALITY + Vision（推荐，最难被识别）\n"
printf "  2) VMess + WebSocket（兼容性好，老客户端也支持）\n"
printf "  3) Trojan + REALITY（和 1 类似，换种协议）\n"
printf "  4) Shadowsocks（最简单，速度不错）\n"
printf "  5) AnyTLS + REALITY（新协议，表现不错）\n"
printf "  6) Hysteria2（UDP，速度快，弱网表现好）\n"
printf "  7) TUIC（UDP，低延迟）\n"
ask "请选择" "1" _proto
case "$_proto" in
  2) PROTO="vmess" ;;
  3) PROTO="trojan" ;;
  4) PROTO="ss" ;;
  5) PROTO="anytls" ;;
  6) PROTO="hy2" ;;
  7) PROTO="tuic" ;;
  *) PROTO="vless" ;;
esac
# 1-4 用 Xray。AnyTLS / TUIC 用 sing-box。
# Hysteria2 用官方 hysteria：sing-box 1.14 解压后约 80MB，64MB 内存的 NAT 会在下载或启动时被撑死。
case "$PROTO" in
  hy2) CORE="hysteria" ;;
  anytls|tuic) CORE="sing-box" ;;
  *) CORE="xray" ;;
esac

# ---------- 5. 问：端口 ----------
step "[3/4] 节点用哪个端口？"
case "$PROTO" in
  hy2|tuic) _PORT_PROTO=udp ;;
  ss) _PORT_PROTO=both ;;
  *) _PORT_PROTO=tcp ;;
esac
_DEF_PORT=$(rand_port "$_PORT_PROTO") || die "找不到空闲端口，请检查这台机器的端口占用情况"
ask "请输入端口（1-65535）" "$_DEF_PORT" PORT
case "$PORT" in
  ''|*[!0-9]*) warn "端口不是数字，用默认 $_DEF_PORT"; PORT="$_DEF_PORT" ;;
esac
# 去掉前导 0（比如 08080）：JSON 数字不允许前导 0，留着后面配置文件校验过不了
PORT=$(printf "%s" "$PORT" | sed 's/^0*//')
[ -z "$PORT" ] && PORT=0
if [ "${#PORT}" -gt 5 ] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  warn "端口超出范围，用默认 $_DEF_PORT"; PORT="$_DEF_PORT"
fi
case "$_PORT_PROTO" in
  tcp|both) port_in_use "$PORT" tcp && die "端口 $PORT/TCP 已被其他程序占用，请重跑脚本换一个端口" ;;
esac
case "$_PORT_PROTO" in
  udp|both) port_in_use "$PORT" udp && die "端口 $PORT/UDP 已被其他程序占用，请重跑脚本换一个端口" ;;
esac
info "端口：$PORT"
printf "如果是 NAT VPS，且服务商分配的公网端口与上面的端口不同，请填公网端口；普通 VPS 直接回车。\n"
ask "公网映射端口" "$PORT" LINK_PORT
case "$LINK_PORT" in
  ''|*[!0-9]*) die "公网映射端口必须是 1-65535 的数字" ;;
esac
LINK_PORT=$(printf '%s' "$LINK_PORT" | sed 's/^0*//')
[ -n "$LINK_PORT" ] && [ "${#LINK_PORT}" -le 5 ] \
  && [ "$LINK_PORT" -ge 1 ] && [ "$LINK_PORT" -le 65535 ] \
  || die "公网映射端口必须是 1-65535 的数字"
if [ "$LINK_PORT" != "$PORT" ]; then
  info "节点链接会使用公网端口 $LINK_PORT；请确认服务商已把它映射到本机 $PORT"
fi

# ---------- 6. REALITY 伪装域名 ----------
NEED_REALITY=0
case "$PROTO" in vless|trojan|anytls) NEED_REALITY=1 ;; esac
if [ "$NEED_REALITY" -eq 1 ]; then
  step "[4/4] REALITY 伪装成哪个网站？"
  printf "  1) www.samsung.com（三星官网，零干扰，最稳）\n"
  printf "  2) www.cisco.com（思科官网，TLS 极稳）\n"
  printf "  3) www.apple.com（苹果官网，社区验证最多，推荐）\n"
  printf "  4) itunes.apple.com（苹果音乐服务）\n"
  printf "  5) www.python.org（Python 官网，技术站小众）\n"
  printf "  6) m.media-amazon.com（亚马逊图片站）\n"
  printf "  7) images-na.ssl-images-amazon.com（亚马逊图片 CDN）\n"
  printf "  8) download-installer.cdn.mozilla.net（火狐下载站）\n"
  printf "  9) www.lovelive-anime.jp（日本动画官网，小众）\n"
  printf " 10) academy.nvidia.com（英伟达学院，备选用）\n"
  printf " 11) lol.secure.dyn.riotcdn.net（游戏补丁 CDN，备选用）\n"
  printf "不知道选哪个就回车用默认 1。\n"
  ask "请选择" "1" _dm
  case "$_dm" in
    2)  REALITY_DOMAIN="www.cisco.com" ;;
    3)  REALITY_DOMAIN="www.apple.com" ;;
    4)  REALITY_DOMAIN="itunes.apple.com" ;;
    5)  REALITY_DOMAIN="www.python.org" ;;
    6)  REALITY_DOMAIN="m.media-amazon.com" ;;
    7)  REALITY_DOMAIN="images-na.ssl-images-amazon.com" ;;
    8)  REALITY_DOMAIN="download-installer.cdn.mozilla.net" ;;
    9)  REALITY_DOMAIN="www.lovelive-anime.jp" ;;
    10) REALITY_DOMAIN="academy.nvidia.com" ;;
    11) REALITY_DOMAIN="lol.secure.dyn.riotcdn.net" ;;
    *)  REALITY_DOMAIN="www.samsung.com" ;;
  esac
  info "伪装域名：$REALITY_DOMAIN"
else
  step "[4/4] 这一步跳过（只有 REALITY 协议才需要选伪装域名）"
fi

# ---------- 7. 随机生成 UUID / 密码 ----------
step "[生成] 随机生成账号和密码…"
UUID=$(gen_uuid)
TROJAN_PASS=$(rand_hex 16)
ANYTLS_PASS=$(rand_hex 16)
HY2_PASS=$(rand_hex 16)
TUIC_PASS=$(rand_hex 16)
if command -v openssl >/dev/null 2>&1; then
  SS_PASS=$(openssl rand -base64 16 2>/dev/null | tr -d '\n')
else
  SS_PASS=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tu1 | awk '{for(i=1;i<=NF;i++) printf "%c",$i}' | base64 | tr -d '\n')
fi
WS_PATH="/$(rand_hex 4)"
info "账号密码已随机生成（装完会显示，平时输入 jiedian 也能看）"

# ---------- 8. 下载内核 ----------
if [ "$CORE" = "xray" ]; then
  dl_xray
elif [ "$CORE" = "hysteria" ]; then
  dl_hysteria
else
  dl_singbox
fi

# ---------- 9. REALITY 密钥对 ----------
if [ "$NEED_REALITY" -eq 1 ]; then
  step "[密钥] 生成 REALITY 密钥…"
  if [ "$CORE" = "xray" ]; then
    _out=$("$XRAY_BIN" x25519 2>/dev/null)
    REALITY_PRIV=$(printf "%s" "$_out" | grep -i "private" | head -1 | awk '{print $NF}' | tr -d '\r\n')
    # 公钥行：老版叫 "Public key"，v26.3.27 起叫 "Password (PublicKey)"——两个关键字都认
    REALITY_PUB=$(printf "%s" "$_out" | grep -iE "public|password" | head -1 | awk '{print $NF}' | tr -d '\r\n')
  else
    # sing-box 自带 reality-keypair 生成，不需要 openssl
    _out=$("$SB_BIN" generate reality-keypair 2>/dev/null)
    REALITY_PRIV=$(printf "%s" "$_out" | grep -i "privatekey" | awk '{print $NF}' | tr -d '\r\n')
    REALITY_PUB=$(printf "%s" "$_out" | grep -i "publickey" | awk '{print $NF}' | tr -d '\r\n')
  fi
  [ -z "$REALITY_PRIV" ] || [ -z "$REALITY_PUB" ] && die "REALITY 密钥生成失败"
  REALITY_SID=$(rand_hex 4)
  info "REALITY 密钥已生成"
fi

# ---------- 9c. REALITY 伪装域名可用性检查 ----------
# 伪装站合不合适，取决于从这台 VPS 连过去的 TLS 握手情况，和在哪看视频没关系。
# 装机时直接测一次：xray 内核就用 xray tls ping，sing-box 内核用 openssl 兜底。
# 握手不顺就自动换社区验证最多的 www.apple.com 再试；实在不行也只警告、不拦安装。
if [ "$NEED_REALITY" -eq 1 ]; then
  step "[检查] 验证伪装域名从这台 VPS 是否可用…"
  _rp_ok=0
  _rp_try=0
  while [ "$_rp_try" -lt 2 ]; do
    _rp_try=$((_rp_try + 1))
    _rp_out=""
    if [ "$CORE" = "xray" ] && [ -x "$XRAY_BIN" ]; then
      _rp_out=$(timeout 25 "$XRAY_BIN" tls ping "$REALITY_DOMAIN" 2>&1)
      if printf "%s" "$_rp_out" | grep -q "Handshake succeeded" \
        && printf "%s" "$_rp_out" | grep -q "TLS 1.3"; then
        _rp_ok=1
      fi
    elif command -v openssl >/dev/null 2>&1; then
      _rp_out=$(timeout 20 openssl s_client -connect "${REALITY_DOMAIN}:443" \
        -servername "$REALITY_DOMAIN" -tls1_3 </dev/null 2>&1)
      if printf "%s" "$_rp_out" | grep -q "Protocol  *: *TLSv1.3" \
        && printf "%s" "$_rp_out" | grep -q "Verify return code: 0"; then
        _rp_ok=1
      fi
    else
      info "没有可用的检测工具，跳过验证"
      _rp_ok=1
    fi
    if [ "$_rp_ok" -eq 1 ]; then break; fi
    if [ "$_rp_try" -eq 1 ] && [ "$REALITY_DOMAIN" != "www.apple.com" ]; then
      warn "你选的 $REALITY_DOMAIN 从这台 VPS 握手不太顺，伪装效果可能打折。"
      _rp_swap=1
      if [ -t 0 ]; then
        _rp_ans=""
        printf "是否自动换成社区验证最多的 www.apple.com 再试一次？[默认 Y]: "
        read -r _rp_ans
        case "$_rp_ans" in n|N|no|NO) _rp_swap=0 ;; esac
      else
        info "无交互环境，自动换成 www.apple.com 重试"
      fi
      if [ "$_rp_swap" -eq 1 ]; then
        REALITY_DOMAIN="www.apple.com"
        info "已换成 www.apple.com，重新验证…"
        continue
      fi
    fi
    break
  done
  if [ "$_rp_ok" -eq 1 ]; then
    info "伪装域名验证通过：$REALITY_DOMAIN（TLS 1.3 握手正常）"
  else
    warn "伪装域名 $REALITY_DOMAIN 验证没通过，继续安装（节点照常用，伪装效果可能打折）。"
  fi
fi

# 前面的输入和下载都成功后才创建新节点目录。
# node.txt 写成功后才算装完。中途失败要停掉刚拉起的服务并删掉这个目录，
# 否则重启循环占着端口，而且管理命令看不到它。
trap _abort_partial_node EXIT
mkdir -p "$NODE_DIR" || die "无法创建节点目录 $NODE_DIR"

# ---------- 9b. 自签证书（Hysteria2 / TUIC 需要） ----------
if [ "$PROTO" = "hy2" ]; then
  step "[证书] 生成自签证书…"
  umask 077
  drop_page_cache
  # 官方 hysteria 自己会写证书和私钥，不用再拆 PEM，也不用装 openssl
  _hy_cert_err=$("$HY_BIN" cert --host www.samsung.com \
    --cert "$NODE_DIR/cert.pem" --key "$NODE_DIR/key.pem" \
    --valid-for 87600h --overwrite 2>&1)
  if [ $? -ne 0 ] || [ ! -s "$NODE_DIR/cert.pem" ] || [ ! -s "$NODE_DIR/key.pem" ]; then
    die "自签证书生成失败。$(printf '%s' "$_hy_cert_err" | tr '\n' ' ' | cut -c1-300)"
  fi
  chmod 600 "$NODE_DIR/key.pem" "$NODE_DIR/cert.pem" 2>/dev/null
  # 新版 Xray 已经取消“跳过证书验证”，客户端必须带这张证书的指纹才能连。
  HY2_PIN=$(printf '%s\n' "$_hy_cert_err" | sed -n 's/.*pinSHA256:[[:space:]]*//p' | head -1 | tr -d ' \r\n' | tr 'a-f' 'A-F')
  case "$HY2_PIN" in
    *[!0-9A-F]*|"") HY2_PIN="" ;;
  esac
  if [ -z "$HY2_PIN" ] && command -v openssl >/dev/null 2>&1; then
    if command -v sha256sum >/dev/null 2>&1; then
      HY2_PIN=$(openssl x509 -in "$NODE_DIR/cert.pem" -outform der 2>/dev/null | sha256sum 2>/dev/null | awk '{print toupper($1)}')
    elif command -v shasum >/dev/null 2>&1; then
      HY2_PIN=$(openssl x509 -in "$NODE_DIR/cert.pem" -outform der 2>/dev/null | shasum -a 256 2>/dev/null | awk '{print toupper($1)}')
    fi
  fi
  case "$HY2_PIN" in
    *[!0-9A-F]*|"") HY2_PIN="" ;;
  esac
  [ "${#HY2_PIN}" -eq 64 ] || HY2_PIN=""
  [ -n "$HY2_PIN" ] || die "自签证书做好了，但没有算出证书指纹。没有指纹的话，新版客户端会拒绝连接。"
  info "自签证书已生成"
elif [ "$PROTO" = "tuic" ]; then
  step "[证书] 生成自签证书…"
  umask 077
  # sing-box 自带 tls-keypair 生成自签证书，不需要 openssl；有效期 120 个月
  # 私钥可能是 "PRIVATE KEY" 或 "EC PRIVATE KEY"，两种都要认
  "$SB_BIN" generate tls-keypair www.samsung.com --months 120 > "$NODE_DIR/tls.pem" 2>/dev/null \
    || die "自签证书生成失败"
  awk '/-----BEGIN / && /PRIVATE KEY-----/{p=1} p{print} /-----END / && /PRIVATE KEY-----/{p=0}' "$NODE_DIR/tls.pem" > "$NODE_DIR/key.pem"
  awk '/BEGIN CERTIFICATE/{p=1} p{print} /END CERTIFICATE/{p=0}' "$NODE_DIR/tls.pem" > "$NODE_DIR/cert.pem"
  rm -f "$NODE_DIR/tls.pem"
  [ -s "$NODE_DIR/key.pem" ] && [ -s "$NODE_DIR/cert.pem" ] \
    || die "自签证书生成失败"
  info "自签证书已生成"
fi

# ---------- 10. 写配置文件 ----------
step "[配置] 写入配置…"
mkdir -p /etc/xray-node

if [ "$CORE" = "xray" ]; then
# 与 Hysteria2 / sing-box 一致：纯 IPv6 机器必须听 [::]，默认 0.0.0.0 只收 IPv4，
# 选了 IPv6 却听不到时会出现“安装成功但客户端连不上”。
if [ "$IPVER" = "6" ]; then XRAY_LISTEN="::"; else XRAY_LISTEN="0.0.0.0"; fi
case "$PROTO" in
  vless)
    cat > "$NODE_DIR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "$XRAY_LISTEN",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$REALITY_DOMAIN:443",
          "xver": 0,
          "serverNames": [ "$REALITY_DOMAIN" ],
          "privateKey": "$REALITY_PRIV",
          "shortIds": [ "$REALITY_SID" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
    ;;
  trojan)
    cat > "$NODE_DIR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "$XRAY_LISTEN",
      "port": $PORT,
      "protocol": "trojan",
      "settings": {
        "clients": [ { "password": "$TROJAN_PASS" } ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$REALITY_DOMAIN:443",
          "xver": 0,
          "serverNames": [ "$REALITY_DOMAIN" ],
          "privateKey": "$REALITY_PRIV",
          "shortIds": [ "$REALITY_SID" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
    ;;
  vmess)
    cat > "$NODE_DIR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "$XRAY_LISTEN",
      "port": $PORT,
      "protocol": "vmess",
      "settings": {
        "clients": [ { "id": "$UUID", "alterId": 0 } ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "$WS_PATH" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
    ;;
  ss)
    cat > "$NODE_DIR/config.json" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "$XRAY_LISTEN",
      "port": $PORT,
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "$SS_PASS",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
    ;;
esac
_xray_test=$("$XRAY_BIN" -test -config "$NODE_DIR/config.json" 2>&1) \
  || die "配置文件校验没通过。$(printf '%s' "$_xray_test" | tr '\n' ' ' | cut -c1-300)"
info "配置文件校验通过"

elif [ "$CORE" = "hysteria" ]; then
# ---------- 官方 Hysteria2 配置 ----------
# 伪装用内置 404，不反向代理外网：NAT 上解析不了伪装站时，节点照样能起。
HY_CONF="$NODE_DIR/config.yaml"
if [ "$IPVER" = "6" ]; then HY_LISTEN="[::]:$PORT"; else HY_LISTEN="0.0.0.0:$PORT"; fi
_hy_quic=""
if [ "$LOW_MEM" = "1" ]; then
  # 官方默认接收窗口是 8MB/20MB，64MB 机器上容易把进程打爆。内存小就收紧。
  if [ "$SWAP_OK" = "1" ]; then
    _hy_qs=2097152; _hy_qc=4194304
  else
    _hy_qs=1048576; _hy_qc=2097152
  fi
  _hy_quic="
quic:
  initStreamReceiveWindow: $_hy_qs
  maxStreamReceiveWindow: $_hy_qs
  initConnReceiveWindow: $_hy_qc
  maxConnReceiveWindow: $_hy_qc
  maxIncomingStreams: 16"
fi
cat > "$HY_CONF" <<EOF
listen: "$HY_LISTEN"

tls:
  cert: $NODE_DIR/cert.pem
  key: $NODE_DIR/key.pem
  sniGuard: disable

auth:
  type: password
  password: "$HY2_PASS"

ignoreClientBandwidth: true

masquerade:
  type: "404"
$_hy_quic
EOF
chmod 600 "$HY_CONF" 2>/dev/null
info "配置文件已写入"

else
# ---------- sing-box 配置（AnyTLS / TUIC） ----------
SB_CONF="$NODE_DIR/config.json"
if [ "$IPVER" = "6" ]; then SB_LISTEN="::"; else SB_LISTEN="0.0.0.0"; fi
case "$PROTO" in
  anytls)
    cat > "$SB_CONF" <<EOF
{
  "log": { "level": "warning" },
  "inbounds": [
    {
      "type": "anytls",
      "listen": "$SB_LISTEN",
      "listen_port": $PORT,
      "users": [ { "name": "xray-node", "password": "$ANYTLS_PASS" } ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_DOMAIN",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$REALITY_DOMAIN", "server_port": 443 },
          "private_key": "$REALITY_PRIV",
          "short_id": [ "$REALITY_SID" ]
        }
      }
    }
  ],
  "outbounds": [ { "type": "direct" } ]
}
EOF
    ;;
  tuic)
    cat > "$SB_CONF" <<EOF
{
  "log": { "level": "warning" },
  "inbounds": [
    {
      "type": "tuic",
      "listen": "$SB_LISTEN",
      "listen_port": $PORT,
      "users": [ { "name": "xray-node", "uuid": "$UUID", "password": "$TUIC_PASS" } ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "www.samsung.com",
        "alpn": [ "h3" ],
        "certificate_path": "$NODE_DIR/cert.pem",
        "key_path": "$NODE_DIR/key.pem"
      }
    }
  ],
  "outbounds": [ { "type": "direct" } ]
}
EOF
    ;;
esac
_sb_test=$("$SB_BIN" check -c "$SB_CONF" 2>&1) \
  || die "配置文件校验没通过。$(printf '%s' "$_sb_test" | tr '\n' ' ' | cut -c1-300)"
info "配置文件校验通过"
fi

# ---------- 11. 开机自启（每个节点独立服务，互不干扰） ----------
# 先记下这个节点用的内核，_svc_install 要读它
echo "$CORE" > "$NODE_DIR/core" 2>/dev/null
step "[服务] 设置开机自启…"
_svc_install "$NODE_ID"

# ---------- 11b. 硬检查：端口必须真的在监听 ----------
# 服务显示"已启动"不代表真在工作，端口没监听节点就是坏的，直接报错不忽悠
_SVC_PROTOS="tcp"
case "$PROTO" in
  hy2|tuic) _SVC_PROTOS="udp" ;;
  ss)       _SVC_PROTOS="tcp udp" ;;  # ss 配了 tcp,udp：只查 TCP 的话，UDP 没起来也发现不了
esac
_svc_listen_ok=1
for _sp in $_SVC_PROTOS; do
  if ! wait_for_port "$PORT" "$_sp" 15; then
    warn "端口 $PORT/$_sp 没在监听"
    _svc_listen_ok=0
  fi
done
# 端口在听不等于是我们的服务：极简机上 port_in_use 曾查不到占用时，
# 别人占用的端口会让 wait_for_port 误报成功。再确认本节点服务/进程还在。
if [ "$_svc_listen_ok" = "1" ]; then
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && [ -n "$SVC_UNIT" ]; then
    systemctl is-active --quiet "$SVC_UNIT" || _svc_listen_ok=0
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service "xray-node-${NODE_ID}" status >/dev/null 2>&1 || _svc_listen_ok=0
  else
    if [ "$CORE" = "hysteria" ]; then
      _svc_cfg_pat="/etc/xray-node/nodes/${NODE_ID}/config.yaml"
    else
      _svc_cfg_pat="/etc/xray-node/nodes/${NODE_ID}/config.json"
    fi
    if command -v pgrep >/dev/null 2>&1; then
      pgrep -f "$_svc_cfg_pat" >/dev/null 2>&1 || _svc_listen_ok=0
    fi
  fi
fi
if [ "$_svc_listen_ok" = "1" ]; then
  info "端口 $PORT 已在监听，服务真正跑起来了"
else
  echo "-------- 服务最后的日志 --------"
  if [ -n "$SVC_UNIT" ] && command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$SVC_UNIT" -n 20 --no-pager 2>/dev/null
  fi
  if [ -f "/var/log/xray-node-${NODE_ID}.log" ]; then
    tail -n 20 "/var/log/xray-node-${NODE_ID}.log" 2>/dev/null
  fi
  die "服务没能监听端口 $PORT：节点装坏了。请把上面的日志截图发我。也可以运行 systemctl status '${SVC_UNIT:-xray-node@${NODE_ID}}'（或 rc-service 'xray-node-${NODE_ID}' status）看原因，修好再重跑脚本"
fi

# ---------- 12. 放行端口 ----------
step "[网络] 放行端口…"
# 各协议要放行的端口类型：ss 的 network 配的是 tcp,udp，两个都得放；
# hy2/tuic 走 UDP；其余走 TCP
_FW_PROTOS="tcp"
case "$PROTO" in
  hy2|tuic) _FW_PROTOS="udp" ;;
  ss) _FW_PROTOS="tcp udp" ;;
esac
# 逐个协议放行，并记到该节点的 fw_info 里给 shanjiedian 用：
# 只删我们亲手加的规则，用户机器上本来就有的不碰。
# 新节点编号不会重用，不可能有旧规则残留，无需清理。
: > "$NODE_DIR/fw_info"
_FW_IPT_TOUCHED=0
if [ "$IPVER" = "6" ]; then _IPT_BIN=ip6tables; else _IPT_BIN=iptables; fi
for _np in $_FW_PROTOS; do
  _UFW_ADDED=0; _FWL_ADDED=0; _IPT_ADDED=0
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qE "^${PORT}/${_np}[[:space:]]"; then
      : # 这条规则本来就存在（用户自己加的），我们不动它
    elif ufw allow "$PORT"/"$_np" >/dev/null 2>&1; then
      _UFW_ADDED=1
      info "ufw 已放行 $PORT/$_np"
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep -qx "${PORT}/${_np}"; then
      : # 这条规则本来就存在（用户自己加的），我们不动它
    elif firewall-cmd --permanent --add-port="$PORT"/"$_np" >/dev/null 2>&1 \
      && firewall-cmd --reload >/dev/null 2>&1; then
      _FWL_ADDED=1
      info "firewalld 已放行 $PORT/$_np"
    fi
  fi
  if command -v "$_IPT_BIN" >/dev/null 2>&1; then
    if "$_IPT_BIN" -C INPUT -p "$_np" --dport "$PORT" -j ACCEPT >/dev/null 2>&1; then
      : # 这条规则本来就存在（用户自己加的），我们不动它
    elif "$_IPT_BIN" -I INPUT -p "$_np" --dport "$PORT" -j ACCEPT >/dev/null 2>&1; then
      _IPT_ADDED=1
      _FW_IPT_TOUCHED=1
    fi
  fi
  echo "$PORT $_np $_UFW_ADDED $_FWL_ADDED $_IPT_ADDED $IPVER" >> "$NODE_DIR/fw_info"
done
# 纯 iptables 的规则默认重启就丢：刚才亲手加了规则就存盘，
# 否则机器一重启端口又被墙、节点连不上（ufw/firewalld 自己会持久化，不用管）
if [ "$_FW_IPT_TOUCHED" = "1" ]; then
  _save_fw "$IPVER"
fi
warn "如果是云服务器（阿里云/腾讯云/AWS 等），还去控制台安全组放行 $PORT 端口"

# ---------- 13. 生成节点链接 ----------
step "[完成] 生成你的节点…"
case "$PROTO" in
  vless)
    LINK="vless://${UUID}@${LINK_IP}:${LINK_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#xray-node"
    PROTO_NAME="VLESS + REALITY + Vision"
    ;;
  trojan)
    LINK="trojan://${TROJAN_PASS}@${LINK_IP}:${LINK_PORT}?security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#xray-node"
    PROTO_NAME="Trojan + REALITY"
    ;;
  vmess)
    _json="{\"v\":\"2\",\"ps\":\"xray-node\",\"add\":\"${SERVER_IP}\",\"port\":\"${LINK_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"${WS_PATH}\",\"tls\":\"\"}"
    LINK="vmess://$(printf "%s" "$_json" | b64url)"
    PROTO_NAME="VMess + WebSocket"
    ;;
  ss)
    LINK="ss://$(printf "%s" "2022-blake3-aes-128-gcm:${SS_PASS}" | b64url)@${LINK_IP}:${LINK_PORT}#xray-node"
    PROTO_NAME="Shadowsocks"
    ;;
  anytls)
    LINK="anytls://${ANYTLS_PASS}@${LINK_IP}:${LINK_PORT}?security=reality&sni=${REALITY_DOMAIN}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#xray-node"
    PROTO_NAME="AnyTLS + REALITY"
    ;;
  hy2)
    # 官方 Hysteria2 客户端连接自签证书须同时设置 insecure=1 与 pinSHA256；
    # pcs 供支持 Xray 分享字段的客户端使用，指纹仍会校验证书。
    LINK="hysteria2://${HY2_PASS}@${LINK_IP}:${LINK_PORT}/?insecure=1&sni=www.samsung.com&peer=www.samsung.com&alpn=h3&pinSHA256=${HY2_PIN}&pcs=${HY2_PIN}#xray-node"
    PROTO_NAME="Hysteria2"
    ;;
  tuic)
    LINK="tuic://${UUID}:${TUIC_PASS}@${LINK_IP}:${LINK_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=www.samsung.com&allow_insecure=1#xray-node"
    PROTO_NAME="TUIC"
    ;;
esac

# ---------- 14. 保存 + jiedian 命令 ----------
{
  printf "==============================================\n"
  printf " 你的节点（复制下面整行，粘贴到客户端导入）\n"
  printf "==============================================\n"
  printf "%s\n" "$LINK"
  printf -- "----------------------------------------------\n"
  printf "协议: %s\n" "$PROTO_NAME"
  printf "地址: %s\n" "$SERVER_IP"
  printf "端口: %s\n" "$LINK_PORT"
  if [ "$LINK_PORT" != "$PORT" ]; then printf "本机监听端口: %s\n" "$PORT"; fi
  case "$PROTO" in
    vless|vmess) printf "UUID: %s\n" "$UUID" ;;
    trojan)      printf "密码: %s\n" "$TROJAN_PASS" ;;
    ss)          printf "密码: %s\n" "$SS_PASS"; printf "加密: 2022-blake3-aes-128-gcm\n" ;;
    anytls)      printf "密码: %s\n" "$ANYTLS_PASS" ;;
    hy2)         printf "密码: %s\n" "$HY2_PASS" ;;
    tuic)        printf "UUID: %s\n" "$UUID"; printf "密码: %s\n" "$TUIC_PASS" ;;
  esac
  case "$PROTO" in
    vless|trojan|anytls) printf "伪装域名: %s\n" "$REALITY_DOMAIN" ;;
    vmess)        printf "WS 路径: %s\n" "$WS_PATH" ;;
    hy2)
      printf "SNI: www.samsung.com\n"
      printf "证书指纹: %s\n" "$HY2_PIN"
      printf "官方 Hysteria2 客户端：自签证书须同时启用 insecure 和证书指纹锁定；如果指纹为空，填入上面的值。\n"
      printf "Loon 可粘贴这一行:\n"
      printf "Hysteria2 = Hysteria2,%s,%s,\"%s\",sni=www.samsung.com,skip-cert-verify=false,tls-cert-sha256=%s,alpn=\"h3\",udp=true,block-quic=false\n" \
        "$SERVER_IP" "$LINK_PORT" "$HY2_PASS" "$HY2_PIN"
      ;;
    tuic)        printf "SNI: www.samsung.com（自签证书，客户端已设跳过验证）\n" ;;
  esac
  printf -- "----------------------------------------------\n"
  printf "以后想看节点，直接输入: jiedian\n"
  printf "==============================================\n"
} > "$NODE_DIR/node.txt"
trap - EXIT

write_helper_cmds
info "已安装 jiedian 命令：以后输入 jiedian 就能看所有节点"
info "已安装 shanjiedian 命令：输入 shanjiedian 可管理节点（查看/删除）"

# ---------- 14b. BBR 加速：检测，没开就自动开 ----------
step "检查 BBR 加速…"
_BBR_ON=0
if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
  _BBR_ON=1
  info "BBR 已经开启，不用动"
fi
if [ "$_BBR_ON" = "0" ]; then
  # 内核本身支持 BBR：直接 sysctl 打开，立即生效、不用重启、不用下载
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 && \
       sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
      mkdir -p /etc/sysctl.d
      printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-xray-node-bbr.conf
      if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
        _BBR_ON=1
        info "BBR 已自动开启（立即生效，已写入开机配置）"
      fi
    fi
    [ "$_BBR_ON" = "0" ] && warn "BBR 开启失败（可能是容器内无权改内核参数），不影响节点使用"
  else
    warn "当前内核不支持 BBR，跳过加速；节点仍可正常使用"
  fi
fi

# ---------- 15. 显示结果 ----------
printf "\n节点 %s 安装完成！\n" "$NODE_ID"
cat "$NODE_DIR/node.txt"
printf "\n${GREEN}${BOLD}安装完成！${NC}把上面那行链接复制到客户端就能用了。\n"
printf "以后看所有节点输入 jiedian，管理节点（查看/删除）输入 shanjiedian。\n"
