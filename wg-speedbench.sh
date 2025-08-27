#!/usr/bin/env bash
# wg-speedbench.sh (fixed)
# - 交互输入 WG 参数
# - 先在宿主解析 Endpoint 主机名并替换为 IP:PORT（避免 netns 内 DNS 鸡生蛋蛋生鸡）
# - 在独立 netns 中启用 WireGuard（不改宿主默认路由）
# - 测速：仅 Speedtest（官方 Ookla）、仅 Cloudflare、两者皆测
# - 只打印结果（Speedtest 输出官方结果链接）
# - clean / uninstall

set -euo pipefail

NS="wgb"                                  # 网络命名空间名
CONF_DIR="/etc/wireguard"
CONF_PATH="$CONF_DIR/wgbench.conf"
NETNS_DIR="/etc/netns/$NS"
RESOLV_PATH="$NETNS_DIR/resolv.conf"
KEEPALIVE="${KEEPALIVE:-25}"
CF_DL_BYTES="${CF_DL_BYTES:-100000000}"   # Cloudflare 下载 100MB
CF_UL_BYTES="${CF_UL_BYTES:-50000000}"    # Cloudflare 上传 50MB

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

ensure_deps_base(){
  local pm; pm=$(detect_pm)
  command -v ip >/dev/null 2>&1        || ensure_pkg "$pm" "iproute2"
  command -v wg-quick >/dev/null 2>&1  || ensure_pkg "$pm" "wireguard-tools"
  command -v curl >/dev/null 2>&1      || ensure_pkg "$pm" "curl"
  command -v getent >/dev/null 2>&1    || true
}

install_speedtest_official(){
  # 只用 Ookla 官方 speedtest，不用 speedtest-cli
  if command -v speedtest >/dev/null 2>&1; then
    ok "已检测到官方 speedtest。"
    return
  fi

  local pm; pm=$(detect_pm)
  info "准备安装 Ookla 官方 speedtest ..."
  case "$pm" in
    apt)
      apt-get update -y || true
      apt-get install -y gnupg ca-certificates curl || true

      # 尝试添加官方仓库，但不因失败退出（plucky 不被支持会 404）
      set +e
      curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
      repo_rc=$?
      apt-get update -y
      apt-get install -y speedtest
      apt_rc=$?
      set -e

      if [ ${apt_rc:-1} -ne 0 ]; then
        info "apt 仓库不可用或未找到 speedtest，回退为官方 .deb 安装"
        # 根据架构选择包名
        arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
        case "$arch" in
          amd64|x86_64) deb_arch="amd64" ;;
          arm64|aarch64) deb_arch="arm64" ;;
          armhf) deb_arch="armhf" ;;
          i386|i686) deb_arch="i386" ;;   # 基本用不到
          *) deb_arch="amd64" ;;
        esac
        ver="${SPEEDTEST_VER:-1.2.0}"   # 需要更新时改这个版本号
        url="https://install.speedtest.net/app/cli/ookla-speedtest-${ver}-linux-${deb_arch}.deb"
        curl -fLo /tmp/ookla-speedtest.deb "$url"
        apt install -y /tmp/ookla-speedtest.deb
      fi
      ;;

    dnf)
      dnf install -y curl ca-certificates || true
      curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | bash || true
      if ! dnf install -y speedtest >/dev/null 2>&1; then
        err "RPM 系列暂未做 .rpm 兜底，请手动安装官方 speedtest 后重试。"
        exit 1
      fi
      ;;

    yum)
      yum install -y curl ca-certificates || true
      curl -fsSL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | bash || true
      if ! yum install -y speedtest >/dev/null 2>&1; then
        err "RPM 系列暂未做 .rpm 兜底，请手动安装官方 speedtest 后重试。"
        exit 1
      fi
      ;;

    pacman)
      err "Arch/Manjaro 请用 AUR 安装 ookla-speedtest-bin（如：yay -S ookla-speedtest-bin）后再运行脚本。"
      exit 1
      ;;

    *)
      err "未支持的包管理器；请手动安装官方 speedtest 后再运行。"
      exit 1
      ;;
  esac

  command -v speedtest >/dev/null 2>&1 || { err "官方 speedtest 安装失败。"; exit 1; }
  ok "官方 speedtest 安装完成。"
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

  # 为 netns 准备 resolv.conf
  {
    echo "# resolv for $NS"
    IFS=',' read -ra DNS_ARR <<< "$WG_DNS"
    for d in "${DNS_ARR[@]}"; do
      echo "nameserver ${d}"
    done
  } > "$RESOLV_PATH"

  # 先解析 Endpoint 主机名（在宿主上解析，取首个 IPv4/IPv6）
  local host="$WG_ENDPOINT" port=""
  if [[ "$WG_ENDPOINT" == *:* ]]; then
    host="${WG_ENDPOINT%:*}"
    port="${WG_ENDPOINT##*:}"
  fi

  # 如果 host 不是纯 IP，则解析
  if ! [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$host" =~ : ]]; then
    info "解析 Endpoint 主机名：$host ..."
    # 优先取 IPv4；若无则取第一条记录
    if ip -br addr >/dev/null 2>&1; then :; fi
    RES_IP=$(getent ahosts "$host" 2>/dev/null | awk '/STREAM|RAW|DGRAM/ {print $1; exit}')
    [[ -z "${RES_IP:-}" ]] && RES_IP=$(getent hosts "$host" 2>/dev/null | awk '{print $1; exit}')
    if [[ -z "${RES_IP:-}" ]]; then
      err "无法解析 Endpoint 主机名：$host"
      exit 1
    fi
    ok "解析到：$RES_IP"
    WG_ENDPOINT="${RES_IP}:${port}"
  fi

  # 写入 wg-quick 配置（在 netns 内启用）
  {
    echo "[Interface]"
    echo "PrivateKey = $WG_PRIV"
    echo "Address = $WG_ADDR"
    echo "DNS = ${WG_DNS}"
    echo
    echo "[Peer]"
    echo "PublicKey = $WG_PUB"
    [[ -n "${WG_PSK:-}" ]] && echo "PresharedKey = $WG_PSK"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "Endpoint = $WG_ENDPOINT"
    echo "PersistentKeepalive = $KEEPALIVE"
  } > "$CONF_PATH"

  ok "已写入临时配置：$CONF_PATH"
  info "Endpoint 已写为：$(grep -E '^Endpoint' "$CONF_PATH" | awk '{print $3}')"
}

