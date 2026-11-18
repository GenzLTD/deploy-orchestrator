# 106 机后续工作指南（团队补齐用）

> as_of: 2026-11-16  
> target: `106.52.73.17`（大陆 looma 宿主）  
> tip: `d35ccbb837bfab01891904db68052b15625f0f9c`（`looma_sha_kind=deploy_tip`）  
> 对照：门面「待办缺口」10 条 + 本机 SSH/nginx 实测  
> **不含任何密钥真值。凭据只进主机 `~/looma/.env`（chmod 600），勿贴聊天/PR。**

---

## 0. 本周已锁定口径（先读再动手）

| 项 | 决定 | 含义 |
|---|---|---|
| 身份 | **C · 只做 API 宿主** | 支付整条先不动：不开真收、不再开 stub 窗 |
| 数据 | **容忍 mock** | `jobs/list`、题库、空 `documents` 本周不强制灌真 |
| 预演残留 | **保留** | 11-15 stub 预演的 `cloudtest` / 1 笔 paid / subscription **不回滚** |

破口径须书面改拍（例如改 **A 真收** 或取消「容忍 mock」），再动对应条目。

**明确冻结（本周禁止）：**

- 写入微信商户 6 件套并切真收  
- `PAYMENT_STUB_MODE=true` 再开公网 stub  
- 在 106 上配 Stripe / 把 106 当海外收款站  
- 为「灭灯」而灌生产级岗位/题库（除非改拍）

---

## 1. 现状快照（2026-11-16 实测；09:51 复核拓扑）

### 1.1 服务（三件套，不是只有 looma）

106 上 **systemd 三服务均 active**，目录分离、nginx 默认站只反代 looma `:5200`（注释写明不反代 5300/5211）：

| 单元 | 目录 / tip | 监听 | /health |
|---|---|---|---|
| `looma-backend` | `~/looma` → `d35ccbb…` | `127.0.0.1:5200` gunicorn | 200 · `deploy_track=looma` · deepseek · `qcc_configured=true` |
| `thomas-core` | `~/thomas` → tip **`c2e854ce…`**（与 `release_dir` / `health.git_commit` 一致） | **`127.0.0.1:5300`** python `run_core.py` | 200 · `service=thomas-core` · `bridge_configured` · `chroma_ok`；账本 drop-in 指到 `~/looma/data/looma.db`（一本账） |
| `gfcc-kernel` | `~/gfcc-kernel` → `09d9e835…` | `127.0.0.1:5211` uvicorn | 200 · `gfcc_kernel` v1.1.0 |

| 其它 | 结果 |
|---|---|
| SSH | `ubuntu@106.52.73.17`，钥 `~/.ssh/deploy106_looma`（Host `looma-106`） |
| Docker | 引擎在跑，**无业务容器**（与 SG 的 compose 形态不同） |
| Flask 路由（looma） | 165（v1: 162） |
| `/v1/endpoints`（本机） | 31 组 / 164 条 |
| `DEPLOY_REGION` | `CN` |
| `PAYMENT_STUB_MODE` | `false`（stub 窗已关） |
| 支付 providers（CN） | `[]`（无可用通道，符合「支付不动」） |
| `:5300` 公网 | 进程绑 `0.0.0.0`，但外网探测超时（多半安全组未放行）；**仍属暴露面风险，补齐时勿当「未部署」** |

### 1.2 公网 vs 门面

| 路径 | 公网（IP 直连） | 本机 / SSH 隧道 |
|---|---|---|
| `/health` | 200 | 200 |
| `/v1/*`（业务） | 200（按接口） | 200 |
| `/`（API 门面 HTML） | **403**（限源后；勿再写成「仅 404」） | **200** |
| `/v1/endpoints` | **403** | **200** |

nginx 意图：App 继续打 `/v1/*` + `/health`；团队看板仅回环可见。`thomas :5300` / `gfcc :5211` **不在** looma 默认站反代里。

### 1.3 库与 mock（已知、本周容忍）

| 项 | 现状 |
|---|---|
| `documents` | 0 |
| `job_posts` | 0 |
| `GET /v1/jobs/list` | MOCK_JOBS |
| 题库 | 仍走硬编码 mock（门面 P0） |
| `users` / `orders` / `subscriptions` | 约 18 / 1 / 1（含 11-15 预演残留，保留） |

