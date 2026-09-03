# 开发交接文档 (Dev Handoff)

> 最后更新：2026-09-03  
> 适用版本：ds-free-api 0.2.7-pre1

本文档记录当前未完成的开发任务，供下一位 AI（或开发者）接手时直接使用。

---

## 当前状态概述

### 已完成

1. **动态添加账号时失效账号保留逻辑**（已合并到主代码）
   - 文件：`src/ds_core/accounts.rs`
   - 改动：`AccountPool::add_account` 方法中（约 L292-304），当 `init_account` 失败时，改为调用 `Account::new_invalid(creds.clone(), Some(e.to_string()))` 并插入池，而不再返回 `Err`。
   - 目的：批量导入 20+ 账号时，即使某些账号初始化失败（被封号、密码错误等），也保留在池中并在前端显示，而不是静默丢弃。
   - 验证：`cargo check --lib` 通过，`cargo test --lib` 通过。

2. **账号状态详表（含失败原因）**（已合并到主代码）
   - 文件：`src/ds_core/accounts.rs`、`web/src/lib/api.ts`、`web/src/pages/DashboardPage.tsx`、`web/src/locales/zh/common.json`、`web/src/locales/en/common.json`
   - 后端改动：
     - `Account` struct 新增 `last_error: std::sync::RwLock<Option<String>>` 字段
     - `new_invalid(creds, error: Option<String>)` 接受可选错误原因
     - `add_account` 和 `init()` 批量初始化失败时传入 `Some(e.to_string())`
     - `re_login_account` 成功时清空 `last_error`，失败时记录原因
     - `AccountStatus` 新增 `last_error: Option<String>`，`account_statuses()` 映射
   - 前端改动：
     - `api.ts` 的 `AccountStatus` 接口补齐 `cooldown_until_ms`/`health_score`/`success_count`/`failure_count`/`last_error` 字段
     - `DashboardPage.tsx` 将 Badge flex 列表替换为 shadcn `Table` 详表（账号/状态/成功/失败/健康/备注），失败原因 hover 悬浮显示
     - zh/en locale 补齐表格列与状态标签翻译键
   - 验证：`cargo check --lib` ✓ | `cargo test --lib` ✓（130 tests）| `npx tsc -b` ✓ | `npx vite build` ✓

---

## 未完成任务（Next Steps）

### 任务 1：部署（待用户确认）

**部署目标**：PVE LXC 容器 CTID `101`，IP `10.0.0.101`

**部署流程**（用户已同意 "使用github编译"，但 git commit 需再次确认）：

1. 确认用户允许 `git commit` + `git push`
2. 执行提交并推送到 GitHub
3. GitHub Actions 触发 release workflow（`.github/workflows/release.yml`），产出 Linux binary
4. 执行 `LXC/deploy-to-pve.ps1` 将 binary 部署到 LXC

---

## 关键文件快速索引

| 功能 | 文件 | 关键位置 |
|------|------|----------|
| 账号结构 (`Account`) | `src/ds_core/accounts.rs` | L68-87 |
| `AccountStatus` 序列化结构 | `src/ds_core/accounts.rs` | L48-66 |
| `new_invalid` 工厂 | `src/ds_core/accounts.rs` | L122-137 |
| `add_account` 动态添加 | `src/ds_core/accounts.rs` | L278-305 |
| `account_statuses` 映射 | `src/ds_core/accounts.rs` | L452-470 |
| TS 接口定义 | `web/src/lib/api.ts` | L108-123 |
| 前端账号展示 | `web/src/pages/DashboardPage.tsx` | L231-250 |
| 中文翻译 | `web/src/locales/zh/common.json` | L48-55 |
| 英文翻译 | `web/src/locales/en/common.json` | 对应节点 |
| 部署脚本 | `LXC/deploy-to-pve.ps1` | 全文 |

---

## 验证步骤

完成改动后按顺序执行：

```powershell
# 1. 后端编译检查
cargo check --lib

# 2. 后端单元测试
cargo test --lib

# 3. 前端构建（若环境无 bun，可用 npx）
cd web
bun run build        # 或: npx vite build
bun run typecheck    # 或: npx tsc -b
```

全部通过后，征得用户同意后提交并部署。
