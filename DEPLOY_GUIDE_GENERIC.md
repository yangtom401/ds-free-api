# 通用部署指南：GitHub Actions 编译 + PVE LXC 容器部署

本指南适用于**任何语言/框架项目**（Rust、Go、Python、Node.js、Java 等），通过 GitHub Actions 交叉编译产物，并部署到 Proxmox VE (PVE) 的 LXC 容器运行。

---

## ⚡ 本项目已填入的真实配置（直接用）

| 配置项 | 值 |
|--------|-----|
| PVE 地址 | `10.0.0.254`（Web: https://10.0.0.254:8006）|
| PVE 登录 | 用户 `root@pam`，密码 `t1213110` |
| GitHub 账号 | `yangtom401` |
| GitHub 仓库 | `yangtom401/xxx （新建一个）` |
| GitHub Token | `<YOUR_GITHUB_TOKEN>`（含 repo + workflow 权限）|
| SSH 密钥路径 | `~/.ssh/id_ed25519`（已加入 PVE authorized_keys）|
| 容器 ID | `100` |
| 容器 IP | `10.0.0.102/24`，网关 `10.0.0.1` |
| 应用目录 | `/opt/nvidia-proxy` |
| artifact 名称 | `nvidia-proxy-linux` |
| 服务名 | `nvidia-proxy` |

> ⚠️ 下方各章节的 `<变量>` 均已按上表替换为实际值。

## 一、架构总览

```
本地开发机 ──push──► GitHub Actions（编译）──artifact──► 下载二进制 ├─► PVE LXC 容器
                                                                    └─► systemd 服务运行
```

核心思想：
1. 本地不用装编译工具链，GitHub Actions 负责编译（Linux x86_64）
2. 编译产物（可执行文件）下载后推入 LXC 容器
3. systemd 管理进程生命周期（开机自启、崩溃重启）

---

## 二、前置准备（一次性的密钥配置）

### 2.1 GitHub Token

用于：推送代码、触发 Actions、下载编译产物。

生成地址：https://github.com/settings/tokens → **Generate new token (classic)**

**所需权限：**

| 权限 | 用途 |
|------|------|
| `repo` | 完整仓库权限（推送、下载 artifact）|
| `workflow` | 更新/触发 GitHub Actions workflow（**必须勾选，否则无法修改 .github/workflows/ 文件**）|

> ⚠️ Token 是最高敏感信息，不要提交到代码仓库、不要写在脚本里写死。
> 建议保存到本地环境变量或密码管理器。

### 2.2 SSH 密钥（本机 → PVE）

用于：免密登录 PVE 宿主机。

```bash
# 本地生成密钥（没有的话）
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

# 查看公钥
cat ~/.ssh/id_ed25519.pub
# 输出形如: ssh-ed25519 AAAA... user@host
```

在 **PVE 控制台**执行（添加公钥）：

```bash
mkdir -p ~/.ssh
echo 'ssh-ed25519 AAAA... user@host' >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
```

验证：

```bash
ssh -i ~/.ssh/id_ed25519 root@10.0.0.254 'echo connected'
```

> 💡 如果 PVE 只开了密码登录，先用以下命令开启密钥认证：
> ```bash
> echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
> systemctl restart ssh
> ```

---

## 三、GitHub 侧配置

### 3.1 创建仓库并推送代码

```bash
# 在项目根目录
git init
git add -A
git commit -m "init"
git remote add origin https://github.com/yangtom401/nvidia-proxy-linux.git
git push origin master
```

### 3.2 添加编译工作流

在项目根目录创建 `.github/workflows/build.yml`，**根据项目语言替换编译步骤**：

```yaml
name: Build

on:
  push:
    branches: [master]
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      # ===== 编译步骤（按语言替换）=====
      # Rust 示例：
      # - name: Setup Rust
      #   uses: dtolnay/rust-toolchain@stable
      # - run: cargo build --release
      # - run: strip target/release/<二进制名>
      #
      # Go 示例：
      # - uses: actions/setup-go@v5
      #   with: { go-version: '1.22' }
      # - run: GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o <二进制名> .
      #
      # Node.js 示例：
      # - uses: actions/setup-node@v4
      #   with: { node-version: '20' }
      # - run: npm ci && npm run build
      #  然后打包产物 (tar czf app.tar.gz dist/)
      #
      # Python 示例：
      # - run: pip install pyinstaller && pyinstaller --onefile main.py
      # ==================================

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: nvidia-proxy-linux          # artifact 名称
          path: target/release/nvidia-proxy   # 编译产物路径
          retention-days: 7            # 保留7天
```

**各语言产物路径对照：**

| 语言 | 编译产物 |
|------|----------|
| Rust | `target/release/<name>` |
| Go | 当前目录生成的二进制 |
| Node.js | `dist/` 目录（建议打成 tar.gz）|
| Python | `dist/<name>` (PyInstaller 单文件) |
| Java | `target/*.jar` |

