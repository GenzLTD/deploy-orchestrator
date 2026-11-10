# deploy-orchestrator 交接单

**日期**：2026-11-10
**仓库**：https://github.com/GenzLTD/deploy-orchestrator（私有，`main` 已推 30 文件）
**状态**：仓已建、配置已齐、首次 `verify_only` 全绿（`attempt=2`）
**交接范围**：以下 5 项修复与真链路验证由 Mac 侧执行，Dell 侧不再跟进。

---

## 一、方案结论（已实证，不需要再讨论）

Looma 部署段**不需要先把 8 个提交合进 main**。

- `looma-zervi` 的 `deploy-106.yml` 在 Actions 注册表里是 `active`
- 它的 `push.branches` 只监听 `feat/core-selfcontained`
- 手动触发用 `--ref feat/core-selfcontained`，部署的是该分支头，与 main 无关
- 实证：run `42645153307`，`headSha=62cfa10`，结论 `success`

**合 main 只解决另一件事**：让 main 本身也能被选作 `workflow_dispatch` 的 ref。当前不需要。

### 三条禁令

1. **不要**为了消 `diverged` 把 main 上落后的 3 个提交并回 `feat/core-selfcontained`。它们是 `7f112dc`（merge PR#53）、`6f1fde2`（retire Tianyi mainland deploy）、`97b0606`（deploy-sg 注释），与部署段无关，且并回会触发一次真实部署。
2. **不要**从 main 触发 looma 部署。main 上没有 `deploy-106.yml`，且 main 头是 `6e3d329`，触发等于把线上回退。
3. **不要**在 `feat/core-selfcontained` 上推任何碰 `scripts/**` 或 `.github/workflows/**` 的提交做"试验"。`deploy-106.yml` 的 push 监听会直接向 106 发一版。

---

## 二、新仓已配好的五项

| 名称 | 类型 | 说明 |
|---|---|---|
| `DEPLOY106_HOST` | Variable | 与 `thomas-core` 同源读取 |
| `DEPLOY106_USER` | Variable | `ubuntu` |
| `DEPLOY106_SSH_KEY` | Secret | 本地 `~/.ssh/id_ed25519_newcloud`（注释 `gh-actions-looma-mainland-20261107`），实测可登 106 |
| `DEPLOY106_HOST_FINGERPRINT` | Secret | ECDSA `SHA256:BtFQ…ggtk`，与 106 实机 `ssh-keyscan` 一致 |
| `ORCH_TOKEN` | Secret | **临时**：`szpeter2026` 的 OAuth token（`repo`+`workflow`），跨仓读 actions 已实测可用 |

**待办**：`ORCH_TOKEN` 换成 fine-grained PAT，只授 `GenzLTD/thomas-core` 与 `GenzLTD/looma-zervi` 的 Actions read+write，避免 OAuth 授权失效后编排静默挂掉。

---

## 三、首次运行结果（run 42822485115）

触发：`gh workflow run deploy-all.yml -R GenzLTD/deploy-orchestrator -f verify_only=true`

| 段 | 结论 | 说明 |
|---|---|---|
| 体检 | ✅ success（7 步） | 配置齐全、SSH 用户 `ubuntu`、主机身份已钉（指纹锁 ECDSA） |
| 核 | skipped | `verify_only` 不部署 |
| 宿主 | skipped | 同上 |
| 基础设施 | skipped | 同上 |
| 验收 | ✅ success（5 步） | 见下表 |

### 线上实测值

| 项 | 值 |
|---|---|
| 未 active | `(none)` |
| looma sha | `62cfa10` |
| core sha | `35f0465` |
| 门户 | `200` |
| 信号队列 | `dlq:3,pending:2` |
| 回环绑定 | `127.0.0.1:5211` `127.0.0.1:5200` |
| 套件 verify | 宿主 `:5200` ok ✅ / 门户 200 ✅ / 核日志 `POST /v1/auth/wechat (400)` 已落到核 ✅ |

### 两条被降级的 warning（不会让 run 变红，但是真缺口）

1. `套件版本不一致：仓内 7676443b / 机器 40d9c09d` —— 机器上是 v2.1，仓里是 v2.3
2. `looma→gfcc 队列未清：dlq:3,pending:2` —— `missing_gfcc_secret`

---

## 四、交接待办（按顺序）

### 1. 把 106 上的套件升到 v2.3（先做这个）

`infra` 段执行的是 `cd /home/ubuntu/106-deploy-kit && ./bootstrap.sh infra`，即**机器上那份 v2.1**。仓里带的 v2.3 只在体检时比 sha，不参与执行。只覆盖脚本、不跑任何子命令，线上产物零改动：

```bash
cd ~ && rm -rf /tmp/k && mkdir /tmp/k \
  && python3 -m zipfile -e 106-deploy-kit-v2.3.zip /tmp/k \
  && cp /tmp/k/106-deploy-kit/bootstrap.sh ~/106-deploy-kit/ \
  && cp -r /tmp/k/106-deploy-kit/tests ~/106-deploy-kit/ \
  && bash ~/106-deploy-kit/tests/selfcheck.sh
```

期望 `40d9c09d…` → `7676443b25c40515…`，selfcheck 8/8。

### 2. 改 infra 段：不再信机器上的脚本

当前 `infra` job 直接执行机器上的 `bootstrap.sh`。建议改为先用仓内 `infra/bootstrap.sh` 覆盖远端再执行（可加 `sha256sum` 比对，不一致才传）。这需要改 `.github/workflows/deploy-all.yml` 并推一版 —— 只改编排仓，不碰项目仓。

### 3. 修断腿：looma → gfcc 信号

- 在 `106:/home/ubuntu/looma/.env` 补 `SIGNAL_INGEST_SECRET`（取 gfcc 那 64 字符）+ `GFCC_SIGNAL_INGEST_URL`
- 然后 `python3 replay_dlq.py` 重放 5 条
- 完成后重跑 `verify_only`，`OUTBOX` 应变为 `ok:N` 且无 dlq

### 4. 真链路验证（最后做，会真部署）

前三步完成后再跑全链，`restart_services` 必须显式打开：

```bash
gh workflow run deploy-all.yml -R GenzLTD/deploy-orchestrator \
  -f verify_only=false -f restart_services=true
```

预期：核 → 宿主 → 基础设施 → 验收 四段全绿；looma 段会 `dispatch --ref feat/core-selfcontained`，**这是一次真实部署**。

---

## 五、悬着的状态（需要决策，不属本次交接执行范围）

`LOOMA=62cfa10` 说明 106 上跑的是那 8 个提交构建的版本，而 `main` 头仍是 `6e3d329`。**代码已在生产跑，主线里没有**。短期无碍（部署走分支 ref），长期隐患：任何人从 main 触发部署会把线上回退。是否合 main 另行决策，**不要为消 diverged 而合**。
