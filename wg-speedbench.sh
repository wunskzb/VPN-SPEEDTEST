#!/usr/bin/env bash
# wg-speedbench.sh
# 交互式导入 WireGuard 配置 -> 在独立 netns 内连接 -> 跑 Speedtest/Cloudflare -> 直接打印结果
# 不改动宿主的默认路由，避免 SSH 失联；带一键卸载/清理
set -euo pipefail

NS="wgb"                                  # 网络命名空间名
CONF_DIR="/etc/wireguard"
CONF_PATH="$CONF_DIR/wgbench.conf"        # 临时配置
NETNS_DIR="/etc/netns/$NS"
RESOLV_PATH="$NETNS_DIR/resolv.conf"
KEEPALIVE="${KEEPALIVE:-25}"
CF_DL_BYTES="${CF_DL_BYTES:-100000000}"   # Cloudflare下载 100MB
CF_UL_BYTES="${CF_UL_BYTES:-50000000}"    # Cloudflare上传 50MB

# -------------------- 通用函数 --------------------
info(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok(){   echo -e "\033[1;32m[DONE]\033[0m $*"; }
err(){  echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

need_root(){
  [[ $EUID -eq 0 ]] || { err "请用 root 运行（或在前面加 sudo）。"; exit 1; }
}

detect_pm(){
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v pacman >/dev/null 2>&1; then echo pacman
  else echo ""
  fi
}

ensure_cmd(){
  local bin="$1" pkg_hint="${2:-$1}" pm
  if ! command -v "$bin" >/dev/null 2>&1; then
    pm=$(detect_pm)
    info "安装依赖：$bin"
    case "$pm" in
      apt) apt-get update -y && apt-get install -y "$pkg_hint" ;;
      dnf) dnf install -y "$pkg_hint" ;;
      yum) yum install -y "$pkg_hint" ;;
      pacman) pacman -Sy --noconfirm "$pkg_hint" ;;
      *) err "无法自动安装 $bin，请手动安装后重试。"; exit 1 ;;
    esac
  fi
}

ensure_deps(){
  ensure_cmd ip iproute2
  ensure_cmd wg-quick wireguard-tools
  ensure_cmd curl curl
  # Speedtest：优先官方 speedtest（带结果URL），否则回落到 speedtest-cli
  if ! command -v speedtest >/dev/null 2>&1; then
    info "未检测到 Ookla speedtest，安装 python3 与 speedtest-cli 回退方案。"
    ensure_cmd python3 python3
    if ! command -v pip3 >/dev/null 2>&1; then ensure_cmd pip3 python3-pip || true; fi
    pip3 install --user --upgrade speedtest-cli || true
    if ! command -v speedtest-cli >/dev/null 2>&1; then
      err "未能安装 speedtest/speedtest-cli；Speedtest 功能将不可用。"
    fi
  fi
  # jq 可选，仅用于漂亮解析（官方 speedtest --format=json 时使用）
  command -v jq >/dev/null 2>&1 || true
}

clean_netns(){
  info "清理命名空间与临时文件……"
  ip netns pids "$NS" >/dev/null 2>&1 && ip netns exec "$NS" wg-quick down "$CONF_PATH" || true
  ip netns del "$NS" 2>/dev/null || true
  rm -rf "$NETNS_DIR"
  rm -f "$CONF_PATH"
  ok "已清理完成。"
}

uninstall_all(){
  clean_netns
  info "如需移除此脚本，请执行：rm -f $(realpath "$0")"
  ok "卸载完成。"
}

trap 'err "脚本异常退出。你可以运行:  sudo bash '$0' clean  进行清理。"' INT TERM

# -------------------- 交互采集配置 --------------------
prompt_wg_conf(){
  echo "请按提示输入 WireGuard 参数（来自 Proton/Surfshark/PIA 节点的 WireGuard 信息）："
  read -rp "PrivateKey: " WG_PRIV
  read -rp "Address (示例 10.2.0.2/32 或 10.2.0.2/32,fd00::2/128): " WG_ADDR
  read -rp "DNS (例如 1.1.1.1 或 1.1.1.1,1.0.0.1; 可留空): " WG_DNS || true
  read -rp "PublicKey: " WG_PUB
  read -rp "Endpoint (示例 host:51820): " WG_ENDPOINT
  read -rp "PresharedKey（可留空）: " WG_PSK || true

  mkdir -p "$CONF_DIR" "$NETNS_DIR"

  # resolv.conf（命名空间内使用）
  if [[ -n "${WG_DNS:-}" ]]; then
    echo -e "# resolv for $NS\nnameserver ${WG_DNS//,/\\nnameserver }" > "$RESOLV_PATH"
  else
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > "$RESOLV_PATH"
  fi

  # 生成 wg-quick 配置（在命名空间内启用）
  {
    echo "[Interface]"
    echo "PrivateKey = $WG_PRIV"
    echo "Address = $WG_ADDR"
    # Table/PreUp/PostDown 不必改，wg-quick 在 netns 内会设置默认路由，仅影响该 netns
    [[ -n "${WG_DNS:-}" ]] && echo "DNS = ${WG_DNS}"
    echo
    echo "[Peer]"
    echo "PublicKey = $WG_PUB"
    [[ -n "${WG_PSK:-}" ]] && echo "PresharedKey = $WG_PSK"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "Endpoint = $WG_ENDPOINT"
    echo "PersistentKeepalive = $KEEPALIVE"
  } > "$CONF_PATH"

  ok "已写入临时配置：$CONF_PATH"
}