推送后自动触发编译：

```bash
git add -A && git commit -m "update" && git push origin master
```

---

## 四、在 PVE 上创建 LXC 容器

### 4.1 下载容器模板

如果 PVE 上没有模板，先下载（PVE 控制台）：

```bash
# 查看可用模板
pveam available | grep debian

# 下载 Debian 13
pveam download local debian-13-standard_13.1-2_amd64.tar.zst
```

> 也可用 Ubuntu、Alpine 等其他模板，命令相同。

### 4.2 创建容器（API 方式，稳定）

> ⚠️ PVE 9.x 的 `pct create` 有 nameserver 校验 bug，推荐用 API 方式：

```bash
HOST="https://10.0.0.254:8006"
USER="root@pam"
PASS="t1213110"

# 获取 ticket
TICKET=$(curl -sk -X POST -d "username=$USER&password=$PASS" \
  "$HOST/api2/json/access/ticket")
TIX=$(echo "$TICKET" | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['ticket'])")
CSRF=$(echo "$TICKET" | python3 -c "import sys,json;print(json.load(sys.stdin)['data']['CSRFPreventionToken'])")

# 创建容器（CTID=100，模板、资源按需改）
CTID=100
curl -sk -X POST -H "Content-Type: application/json" \
  -H "Cookie: PVEAuthCookie=$TIX" -H "CSRFPreventionToken: $CSRF" \
  -d "{\"ostemplate\":\"local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst\",\"vmid\":$CTID,\"hostname\":\"nvidia-proxy\",\"memory\":2048,\"cores\":2,\"rootfs\":{\"storage\":\"local\",\"size\":\"8G\"},\"net0\":\"name=eth0,bridge=vmbr0\"}" \
  "$HOST/api2/json/nodes/pve/lxc"
```

### 4.3 配置网络（静态 IP）

```bash
# 设置 IP/网关/DNS（IP 按你的网段改）
pct set $CTID --net0 name=eth0,bridge=vmbr0,gw=10.0.0.1,ip=10.0.0.102/24
pct set $CTID --nameserver 8.8.8.8
pct reboot $CTID
```

### 4.4 验证容器

```bash
pct list
pct exec $CTID -- ping -c 1 8.8.8.8   # 网络通
pct exec $CTID -- uname -a            # 系统信息
```

---

## 五、下载 GitHub 编译产物

```bash
# ===== 本项目已配置（直接用） =====
TOKEN="<YOUR_GITHUB_TOKEN>"   # GitHub Token（repo+workflow 权限）
REPO="yangtom401/nvidia-proxy-linux"

# 1. 获取最新 run ID
RUN_ID=$(curl -s -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs?per_page=1" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['workflow_runs'][0]['id'])")

# 2. 获取 artifact ID
ARTIFACT_ID=$(curl -s -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID/artifacts" \
  | python3 -c "import sys,json; print([a['id'] for a in json.load(sys.stdin)['artifacts'] if a['name']=='nvidia-proxy-linux'][0])")

# 3. 下载并解压
curl -s -L -H "Authorization: token $TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip" \
  -o artifact.zip
unzip -o artifact.zip -d artifact

# 4. 查看产物（Linux 可执行文件应显示 ELF）
file artifact/*
```

---

## 六、部署到 LXC 容器

### 6.1 上传产物

```bash
PVE_IP="10.0.0.254"
CTID=100
APP_DIR="/opt/nvidia-proxy"
SSH_KEY="~/.ssh/id_ed25519"

# 本机 → PVE 宿主机
scp -i $SSH_KEY artifact/nvidia-proxy root@$PVE_IP:/tmp/deploy.bin

# PVE → 容器
ssh -i $SSH_KEY root@$PVE_IP "pct push $CTID /tmp/deploy.bin $APP_DIR/nvidia-proxy"
ssh -i $SSH_KEY root@$PVE_IP "pct exec $CTID -- chmod +x $APP_DIR/nvidia-proxy"
```

### 6.2 配置 systemd 服务（开机自启）

在容器内创建 `/etc/systemd/system/nvidia-proxy.service`：

```bash
ssh -i ~/.ssh/id_ed25519 root@$PVE_IP "pct exec $CTID -- bash -c 'cat > /etc/systemd/system/nvidia-proxy.service << EOF
[Unit]
Description=NVIDIA Proxy Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/nvidia-proxy
Restart=always
RestartSec=5
EnvironmentFile=$APP_DIR/.env
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF'"

# 启动并设置开机自启
ssh -i ~/.ssh/id_ed25519 root@$PVE_IP "pct exec $CTID -- bash -c '\
  systemctl daemon-reload && systemctl enable nvidia-proxy && systemctl start nvidia-proxy'"
```

### 6.3 密钥/环境变量管理

**不要把密钥编译进二进制或提交到 git。** 放容器内的 `.env`（chmod 600）：

