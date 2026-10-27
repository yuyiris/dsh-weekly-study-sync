// session_topics.mjs — 提取近期会话的标题与用户提问，供 weekly-study-sync 判断"这周在学什么"
// 用法: node session_topics.mjs [--days 7] [--max 15] [--cache <dir>]
//
// 退出码（调度脚本据此区分「没东西」和「没读到」，两者不能混为一谈）：
//   0  正常，且找到了缓存目录
//   3  缓存目录不存在 / 不是目录 —— 这是「读不到」，不是「本周没有会话」
//   2  参数非法
//
// 只读：本脚本不写入任何会话文件。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const DEFAULT_CACHE = path.join(os.homedir(), '.dsh', 'storages', 'session_projcache', 'sessions');

const argv = process.argv.slice(2);
const getArg = (name, def) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : def;
};
const days = Number(getArg('--days', '7'));
const max = Number(getArg('--max', '15'));
const CACHE = getArg('--cache', process.env.DSH_SESSION_CACHE || DEFAULT_CACHE);

if (!Number.isFinite(days) || days <= 0) {
  console.error(`invalid --days: ${getArg('--days', '')}`);
  process.exit(2);
}
if (!Number.isFinite(max) || max <= 0) {
  console.error(`invalid --max: ${getArg('--max', '')}`);
  process.exit(2);
}

const since = Date.now() - days * 24 * 3600 * 1000;

const result = {
  days,
  since: new Date(since).toISOString(),
  cache: CACHE,
  count: 0,
  sessions: [],
};

if (!fs.existsSync(CACHE) || !fs.statSync(CACHE, { throwIfNoEntry: false })?.isDirectory()) {
  // 「读不到」必须向调度脚本暴露为错误，否则会静默退化成「本周无新增学习内容」。
  result.error = `cache dir not found: ${CACHE}`;
  console.log(JSON.stringify(result, null, 2));
  process.exit(3);
}

const out = [];
for (const name of fs.readdirSync(CACHE)) {
  if (!name.endsWith('.json')) continue;
  const full = path.join(CACHE, name);
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(full, 'utf8'));
  } catch {
    continue;
  }
  const rows = raw?.record?.rows;
  if (!rows) continue;
  const val = (k) => rows[k]?.val;
  const title = val('title') ?? '';
  const lastPromptAt = Number(val('sessionListMetadata')?.lastPromptAt ?? 0);
  if (lastPromptAt && lastPromptAt < since) continue;

  const turns = val('turnOutline')?.turns ?? [];
  const prompts = turns
    .map((t) => (t?.prompt ?? '').trim())
    .filter(Boolean)
    .slice(-max)
    .map((p) => (p.length > 220 ? p.slice(0, 220) + '…' : p));

  out.push({
    id: raw?.record?.identity?.id ?? name.replace(/\.json$/, ''),
    title,
    lastPromptAt: lastPromptAt ? new Date(lastPromptAt).toISOString() : null,
    prompts,
  });
}

out.sort((a, b) => String(b.lastPromptAt).localeCompare(String(a.lastPromptAt)));
result.count = out.length;
result.sessions = out;
console.log(JSON.stringify(result, null, 2));