# -------------------- 建立 netns 并连接 --------------------
bring_up(){
  ip netns add "$NS" 2>/dev/null || true
  # 准备 /etc/netns/$NS/resolv.conf（上面已写）
  # 在 netns 中启用 WireGuard
  info "在命名空间 $NS 内启动 WireGuard……"
  ip netns exec "$NS" wg-quick up "$CONF_PATH"
  ok "WireGuard 已连接（仅在 $NS 内生效，宿主路由不变）。"
}

bring_down(){
  ip netns exec "$NS" wg-quick down "$CONF_PATH" || true
}

# -------------------- 测速实现 --------------------
# Cloudflare：返回 Mbps（两位小数）
cf_download(){
  local bps
  bps=$(ip netns exec "$NS" curl -s -o /dev/null -w "%{speed_download}" \
        "https://speed.cloudflare.com/__down?bytes=${CF_DL_BYTES}")
  awk -v b="$bps" 'BEGIN{printf "%.2f", b*8/1000000}'
}
cf_upload(){
  local bps
  bps=$(head -c "$CF_UL_BYTES" /dev/urandom | \
        ip netns exec "$NS" curl -s -o /dev/null -w "%{speed_upload}" -X POST \
        -H "Content-Type: application/octet-stream" --data-binary @- \
        "https://speed.cloudflare.com/__up")
  awk -v b="$bps" 'BEGIN{printf "%.2f", b*8/1000000}'
}

do_cloudflare(){
  info "Cloudflare（speed.cloudflare.com）测速中……"
  local dl ul
  dl=$(cf_download)
  ul=$(cf_upload)
  ok "Cloudflare 结果：下载 ${dl} Mbps，上传 ${ul} Mbps"
}

do_speedtest(){
  info "Ookla Speedtest 测试中……（优先使用官方 speedtest）"
  local link="N/A" dl="-" ul="-" ping="-"
  if command -v speedtest >/dev/null 2>&1; then
    # 官方 speedtest：JSON 可包含结果链接
    local out
    out=$(ip netns exec "$NS" speedtest --accept-license --accept-gdpr --format=json 2>/dev/null || true)
    if [[ -n "$out" ]]; then
      if command -v jq >/dev/null 2>&1; then
        dl=$(echo "$out" | jq -r '.download.bandwidth' 2>/dev/null); [[ "$dl" != "null" && -n "$dl" ]] && dl=$(awk -v b="$dl" 'BEGIN{printf "%.2f", b*8/1000000}')
        ul=$(echo "$out" | jq -r '.upload.bandwidth'   2>/dev/null); [[ "$ul" != "null" && -n "$ul" ]] && ul=$(awk -v b="$ul" 'BEGIN{printf "%.2f", b*8/1000000}')
        ping=$(echo "$out" | jq -r '.ping.latency'     2>/dev/null)
        link=$(echo "$out" | jq -r '.result.url // empty')
      else
        # 无 jq 时，退回纯文本
        out=$(ip netns exec "$NS" speedtest 2>/dev/null || true)
        dl=$(echo "$out" | awk '/Download:/{print $(NF-1)}')
        ul=$(echo "$out" | awk '/Upload:/{print $(NF-1)}')
        ping=$(echo "$out" | awk '/Latency:|Ping:/{print $2}')
      fi
    fi
  elif command -v speedtest-cli >/dev/null 2>&1; then
    local out
    out=$(ip netns exec "$NS" speedtest-cli --share 2>/dev/null || ip netns exec "$NS" speedtest-cli 2>/dev/null || true)
    dl=$(echo "$out" | awk '/Download:/{print $(NF-1)}')
    ul=$(echo "$out" | awk '/Upload:/{print $(NF-1)}')
    ping=$(echo "$out" | awk '/Ping:/{print $2}')
    link=$(echo "$out" | awk '/Share results:/{print $3}')
  else
    err "未找到 speedtest 或 speedtest-cli。"
  fi
  ok "Speedtest 结果：下载 ${dl:-?} Mbps，上传 ${ul:-?} Mbps，Ping ${ping:-?} ms"
  [[ -n "${link:-}" ]] && echo "结果链接：${link}"
}

menu(){
  cat <<EOF
选择测试项目：
  1) 仅 Speedtest
  2) 仅 Cloudflare
  3) 两者都测
EOF
  read -rp "请输入 1/2/3: " choice
  case "$choice" in
    1) do_speedtest ;;
    2) do_cloudflare ;;
    3) do_speedtest; echo; do_cloudflare ;;
    *) err "无效选择。"; exit 1 ;;
  esac
}

# -------------------- 主入口 --------------------
usage(){
  cat <<'EOF'
用法：
  sudo ./wg-speedbench.sh           # 交互式：输入WG参数 -> 连接 -> 选择测速
  sudo ./wg-speedbench.sh clean     # 断开并清理命名空间与临时配置
  sudo ./wg-speedbench.sh uninstall # 一键卸载（含清理）
EOF
}

main(){
  case "${1:-}" in
    clean)     need_root; ensure_deps; bring_down; clean_netns; exit 0 ;;
    uninstall) need_root; ensure_deps; uninstall_all; exit 0 ;;
    "" )       need_root; ensure_deps; prompt_wg_conf; bring_up; menu; bring_down; ok "测试完成（已断开）。提示：可执行  sudo ./wg-speedbench.sh clean  彻底清理。";;
    * ) usage; exit 1;;
  esac
}

main "$@"
