#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MANIFEST_PATH="$SCRIPT_DIR/patch-manifest.json"

usage() {
  cat <<'EOF'
Usage: sh apply.sh [options]

Options:
  --target-dir <dir>    Patch a specific installed OMC version directory
  --backup-root <dir>   Override backup root directory
  --dry-run             Show what would change without writing
  --list-targets        Print detected runtime paths and exit
  -h, --help            Show help
EOF
}

resolve_claude_config_dir() {
  configured="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  configured=${configured%/}
  case "$configured" in
    '~') printf '%s\n' "$HOME" ;;
    '~/'*) configured=${configured#\~/}; printf '%s/%s\n' "$HOME" "$configured" ;;
    *) printf '%s\n' "$configured" ;;
  esac
}

resolve_xdg_config_home() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

node_available() {
  command -v node >/dev/null 2>&1
}

latest_version_dir() {
  base_dir="$1"
  if [ ! -d "$base_dir" ]; then
    return 0
  fi
  node - "$base_dir" <<'NODE'
const fs = require('fs');
const path = require('path');
const base = process.argv[2];
if (!base || !fs.existsSync(base)) process.exit(0);
const entries = fs.readdirSync(base, { withFileTypes: true })
  .filter((entry) => entry.isDirectory() && /^\d+\.\d+\.\d+([-.+].*)?$/.test(entry.name))
  .map((entry) => entry.name);
entries.sort((a, b) => {
  const pa = a.split(/[.+-]/)[0].split('.').map((v) => parseInt(v, 10) || 0);
  const pb = b.split(/[.+-]/)[0].split('.').map((v) => parseInt(v, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i += 1) {
    const diff = (pb[i] || 0) - (pa[i] || 0);
    if (diff !== 0) return diff;
  }
  return a < b ? 1 : a > b ? -1 : 0;
});
if (entries[0]) console.log(path.join(base, entries[0]));
NODE
}

installed_plugin_path() {
  installed_plugins="$1"
  if [ ! -f "$installed_plugins" ]; then
    return 0
  fi
  node - "$installed_plugins" <<'NODE'
const fs = require('fs');
const file = process.argv[2];
try {
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
  const plugins = raw.plugins || raw;
  for (const [name, entries] of Object.entries(plugins || {})) {
    if (!String(name).startsWith('oh-my-claudecode')) continue;
    if (Array.isArray(entries) && entries[0] && entries[0].installPath) {
      console.log(entries[0].installPath);
      process.exit(0);
    }
  }
} catch (_) {}
NODE
}

TARGET_DIR=""
BACKUP_ROOT=""
DRY_RUN=0
LIST_TARGETS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-dir)
      TARGET_DIR=${2:?missing value for --target-dir}
      shift 2
      ;;
    --backup-root)
      BACKUP_ROOT=${2:?missing value for --backup-root}
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --list-targets)
      LIST_TARGETS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! node_available; then
  echo "Error: node is required to run this patch script." >&2
  exit 1
fi

CLAUDE_DIR=$(resolve_claude_config_dir)
XDG_DIR=$(resolve_xdg_config_home)
SETTINGS_JSON="$CLAUDE_DIR/settings.json"
OMC_USER_CONFIG="$XDG_DIR/claude-omc/config.jsonc"
PLUGIN_CACHE_BASE="$CLAUDE_DIR/plugins/cache/omc/oh-my-claudecode"
INSTALLED_PLUGINS_JSON="$CLAUDE_DIR/plugins/installed_plugins.json"
ACTIVE_INSTALL_PATH=$(installed_plugin_path "$INSTALLED_PLUGINS_JSON" || true)
LATEST_CACHE_DIR=$(latest_version_dir "$PLUGIN_CACHE_BASE" || true)

if [ -z "$TARGET_DIR" ]; then
  if [ -n "$ACTIVE_INSTALL_PATH" ] && [ -d "$ACTIVE_INSTALL_PATH" ]; then
    TARGET_DIR=$ACTIVE_INSTALL_PATH
  elif [ -n "$LATEST_CACHE_DIR" ] && [ -d "$LATEST_CACHE_DIR" ]; then
    TARGET_DIR=$LATEST_CACHE_DIR
  else
    TARGET_DIR=""
  fi