### 1.4 与 SG 的关系（勿混）

| | 106 | SG `api.genz.ltd` / `139.180.184.25` |
|---|---|---|
| 形态 | **systemd 三件套**：looma + thomas-core + gfcc-kernel（无业务 Docker 容器） | **Docker**：`looma-backend` + `gfcc-kernel` + redis + chromadb；**无**本机 `:5300` thomas 进程 |
| 轨 | `deploy_track=looma` · CN | `vultr` · `stack-v0.1.20` |
| tip/pin | looma `d35ccbb`；thomas tip `c2e854ce`；gfcc `09d9e835` | looma stack `6ca4db35` + `looma_sha=d35ccbb` join_pin；gfcc image `stage-3dcb0846…` |
| LLM | deepseek | openai 优先 |
| QCC | configured true | configured false |
| Stripe | 无 | US providers 有 |
| 门面 HTML | 隧道可见 | 公网 `/` 为 JSON「Use /v1/ endpoints」 |

Google / Stripe / Web Push 等海外项，**默认补齐战场在 SG**，不要为灭 106 门面灯而往 CN 宿主硬塞。

---

## 2. 团队如何看门面（私密通道）

已落地：nginx 对 `/`、`/v1/endpoints` 仅 `allow 127.0.0.1; allow ::1; deny all;`。

```bash
# 仓库脚本（推荐）
/Applications/ServBay/www/looma-zervi-dev/scripts/ssh-looma-board-106.sh

# 或等价
ssh -i ~/.ssh/deploy106_looma -N -L 18080:127.0.0.1:80 ubuntu@106.52.73.17
```

浏览器：

- 门面：`http://127.0.0.1:18080/`
- 清单：`http://127.0.0.1:18080/v1/endpoints`
- 健康：`http://127.0.0.1:18080/health`

需要：106 SSH 钥（与 CI `DEPLOY106_SSH_KEY` 同源或只读副本）。**不要**把门面重新对公网 200。

配置参考：`looma-zervi-dev/scripts/looma-nginx.conf`、`ssh-looma-cloud.config.example`（Host `looma-106`）。  
主机备份：`/etc/nginx/sites-available/looma.conf.bak-board-*`。

---

## 3. 待办 10 条：可解性与补齐指引

门面 = **运行时探测（auto）** + **`backend/open_items.json`（编辑后刷新）**。  
灭「auto」灯靠环境/数据；灭清单灯靠改 JSON 或做完对应工程。

### 图例

- ✅ 不破 C，现在可做  
- ⏸️ 本周冻结 / 需改拍  
- 🌐 主战场在 SG（或海外轨）  
- 🔧 代码/确认项  

---

### P0 · 微信支付商户凭证不完整 → stub 假订单

| | |
|---|---|
| 状态 | ⏸️ **本周不解（口径 C）** |
| 探测 | 缺 `mchid, api_v3_key, serial_no, private_key` |
| 106 现况 | 登录侧可有 `WECHAT_APPID`；商户键仍缺；`PAYMENT_STUB_MODE=false` → providers 空，**不是**「假订单乱飞」，而是 **CN 无支付通道** |
| 改拍为 A 后物料 | 商户平台 `pay.weixin.qq.com`：**mchid / APIv3 密钥 / 证书序列号 / apiclient_key.pem**；`WECHAT_NOTIFY_URL`（HTTPS）；AppID 与商户号绑定（开发者平台「小程序」等拿 AppID，**6 件套主体不在「我的业务」下拉里齐**） |
| `.env` 键 | `WECHAT_MCHID` `WECHAT_API_V3_KEY` `WECHAT_SERIAL_NO` `WECHAT_PRIVATE_KEY_PATH` `WECHAT_NOTIFY_URL`（+ 绑定用的 `WECHAT_APPID`） |
| 验收 | stub 关且商户齐 → 真下单；门面该条 auto 灭 |

---

### P1 · Google OAuth Client ID 未配置

| | |
|---|---|
| 状态 | 🌐 可做，但 **优先 SG**；106=CN 非 G3 主路径 |
| 探测 | `GOOGLE_CLIENT_ID` 空 |
| 补齐 | Google Cloud 建 OAuth 客户端 → 写入目标机 `.env`（SG 为主） |
| 关联 | 下条「GIS 已接待 E2E」 |

