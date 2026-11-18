# 106 Ask 隐私分轨 + Ollama 运维窗

> target: `106.52.73.17`（大陆 looma 宿主）  
> 承诺：检索可在机内完成；带正文的 RAG 生成不得在未授权情况下出境到云 LLM。  
> **不含任何密钥真值。** 凭据只进主机 `~/looma/.env` / `~/thomas/.env`（chmod 600）。

---

## 1. 定案（评审默认）

| 项 | 值 |
|---|---|
| `RAG_PRIVACY_MODE` | `dual` |
| `RAG_CLOUD_ALLOWED_COLLECTIONS` | `poetry_full`（仅公开古典；其余默认隐私轨） |
| 隐私轨 | 仅 `ollama`；不可用 → `error=rag_local_required`（fail-closed，禁止回落 DeepSeek） |
| 公开轨 / 无检索 | 走 `LLM_PROVIDER_ORDER`（境内 `deepseek,ollama`） |

回滚：临时设 `RAG_PRIVACY_MODE=off`（仅应急；须书面改拍）。

---

## 2. 机上安装 Ollama（运维窗）

```bash
ssh -i ~/.ssh/deploy106_looma ubuntu@106.52.73.17

# 官方安装脚本（或内网镜像等价包）
curl -fsSL https://ollama.com/install.sh | sh

# 拉 CN 基线本地模型（与模板 OLLAMA_MODEL 一致）
ollama pull qwen2.5:7b

# 验活
curl -sS http://127.0.0.1:11434/api/tags | head
curl -sS http://127.0.0.1:11434/api/generate \
  -d '{"model":"qwen2.5:7b","prompt":"ping","stream":false}' | head -c 200
```

要求：`systemctl --user` / 系统服务保证开机自启；仅监听 `127.0.0.1`（勿对公网暴露 11434）。

---

## 3. 写入 env 并重启

在 `~/looma/.env` 与 `~/thomas/.env` 追加或对齐（无密钥写进聊天）：

```bash
RAG_PRIVACY_MODE=dual
RAG_CLOUD_ALLOWED_COLLECTIONS=poetry_full
LLM_PROVIDER_ORDER=deepseek,ollama
OLLAMA_HOST=http://127.0.0.1:11434
OLLAMA_MODEL=qwen2.5:7b
```

```bash
sudo systemctl restart looma-backend thomas-core
# 确认
curl -sS http://127.0.0.1:5200/health | jq '{ollama_ok,rag_privacy_mode,rag_cloud_allowed_collections,llm_provider_order}'
curl -sS http://127.0.0.1:5300/health | jq '{ollama_ok,rag_privacy_mode,rag_cloud_allowed_collections,service}'
```

期望：`ollama_ok=true`，`rag_privacy_mode=dual`，allowlist 含 `poetry_full`。

---

## 4. Ask 冒烟验收

经本机隧道或机上 curl（路径以现网 nginx 为准；以下为本机反代示例）：

```bash
# A. 隐私轨（looma_knowledge 默认不在 allowlist）
# 有检索命中且 Ollama 正常 → llm_provider=ollama，egress=local_only
# Ollama 停掉时 → error=rag_local_required，且不得出现 cloud 生成

# B. 公开轨（poetry）
# 诗词推荐 → egress=cloud_ok（dual 下）或 local_only（若改拍 local_only）

# C. health
# ollama_ok 必须为 true 才算 P2 完成
```

停 Ollama 负向用例（可选）：

```bash
sudo systemctl stop ollama   # 或等价
# 再打隐私 Ask → 必须 error=rag_local_required
sudo systemctl start ollama
```

---

## 5. 与代码仓对应

| 改动 | 位置 |
|---|---|
| 分轨判定 | `looma-zervi` `src/config.py` → `rag_egress_for_collection` |
| 生成闸门 | `src/agents/central_brain.py` → `_call_llm(allowed_providers=…)` |
| Ask 响应字段 | `egress` / `rag_privacy` / `llm_provider` / `error` |
| 单测 | `backend/tests/test_rag_egress_policy.py` |
| 本机模板 | `infra/env-templates/looma.env.example`、`thomas.env.example` |

---

## 6. 本包不做

- 不在评审合入前擅自 SSH 改生产（本手册供运维窗执行）。
- 不灌生产语料、不改 Chroma 存量向量元数据（P3 另评）。
- 不把 DSH/MCP 宿主出域问题并进本窗。