fi

if [ -z "$BACKUP_ROOT" ]; then
  BACKUP_ROOT="$CLAUDE_DIR/.omc-thirdparty-runtime-patch"
fi

if [ "$LIST_TARGETS" -eq 1 ]; then
  cat <<EOF
CLAUDE_CONFIG_DIR=$CLAUDE_DIR
XDG_CONFIG_HOME=$XDG_DIR
settings.json=$SETTINGS_JSON
omc_user_config=$OMC_USER_CONFIG
installed_plugins.json=$INSTALLED_PLUGINS_JSON
plugin_cache_base=$PLUGIN_CACHE_BASE
active_install_path=${ACTIVE_INSTALL_PATH:-}
latest_cache_dir=${LATEST_CACHE_DIR:-}
selected_target_dir=${TARGET_DIR:-}
backup_root=$BACKUP_ROOT
EOF
  exit 0
fi

if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
  echo "Error: could not resolve an installed OMC version directory." >&2
  echo "Hint: use --list-targets or pass --target-dir explicitly." >&2
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"

export TARGET_DIR BACKUP_ROOT BACKUP_DIR DRY_RUN MANIFEST_PATH SETTINGS_JSON OMC_USER_CONFIG CLAUDE_DIR XDG_DIR

node <<'NODE'
const fs = require('fs');
const path = require('path');

const targetDir = process.env.TARGET_DIR;
const backupRoot = process.env.BACKUP_ROOT;
const backupDir = process.env.BACKUP_DIR;
const manifestPath = process.env.MANIFEST_PATH;
const dryRun = process.env.DRY_RUN === '1';

const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const results = [];
const errors = [];
const touchedFiles = new Set();
const createdFiles = [];
const requiredAny = manifest.targetValidation?.requiredAny || [];

