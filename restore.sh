#!/usr/bin/env sh
set -eu

usage() {
  cat <<'EOF'
Usage: sh restore.sh [options]

Options:
  --backup-dir <dir>    Restore from a specific backup directory
  --target-dir <dir>    Override target install directory from backup manifest
  --backup-root <dir>   Override backup root directory
  --dry-run             Show what would be restored without writing
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

node_available() {
  command -v node >/dev/null 2>&1
}

latest_backup_dir() {
  root="$1"
  latest_file="$root/LATEST"
  if [ -f "$latest_file" ]; then
    sed -n '1p' "$latest_file"
    return 0
  fi
  if [ ! -d "$root" ]; then
    return 0
  fi
  node - "$root" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
if (!root || !fs.existsSync(root)) process.exit(0);
const entries = fs.readdirSync(root, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name)
  .sort()
  .reverse();
if (entries[0]) console.log(path.join(root, entries[0]));
NODE
}

BACKUP_DIR=""
TARGET_DIR=""
BACKUP_ROOT=""
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --backup-dir)
      BACKUP_DIR=${2:?missing value for --backup-dir}
      shift 2
      ;;
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
  echo "Error: node is required to run this restore script." >&2
  exit 1
fi

CLAUDE_DIR=$(resolve_claude_config_dir)
if [ -z "$BACKUP_ROOT" ]; then
  BACKUP_ROOT="$CLAUDE_DIR/.omc-thirdparty-runtime-patch"
fi
if [ -z "$BACKUP_DIR" ]; then
  BACKUP_DIR=$(latest_backup_dir "$BACKUP_ROOT" || true)
fi

if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
  echo "Error: backup directory not found." >&2
  echo "Hint: pass --backup-dir explicitly or ensure a previous apply backup exists." >&2
  exit 1
fi

export BACKUP_DIR TARGET_DIR DRY_RUN

node <<'NODE'
const fs = require('fs');
const path = require('path');

const backupDir = process.env.BACKUP_DIR;
const targetDirOverride = process.env.TARGET_DIR || '';
const dryRun = process.env.DRY_RUN === '1';
const manifestPath = path.join(backupDir, 'manifest.json');

if (!fs.existsSync(manifestPath)) {
  console.error(`Restore failed: backup manifest not found at ${manifestPath}`);
  process.exit(1);
}

const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const targetDir = targetDirOverride || manifest.targetDir;
if (!targetDir) {
  console.error('Restore failed: target directory is missing.');
  process.exit(1);
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

const restored = [];
for (const relPath of manifest.patchedFiles || []) {
  const backupFile = path.join(backupDir, 'files', relPath);
  const targetFile = path.join(targetDir, relPath);
  if (!fs.existsSync(backupFile)) {
    console.error(`Restore failed: backup file missing: ${backupFile}`);
    process.exit(1);
  }
  const mode = fs.statSync(backupFile).mode;
  if (!dryRun) {
    ensureDir(path.dirname(targetFile));
    fs.copyFileSync(backupFile, targetFile);
    fs.chmodSync(targetFile, mode);
  }
  restored.push(relPath);
}

const removed = [];
for (const relPath of manifest.createdFiles || []) {
  const targetFile = path.join(targetDir, relPath);
  if (fs.existsSync(targetFile)) {
    if (!dryRun) {
      fs.rmSync(targetFile, { force: true, recursive: true });
    }
    removed.push(relPath);
  }
}

console.log(`Target: ${targetDir}`);
console.log(`Backup dir: ${backupDir}`);
console.log('Restore results:');
for (const relPath of restored) {
  console.log(`- [restored] ${relPath}`);
}
for (const relPath of removed) {
  console.log(`- [removed] ${relPath}`);
}
console.log(`Restored file count: ${restored.length}`);
NODE
