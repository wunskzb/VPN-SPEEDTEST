# wg-speedbench

在**独立网络命名空间**中连接 WireGuard 节点，不改动宿主默认路由（不会断开 SSH），并支持：
- 仅测 Ookla Speedtest（返回官方**结果链接**）
- 仅测 Cloudflare（speed.cloudflare.com）
- 两者都测  
结果**直接打印**，不写入 CSV。

## 快速开始
```bash
curl -fsSL https://raw.githubusercontent.com/<your-username>/<your-repo>/main/wg-speedbench.sh -o wg-speedbench.sh
chmod +x wg-speedbench.sh
sudo ./wg-speedbench.sh
