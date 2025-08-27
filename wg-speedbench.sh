#!/usr/bin/env bash
# wg-speedbench.sh (Cloudflare-only, fixed)
# - 交互输入 WG 参数
# - 宿主解析 Endpoint 主机名 -> 写 IP:PORT（避免 netns 解析失败）
# - 独立 netns 内启用 WireGuard（不改宿主默认路由）
# - 仅测 Cloudflare 下载/上传/两者
# - clean / uninstall

set -euo pipefail

NS="wgb"                                  # 网络命名空间
CONF_DIR="/etc/wireguard"
CONF_PATH="$CONF_DIR/wgbench.conf"
NETNS_DIR="/etc/netns/$NS"
RESOLV_PATH="$NETNS_DIR/resolv.conf"
KEEPALIVE="${KEEPALIVE:-25}"
CF_DL_BYTES="${CF_DL_BYTES:-100000000}"   # 下载测试字节数 (默认 100MB)
CF_UL_BYTES="${CF_UL_BYTES:-50000000}"    # 上传测试字节数 (默认 50MB)

info(){ echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok(){   echo -e "\033[1;32m[DONE]\033[0m $*"; }
err(){  echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }

need_root(){ [[ $EUID -eq 0 ]] || { err "请用 root 运行（或 sudo）。"; exit 1; }; }

detect_pm(){
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v pacman >/dev/null 2>&1; then echo pacman
  else echo ""
  fi
}

ensure_pkg(){
  local pm="$1" pkg="$2"
  case "$pm" in
    apt) apt-get update -y && apt-get install -y $pkg ;;
    dnf) dnf install -y $pkg ;;
    yum) yum install -y $pkg ;;
    pacman) pacman -Sy --noconfirm $pkg ;;
    *) err "无法自动安装：$pkg"; exit 1 ;;
  esac
}

ensure_deps(){
  local pm; pm=$(detect_pm)
  command -v ip >/dev/null 2>&1        || ensure_pkg "$pm" "iproute2"
  command -v wg-quick >/dev/null 2>&1  || ensure_pkg "$pm" "wireguard-tools"
  command -v curl >/dev/null 2>&1      || ensure_pkg "$pm" "curl"
  command -v getent >/dev/null 2>&1    || true
}

clean_netns(){
  info "清理命名空间与临时文件……"
  if ip netns pids "$NS" >/dev/null 2>&1; then
    ip netns exec "$NS" wg-quick down "$CONF_PATH" || true
  fi
  ip netns del "$NS" 2>/dev/null || true
  rm -rf "$NETNS_DIR"
  rm -f "$CONF_PATH"
  ok "已清理完成。"
}

uninstall_all(){
  clean_netns
  info "如需移除此脚本：rm -f $(realpath "$0")"
  ok "卸载完成。"
}

prompt_wg_conf(){
  echo "请按提示输入 WireGuard 参数："
  read -rp "PrivateKey: " WG_PRIV
  read -rp "Address (示例 10.2.0.2/32 或 10.2.0.2/32,fd00::2/128): " WG_ADDR
  read -rp "DNS（逗号分隔，可留空，默认 1.1.1.1,1.0.0.1）: " WG_DNS || true
  read -rp "PublicKey: " WG_PUB
  read -rp "Endpoint（主机或IP:端口，如 nl-xxx.surfshark.com:51820）: " WG_ENDPOINT
  read -rp "PresharedKey（可留空）: " WG_PSK || true

  [[ -n "${WG_DNS:-}" ]] || WG_DNS="1.1.1.1,1.0.0.1"

  mkdir -p "$CONF_DIR" "$NETNS_DIR"

  # 为 netns 写 resolv.conf（glibc 会自动在该 netns 使用它）
  {
    echo "# resolv for $NS"
    IFS=',' read -ra DNS_ARR <<< "$WG_DNS"
    for d in "${DNS_ARR[@]}"; do
      echo "nameserver ${d}"
    done
  } > "$RESOLV_PATH"

  # 宿主解析 Endpoint → IP:PORT
  local host="$WG_ENDPOINT" port=""
  if [[ "$WG_ENDPOINT" == *:* ]]; then
    host="${WG_ENDPOINT%:*}"
    port="${WG_ENDPOINT##*:}"
  fi
  if ! [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$host" =~ : ]]; then
    info "解析 Endpoint 主机名：$host ..."
    RES_IP=$(getent ahosts "$host" 2>/dev/null | awk '/STREAM|RAW|DGRAM/ {print $1; exit}')
    [[ -z "${RES_IP:-}" ]] && RES_IP=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}')
    [[ -z "${RES_IP:-}" ]] && { err "无法解析 Endpoint：$host"; exit 1; }
    ok "解析到：$RES_IP"
    WG_ENDPOINT="${RES_IP}:${port}"
  fi

  # 写 wg-quick 配置（⚠ 不写 DNS=，避免 wg-quick 调 resolvconf）
  {
    echo "[Interface]"
    echo "PrivateKey = $WG_PRIV"
    echo "Address = $WG_ADDR"
    echo
    echo "[Peer]"
    echo "PublicKey = $WG_PUB"
    [[ -n "${WG_PSK:-}" ]] && echo "PresharedKey = $WG_PSK"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "Endpoint = $WG_ENDPOINT"
    echo "PersistentKeepalive = ${KEEPALIVE:-25}"
  } > "$CONF_PATH"

  ok "已写入临时配置：$CONF_PATH"
  info "Endpoint 已写为：$(grep -E '^Endpoint' "$CONF_PATH" | awk '{print $3}')"
}

