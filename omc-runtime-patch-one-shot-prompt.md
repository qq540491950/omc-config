# OMC 第三方模型补丁最终提示词

> 使用方式：进入 **oh-my-claudecode 源码仓库根目录**，按场景复制下面对应整段提示词给 AI 执行。

## 1）编写脚本的提示词

```text
你现在位于 oh-my-claudecode 源码仓库根目录。

目标：
基于源码分析，生成一套“安装 OMC 插件后执行的本地运行时补丁脚本（sh）”，通过 patch 本机已安装的 OMC，让第三方模型 / proxy provider 环境下的兼容性尽可能完整。

最终交付：
1. scripts/thirdparty-runtime-patch/apply.sh
2. scripts/thirdparty-runtime-patch/restore.sh
3. scripts/thirdparty-runtime-patch/README.md
4. 如有必要，可增加 rules.json 或 patch-manifest.json，用于声明补丁规则

强约束：
1. 先分析，再实现，禁止直接写脚本
2. 使用 TaskCreate / TaskUpdate 跟踪以下阶段：
   - 源码分析
   - 补丁设计
   - 脚本实现
   - 最小验证
   - 最终报告
3. 必须从源码中找出所有第三方模型不兼容入口，至少覆盖：
   - provider model validation
   - routing / forceInherit / inherit fallback
   - Agent / Task delegation
   - skills 中显式 model="haiku|sonnet|opus"
   - src/dist 运行时代码中的 prompt builder
   - autopilot
   - ralph
   - ultrawork
   - ultraqa
   - native team
   - validation / review / planner / execution adapters
4. 补丁脚本作用对象必须是“本机已安装的 OMC”，不是当前源码仓库
5. 脚本必须自动探测环境与安装目录，不允许写死版本号
6. 必须兼容：
   - CLAUDE_CONFIG_DIR
   - XDG_CONFIG_HOME
   - ~/.claude/settings.json
   - ~/.config/claude-omc/config.jsonc
   - ~/.claude/plugins/cache/omc/oh-my-claudecode/<version>/
7. apply.sh 必须具备：
   - 自动备份
   - 幂等执行
   - 输出 patch 文件清单
   - 失败即停止
   - 尽量支持 --dry-run
   - 尽量支持自动选择最新已安装版本
   - 尽量支持指定目标版本目录
8. restore.sh 必须支持：
   - 从最近一次备份恢复
   - 指定备份目录恢复
   - 删除 apply 创建的新文件
   - 输出恢复清单
9. patch 范围不能只覆盖 skills 文档，必须尽量覆盖 src/dist 运行时代码残留的显式 tier model
10. 如果某些模式无法通过安装后 patch 稳定修复，必须在 README 和最终报告中明确列出，不允许宣称“全部支持”
11. 不做无关重构，不改业务无关逻辑
12. 每阶段开始前先给计划，每阶段结束后给出证据化结论

实施步骤：
第一阶段：源码分析
- 找出所有会生成或要求显式 model="haiku|sonnet|opus" 的源码与构建产物位置
- 找出 provider 拦截与 model 安全校验入口
- 输出“补丁落点清单 + 风险分级 + 能否通过安装后 patch 修复”

第二阶段：补丁设计
- 设计 apply / restore 流程
- 设计备份目录结构
- 设计版本探测逻辑
- 设计文本替换规则
- 设计不能自动修复的边界说明
- 如果需要，设计 rules.json 或 patch-manifest.json

第三阶段：实现文件
- 创建 scripts/thirdparty-runtime-patch/
- 编写 apply.sh / restore.sh / README.md
- 如有必要，再增加规则文件

第四阶段：最小验证
- 校验 shell 语法
- 验证路径探测逻辑
- 验证替换规则是否能命中真实安装目录
- 输出“已覆盖 / 条件覆盖 / 未覆盖”结论

输出要求：
1. 每一阶段先给计划，再执行
2. 最终报告必须包含：
   - 修改了哪些文件
   - patch 命中的源码/运行时入口
   - 已通过路径
   - 条件通过路径
   - 未覆盖或仍可能失败路径
   - 是否能宣称“全面支持第三方模型”
3. 结论必须基于证据，不要猜测

现在先做第一阶段：只分析源码并给出补丁落点清单，不要立刻写脚本。
```

## 2）升级之后的更改脚本提示词

