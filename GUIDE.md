# 第三方模型 / Proxy Provider 完整适配方案

> 适用场景：AWS Bedrock、Google Vertex AI、LiteLLM proxy、CC Switch 等非标准 provider

---

## 目录

1. [问题根源分析](#1-问题根源分析)
2. [诊断：确认你的 model id](#2-诊断确认你的-model-id)
3. [方案 A（推荐）：forceInherit 全继承模式](#3-方案-a推荐forceinherit-全继承模式)
4. [方案 B（精细）：tier alias 重映射模式](#4-方案-b精细tier-alias-重映射模式)
5. [层 3：运行时补丁（apply.sh）](#5-层-3运行时补丁applysh)
6. [层 4：项目级覆盖](#6-层-4项目级覆盖)
7. [完整执行步骤（copy-paste 版）](#7-完整执行步骤copy-paste-版)
8. [验证方法](#8-验证方法)
9. [常见报错对照表](#9-常见报错对照表)
10. [回滚方法](#10-回滚方法)
11. [不能完全解决的边界问题](#11-不能完全解决的边界问题)

---

## 1. 问题根源分析

OMC 内部有 3 个独立的 model 注入/校验层，每一层都可能在第三方 provider 下失败：

```
┌────────────────────────────────────────────────────────┐
│ 层 A  pre-tool-enforcer.mjs  (hook)                     │
│       └─ 拦截 Task/Agent 调用，检查 model 是否合法       │
│          ✗ 第三方: tier alias 被拒绝                    │
├────────────────────────────────────────────────────────┤
│ 层 B  delegation-enforcer.js (runtime JS)               │
│       └─ 注入默认 model，归一化 model id                 │
│          ✗ 第三方: provider-specific id 被改成 sonnet 等 │
├────────────────────────────────────────────────────────┤
│ 层 C  agents/definitions.js  (registry)                 │
│       └─ 每个 agent 有默认 model (opus/sonnet/haiku)     │
│          ✗ 第三方: Anthropic family id 无效              │
└────────────────────────────────────────────────────────┘

额外:  autopilot/ralph/ultraqa prompt builder 会生成
       Task(model="opus") 之类的文本 → LLM 照着发出去 → 层 A 拦截
```

**核心矛盾：**  
OMC 的 tier alias（`haiku/sonnet/opus`）在 Anthropic 标准 API 下合法，  
但在 Bedrock/Vertex/proxy 下 Claude Code 不知道怎么展开它们。

**解法：** 让 OMC 不注入任何 model，或者注入正确的 provider-specific model id。

---

## 2. 诊断：确认你的 model id

先搞清楚你的实际 model id，后续所有配置都要用它。

```bash
# 检查当前会话 Claude Code 使用的 model
echo "ANTHROPIC_MODEL: $ANTHROPIC_MODEL"
echo "CLAUDE_MODEL:    $CLAUDE_MODEL"

# 查看 Claude Code 设置文件
cat ~/.claude/settings.json | grep -A5 '"model"'

# 检查是否 Bedrock
echo "CLAUDE_CODE_USE_BEDROCK: $CLAUDE_CODE_USE_BEDROCK"
echo "CLAUDE_CODE_USE_VERTEX:  $CLAUDE_CODE_USE_VERTEX"
```

**典型 model id 示例：**

| Provider | 示例 model id |
|----------|--------------|
| Bedrock (区域前缀) | `us.anthropic.claude-sonnet-4-6-v1:0` |
| Bedrock (global) | `global.anthropic.claude-opus-4-7-v1:0` |
| Bedrock (ARN) | `arn:aws:bedrock:us-east-1:123456:inference-profile/...` |
| Bedrock (旧版) | `anthropic.claude-3-haiku-20240307-v1:0` |
| Vertex AI | `vertex_ai/claude-sonnet-4-6` |
| LiteLLM proxy | `bedrock/anthropic.claude-...` 或自定义别名 |
| CC Switch/proxy | 取决于你的配置 |

---

## 3. 方案 A（推荐）：forceInherit 全继承模式

**原理：** 禁止 OMC 给子代理注入任何 model 参数，让所有子代理继承父 session 的 model 设置。

**适用：** Bedrock / Vertex / 任何非标准 provider。配置最简单，最稳。

**不适用：** 希望不同复杂度任务用不同 model 时（用方案 B）。

### 3.1 用户配置（持久化，全局生效）

```bash
# 创建目录（若不存在）
mkdir -p ~/.config/claude-omc
```

编辑文件 `~/.config/claude-omc/config.jsonc`：

```jsonc
{
  // 全局路由配置
  "routing": {
    // 关键：强制所有子代理继承父 session model，不注入任何 Claude tier alias
    "forceInherit": true
  }
}
```

### 3.2 环境变量（可写入 ~/.bashrc 或 ~/.zshrc）

```bash
# 明确告诉 OMC hook 该用哪个 model 作引导提示
export OMC_SUBAGENT_MODEL="us.anthropic.claude-sonnet-4-6-v1:0"  # 改成你的实际 model id

# 也可以用 env var 开启 forceInherit（与 config 文件二选一即可，两者都设置也没问题）
export OMC_ROUTING_FORCE_INHERIT=true
```

### 3.3 验证 forceInherit 是否生效

```bash
# 启动 Claude Code 后，在 Claude 会话里执行一个 Task 并观察是否有 model 参数被注入
# 日志里不应该再出现 '[MODEL ROUTING]' 报错
```

---

## 4. 方案 B（精细）：tier alias 重映射模式

**原理：** 保留 OMC 的智能路由（不同任务用不同 tier），但把 `haiku/sonnet/opus` 这三个 alias 重映射到你的 provider-specific model id。

**适用：** 希望复杂任务用更大模型、简单任务用轻量模型，同时兼容第三方 provider。

### 4.1 用户配置文件

编辑 `~/.config/claude-omc/config.jsonc`：

```jsonc
{
  "routing": {
    // 不用 forceInherit，改用 tierModels 精确映射
    "forceInherit": false,

    // 把三个 tier 映射到你 provider 的实际 model id
    "tierModels": {
      "HIGH":   "us.anthropic.claude-opus-4-7-v1:0",      // 替换为你的 HIGH tier model
      "MEDIUM": "us.anthropic.claude-sonnet-4-6-v1:0",   // 替换为你的 MEDIUM tier model
      "LOW":    "us.anthropic.claude-haiku-4-5-v1:0"     // 替换为你的 LOW tier model
    },

    // 把文本 alias 也映射一遍（处理 skill/prompt builder 生成的显式 model= 参数）
    "modelAliases": {
      "opus":   "us.anthropic.claude-opus-4-7-v1:0",
      "sonnet": "us.anthropic.claude-sonnet-4-6-v1:0",
      "haiku":  "us.anthropic.claude-haiku-4-5-v1:0"
    }
  }
}
```

### 4.2 环境变量（替代 config 文件中的 tierModels）

```bash
# 优先级高于 config 文件中的 tierModels
export OMC_MODEL_HIGH="us.anthropic.claude-opus-4-7-v1:0"
export OMC_MODEL_MEDIUM="us.anthropic.claude-sonnet-4-6-v1:0"
export OMC_MODEL_LOW="us.anthropic.claude-haiku-4-5-v1:0"

# 别名 env var（与 config.modelAliases 等价）
export OMC_MODEL_ALIAS_OPUS="us.anthropic.claude-opus-4-7-v1:0"
export OMC_MODEL_ALIAS_SONNET="us.anthropic.claude-sonnet-4-6-v1:0"
export OMC_MODEL_ALIAS_HAIKU="us.anthropic.claude-haiku-4-5-v1:0"

# 子代理路由目标
export OMC_SUBAGENT_MODEL="us.anthropic.claude-sonnet-4-6-v1:0"
```

---

## 5. 层 3：运行时补丁（apply.sh）

无论用方案 A 还是 B，都建议额外跑一次 `apply.sh`，它会修复 prompt builder 里残留的硬编码 `model="opus"` 文本，避免 LLM 被这些文本诱导生成不兼容的 Task 调用。

```bash
# 1. 进入源码仓库（或直接用你已安装的 OMC 位置也行）
cd /path/to/oh-my-claudecode  # 或你克隆仓库的位置

# 2. 查看会 patch 哪些文件
sh scripts/thirdparty-runtime-patch/apply.sh --list-targets

# 3. 预演（不实际写文件）
sh scripts/thirdparty-runtime-patch/apply.sh --dry-run

# 4. 实际执行
sh scripts/thirdparty-runtime-patch/apply.sh

# 5. 查看结果（输出里每行显示 [patched] / [already_patched] / [not_matched]）
```

**apply.sh 做了什么：**

| 目标文件 | patch 内容 |
|----------|-----------|
| `scripts/pre-tool-enforcer.mjs` | 放宽对 tier alias 的 deny，减少误拒 |
| `dist/features/delegation-enforcer.js` | provider-specific model id 不再被归一化为 `sonnet` 等 |
| `dist/agents/definitions.js` | agent registry 优先复用 session/provider model，而不是硬编码 tier alias |
| `dist/team/stage-router.js` | team Claude worker 优先复用 provider session model |
| `dist/team/model-contract.js` | 启动 Claude worker 时 pass through proxy model id |
| `dist/hooks/autopilot/**/*.js` | 删除 autopilot prompt builder 里的 `model="opus"` 等文本 |
| `skills/**/*.md` | 删除 skill 文档里的显式 `model="haiku|sonnet|opus"` 示例 |
| `agents/*.md` | agent frontmatter `model:` 字段改为 `model: inherit` |

---

## 6. 层 4：项目级覆盖

**路径：** 项目根目录下的 `.claude/omc.jsonc`（只影响该项目）

```jsonc
{
  "routing": {
    "forceInherit": true  // 或用方案 B 的 tierModels/modelAliases
  },

  // 可选：team 每个角色单独指定 model
  "team": {
    "roleRouting": {
      // model 填 tierModels 里的 key（HIGH/MEDIUM/LOW）或完整 model id
      "executor":        { "provider": "claude", "model": "MEDIUM" },
      "architect":       { "provider": "claude", "model": "HIGH"   },
      "code-reviewer":   { "provider": "claude", "model": "HIGH"   },
      "planner":         { "provider": "claude", "model": "HIGH"   },
      "debugger":        { "provider": "claude", "model": "MEDIUM" },
      "explore":         { "provider": "claude", "model": "LOW"    }
    }
  }
}
```

---

## 7. 完整执行步骤（copy-paste 版）

> 把下面所有 `YOUR_MODEL_ID` 替换为你的实际 model id，然后从上到下执行一遍。

```bash
# ====== 第 0 步：确认你的 model id ======
YOUR_SONNET_ID="us.anthropic.claude-sonnet-4-6-v1:0"   # 修改这里
YOUR_OPUS_ID="us.anthropic.claude-opus-4-7-v1:0"      # 修改这里
YOUR_HAIKU_ID="us.anthropic.claude-haiku-4-5-v1:0"    # 修改这里

# ====== 第 1 步：写用户配置（方案 A forceInherit，最稳）======
mkdir -p ~/.config/claude-omc
cat > ~/.config/claude-omc/config.jsonc <<EOF
{
  "routing": {
    "forceInherit": true
  }
}
EOF

# ====== 第 2 步：设置环境变量（写入 shell 配置文件使其持久化）======
cat >> ~/.bashrc <<EOF

# === OMC 第三方 provider 适配 ===
export OMC_ROUTING_FORCE_INHERIT=true
export OMC_SUBAGENT_MODEL="$YOUR_SONNET_ID"
EOF

# 立即生效（当前 shell）
export OMC_ROUTING_FORCE_INHERIT=true
export OMC_SUBAGENT_MODEL="$YOUR_SONNET_ID"

# ====== 第 3 步：运行安装后补丁 ======
# （先确认找到了正确的安装目录）
sh scripts/thirdparty-runtime-patch/apply.sh --list-targets

# 预演
sh scripts/thirdparty-runtime-patch/apply.sh --dry-run

# 实际 patch
sh scripts/thirdparty-runtime-patch/apply.sh

# ====== 第 4 步：重启 Claude Code ======
# 让 hooks 和配置重新加载
```

---

## 8. 验证方法

```bash
# 8.1 验证 apply.sh 的实际 patch 状态
sh scripts/thirdparty-runtime-patch/apply.sh --dry-run 2>&1 | grep -E '\[(would_patch|already_patched|not_matched|patched)\]'

# 8.2 验证 config 文件语法
node -e "
const fs = require('fs');
const { parse } = require('jsonc-parser');
const content = fs.readFileSync(process.env.HOME + '/.config/claude-omc/config.jsonc', 'utf8');
const result = parse(content);
console.log('routing.forceInherit:', result?.routing?.forceInherit);
"

# 8.3 验证 env var 是否被正确继承
env | grep -E 'OMC_|ANTHROPIC_MODEL|CLAUDE_MODEL|CLAUDE_CODE_USE_'

# 8.4 验证 agent definitions 里不再有硬编码 model 回落
grep -n "model: 'sonnet'\|model: 'opus'\|model: 'haiku'" \
  ~/.claude/plugins/cache/omc/oh-my-claudecode/*/dist/agents/definitions.js | head -20

# 8.5 验证 pre-tool-enforcer 的放宽已生效
grep -n 'isTierAlias(toolModel)' \
  ~/.claude/plugins/cache/omc/oh-my-claudecode/*/scripts/pre-tool-enforcer.mjs
```

---

## 9. 常见报错对照表

| 报错关键字 | 原因 | 解法 |
|-----------|------|------|
| `[MODEL ROUTING] This environment uses a non-standard provider` | pre-tool-enforcer 拒绝了 tier alias | 1. 运行 apply.sh 补丁 2. 设置 `OMC_SUBAGENT_MODEL` |
| `unknown provider for model claude-haiku-4-5-20251001` | delegation-enforcer 归一化后的 model id provider 不认 | 1. 运行 apply.sh 补丁 2. 设置 `forceInherit: true` |
| `[MODEL ROUTING] Your session model "...[1m]"` | 会话模型带 `[1m]` 后缀，子代理继承后变成非法 id | 在 env 设置不带 `[1m]` 的 `OMC_SUBAGENT_MODEL` |
| `Agent type not found` | subagent_type 写错（可能是 skill 被当成 agent 调用） | 不是 model 问题，检查 subagent_type 是否存在 |
| `API Error: 502` | provider 端模型不存在或格式错误 | 确认 `YOUR_*_ID` 是该 provider 的合法 model id |

---

## 10. 回滚方法

```bash
# 恢复最近一次 apply 备份
sh scripts/thirdparty-runtime-patch/restore.sh

# 恢复指定备份（先查看有哪些备份）
ls ~/.claude/.omc-thirdparty-runtime-patch/
sh scripts/thirdparty-runtime-patch/restore.sh --backup-dir ~/.claude/.omc-thirdparty-runtime-patch/20260417-180000

# 回滚用户配置
rm ~/.config/claude-omc/config.jsonc

# 回滚 env var（从 ~/.bashrc 删除相关行）
```

---

## 11. 不能完全解决的边界问题

这三个问题无法通过 apply.sh 或配置文件完全消除：

### 11.1 Claude Code 工具 schema 的 model 参数限制

- **证据：** `scripts/pre-tool-enforcer.mjs:718-721`
- **本质：** Agent/Task 工具的参数 schema 只接受短 alias（`sonnet/opus/haiku`）作为 `model` 值；但在 Bedrock 等 provider 下这些 alias 又无效
- **现有规避：** `forceInherit` 让 OMC 完全不传 `model` 参数，跳过这个矛盾

### 11.2 会话模型带 `[1m]` 扩展上下文后缀

- **证据：** `scripts/pre-tool-enforcer.mjs:741-759`
- **本质：** `[1m]` 是 Claude Code 内部注解；子代理继承这个 model id 后，runtime 会 strip 掉 `[1m]` 变成裸 Anthropic model id，在 Bedrock 上无效
- **现有规避：** 设置 `OMC_SUBAGENT_MODEL` 为不带后缀的 provider-safe id；或不使用 1M 上下文变体

### 11.3 team worker CLI 子进程的 provider 解析

- **证据：** `dist/team/model-contract.js:320-347`（`resolveClaudeWorkerModel()`）
- **本质：** Claude CLI 进程以 tmux 子进程方式运行，其内部如何向 provider 发起请求由 CLI 自身控制，OMC 只能传 `--model` 参数进去；CLI 进程内部的解析逻辑不在 OMC 管控范围
- **现有规避：** 确保启动 Claude Code 前 `ANTHROPIC_MODEL` / `CLAUDE_MODEL` env 已正确设置，让 CLI 子进程继承正确的 model

---

## 优先级建议

```
最简单最稳    →  方案 A (forceInherit) + apply.sh
需要分级模型  →  方案 B (tierModels/modelAliases) + apply.sh
补充保障      →  OMC_SUBAGENT_MODEL 设置正确的 provider-safe id
```