bring_up(){
  ip netns add "$NS" 2>/dev/null || true
  # 先把 loopback 拉起，避免 “Network is unreachable”
  ip netns exec "$NS" ip link set lo up

  info "在命名空间 $NS 内启动 WireGuard……"
  # 禁用 wg-quick 的 DNS 操作（我们用 /etc/netns/$NS/resolv.conf）
  ip netns exec "$NS" env WG_QUICK_DNS=off wg-quick up "$CONF_PATH"

  ok "WireGuard 已连接（仅在 $NS 内生效）。"
  info "命名空间 DNS 配置："
  ip netns exec "$NS" cat /etc/resolv.conf || true
}

bring_down(){
  ip netns exec "$NS" wg-quick down "$CONF_PATH" || true
}

# ------------ Cloudflare 速度（Mbps，两位小数） ------------
cf_download(){
  local bps
  bps=$(ip netns exec "$NS" curl -s -o /tmp/cf_down.bin -w "%{speed_download}" \
        "https://speed.cloudflare.com/__down?bytes=${CF_DL_BYTES}" \
        || true)
  rm -f /tmp/cf_down.bin
  awk -v b="${bps:-0}" 'BEGIN{printf "%.2f", b*8/1000000}'
}
cf_upload(){
  local bps
  bps=$(head -c "$CF_UL_BYTES" /dev/urandom | \
        ip netns exec "$NS" curl -s -o /dev/null -w "%{speed_upload}" -X POST \
        -H "Content-Type: application/octet-stream" --data-binary @- \
        "https://speed.cloudflare.com/__up" \
        || true)
  awk -v b="${bps:-0}" 'BEGIN{printf "%.2f", b*8/1000000}'
}

do_cloudflare_dl(){ info "Cloudflare 下载测速中……"; local dl; dl=$(cf_download); ok "下载 ${dl} Mbps"; }
do_cloudflare_ul(){ info "Cloudflare 上传测速中……"; local ul; ul=$(cf_upload); ok "上传 ${ul} Mbps"; }
do_cloudflare_both(){ do_cloudflare_dl; echo; do_cloudflare_ul; }

menu(){
  cat <<EOF
选择测试项目：
  1) 仅下载（Cloudflare）
  2) 仅上传（Cloudflare）
  3) 下载+上传（Cloudflare）
EOF
  read -rp "请输入 1/2/3: " choice
  case "$choice" in
    1) do_cloudflare_dl ;;
    2) do_cloudflare_ul ;;
    3) do_cloudflare_both ;;
    *) err "无效选择。"; exit 1 ;;
  esac
}

usage(){
  cat <<'EOF'
用法：
  sudo ./wg-speedbench.sh           # 交互：输入 WG 参数 -> 连接 -> 选择 Cloudflare 测速
  sudo ./wg-speedbench.sh clean     # 断开并清理命名空间与临时配置
  sudo ./wg-speedbench.sh uninstall # 一键卸载（含清理）

可通过环境变量调整测试大小：
  CF_DL_BYTES=200000000 CF_UL_BYTES=100000000 sudo ./wg-speedbench.sh
EOF
}

main(){
  case "${1:-}" in
    clean)     need_root; bring_down; clean_netns; exit 0 ;;
    uninstall) need_root; bring_down; uninstall_all; exit 0 ;;
    "" )
      need_root
      ensure_deps
      prompt_wg_conf
      bring_up
      menu
      bring_down
      ok "测试完成（连接已断开）。如需彻底清理：sudo ./wg-speedbench.sh clean"
      ;;
    * ) usage; exit 1;;
  esac
}

main "$@"