bring_up(){
  ip netns add "$NS" 2>/dev/null || true
  info "在命名空间 $NS 内启动 WireGuard……"
  ip netns exec "$NS" wg-quick up "$CONF_PATH"
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
  ok "Cloudflare：下行 ${dl} Mbps，上行 ${ul} Mbps"
}

# ------------ Ookla 官方 Speedtest ------------
do_speedtest(){
  command -v speedtest >/dev/null 2>&1 || { err "未检测到官方 speedtest。"; exit 1; }
  info "Ookla Speedtest 测试中……"
  # 用 JSON 输出，便于解析结果链接
  local out; out=$(ip netns exec "$NS" speedtest --accept-license --accept-gdpr --format=json 2>/dev/null || true)
  if [[ -z "$out" ]]; then
    # 再试一次普通输出
    out=$(ip netns exec "$NS" speedtest 2>/dev/null || true)
  fi

  local link="N/A" dl="-" ul="-" ping="-"
  if command -v jq >/dev/null 2>&1 && [[ "$(printf "%s" "$out" | head -c 1)" == "{" ]]; then
    dl=$(echo "$out"   | jq -r '.download.bandwidth // empty'); [[ -n "$dl" ]] && dl=$(awk -v b="$dl" 'BEGIN{printf "%.2f", b*8/1000000}')
    ul=$(echo "$out"   | jq -r '.upload.bandwidth   // empty'); [[ -n "$ul" ]] && ul=$(awk -v b="$ul" 'BEGIN{printf "%.2f", b*8/1000000}')
    ping=$(echo "$out" | jq -r '.ping.latency       // empty')
    link=$(echo "$out" | jq -r '.result.url         // empty')
  else
    # 文本兜底（有些环境 --format 不可用）
    dl=$(echo "$out" | awk '/Download:/{print $(NF-1)}')
    ul=$(echo "$out" | awk '/Upload:/{print $(NF-1)}')
    ping=$(echo "$out" | awk '/Latency:|Ping:/{print $2}')
    link=$(echo "$out" | awk '/Result URL:/{print $3}')
  fi

  ok "Speedtest：下行 ${dl:-?} Mbps，上行 ${ul:-?} Mbps，Ping ${ping:-?} ms"
  [[ -n "${link:-}" ]] && echo "结果链接：${link}"
}

menu(){
  cat <<EOF
选择测试项目：
  1) 仅 Speedtest（官方 Ookla）
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

usage(){
  cat <<'EOF'
用法：
  sudo ./wg-speedbench.sh           # 交互：输入 WG 参数 -> 连接 -> 选择测速
  sudo ./wg-speedbench.sh clean     # 断开并清理命名空间与临时配置
  sudo ./wg-speedbench.sh uninstall # 一键卸载（含清理）
EOF
}

main(){
  case "${1:-}" in
    clean)     need_root; bring_down; clean_netns; exit 0 ;;
    uninstall) need_root; bring_down; uninstall_all; exit 0 ;;
    "" )
      need_root
      ensure_deps_base
      install_speedtest_official
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
