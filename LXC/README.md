# DS-Free-API LXC 独立部署与源码包

本目录是一个**100% 独立、自包含**的 LXC 部署与编译源码包，既包含可直接部署的 Linux 二进制产物，也包含完整的全栈源代码（Rust 后端 + React 前端），可独立进行二次开发与编译。

---

## 📁 目录内容说明

### 1. 源代码与编译配置
- src/：Rust 后端核心源码（含 OpenAI / Anthropic 协议适配器、PoW 解密、多账号池调度等）
- web/：React + Vite 管理面板前端源码（含 dist 编译产物）
- Cargo.toml / Cargo.lock / ust-toolchain.toml / .cargo/：Rust 构建与依赖锁定配置
- .github/：GitHub Actions 自动化 CI/CD 编译工作流配置

### 2. 部署运行产物与配置文件
- ds-free-api：GitHub Actions 编译生成的 64 位 Linux Release 可执行二进制（已内置最新前端及批量导入账号功能）
- sha3_wasm_bg.7b9ca65ddd.wasm：DeepSeek PoW 算力计算所需的 WASM 核心文件
- config.example.toml：配置文件参考模板
- ds-free-api.service：LXC 容器内 systemd 守护进程服务配置文件
- deploy-to-pve.ps1：Windows PowerShell 一键部署/更新至 PVE 容器脚本

---

## ⚡ 一键部署到 PVE LXC 容器

在 Windows 电脑上打开 PowerShell，进入本目录运行一键部署脚本：

`powershell
cd D:\APP\ds-free-api-0.2.7-pre1\ds-free-api-0.2.7-pre1\LXC
.\deploy-to-pve.ps1
`

脚本将自动执行：
1. 将 ds-free-api 与 sha3_wasm_bg.7b9ca65ddd.wasm 上传至 PVE（10.0.0.254）；
2. 停止 LXC 容器（CTID 101）内的服务；
3. 推送最新文件到容器 /opt/ds-free-api/ 并赋予可执行权限；
4. 重启并验证 ds-free-api 服务状态。

---

## 🌐 访问管理面板与接口

- **管理面板**：http://10.0.0.101:22217/admin
- **配置管理（含批量导入账号）**：http://10.0.0.101:22217/admin/config
- **OpenAI 兼容接口**：http://10.0.0.101:22217/v1/chat/completions
- **Anthropic 兼容接口**：http://10.0.0.101:22217/anthropic/v1/messages