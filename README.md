# deploy-orchestrator

106（`106.52.73.17`）的**一层编排入口**。它自己不部署任何东西，只负责按正确顺序调用别人的部署、等到结束、把结果摊成一张表。

## 为什么需要它

原来三件事各自为政，靠人脑记顺序：

1. `GenzLTD/looma-zervi` 的 `deploy-106.yml` —— 部署宿主（:5200）
2. `GenzLTD/thomas-core` 的 `deploy-106.yml` —— 部署核（:5300），并在收到 gfcc 钉时**顺手起 gfcc-kernel（:5211）**
3. `106:/home/ubuntu/106-deploy-kit/bootstrap.sh` —— 基础设施（nginx / systemd 单元 / drop-in / .env 骨架）

真实依赖是单向的：

```
gfcc 契约 ──钉进──▶ thomas-core（核 :5300）──被调用──▶ looma（宿主 :5200）──对外──▶ nginx :80
```

所以顺序反过来就会出现「宿主换了、核还没换」的假绿。本仓把这个顺序固化下来。

**gfcc 没有独立部署流水线**：`GenzLTD/gfcc` 的 `deploy.yml` 只向 thomas-core 发 `repository_dispatch`（`gfcc-tag`），gfcc-kernel 由 thomas-core 的部署连带拉起。这不是缺陷，是设计——契约必须先钉进核。

## 边界（重要）

| 谁 | 管什么 | 不管什么 |
|---|---|---|
| 三个项目仓的 CI | 拉码、装依赖、跑测试、切 `current`、重启自己的服务 | 不碰 nginx，不碰别的仓 |
| `infra/`（= 106-deploy-kit v2.1） | nginx、systemd 单元与 drop-in、.env 骨架、账本路径 | 不装代码、不重启业务进程（除非显式 `restart_services`） |
| 本仓 | 顺序、等待、失败即停、汇总 | 不做任何部署动作，不持有应用私钥以外的凭据 |

**不要把部署逻辑搬进这里。** 一旦本仓开始自己 rsync 代码，就会出现第三份“怎么部署”的真相，双源变三源。

## 首次上线

### 1. 建仓并推上来

```bash
cd deploy-orchestrator
git init -b main && git add -A
git commit -m "feat: 106 一键编排入口（契约→核→宿主→基础设施→验收）"
gh repo create GenzLTD/deploy-orchestrator --private --source=. --push
```

### 2. 配 variable 与 secret

本仓需要与两个项目仓**相同**的四项：

| 名称 | 类型 | 值 |
|---|---|---|
| `DEPLOY106_HOST` | Variable | `106.52.73.17` |
| `DEPLOY106_USER` | Variable | `ubuntu`（可留空，默认 ubuntu） |
| `DEPLOY106_SSH_KEY` | Secret | 与 `looma-zervi` / `thomas-core` 同一个部署私钥内容 |
| `DEPLOY106_HOST_FINGERPRINT` | Secret | 同上的主机指纹（SHA256 或 MD5 冒号串均可） |

再加一个跨仓令牌：

| 名称 | 类型 | 说明 |
|---|---|---|
| `ORCH_TOKEN` | Secret | 对 `GenzLTD/thomas-core` 与 `GenzLTD/looma-zervi` 具备 **Actions: read+write** 的令牌；classic PAT 用 `repo` + `workflow` 两个 scope |

`GITHUB_TOKEN` 不能触发别的仓的 workflow，所以必须有 `ORCH_TOKEN`。

一次性导入（从本机，值不落盘到仓库）：

```bash
gh variable set DEPLOY106_HOST -R GenzLTD/deploy-orchestrator --body 106.52.73.17
gh variable set DEPLOY106_USER -R GenzLTD/deploy-orchestrator --body ubuntu
gh secret set DEPLOY106_SSH_KEY -R GenzLTD/deploy-orchestrator < ~/.ssh/id_ed25519_newcloud
gh secret set DEPLOY106_HOST_FINGERPRINT -R GenzLTD/deploy-orchestrator --body "SHA256:..."
gh secret set ORCH_TOKEN -R GenzLTD/deploy-orchestrator   # 交互粘贴
```

### 3. 先只验收，别全量

```bash
gh workflow run deploy-all.yml -R GenzLTD/deploy-orchestrator -f verify_only=true
gh run watch -R GenzLTD/deploy-orchestrator
```

跑通说明：凭据齐、指纹对得上、sudo 通、106 上的套件在。**这一步不碰任何东西**。

### 4. 再全量

```bash
gh workflow run deploy-all.yml -R GenzLTD/deploy-orchestrator
```