```bash
# 创建 .env（PVE → 容器）
ssh -i ~/.ssh/id_ed25519 root@$PVE_IP "pct exec $CTID -- bash -c '\
  mkdir -p $APP_DIR && chmod 700 $APP_DIR'"

# 先传上去再改权限
scp -i ~/.ssh/id_ed25519 .env root@$PVE_IP:/tmp/app.env
ssh -i ~/.ssh/id_ed25519 root@$PVE_IP "pct push $CTID /tmp/app.env $APP_DIR/.env && pct exec $CTID -- chmod 600 $APP_DIR/.env"
```

**本项目 `.env` 实际内容**（容器内 `/opt/nvidia-proxy/.env`，24 字节）:

```ini
PORT=3000
RUST_LOG=info
```

> 说明：本项目预置的 NVIDIA API Keys 已通过 `db.init_default_api_keys()` 写入 SQLite 数据库（`/opt/nvidia-proxy/data/nvidia_proxy.db`），无需在 .env 中配置。
> 数据库中的 key：`nvapi-hs4jHU8x...`（road）、`nvapi-96p4uBeL...`（road）、`nvapi-i0yXydqI...`（score）。

---

## 七、验证与故障排查

### 7.1 验证

```bash
# 查看服务状态
ssh -i ~/.ssh/id_ed25519 root@$PVE_IP "pct exec $CTID -- systemctl status nvidia-proxy"

# 查看日志
ssh -i ~/.ssh/id_ed25519 root@$PVE_IP "pct exec $CTID -- journalctl -u nvidia-proxy -f"

# 测试端口（按项目端口改）
curl http://10.0.0.102:3000/health
```

### 7.2 常见问题

| 问题 | 解决方案 |
|------|----------|
| Actions 推送被拒（token 无 workflow 权限）| 重新生成 token，勾选 `workflow` |
| Artifact 下载 404 | 检查 artifact 是否过期（retention-days），或 workflow 是否成功 |
| 容器内 curl 不可用 | `pct exec $CTID -- apt-get install -y curl` |
| 容器无外网 | 检查 `--nameserver 8.8.8.8` 和网关 `gw=10.0.0.1` |
| 服务启动失败 | `journalctl -u nvidia-proxy -xe` 看详细错误；检查二进制是否 Linux ELF |
| pct create 报 nameserver 错误 | 用 4.2 节的 API 方式创建 |
| 二进制无法运行（缺动态库）| 优先静态编译（Rust/Go 默认静态）；Python 用 PyInstaller 单文件 |

---

## 八、一键更新命令（本项目已填好）

```bash
#!/bin/bash
set -e
# ===== 本项目实际配置 =====
REPO="yangtom401/nvidia-proxy-linux"
ARTIFACT_NAME="nvidia-proxy-linux"
CTID=100
APP_DIR="/opt/nvidia-proxy"
PVE_IP="10.0.0.254"
SSH_KEY="$HOME/.ssh/id_ed25519"
TOKEN="<YOUR_GITHUB_TOKEN>"   # GitHub Token（repo+workflow 权限）
# ==========================

# 1. 下载最新产物
RUN_ID=$(curl -s -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs?per_page=1" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['workflow_runs'][0]['id'])")
ARTIFACT_ID=$(curl -s -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID/artifacts" \
  | python3 -c "import sys,json; print([a['id'] for a in json.load(sys.stdin)['artifacts'] if a['name']=='$ARTIFACT_NAME'][0])")
curl -s -L -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/$REPO/actions/artifacts/$ARTIFACT_ID/zip" -o /tmp/artifact.zip
unzip -o /tmp/artifact.zip -d /tmp/artifact

# 2. 上传 PVE → 容器
scp -i $SSH_KEY /tmp/artifact/* root@$PVE_IP:/tmp/deploy.bin
ssh -i $SSH_KEY root@$PVE_IP "pct exec $CTID -- systemctl stop nvidia-proxy; \
  pct push $CTID /tmp/deploy.bin $APP_DIR/nvidia-proxy && pct exec $CTID -- chmod +x $APP_DIR/nvidia-proxy; \
  pct exec $CTID -- systemctl start nvidia-proxy"

# 3. 验证
sleep 3
curl -s http://10.0.0.102:3000/health && echo " OK"
```

---

## 九、密钥安全清单

| 密钥 | 存放位置 | 注意事项 |
|------|----------|----------|
| GitHub Token | 本地环境变量 / 密码管理器 | ⚠️ 永不入 git、永不写死脚本 |
| SSH 私钥 | 本地 `~/.ssh/id_ed25519` | 权限 600，不上传 |
| 应用密钥 (API Key 等) | 容器内 `.env`（chmod 600）| 从 git 中排除（加 .gitignore）|
| PVE root 密码 | 密码管理器 | 尽量改用密钥登录 |

**`.gitignore` 必须包含：**

```gitignore
.env
data/
*.db
token.txt
password.txt
```

---

*本指南为通用模板，替换 `<变量>` 即可用于任何项目。生成时间：2026-08-29*