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

### 1. ~~把 106 上的套件升到 v2.3~~ ✅ 已完成（2026-11-10 22:14，Dell 侧）

原风险是：`infra` 段执行 `cd /home/ubuntu/106-deploy-kit && ./bootstrap.sh infra`，用的是**机器上那份 v2.1**，仓里的 v2.3 只参与比 sha。已处理：

| 项 | 结果 |
|---|---|
| `bootstrap.sh` | `40d9c09d…` → **`7676443b25c40515…`**，原文件备份为 `bootstrap.sh.bak-20261110-221427` |
| `tests/` | 已补到 `~/106-deploy-kit/tests/`（机器上原本没有） |
| selfcheck | **8/8 通过**（在 106 上，bash 5.1.16） |
| preflight | **exit 0**，三单元 + 三 drop-in 全部识别 |
| 模板一致性 | systemd / nginx / env-templates / snapshots **全部与仓内逐字节一致**（只有 `kit.conf.example` 示例文件不同，不影响执行） |
| 线上产物 | **零改动**（只换脚本，未跑 infra/secrets） |

验证证据：run `42832181952` 的体验段已打印 `套件版本不一致` warning 消失，验收段输出 `[bootstrap] === verify（v2.3.0）===`。

**这一步不用再做了。**

### 2. 改 infra 段：不再信机器上的脚本（可选，已缓解）

第 1 项做完后，机器上的脚本已与仓内一致，**当前不阻塞部署**。但这是靠手动同步维持的，下次改 `bootstrap.sh` 又会漂移。可选改进：infra 段执行前先用仓内 `infra/bootstrap.sh` 覆盖远端（加 `sha256sum` 比对，不一致才传）。需要改 `.github/workflows/deploy-all.yml` 并推一版 —— 只改编排仓，不碰项目仓。

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

---

## 六、关于"首次 dispatch 失败"——不是配额问题

曾出现 job `steps=0`、`runner` 空、4 秒失败，容易被误判成 Actions 配额耗尽。**实测不是**：

| run | 情形 | attempt 1 | attempt 2 |
|---|---|---|---|
| `42822485115` | 仓创建后 6 分钟触发 | failure（steps=0） | **success** |
| `42829779973` | 改 visibility 后 1 分钟触发 | failure（steps=0） | **success** |
| `42832181952` | 仓稳定后触发 | **success（一次过）** | — |

规律：仓库**刚创建**或**刚改可见性**之后的首次 dispatch 会瞬时调度失败，重跑或等几分钟即恢复。看到 `steps=0` 不要先怀疑代码或配额，先重跑一次。

配额数据仅作参考：11 月 Actions Linux 用量 2347 分钟，Free 组织额度 2000 分钟，但 Linux 单价 $0.008 分钟、`netAmount` 为 0，未构成阻断——上面的实测已经证伪了"配额锁死"。

---

## 七、当前可部署状态（Dell 侧已解锁）

| 检查项 | 状态 |
|---|---|
| 五项配置 | ✅ 齐（`配置齐全；SSH 用户=ubuntu`） |
| 目标仓 `deploy-106.yml` 可 dispatch | ✅ thomas-core(main) / looma-zervi(feat/core-selfcontained) |
| 分支头与线上一致（幂等） | ✅ core `35f0465` / looma `62cfa10` |
| 106 套件版本 | ✅ `7676443b`（v2.3.0） |
| 跨仓互斥 | ✅ 两仓均 0 个 run 在跑 |
| 编排仓可运行 | ✅ 私有仓，`attempt=1` 直接 success |

按默认参数触发即为**真部署**（`verify_only` 默认 `false`、`skip_*` 默认 `false`、`run_infra` 默认 `true`）：

```bash
gh workflow run deploy-all.yml -R GenzLTD/deploy-orchestrator \
  -f restart_services=true
```

`restart_services` 默认 `false`，只决定 infra 跑完是否重启三服务，不挡部署；要新单元进进程就显式打开。注意这一步会真部署 thomas-core `main` 与 looma `feat/core-selfcontained` 到 106——因两头与线上一致，属幂等重部署，不改变线上版本。
