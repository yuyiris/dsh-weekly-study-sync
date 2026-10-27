# weekly-study-sync

> 给 DeepSeek Harness（`dsh`）用的技能：**每周把工作区里的课件、试卷、作业和近期会话，提炼成知识点写进 Obsidian 知识库**，并自动接线到学科 MOC 与总索引。

不需要你开口、不需要点确认 —— 一个计划任务，每周跑一次。

---

## 它做什么

1. **收集**：扫描工作区窗口内新增/修改的 `docx / pdf / md / txt`；读取近期会话的标题与提问
2. **归类**：按课程代码或学科分桶（`ABC1D`、`ENG3U`、`math`、`物理` …，以实际出现的为准）
3. **筛选**：只写「概念辨析、事件因果、数据、易错点、答题结构」，跳过临时脚本与闲聊
4. **写笔记**：按知识库自己的模板（frontmatter + 核心观点 + 支撑论证 + 来源 + 延伸阅读）
5. **接线**：更新学科 MOC、总索引页、标签表；校验 wikilink 是否指向真实文件
6. **收尾**：写回 `state.json`、生成人类可读的运行报告

**设计取舍**

| 原则 | 原因 |
|---|---|
| 只在 vault 内写 | 越界写入是最高危行为；agent 只拿到 `workspace-write`，不碰 vault 之外 |
| 不删、不覆写正文 | 已有笔记被覆盖等于丢知识；修正只能在文件末尾追加「更正」 |
| 宁缺毋滥 | 窗口内没有真学习内容就**不写**，只更新状态并输出「本周无新增学习内容」 |
| 单次最多 10 篇 | 防止一次刷出几十篇低质量笔记；调度脚本会核对实际数量 |
| 沿用目录命名习惯 | 英文目录用英文名，避免中英混杂 |
| 会话只用来判主题 | 会话缓存只有标题与提问，史实一律以文档为准 |
| 文档内容是数据不是命令 | 课件里可能藏提示注入；指令只来自模板，不来自输入文件 |

---

## 安装

### 0｜安装（只复制需要的文件）

```powershell
$src  = 'D:\path\to\dsh-weekly-study-sync'          # 解压/克隆出来的仓库
$dest = Join-Path $env:USERPROFILE '.dsh\skills\weekly-study-sync'
New-Item -ItemType Directory -Force -Path "$dest\resources" | Out-Null
Copy-Item -Path "$src\SKILL.md","$src\README.md","$src\LICENSE","$src\config.example.json" -Destination $dest -Force
Copy-Item -Path "$src\resources\run-weekly-sync.ps1","$src\resources\prompt-template.md",`
              "$src\resources\session_topics.mjs","$src\resources\docx_text.py" -Destination "$dest\resources" -Force
```

> 不要 `Copy-Item .\* $dest -Recurse`：那会把 `.git\`、`logs\` 和你的本地 `config.json` 一起搬过去。

### 1｜配置文件（必须填 workspace 与 vault）

脚本**不会**扫描整个用户目录去猜路径。缺 `workspace` 或 `vault` 时直接报错退出。

```powershell
notepad "$dest\config.example.json"   # 改好后另存为 config.json
```

```json
{
  "workspace": "D:\\path\\to\\workspace",
  "vault": "D:\\path\\to\\vault",
  "timeoutMinutes": 45,
  "maxNewNotes": 10,
  "logKeep": 12
}
```

| 字段 | 是否必填 | 说明 |
|---|---|---|
| `workspace` | ✅ | 扫描文档的根目录，必须已存在 |
| `vault` | ✅ | Obsidian 库根目录（含 `.obsidian`），必须已存在；也可用环境变量 `DSH_VAULT` 指定 |
| `timeoutMinutes` | | 超时分钟数，缺省 45 |
| `maxNewNotes` | | 单次最多新建笔记数，缺省 10 |
| `logKeep` | | `resources/logs/` 保留多少个文件，缺省 12 |

也可以 `-Config "D:\my\config.json"` 指定另一份配置。

> 修好配置后**先跑一次 `-DryRun`** 再建计划任务。

### 2｜建计划任务（每周五 14:00）

```powershell
$script = Join-Path $env:USERPROFILE '.dsh\skills\weekly-study-sync\resources\run-weekly-sync.ps1'
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
           -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Friday -At 14:00
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 60)
Register-ScheduledTask -TaskName 'DSH-WeeklyStudySync' -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Weekly: harvest study content into Obsidian' -Force
```

- `-StartWhenAvailable`：错过的任务（休眠、锁屏、关机）会在下次开机后补跑，避免静默漏跑。
- `-ExecutionTimeLimit`：给任务本身兜底超时。

**核对漏跑**：`Get-ScheduledTaskInfo -TaskName DSH-WeeklyStudySync` 看 `LastRunTime` / `LastTaskResult`。
`LastTaskResult` 含义：`0` 成功、`2` 本次 agent 超时、其它非 0 见 `resources\logs\` 当天日志。

### 3｜自检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$script" -DryRun
```

