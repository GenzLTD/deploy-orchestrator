# 106 Ask 隐私分轨 + Ollama 运维窗

> target: `106.52.73.17`（大陆 looma 宿主）  
> 承诺：检索可在机内完成；带正文的 RAG 生成不得在未授权情况下出境到云 LLM。  
> **不含任何密钥真值。** 凭据只进主机 `~/looma/.env` / `~/thomas/.env`（chmod 600）。  
> 对齐：playbook v3（Docker 边车 + `qwen2.5-coder:1.5b` + 向量轨本地）。

---

## 1. 定案（评审默认）

| 项 | 值 |
|---|---|
| `RAG_PRIVACY_MODE` | `dual` |
| `RAG_CLOUD_ALLOWED_COLLECTIONS` | `poetry_full`（仅公开古典；其余默认隐私轨） |
| 隐私轨 | 仅 `ollama`；不可用 → `error=rag_local_required`（fail-closed，禁止回落 DeepSeek） |
| 公开轨 / 无检索 | 走 `LLM_PROVIDER_ORDER`（境内 `deepseek,ollama`） |
| 向量轨 | `EMBED_PROVIDER_ORDER=ollama`（禁止默认 openai 先试导致语料出域） |
| 默认模型 | **`qwen2.5-coder:1.5b`**（106 无 GPU / ~7.6 GiB；`7b` 仅二阶段实测） |
| 安装形态 | **Docker 边车**（`127.0.0.1:11434`）；勿整栈 compose 替换 systemd |

回滚：临时设 `RAG_PRIVACY_MODE=off`（仅应急；须书面改拍）。

**序：** 先边车探活（`/api/tags`）→ tip 含分轨代码（≥`52e264b` 系）→ 再开 `dual`。现网仅 `d35ccbb` 时写 RAG 键不生效。

---

## 2. 机上 Ollama（运维窗 · 边车优先）

放置：`/home/ubuntu/ollama/`（与 `~/looma` 并列）。须 jun 授权后再执行。

```yaml
# /home/ubuntu/ollama/docker-compose.yml（示意）
name: looma-ollama
services:
  ollama:
    image: ollama/ollama:latest   # 授权后钉 digest
    container_name: looma-ollama
    restart: unless-stopped
    ports:
      - "127.0.0.1:11434:11434"   # 仅回环
    volumes:
      - ollama-data:/root/.ollama
    environment:
      - OLLAMA_HOST=0.0.0.0:11434
volumes:
  ollama-data:
```

```bash
ssh -i ~/.ssh/deploy106_looma ubuntu@106.52.73.17   # 或显式 -i 本机钥

cd /home/ubuntu/ollama
docker compose up -d
docker exec looma-ollama ollama pull qwen2.5-coder:1.5b
docker exec looma-ollama ollama pull nomic-embed-text:latest

# 探活（勿用 /health 的 providers_configured.ollama）
curl -sS http://127.0.0.1:11434/api/tags | head
ss -lntp | grep 11434   # 必须只有 127.0.0.1
```

备选：裸机 `curl -fsSL https://ollama.com/install.sh | sh`（等价；本窗优先边车以便钉镜像）。

要求：仅 `127.0.0.1:11434`；**禁止**挂 nginx / 公网暴露。

---

## 3. 写入 env 并重启

在 `~/looma/.env` 与 `~/thomas/.env` 追加或对齐（无密钥写进聊天）：

```bash
# 生成轨（MVP：DeepSeek 主 + ollama 兜底）
LLM_PROVIDER_ORDER=deepseek,ollama
OLLAMA_HOST=http://127.0.0.1:11434
OLLAMA_MODEL=qwen2.5-coder:1.5b

# 向量轨（隐私目标必填）
EMBED_PROVIDER_ORDER=ollama
EMBED_MODEL=nomic-embed-text:latest

# 隐私分轨（须 tip 含 RAG 分轨代码后再开）
RAG_PRIVACY_MODE=dual
RAG_CLOUD_ALLOWED_COLLECTIONS=poetry_full
```

```bash
sudo systemctl restart looma-backend thomas-core
curl -sS http://127.0.0.1:5200/health | jq '{ollama_ok,rag_privacy_mode,rag_cloud_allowed_collections,llm_provider_order}'
curl -sS http://127.0.0.1:5300/health | jq '{ollama_ok,rag_privacy_mode,rag_cloud_allowed_collections,service}'
```

期望（tip≥分轨）：`ollama_ok=true`，`rag_privacy_mode=dual`，allowlist 含 `poetry_full`。

---

## 4. Ask 冒烟验收

```bash
# 或本机：./scripts/106-rag-privacy-smoke.sh
# A. 隐私轨：有命中 + Ollama 正常 → llm_provider=ollama，egress=local_only
#    Ollama 停掉 → error=rag_local_required，不得回落云
# B. 公开轨 poetry → egress=cloud_ok（dual）
# C. health.ollama_ok == true
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

- 不在 jun 授权前擅自 SSH 改生产。
- 不灌生产语料、不改 Chroma 存量向量元数据。
- 不把 DSH/MCP 宿主出域、mTLS、整栈 compose 并进本窗。