---

### P1 · Stripe 凭证未配置

| | |
|---|---|
| 状态 | ⏸️ 对 106：**不做**；🌐 SG 已具备 US Stripe |
| 说明 | 106 `DEPLOY_REGION=CN`；在 106 配 Stripe 与架构冲突 |
| 补齐 | 只在海外部署轨维护 `STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` |

---

### P1 · 华为推送凭证未配置

| | |
|---|---|
| 状态 | ✅ 有凭证则可做；无凭证则标延后 |
| 探测 | `HUAWEI_PUSH_CLIENT_ID` 空 |
| 补齐 | 华为推送控制台凭证 → `.env`（及代码要求的配套键，以 `backend/.env.example` 为准） |
| 验收 | 门面 auto 灭；真机推送另开 E2E |

---

### P0 · 无持久化岗位 · MOCK_JOBS

| | |
|---|---|
| 状态 | ⏸️ **本周容忍 mock** |
| 探测 | `documents(job,processed)=0` → fallback MOCK |
| 改拍后 | 灌入 processed 的 job 类 `documents`，或走真 `job_posts` 路径（以当前 tip 代码为准） |
| 验收 | `GET /v1/jobs/list` 不再是固定三家 MOCK；auto 灭 |

---

### P0 · 答题题库 MOCK_QUIZ_QUESTIONS

| | |
|---|---|
| 状态 | ⏸️ 与「容忍 mock」一致本周可搁；🔧 改拍后接真源 |
| 位置 | `game_routes.py` quiz/start（门面所注行号随 tip 漂移，以仓库为准） |
| 补齐 | 题库表或上游 API + 去掉无条件 mock 返回 |
| 验收 | `POST /v1/game/quiz/start` 返回非硬编码集；改 `open_items.json` 对应条 |

---

### P1 · Google OAuth 前端 GIS 已接 · 待 Client ID + E2E

| | |
|---|---|
| 状态 | 🌐 同 Google；见 `MULTI_CLIENT_CX_STRATEGY.md` G3-M2 |
| 补齐 | 配 Client ID → 海外前端 E2E；106 不作为主验收机 |

---

### P1 · Timeline backfill 白名单是否覆盖 quiz / share / login

| | |
|---|---|
| 状态 | ✅ **推荐下一刀**（不破 C） |
| 文档 | `ENGINEERING_CLOSED_LOOP_P0.md` §E1.6 |
| 动作 | 核对白名单是否含 quiz / share / login → 缺则补代码或确认「有意不含」→ 更新/关闭 `open_items.json` 条目 |
| 验收 | 清单该项关闭或改为「已确认：含/不含 + 理由」 |

---

### P2 · G3-M4 Web Push 海外通知

| | |
|---|---|
| 状态 | 🌐 专项；不挡 106 API 宿主 |
| 文档 | `MULTI_CLIENT_CX_STRATEGY.md` G3-M4 |
| 补齐 | 海外轨实现；勿塞进 106 CN 周目标 |

---

### P2 · 腾讯 1.14.202.161:8998 QCC 网关退役

| | |
|---|---|
| 状态 | ✅ **可半解**（不破 C） |
| 现况 | health 已 `qcc_configured=true`；`QCC_MCP_BASE_URL` 往往未设 → 直连官方 `agent.qcc.com` |
| 选项 A | 本地 ServBay `:8998` 承接后，106 `.env` 设 `QCC_MCP_BASE_URL` 指向可达网关，并确认白名单含 106 出口 |
| 选项 B | 明确「直连官方可接受」→ 改 `open_items.json` 文案/关闭退役项，避免假缺口 |
| 文档 | `docs/QCC_GATEWAY_LOCAL.md` |
| 验收 | 门面依赖区与清单一致；credit 链路抽检 |

---

## 4. 建议执行顺序（不破 C）

1. **Timeline 白名单确认（#8）** — 纯确认/小改，立刻能关清单项  
2. **QCC 口径落地（#10）** — 设 `QCC_MCP_BASE_URL` 或改 JSON 说明  
3. **华为推送（#4）** — 仅当凭证已批下来  
4. **其余** — 等改拍：A 真收 / 取消容忍 mock；海外项走 SG  

改拍对照：