function toPosix(value) {
  return value.split(path.sep).join('/');
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function targetPath(relPath) {
  return path.join(targetDir, relPath);
}

function backupPath(relPath) {
  return path.join(backupDir, 'files', relPath);
}

function readUtf8(absPath) {
  return fs.readFileSync(absPath, 'utf8');
}

function writeUtf8(absPath, content, mode) {
  ensureDir(path.dirname(absPath));
  fs.writeFileSync(absPath, content, 'utf8');
  if (typeof mode === 'number') {
    fs.chmodSync(absPath, mode);
  }
}

function backupOriginal(relPath, content, mode) {
  const absBackup = backupPath(relPath);
  if (fs.existsSync(absBackup) || dryRun) return;
  writeUtf8(absBackup, content, mode);
}

function record(relPath, status, detail) {
  results.push({ file: relPath, status, detail });
}

function checkTargetValidation() {
  const found = requiredAny.some((relPath) => fs.existsSync(targetPath(relPath)));
  if (!found) {
    errors.push(`Target directory does not look like an installed OMC runtime: ${targetDir}`);
  }
}

function replaceLiteral(relPath, oldString, newString, options = {}) {
  const absPath = targetPath(relPath);
  if (!fs.existsSync(absPath)) {
    if (options.required) {
      errors.push(`Missing required file: ${relPath}`);
    } else {
      record(relPath, 'skipped', 'file missing');
    }
    return;
  }

  const before = readUtf8(absPath);
  const stat = fs.statSync(absPath);

  if (!before.includes(oldString)) {
    if (before.includes(newString)) {
      record(relPath, 'already_patched', options.description || 'literal already patched');
      return;
    }
    if (options.required) {
      errors.push(`Required patch text not found in ${relPath}`);
    } else {
      record(relPath, 'not_matched', options.description || 'literal not found');
    }
    return;
  }

  const after = before.replace(oldString, newString);
  if (after === before) {
    errors.push(`Literal replacement made no changes in ${relPath}`);
    return;
  }

  backupOriginal(relPath, before, stat.mode);
  if (!dryRun) {
    writeUtf8(absPath, after, stat.mode);
  }
  touchedFiles.add(relPath);
  record(relPath, dryRun ? 'would_patch' : 'patched', options.description || 'literal replacement applied');
}

function walkFiles(rootDir, filter) {
  const out = [];
  if (!fs.existsSync(rootDir)) return out;
  for (const entry of fs.readdirSync(rootDir, { withFileTypes: true })) {
    const abs = path.join(rootDir, entry.name);
    if (entry.isDirectory()) {
      out.push(...walkFiles(abs, filter));
      continue;
    }
    if (!filter || filter(abs)) {
      out.push(abs);
    }
  }
  return out;
}

function bulkTransform(dirRel, filter, transformer, options = {}) {
  const absDir = targetPath(dirRel);
  if (!fs.existsSync(absDir)) {
    if (options.required) {
      errors.push(`Missing required directory: ${dirRel}`);
    } else {
      record(dirRel, 'skipped', 'directory missing');
    }
    return;
  }

  const files = walkFiles(absDir, filter);
  let changed = 0;
  let already = 0;

  for (const absFile of files) {
    const relPath = toPosix(path.relative(targetDir, absFile));
    const before = readUtf8(absFile);
    const stat = fs.statSync(absFile);
    const after = transformer(before, relPath);
    if (after === before) {
      already += 1;
      continue;
    }
    backupOriginal(relPath, before, stat.mode);
    if (!dryRun) {
      writeUtf8(absFile, after, stat.mode);
    }
    touchedFiles.add(relPath);
    changed += 1;
  }

  if (changed > 0) {
    record(dirRel, dryRun ? 'would_patch' : 'patched', `${changed} file(s) updated`);
  } else if (already > 0) {
    record(dirRel, 'already_patched', `${already} file(s) already compatible or unchanged`);
  } else {
    record(dirRel, 'skipped', 'no matching files');
  }
}

checkTargetValidation();

replaceLiteral(
  'scripts/pre-tool-enforcer.mjs',
  '} else if (!isSubagentSafeModelId(toolModel)) {',
  '} else if (!isTierAlias(toolModel) && !isSubagentSafeModelId(toolModel)) {',
  { required: true, description: 'allow tier aliases to pass provider validation hook' }
);

replaceLiteral(
  'dist/features/delegation-enforcer.js',
  `export function normalizeToCcAlias(model) {\n    const family = resolveClaudeFamily(model);\n    return family ? (FAMILY_TO_ALIAS[family] ?? model) : model;\n}`,
  `export function normalizeToCcAlias(model) {\n    if (/^((us|eu|ap|global)\\.anthropic\\.|anthropic\\.claude)/i.test(model) ||\n        /^arn:aws(-[^:]+)?:bedrock:/i.test(model) ||\n        model.toLowerCase().startsWith('vertex_ai/') ||\n        /[/:]/.test(model)) {\n        return model;\n    }\n    const family = resolveClaudeFamily(model);\n    return family ? (FAMILY_TO_ALIAS[family] ?? model) : model;\n}`,
  { required: true, description: 'preserve provider-specific model ids during delegation normalization' }
);

replaceLiteral(
  'dist/agents/definitions.js',
  `        const resolvedModel = override?.model ?? inheritModel ?? configuredModel ?? agentConfig.model;`,
  `        const providerSessionModel = process.env.OMC_SUBAGENT_MODEL || process.env.ANTHROPIC_MODEL || process.env.CLAUDE_MODEL || '';\n        const canReuseProviderSessionModel = providerSessionModel.length > 0\n            && !/\\[\\d+[mk]\\]$/i.test(providerSessionModel)\n            && (/^((us|eu|ap|global)\\.anthropic\\.|anthropic\\.claude)/i.test(providerSessionModel)\n                || /^arn:aws(-[^:]+)?:bedrock:/i.test(providerSessionModel)\n                || providerSessionModel.toLowerCase().startsWith('vertex_ai/')\n                || /[/:]/.test(providerSessionModel));\n        const resolvedModel = override?.model ?? inheritModel ?? configuredModel ?? (canReuseProviderSessionModel ? providerSessionModel : agentConfig.model);`,
  { required: true, description: 'prefer safe session/provider model ids in agent registry' }
);

replaceLiteral(
  'dist/team/stage-router.js',
  `function resolveClaudeModel(role, raw, cfg) {\n    if (typeof raw === 'string' && raw.length > 0) {\n        return isTier(raw) ? resolveTierToModelId(raw, cfg) : raw;\n    }\n    return resolveTierToModelId(ROLE_DEFAULT_TIER[role], cfg);\n}`,
  `function resolveClaudeModel(role, raw, cfg) {\n    if (typeof raw === 'string' && raw.length > 0) {\n        return isTier(raw) ? resolveTierToModelId(raw, cfg) : raw;\n    }\n    const providerSessionModel = process.env.OMC_SUBAGENT_MODEL || process.env.ANTHROPIC_MODEL || process.env.CLAUDE_MODEL || '';\n    const canReuseProviderSessionModel = providerSessionModel.length > 0\n        && !/\\[\\d+[mk]\\]$/i.test(providerSessionModel)\n        && (/^((us|eu|ap|global)\\.anthropic\\.|anthropic\\.claude)/i.test(providerSessionModel)\n            || /^arn:aws(-[^:]+)?:bedrock:/i.test(providerSessionModel)\n            || providerSessionModel.toLowerCase().startsWith('vertex_ai/')\n            || /[/:]/.test(providerSessionModel));\n    if (canReuseProviderSessionModel) {\n        return providerSessionModel;\n    }\n    return resolveTierToModelId(ROLE_DEFAULT_TIER[role], cfg);\n}`,
  { required: true, description: 'prefer safe provider session model for team claude workers' }
);

replaceLiteral(
  'dist/team/model-contract.js',
  `                const resolved = isProviderSpecificModelId(model) ? model : normalizeToCcAlias(model);`,
  `                const resolved = (isProviderSpecificModelId(model) || /[/:]/.test(model)) ? model : normalizeToCcAlias(model);`,
  { required: true, description: 'pass through proxy/provider model ids when launching Claude workers' }
);

bulkTransform(
  'dist/hooks/autopilot',
  (abs) => abs.endsWith('.js') && !abs.includes('__tests__'),
  (content) => content
    .replace(/,\s*model=\"(haiku|sonnet|opus)\"/g, '')
    .replace(/subagent_type=\"oh-my-claudecode:([a-z-]+)-(low|medium|high)\"/g, 'subagent_type="oh-my-claudecode:$1"'),
  { required: false }
);

bulkTransform(
  'skills',
  (abs) => abs.endsWith('.md'),
  (content) => content
    .replace(/,\s*model=\"(haiku|sonnet|opus)\"/g, '')
    .replace(/subagent_type=\"oh-my-claudecode:([a-z-]+)-(low|medium|high)\"/g, 'subagent_type="oh-my-claudecode:$1"'),
  { required: false }
);

bulkTransform(
  'agents',
  (abs) => abs.endsWith('.md'),
  (content) => content.replace(/^model:\s*(haiku|sonnet|opus)\s*$/m, 'model: inherit'),
  { required: false }
);

if (errors.length > 0) {
  console.error('Patch failed:');
  for (const error of errors) {
    console.error(`- ${error}`);
  }
  process.exit(1);
}

const backupManifest = {
  targetDir,
  createdAt: new Date().toISOString(),
  dryRun,
  patchedFiles: Array.from(touchedFiles).sort(),
  createdFiles,
  results,
};

if (!dryRun) {
  ensureDir(backupDir);
  fs.writeFileSync(path.join(backupDir, 'manifest.json'), JSON.stringify(backupManifest, null, 2) + '\n', 'utf8');
  ensureDir(backupRoot);
  fs.writeFileSync(path.join(backupRoot, 'LATEST'), `${backupDir}\n`, 'utf8');
}

console.log(`Target: ${targetDir}`);
console.log(`Backup root: ${backupRoot}`);
console.log(`Backup dir: ${dryRun ? '(dry-run, not created)' : backupDir}`);
console.log('Patch results:');
for (const result of results) {
  console.log(`- [${result.status}] ${result.file} — ${result.detail}`);
}
console.log(`Patched file count: ${touchedFiles.size}`);
NODE
