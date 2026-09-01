# DS-Free-API 项目交接与运维手册 (HANDOVER)

> 本文档用于记录项目的架构、部署拓扑、关键排错经验、日常迭代流程以及账号批量导入功能细节，以便后续开发者或 AI 快速接手，不丢失上下文。

---

## 1. 架构与服务拓扑

### 1.1 系统架构
- **后端语言/框架**：Rust 1.95.0（Edition 2024）+ Axum + Tokio
- **网络与 WAF 绕过**：wreq + BoringSSL（模拟 Chrome 136 指纹）
- **PoW 算力运算**：wasmtime + sha3_wasm_bg.7b9ca65ddd.wasm
- **前端架构**：React 18 + Vite + shadcn/ui + TailwindCSS + i18n
- **前端集成方式**：前端静态文件位于 web/dist/，通过 ust_embed 在 Rust 编译期直接固化在二进制中。在运行时若检测到物理机/容器内的 web/dist 则优先从磁盘读取，否则读取二进制内嵌资源。

### 1.2 部署拓扑与节点信息
| 角色 | IP / 端口 | 说明 |
| :--- | :--- | :--- |
| **PVE 宿主机** | 10.0.0.254:8006 | root@pam，已配置 SSH 免密公钥 |
| **LXC 容器** | 10.0.0.101（CTID 101） | 生产环境容器，运行 ds-free-api.service |
| **应用目录** | /opt/ds-free-api | 存放可执行文件、wasm 文件、config.toml、stats.json |
| **管理面板** | http://10.0.0.101:22217/admin | 账号池监控、配置编辑、统计面板 |
| **配置页面** | http://10.0.0.101:22217/admin/config | 核心配置项与**账号批量导入** |
| **API 接口** | http://10.0.0.101:22217/v1/chat/completions | OpenAI 兼容标准接口 |
| **GitHub 仓库** | https://github.com/yangtom401/ds-free-api | 用于 GitHub Actions 交叉编译 Linux 产物 |

---

## 2. 目录规范与职责划分

| 目录路径 | 职责与说明 |
| :--- | :--- |
| **src/** | 项目根目录主 Rust 源码（Facade 门面架构） |
| **web/** | 项目根目录前端源码（修改 UI 或 i18n 在此处） |
| **LXC/** | **LXC 专属独立包**：包含完整源码、GitHub Actions 编译出的最新 Linux 二进制、WASM、systemd 服务文件及 deploy-to-pve.ps1 一键部署脚本 |
| **docker1/** | **Docker 专属独立包**：保持原样，供 Docker / docker-compose 环境独立构建与运行 |
| **.github/workflows/** | uild.yml（Push 自动触发编译 Linux 二进制并上传 Artifact） |

---

## 3. 关键问题与排错复盘（防踩坑必读）

### 🚨 坑点 1：管理后台配置页面白屏问题
- **现象**：访问 http://10.0.0.101:22217/admin/config 出现空白。
- **原因**：
  1. 之前修改添加导入账号功能时，ConfigPage.tsx 源码被意外截断损坏；
  2. 新增的批量导入国际化键值未写入 locales/zh/common.json 和 locales/en/common.json；
  3. 修改前端后未在本地执行 
pm run build，编译进 Rust 二进制的前端产物损坏抛错。
- **排查与解决**：
  1. 确保 web/src/pages/ConfigPage.tsx 完整无语法错误；
  2. 补齐中英文语言包；
  3. 修改前端后必须运行 
pm run build 重新生成 web/dist/。

### 🚨 坑点 2：GitHub Actions 编译与推送阻止
- **现象**：Git 推送时报 GH013: Repository rule violations (Push cannot contain secrets)。
- **原因**：文档中包含裸字符的 GitHub Token（ghp_...）触发了 GitHub Secret Scanning 阻断。
- **规避方案**：任何文档和脚本中严禁明文硬编码真实 Token，统一使用 <YOUR_GITHUB_TOKEN> 占位符或环境变量。

### 🚨 坑点 3：Windows OpenSSH scp 传输协议
- **现象**：PowerShell 执行 scp 上传大文件到 PVE 时偶现 Connection closed 或路径解析错误。
- **规避方案**：Windows 下调用 scp 时推荐加入 -O 参数（强制使用老版本 SCP 传输协议），路径中的斜杠统一使用正斜杠 /。

---

## 4. 核心功能：账号批量导入规范

在配置页面（/admin/config）中的账号区域，点击「**批量导入**」按钮，在文本框中粘贴账号，支持以下格式（自动过滤 # 开头的注释行与空行）：

1. **空格 / 制表符分隔**：
   `	ext
   user1@example.com password123
   user2@example.com password456
   `
2. **四横线 / 双横线卡密格式**：
   `	ext
   user1@example.com----password123
   user2@example.com--password456
   `
3. **冒号 / 逗号分隔**：
   `	ext
   user1@example.com:password123
   user2@example.com,password456
   `
4. **手机号格式**：
   `	ext
   13800138000 password123
   +86 13800138000 password123
   `

---

## 5. 日常迭代与部署 SOP

### 第一步：修改代码并验证
`powershell
# 1. 如果修改了前端（web/）：
cd D:\APP\ds-free-api-0.2.7-pre1\ds-free-api-0.2.7-pre1\web
npm run build

# 2. 如果修改了后端（src/）：
cd D:\APP\ds-free-api-0.2.7-pre1\ds-free-api-0.2.7-pre1
cargo check
`

### 第二步：提交并推送到 GitHub 触发编译
`powershell
cd D:\APP\ds-free-api-0.2.7-pre1\ds-free-api-0.2.7-pre1
git add -A
git commit -m feat: 你的更新说明
git push origin master
`
- GitHub Actions 将自动执行 .github/workflows/build.yml 工作流。

### 第三步：一键更新到 PVE LXC 容器
`powershell
# 运行 LXC 目录下的部署脚本：
cd D:\APP\ds-free-api-0.2.7-pre1\ds-free-api-0.2.7-pre1\LXC
.\deploy-to-pve.ps1
`
脚本将自动完成：
1. SCP 上传最新的 ds-free-api 与 sha3_wasm_bg.7b9ca65ddd.wasm 到 PVE 宿主机；
2. 停止容器 101 的服务；
3. 推入 /opt/ds-free-api/ 并赋予执行权限；
4. 启动服务并打印运行状态。

---

## 6. PVE 常用维护命令速查

`ash
# 登录 PVE 宿主机
ssh root@10.0.0.254

# 查看所有容器运行状态
pct list

# 查看 ds-free-api 实时运行日志
pct exec 101 -- journalctl -u ds-free-api -f

# 重启容器内服务
pct exec 101 -- systemctl restart ds-free-api

# 进入容器终端
pct enter 101
`

*交接文档创建时间：2026-09-01*