# 106 → stack 对齐 · 范围一页纸

> as_of: 2026-11-16  
> target: `106.52.73.17`  
> 前置口径：本周 **C**（API 宿主）· **容忍 mock** · **预演残留保留** · **支付不动**  
> 下一步：本范围定稿后，再迭代 **deploy 专属部署仓**（本页不写仓名/CI 细节）  
> 对照：`106-followup-guide-20261116.md` · SG `stack-v0.1.20` 现网

---

## 1. 目标（一句话）

把 106 从「三仓三 tip 各自漂」收成 **可同版钉死、可整组回滚** 的运行单元，并先吃掉安全债（回环监听）；**不**在本阶段上真收、不开 stub、不灌生产数据。

---

## 2. 现状锚点（对齐前）

| 组件 | 现形态 | tip / 监听 |
|---|---|---|
| looma-backend | systemd · `~/looma` | `d35ccbb` · `127.0.0.1:5200` |
| thomas-core | systemd · `~/thomas` | tip **`c2e854ce`**（thomas-core#1 bind-loopback）· **`127.0.0.1:5300`** |
| gfcc-kernel | systemd · `~/gfcc-kernel` | `09d9e835` · `127.0.0.1:5211` |
| Docker | 引擎在 · **0 容器 / 0 镜像** | 非现网业务路径 |
| 入口 | nginx :80 | 只反代 looma；门面 `/`、`/v1/endpoints` 仅回环 |
| SG 参考 | Docker stack | looma+gfcc+redis+chroma；**无** thomas `:5300` |

---

## 3. 动哪些 / 不动哪些

### 3.1 本阶段要动（P0 → P1）

| # | 动作 | 学 SG 的点 | 仍用 106 的点 |
|---|---|---|---|
| A | **thomas 改为 `127.0.0.1:5300`**（systemd/`run_core` 绑定） | 回环、缩小暴露面 | 保留 thomas 进程与一本账 |
| B | **定义 stack 清单文件**（例：`STACK.lock` / `stack.json`）钉死三 tip + 生成时间 | `stack-v*` 同版语义 | 首期仍可 systemd 起，不强制 Docker |
| C | **整组发布/回滚脚本契约**：一次操作切 looma+thomas+gfcc 到清单内 tip，失败整组回退 | 原子感 | 可先包现有 `~/…/releases` |
| D | **nginx / 门面限源** 纳入 stack 配置基线（与 `looma-nginx.conf` 同源） | 入口单一 | 不公开门面 |
| E | （P1）**依赖显式化**：若 looma/thomas 需要 redis/chroma，写入 stack 清单；能本机已有则先声明、后容器化 | SG compose 依赖可见 | 可不首期迁容器 |

### 3.2 本阶段明确不动

| 冻结项 | 原因 |
|---|---|
| 微信支付 / 商户 6 件套 / 真收 | 口径 **C** |
| `PAYMENT_STUB_MODE=true` 再开窗 | 口径 **C**；残留订单保留不回滚即可 |
| Stripe / 海外收银键上 106 | CN 站；战场在 SG |
| 灌真岗位 / 题库 / 清 mock | **容忍 mock** |
| 整机照搬 SG compose（撤 systemd 三件套） | SG 无 thomas；106 一本账 drop-in 未设计进海外栈 |
| 公开门面 HTML / `/v1/endpoints` | 私密通道已定 |
| 改 SG 现网 / 动 `api.genz.ltd` | 范围仅 106 |
| 把 gfcc 上游「智能体全栈 compose」当 106 现网 | 与当前 `gfcc-kernel` 单进程不是同一产物 |

### 3.3 刻意后置（留给 deploy 专属仓迭代）

- 新建 **deploy 专属仓**：只承载 106 stack 清单、发布脚本、nginx 基线、环境变量**键名**清单（无密钥）  
- CI：凭证仍走现有 `DEPLOY106_*`；专属仓只触发/编排，不发明第二套主机  
- looma±gfcc **可选** Docker 化；thomas 是否入 compose 单独立项  
- TLS / 边缘（Cloudflare 或证书）  
- 与 SG `join_pin` 对拍自动化  

---

## 4. 非目标（写清以免膨胀）

- 不解决门面 10 条待办里的支付 / OAuth / Stripe / Web Push  
- 不做 106↔SG 数据合并或切权威库  
- 不退役 thomas、不改「一本账」指向（除非另开 ADR）  
- 不把法兰克福 / 旧天翼机拉进本范围  

---

## 5. 验收（对齐阶段完成的定义）

1. `ss`：`5200` / `5211` / **`5300` 均为 `127.0.0.1`**（或等价仅本机）  
2. 存在一份 **stack 清单**，三 tip 可查、与进程/`/health` 一致  
3. 演练一次 **整组回滚**（或 dry-run 到可执行），有人可读回执  
4. 公网：`/health` 仍 200；`/`、`/v1/endpoints` 仍 403；**支付相关探测无回归**（stub 仍关、providers 行为与改前一致）  
5. 文档：本范围 + followup 指南互链；专属仓目录骨架可空但已立项  

---

## 6. 建议迭代顺序

```
本页定稿
  → A 回环 :5300（小步、可当日）
  → B+C stack 清单 + 整组脚本契约（仍 systemd）
  → 建 deploy 专属仓（清单/脚本迁入，106 现网继续吃同一产物）
  → （改拍后）D 依赖容器化 / TLS / 再谈 Docker 化 thomas
```

---

## 7. 待你拍板的两个开关（定稿用）

| # | 问题 | 建议默认 |
|---|---|---|
| Q1 | 首期 stack **是否必须 Docker**？ | **否**（先清单+systemd；Docker 作专属仓二期） |
| Q2 | thomas 是否永久留在 106 stack？ | **是**（与 SG 差异写死；不对齐「SG 无 thomas」） |

回复 Q1/Q2 后即可开专属仓骨架；本页其余冻结表视为已赞成。

---

## 8. 变更记录

| 日期 | 内容 |
|---|---|
| 2026-11-16 | 首版范围：学 SG 的回环与同版语义；保留 106 三件套；支付/mock 冻结；专属仓后置 |