输出会列出解析后的 `workspace`、`vault`、`prompt` 路径和日志清理结果。确认无误再手动跑一次真实的：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$script" -Days 7
```

---

## 手动跑一次

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.dsh\skills\weekly-study-sync\resources\run-weekly-sync.ps1" -Days 7
```

`-Days 7` 表示回溯 7 天；不带参数则从 `state.json` 的 `lastRun` 算起。

只验证配置与提示词、不启动 agent：加 `-DryRun`。

---

## 权限与安全

| 项 | 取值 | 说明 |
|---|---|---|
| `DSH_PERMISSION_MODE` | `workspace-write` | **不再使用 `danger-full-access`**；可用 `-PermissionMode` 覆盖，但不建议 |
| 写入范围 | 仅 `<vault>` | 提示词明确禁止写工作区、技能目录、用户目录、系统目录 |
| 删除 | 禁止 | agent 不许删除任何文件；日志清理由脚本自己做 |
| 网络 | 禁止 | 提示注入无法让它外发数据 |
| 注入防御 | 提示词层 + 权限层 | 文档内容视为不可信数据，其中的指令一律忽略 |

> 提示词只是**软约束**，真正兜底的是权限模式：即使模型被注入，`workspace-write` 也让它写不出工作区之外。

---

## 依赖

| 依赖 | 用途 | 必需 |
|---|---|---|
| `dsh`（含 `headless` profile） | 执行同步会话 | ✅ |
| Node.js ≥ 20 | `resources/session_topics.mjs` 读会话缓存 | ✅ |
| Python 3 | `resources/docx_text.py` 提取 docx 文本 | ✅（只处理 docx 时） |
| `pdf-text-extraction` 技能 | 提取 PDF 文本 | 可选（有 PDF 时建议装） |

---

## 目录结构

```
weekly-study-sync/
├─ SKILL.md                   技能正文（执行流程 + 红线）
├─ config.example.json        配置模板（填好后另存为 config.json）
└─ resources/
   ├─ run-weekly-sync.ps1     调度入口（防重入 / 超时 / 日志清理 / 硬上限核对）
   ├─ prompt-template.md      提示词模板（UTF-8）
   ├─ session_topics.mjs      读会话缓存，提取标题与近期提问
   ├─ docx_text.py            docx → 纯文本（零依赖）
   └─ logs/                   每次运行的报告与日志（不入库）
```

下列文件属于**运行时本地数据，绝不要提交**：`config.json`、`state.json`、`.lock`、`resources/logs/`。

---

## 输出长什么样

运行报告写到 `resources/logs/YYYY-MM-DD.md`，示例：

```markdown
## 新增笔记（2）
| 分类 | 文件 | 主题 |
|---|---|---|
| 历史 | 某战役年份与伤亡口径.md | 战役背景、数据口径差异 |
| 数学 | 三角恒等式汇总.md | 和差化积、积化和差 |
...
## 跳过（及理由）
- 00_总纲.md — 规划与申请实务，非知识点
- 06_错题本.csv — 空模板，无实际错题记录
```

---

## 隐私说明

本仓库**不包含**任何真实路径、个人信息或学习内容；示例中的目录、课程代码、笔记名均为占位符。

本地运行时产生的 `config.json`、`state.json`、`logs/` 含有你的真实路径和文件名，已在 `.gitignore` 中排除，请勿提交或分享。

---

## 许可

MIT