## 典型用法

```bash
# 只换宿主（核不动）
gh workflow run deploy-all.yml -R GenzLTD/deploy-orchestrator -f skip_core=true

# 只换核
gh workflow run deploy-all.yml -R GenzLTD/deploy-orchestrator -f skip_looma=true

# 钉一个新 gfcc 版本（契约 → 核 → 宿主 全走一遍）
gh workflow run deploy-all.yml -R GenzLTD/deploy-orchestrator -f gfcc_ref=v1.4.0

# 部署完顺手重启，让新单元/新内核进进程
gh workflow run deploy-all.yml -R GenzLTD/deploy-orchestrator -f restart_services=true

# 指定 commit（跳过该仓的测试门禁，慎用）
gh workflow run deploy-all.yml -R GenzLTD/deploy-orchestrator \
  -f looma_sha=<40位sha> -f core_sha=<40位sha>
```

`sha` 留空 = 用分支头并**先跑该仓的测试**。填了 sha = 直接部署，不跑测试（原仓 CI 的行为，不是本仓加的）。

## 节点说明

| job | 做什么 | 失败时 |
|---|---|---|
| `preflight` | 配置自检、跨仓互斥检查（别的部署在跑就退出）、线上现状 + 套件 sha 核对 | 立即停，不触发任何部署 |
| `core` | 触发 `thomas-core/deploy-106.yml` 并轮询到结束 | 停，不部署宿主（避免宿主指向旧核） |
| `looma` | 触发 `looma-zervi/deploy-106.yml` 并轮询到结束 | 停，不进 infra |
| `infra` | ssh 执行 `bootstrap.sh infra`（幂等：内容一致则不动） | 停，但仍进验收（看现场） |
| `verify` | 套件 `verify` + 服务/门户/队列/绑定汇总 | 失败即整条红，`::error::` 点名 |

## 已知缺口（本仓不掩盖）

| 缺口 | 现状 | 影响 |
|---|---|---|
| looma → gfcc 信号腿断 | `signal_outbox`：`dlq:3, pending:2`，全因 `missing_gfcc_secret`（宿主侧 `SIGNAL_INGEST_SECRET` 为空） | 人格信标发不出去。`verify` 只给 `::warning::`，不判死——**这是已知未修，不是新故障** |
| 核绑 `0.0.0.0:5300` | `run_core.py` 未改绑回环，公网边界只靠安全组 | 需改代码，不在部署层解决 |
| 套件双源 | `infra/` 是 git 副本，机器上 `/home/ubuntu/106-deploy-kit` 是运行态 | `preflight` 会比对 sha 并在不一致时 `::warning::`，**不自动覆盖**机器 |
| 跨仓互斥只在编排层 | 三仓 CI 的 `concurrency` 不互通 | 手动跑某一仓的 deploy 时，编排层发现不了正在跑的反向情况 |

### 手工同步套件到机器（需要时）

```bash
cd deploy-orchestrator
scp -r infra ubuntu@106.52.73.17:/home/ubuntu/106-deploy-kit.new
ssh ubuntu@106.52.73.17 'set -e; ts=$(date +%Y%m%d-%H%M%S); \
  mv /home/ubuntu/106-deploy-kit /home/ubuntu/106-deploy-kit.bak-$ts; \
  mv /home/ubuntu/106-deploy-kit.new /home/ubuntu/106-deploy-kit; \
  chmod +x /home/ubuntu/106-deploy-kit/bootstrap.sh'
```

## 本地干跑（不上 GitHub 也能验）

```bash
export DEPLOY106_HOST=106.52.73.17 DEPLOY106_USER=ubuntu
export DEPLOY106_SSH_KEY=~/.ssh/<部署私钥>
export DEPLOY106_HOST_FINGERPRINT="SHA256:..."

./scripts/106.sh 'hostname; systemctl is-active looma-backend'
./scripts/106.sh --sudo 'cd /home/ubuntu/106-deploy-kit && ./bootstrap.sh verify'
```

`scripts/106.sh` 会先扫主机公钥、与指纹逐字比对、再锁定算法（ECDSA / ED25519 / RSA 按匹配到的那类），**不会** `StrictHostKeyChecking=no`。指纹对不上直接 `exit 2`，连都不连。

## 变更记录

- v1（2026-11-10）：首版。preflight → core（含 gfcc 钉）→ looma → infra → verify。两个内置 bug 在 106 真机干跑时抓出并修掉：核 `/health` 多行 JSON 导致 sha 提取失败、`systemctl is-active` 只返回状态词导致误判四项全挂。