| 若改拍为… | 解锁 |
|---|---|
| **A 大陆真收** | P0 微信商户 + notify HTTPS + 实单验收 |
| **取消容忍 mock** | P0 岗位灌数 + P0 题库真源 |
| **B 再 stub 预演** | 短窗 `PAYMENT_STUB_MODE` + nginx 限源（参 11-15 预演手册）；与现行 C 互斥 |

---

## 5. 操作备忘（补齐时用）

### 5.1 只读自检

```bash
ssh looma-106 'systemctl is-active looma-backend; curl -sS http://127.0.0.1:5200/health'
# 门面隧道见 §2
```

### 5.2 改 `.env`（有授权时）

- 路径：`/home/ubuntu/looma/.env`（chmod 600）  
- 改完：`sudo systemctl restart looma-backend`  
- **禁止**在 systemd drop-in 里写支付密钥（与预演 B3 一致）  
- CI **不**下发密钥；deploy 脚本不写 secrets  

### 5.3 改团队清单

- 文件：`~/looma/current/backend/open_items.json`（发布树内；下次 release 会被覆盖 → **源仓库同步提交**）  
- 门面：隧道打开后刷新即可  

### 5.4 nginx / 发布注意

- 门面限源已写入 `scripts/looma-nginx.conf`；`deploy-looma-106.sh` 会把该文件拷到 sites-available  
- 以后发版勿把 `/`、`/v1/endpoints` 改回公网 200  
- 公网继续只暴露 App 需要的 `/v1/*` + `/health`  

### 5.5 预演残留（保留）

- 勿擅自删 `orders` / 降 `cloudtest` tier，除非产品书面要求回滚  
- 新支付/账户测试避开污染该账号，或另开专用测试用户  

---

## 6. 一页纸：谁补什么

| 角色 | 补齐内容 |
|---|---|
| 账密/商户 Owner | 微信 6 件套、华为推送、Google/Stripe（后两者交 SG）— **改拍后**再给 |
| 106 运维 | `.env` 落盘、restart、QCC_MCP_BASE_URL、nginx 限源不被回滚 |
| 后端 | Timeline 白名单、题库/岗位真源（改拍后）、`open_items.json` 与仓库同步 |
| 前端 / G3 | Google GIS E2E、Web Push — **SG / 海外** |
| 全员 | 看门面走 §2 隧道；公网 403 是预期 |

---

## 6.1 Ask 隐私分轨（RAG 出境纪律）

完整手册：[106_RAG_PRIVACY_DUAL_TRACK.md](./106_RAG_PRIVACY_DUAL_TRACK.md)

定案摘要：`RAG_PRIVACY_MODE=dual`；`RAG_CLOUD_ALLOWED_COLLECTIONS=poetry_full`；隐私命中仅 Ollama，不可用则 `rag_local_required`（禁止回落云）。**106 默认模型 `qwen2.5-coder:1.5b`**；**向量轨 `EMBED_PROVIDER_ORDER=ollama`**；安装优先 **Docker 边车**（`127.0.0.1:11434`）。机上须 Ollama 探活后再开 dual；验收看 `/health` 的 `ollama_ok` 与 Ask 的 `egress` / `llm_provider`。

运维窗冒烟脚本（本机隧道或机上执行）：`scripts/106-rag-privacy-smoke.sh`。

---

## 7. 变更记录

| 日期 | 内容 |
|---|---|
| 2026-11-18 | Ask 隐私分轨：dual + poetry allowlist；对齐 1.5b + EMBED 本地 + Docker 边车；smoke 脚本 |
| 2026-11-18 | Ask 隐私分轨：dual + poetry allowlist；Ollama 运维窗手册与 smoke 脚本（初版） |
| 2026-11-16 | 首版：C + 容忍 mock + 保留预演；基线与私密通道；10 条可解性与补齐指引 |
| 2026-11-16 | 复核：更正「106 只有 looma」——实为 looma+thomas+gfcc 三件套；SG 为 Docker looma+gfcc（无 :5300）；公网门面为 403 非 404 |
| 2026-11-16 | thomas tip：清单改为代码钉 `35f0465`；现网 `current` 目录名 `381042d2` 为 looma 树误标，`THOMAS_CORE_PIN` 为准 |
| 2026-11-16 | thomas tip → `c2e854ce`（合入 bind-loopback）；`:5300` 回环验收通过；清单与现网 tip/health/release_dir 对齐 |