```text
你现在位于 oh-my-claudecode 源码仓库根目录。

背景：
这个仓库里已经存在一套“安装后运行时补丁脚本”，目录为：
- scripts/thirdparty-runtime-patch/apply.sh
- scripts/thirdparty-runtime-patch/restore.sh
- scripts/thirdparty-runtime-patch/README.md
- 如存在，再包括 rules.json / patch-manifest.json

当前任务：
上游 OMC 已升级。请基于最新源码，分析现有补丁脚本是否仍然适用，并更新这套脚本，使其继续支持第三方模型 / proxy provider 环境下的已安装 OMC。

任务目标：
1. 不要从零重写，优先复用现有补丁脚本与规则
2. 识别升级后失效的补丁点
3. 更新脚本与规则
4. 输出哪些补丁仍稳定、哪些需要调整、哪些已无法通过安装后 patch 保证

强约束：
1. 先分析，再修改，禁止直接大改
2. 使用 TaskCreate / TaskUpdate 跟踪以下阶段：
   - 升级影响分析
   - 现有补丁失效点评估
   - 规则更新设计
   - 脚本修改
   - 最小验证
   - 最终报告
3. 必须先读取并理解已有文件：
   - scripts/thirdparty-runtime-patch/apply.sh
   - scripts/thirdparty-runtime-patch/restore.sh
   - scripts/thirdparty-runtime-patch/README.md
   - rules.json / patch-manifest.json（如果存在）
4. 必须对比最新源码与已有补丁假设，重点检查：
   - provider model validation
   - routing / forceInherit / inherit fallback
   - Agent / Task delegation
   - skills 中显式 model="haiku|sonnet|opus"
   - src/dist 运行时代码中的 prompt builder
   - autopilot
   - ralph
   - ultrawork
   - ultraqa
   - native team
   - validation / review / planner / execution adapters
5. 目标不是机械修补，而是判断：
   - 哪些补丁规则仍跨版本稳定
   - 哪些补丁规则需要调整路径或匹配模式
   - 哪些补丁点已经不适合文本 patch
6. 不允许只更新 skills 文档 patch；必须优先检查真实运行时代码路径
7. 脚本仍必须兼容：
   - CLAUDE_CONFIG_DIR
   - XDG_CONFIG_HOME
   - ~/.claude/settings.json
   - ~/.config/claude-omc/config.jsonc
   - ~/.claude/plugins/cache/omc/oh-my-claudecode/<version>/
8. 不能写死新版本号；要保持对未来版本尽量稳健
9. 如果升级后某些模式无法再通过安装后 patch 稳定修复，必须在 README 和最终报告中明确列出
10. 不做无关重构，不改业务无关逻辑
11. 所有结论必须基于源码证据和最小验证，不允许猜测

实施步骤：
第一阶段：升级影响分析
- 分析最新源码中与第三方模型兼容相关的核心入口
- 对比已有补丁脚本的命中假设
- 输出：
  - 仍有效的补丁点
  - 已失效的补丁点
  - 新增的风险入口
  - 不能再承诺稳定 patch 的路径

第二阶段：规则更新设计
- 更新 apply / restore 的处理逻辑
- 更新规则文件或内置替换规则
- 对每条规则说明：
  - 目标文件模式
  - 匹配文本或正则
  - 替换内容
  - 是否允许 0 命中
  - 为什么需要调整

第三阶段：修改脚本
- 仅修改必要文件
- 保持现有脚本结构尽量稳定
- README 同步更新：
  - 适用版本范围
  - 升级后重跑要求
  - 已知限制
  - 已覆盖 / 条件覆盖 / 未覆盖

第四阶段：最小验证
- shell 语法检查
- 路径探测逻辑检查
- 规则命中验证
- 输出：
  - 已可靠覆盖
  - 条件覆盖
  - 无法稳定覆盖

输出要求：
1. 每一阶段先给计划，再执行
2. 最终报告必须包含：
   - 这次升级改了哪些补丁规则
   - 哪些旧规则被保留
   - 哪些旧规则被删除
   - 哪些新风险被纳入
   - 是否还能称为“跨版本自动 patch”
   - 是否还能宣称“全面支持第三方模型”
3. 如果不能证明升级后仍稳定，就直接说明不能保证，不要模糊表述

现在先做第一阶段：分析“升级后现有补丁脚本的失效点与新增风险”，不要立刻改脚本。
```
