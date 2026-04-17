# thirdparty-runtime-patch

这是对“**本机已安装** 的 OMC 插件运行时”做安装后补丁的脚本集合，不修改当前源码仓库的运行时。

## 交付物

- `apply.sh`：探测并 patch 已安装 OMC
- `restore.sh`：从最近一次或指定备份恢复
- `patch-manifest.json`：声明补丁目标与规则范围

## 目标范围

脚本优先 patch 已安装 OMC 中这些入口：

- `scripts/pre-tool-enforcer.mjs`
- `dist/features/delegation-enforcer.js`
- `dist/agents/definitions.js`
- `dist/hooks/autopilot/**/*.js`
- `dist/team/stage-router.js`
- `dist/team/model-contract.js`
- `skills/**/*.md`
- `agents/*.md`

## 解决的问题

尽量降低第三方模型 / proxy provider 下这些兼容性问题：

- provider model validation 过早拒绝
- delegation runtime 把 provider-specific model 归一成 `haiku|sonnet|opus`
- agent registry 回退到硬编码 Claude tier model
- autopilot / ralph / ultraqa / execution adapters 生成显式 `model="haiku|sonnet|opus"`
- native team 在未显式配置时回落到 Claude-centric tier model
- skills / agents 文本继续诱导显式 tier model 调用

## 自动探测

`apply.sh` 会自动探测：

- `CLAUDE_CONFIG_DIR`
- `XDG_CONFIG_HOME`
- `~/.claude/settings.json`
- `~/.config/claude-omc/config.jsonc`
- `~/.claude/plugins/cache/omc/oh-my-claudecode/<version>/`
- `installed_plugins.json` 中的当前安装路径
- plugin cache 中最新版本目录

目标版本目录优先级：

1. `--target-dir`
2. `installed_plugins.json` 中的 `installPath`
3. plugin cache 最新版本目录

## 用法

### 查看探测结果

```sh
sh scripts/thirdparty-runtime-patch/apply.sh --list-targets
```

### 预演

```sh
sh scripts/thirdparty-runtime-patch/apply.sh --dry-run
```

### 实际应用

```sh
sh scripts/thirdparty-runtime-patch/apply.sh
```

### 指定目标版本目录

```sh
sh scripts/thirdparty-runtime-patch/apply.sh --target-dir "$HOME/.claude/plugins/cache/omc/oh-my-claudecode/4.12.0"
```

### 恢复最近一次备份

```sh
sh scripts/thirdparty-runtime-patch/restore.sh
```

### 从指定备份恢复

```sh
sh scripts/thirdparty-runtime-patch/restore.sh --backup-dir "$HOME/.claude/.omc-thirdparty-runtime-patch/20260417-120000"
```

## 备份结构

默认备份根目录：

```text
$CLAUDE_CONFIG_DIR/.omc-thirdparty-runtime-patch/
```

每次 `apply.sh` 会创建：

```text
<backup-root>/<timestamp>/manifest.json
<backup-root>/<timestamp>/files/<relative-path>
<backup-root>/LATEST
```

## 幂等性

- 已 patch 的文本再次执行会显示 `already_patched`
- 未命中的规则会显示 `not_matched` 或 `skipped`
- 核心运行时入口未命中时脚本会失败退出

## 已覆盖 / 条件覆盖 / 未覆盖

### 已覆盖

- provider-specific model id 在 delegation runtime / team Claude worker launch 中尽量直通
- autopilot 运行时 prompt builder 中显式 `model="haiku|sonnet|opus"`
- skills 示例中的显式 tier model
- agent markdown frontmatter 中的 `model: haiku|sonnet|opus`

### 条件覆盖

- `pre-tool-enforcer` 的第三方 provider 拦截：补丁会放宽 tier alias 拒绝，但不移除全部保护逻辑
- native team fallback：补丁优先复用安全的 session/provider model；若当前会话模型本身不可复用，仍可能回落到配置或默认 tier model
- `OMC_SUBAGENT_MODEL` / `routing.tierModels` / `forceInherit`：若用户已正确配置，补丁效果更稳定

### 未覆盖或仍可能失败

- Claude Code 工具 schema 对某些 `model` 参数形式的限制
- 会话模型带 `[1m]` 等扩展上下文后缀且没有可复用 provider-safe model 时的子代理继承问题
- 第三方 proxy 自身的 provider 解析差异
- 所有 OMC 文本提示中的 tier 语义残留都不保证被完全移除

## 重要声明

这个补丁集的目标是“**尽可能提升** 已安装 OMC 在第三方模型 / proxy provider 下的兼容性”。

**不能宣称：全面支持第三方模型。**

更准确的说法是：

- 已覆盖一批关键运行时入口
- 某些路径可条件通过
- 仍有一部分失败模式受 Claude Code schema、provider runtime、会话模型形态约束
