# lhu-email 專案規格

## 1. 專案目標

建立一個乾淨、可重現、可排程的 Node.js + Playwright Docker 專案，用於定期登入 LHU 信箱系統，並在成功登入後寄出通知信。

此專案會部署在 Windows 電腦上，但實際任務必須在 Docker container 內執行。Windows 只負責用 Task Scheduler 觸發 PowerShell script，再由 PowerShell 呼叫 Docker Compose 執行一次性 job。

---

## 2. 核心架構

```text
Windows Task Scheduler
  ↓
PowerShell wrapper
  ↓
docker compose run --rm lhu-weekly-email
  ↓
Docker container
  ↓
Node.js + Playwright
  ↓
登入 LHU
  ↓
寄出成功通知 email
  ↓
寫入 logs / state
```

設計原則：

1. Windows 主機不要直接安裝或依賴 Playwright browser。
2. Playwright、Node.js runtime、browser dependencies 全部放在 Docker image 內。
3. secrets 不可寫入程式碼、不可進 Git、不可 bake 進 Docker image。
4. logs、state、sessions 必須掛載到 host volume，讓 container 刪除後資料仍保留。
5. job 必須可以手動執行，也可以被 Task Scheduler 觸發。
6. 正式 job 失敗時要有清楚 log，必要時輸出 screenshot / HTML dump。

---

## 3. 目錄結構

請在目前資料夾 `lhu-email` 內建立以下結構：

```text
lhu-email/
├── src/
│   ├── jobs/
│   │   └── lhu-weekly-email.js
│   ├── lib/
│   │   ├── date.js
│   │   ├── env.js
│   │   ├── logger.js
│   │   ├── mailer.js
│   │   └── state.js
│   └── smoke-playwright.js
│
├── scripts/
│   └── run-lhu-weekly-email.ps1
│
├── secrets/
│   └── lhu-weekly-email.env.example
│
├── logs/
│   └── .gitkeep
│
├── state/
│   └── .gitkeep
│
├── sessions/
│   └── .gitkeep
│
├── artifacts/
│   └── .gitkeep
│
├── package.json
├── package-lock.json
├── Dockerfile
├── docker-compose.yml
├── .dockerignore
├── .gitignore
└── README.md
```

說明：

```text
src/jobs/      實際任務入口
src/lib/       共用工具
scripts/       Windows Task Scheduler 呼叫的 PowerShell wrapper
secrets/       env 範本，不放真實密碼
logs/          job log
state/         job 執行狀態
sessions/      Playwright storage state 或 session 檔
artifacts/     失敗截圖、HTML dump、trace 等除錯產物
```

---

## 4. 技術棧

使用：

```text
Node.js >= 20
CommonJS
Playwright 1.60.0
Docker
Docker Compose
PowerShell
```

建議 dependencies：

```json
{
  "dependencies": {
    "nodemailer": "^6.9.16"
  },
  "devDependencies": {
    "@playwright/test": "^1.60.0"
  }
}
```

注意：如果寄信不使用 SMTP，而是改用其他 mail provider，`nodemailer` 可以之後調整。

---

## 5. package.json 規格

建立 `package.json`：

```json
{
  "name": "lhu-email",
  "version": "1.0.0",
  "description": "Dockerized LHU login email automation job",
  "main": "src/jobs/lhu-weekly-email.js",
  "type": "commonjs",
  "scripts": {
    "smoke": "node src/smoke-playwright.js",
    "job:lhu-email": "node src/jobs/lhu-weekly-email.js"
  },
  "keywords": [],
  "author": "",
  "license": "ISC",
  "dependencies": {
    "nodemailer": "^6.9.16"
  },
  "devDependencies": {
    "@playwright/test": "^1.60.0"
  }
}
```

---

## 6. 環境變數規格

真實 secret 檔案路徑：

```text
secrets/lhu-weekly-email.env
```

此檔案不可進 Git。

建立範本檔：

```text
secrets/lhu-weekly-email.env.example
```

內容：

```env
LHU_URL=https://ms.lhu.edu.tw/cgi-bin/login?index=1
LHU_USERNAME=replace-me
LHU_PASSWORD=replace-me

MAIL_TO=replace-me@example.com
MAIL_BODY_TEMPLATE={{TODAY_TAIPEI}} 已成功登入

SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=replace-me
SMTP_PASS=replace-me
MAIL_FROM=replace-me@example.com

TZ=Asia/Taipei
```

規則：

1. `LHU_USERNAME`、`LHU_PASSWORD` 不可寫死在 JS 內。
2. `SMTP_PASS` 不可寫死在 JS 內。
3. `.env.example` 只放 placeholder。
4. 真實 `.env` 必須被 `.gitignore` 排除。
5. 程式啟動時要檢查必要 env 是否存在，缺少就 fail fast。

必要 env：

```text
LHU_URL
LHU_USERNAME
LHU_PASSWORD
MAIL_TO
MAIL_BODY_TEMPLATE
SMTP_HOST
SMTP_PORT
SMTP_USER
SMTP_PASS
MAIL_FROM
```

---

## 7. Dockerfile 規格

建立 `Dockerfile`：

```dockerfile
FROM mcr.microsoft.com/playwright:v1.60.0-jammy

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .

ENV NODE_ENV=production
ENV TZ=Asia/Taipei

CMD ["npm", "run", "smoke"]
```

要求：

1. 使用 Playwright 官方 image。
2. 使用 `npm ci`，確保 lockfile 一致。
3. 不要把 secrets copy 進 image。
4. 預設 CMD 可以是 smoke test，正式 job 由 docker-compose service command 覆蓋。

---

## 8. docker-compose.yml 規格

建立 `docker-compose.yml`：

```yaml
services:
  smoke:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: lhu-email-smoke
    environment:
      TZ: Asia/Taipei
    volumes:
      - ./logs:/app/logs
      - ./state:/app/state
      - ./sessions:/app/sessions
      - ./artifacts:/app/artifacts
    command: ["npm", "run", "smoke"]
    restart: "no"

  lhu-weekly-email:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: lhu-weekly-email-job
    env_file:
      - ./secrets/lhu-weekly-email.env
    environment:
      TZ: Asia/Taipei
    volumes:
      - ./logs:/app/logs
      - ./state:/app/state
      - ./sessions:/app/sessions
      - ./artifacts:/app/artifacts
    command: ["npm", "run", "job:lhu-email"]
    restart: "no"
```

執行方式：

```powershell
docker compose build
docker compose run --rm smoke
docker compose run --rm lhu-weekly-email
```

---

## 9. .gitignore 規格

建立 `.gitignore`：

```gitignore
node_modules/
npm-debug.log*

secrets/*.env
!secrets/*.env.example

logs/*
!logs/.gitkeep

state/*
!state/.gitkeep

sessions/*
!sessions/.gitkeep

artifacts/*
!artifacts/.gitkeep

.env
.DS_Store
```

---

## 10. .dockerignore 規格

建立 `.dockerignore`：

```dockerignore
node_modules
npm-debug.log*

.git
.gitignore

secrets
logs
state
sessions
artifacts

README.md
```

注意：`secrets` 不可進 Docker image。正式執行時由 `docker-compose.yml` 的 `env_file` 注入。

---

## 11. smoke-playwright.js 規格

建立 `src/smoke-playwright.js`。

用途：確認 Docker container 內 Playwright 可以正常啟動 Chromium 並打開網頁。

需求：

1. 使用 `chromium.launch({ headless: true })`。
2. 打開 `https://example.com`。
3. 輸出 JSON 結果。
4. 成功時 exit code = 0。
5. 失敗時印出錯誤並 exit code = 1。

預期輸出：

```json
{
  "ok": true,
  "status": 200,
  "title": "Example Domain",
  "url": "https://example.com/"
}
```

---

## 12. lhu-weekly-email.js 規格

建立 `src/jobs/lhu-weekly-email.js`。

任務流程：

```text
1. 載入並驗證 env
2. 建立 logger
3. 取得台灣日期 TODAY_TAIPEI
4. 啟動 Playwright Chromium
5. 前往 LHU_URL
6. 嘗試登入
7. 判斷登入是否成功
8. 成功後寄出通知信
9. 寫入 state
10. 關閉 browser
11. exit 0
```

失敗流程：

```text
1. 捕捉錯誤
2. 寫入 error log
3. 如果 page 存在，輸出 screenshot 到 artifacts/
4. 如果 page 存在，輸出 HTML dump 到 artifacts/
5. 寫入 state，標記 failed
6. 關閉 browser
7. exit 1
```

---

## 13. Playwright 登入邏輯

LHU 登入頁：

```text
https://ms.lhu.edu.tw/cgi-bin/login?index=1
```

環境變數：

```text
LHU_URL
LHU_USERNAME
LHU_PASSWORD
```

登入流程初版可以先採用保守策略：

1. 開啟 `LHU_URL`
2. 等待 `domcontentloaded`
3. 偵測 username input
4. 偵測 password input
5. 填入帳號密碼
6. 點擊 submit button
7. 等待 navigation 或 network idle
8. 透過 URL、頁面文字、或 logout element 判斷登入成功

由於實際 LHU 頁面 selector 可能不確定，請實作時保留 selector 設定區，例如：

```js
const selectors = {
  username: 'input[name="id"], input[name="username"], input[type="text"]',
  password: 'input[name="password"], input[type="password"]',
  submit: 'input[type="submit"], button[type="submit"]'
};
```

若 selector 找不到，必須輸出 screenshot 與 HTML dump。

---

## 14. Mailer 規格

建立 `src/lib/mailer.js`。

使用 `nodemailer`。

env：

```text
SMTP_HOST
SMTP_PORT
SMTP_SECURE
SMTP_USER
SMTP_PASS
MAIL_FROM
MAIL_TO
MAIL_BODY_TEMPLATE
```

寄信內容：

subject：

```text
LHU login success - {{TODAY_TAIPEI}}
```

body：

```text
{{MAIL_BODY_TEMPLATE}}
```

其中 `{{TODAY_TAIPEI}}` 要替換為台灣日期，例如：

```text
2026-06-19 已成功登入
```

---

## 15. Logger 規格

建立 `src/lib/logger.js`。

log 目錄：

```text
logs/lhu-weekly-email/
```

log 檔案：

```text
logs/lhu-weekly-email/YYYY-MM-DD.log
logs/lhu-weekly-email/latest.log
```

每筆 log 建議格式：

```text
[2026-06-19T09:00:00+08:00] [INFO] message
[2026-06-19T09:00:01+08:00] [ERROR] message
```

logger 至少支援：

```js
logger.info(message)
logger.error(message, error)
```

---

## 16. State 規格

建立 `src/lib/state.js`。

state 檔案：

```text
state/lhu-weekly-email.json
```

成功時寫入：

```json
{
  "job": "lhu-weekly-email",
  "lastRunAt": "2026-06-19T09:00:00+08:00",
  "lastSuccessAt": "2026-06-19T09:00:20+08:00",
  "lastFailureAt": null,
  "status": "success",
  "message": "LHU login and email notification completed"
}
```

失敗時寫入：

```json
{
  "job": "lhu-weekly-email",
  "lastRunAt": "2026-06-19T09:00:00+08:00",
  "lastSuccessAt": "2026-06-12T09:00:20+08:00",
  "lastFailureAt": "2026-06-19T09:00:20+08:00",
  "status": "failed",
  "message": "error message here"
}
```

注意：失敗時不要覆蓋掉前一次成功時間。

---

## 17. Artifacts 規格

失敗時輸出：

```text
artifacts/lhu-weekly-email/failure-YYYY-MM-DD-HHmmss.png
artifacts/lhu-weekly-email/failure-YYYY-MM-DD-HHmmss.html
```

用途：

1. 檢查登入頁是否改版
2. 檢查 selector 是否失效
3. 檢查是否出現驗證碼、MFA、維護頁面
4. 檢查網路或憑證錯誤

---

## 18. PowerShell wrapper 規格

建立：

```text
scripts/run-lhu-weekly-email.ps1
```

功能：

1. 切到專案根目錄。
2. 檢查 Docker Engine 是否可用。
3. 執行 `docker compose run --rm lhu-weekly-email`。
4. 將 stdout / stderr 寫入 `logs/lhu-weekly-email/task-scheduler.log`。
5. Docker job 失敗時 PowerShell exit code = 1。
6. Docker job 成功時 PowerShell exit code = 0。

PowerShell 內容：

```powershell
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $Root "logs\lhu-weekly-email"
$TaskLog = Join-Path $LogDir "task-scheduler.log"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-TaskLog {
    param ([string]$Message)
    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content $TaskLog "[$Time] $Message"
}

try {
    Set-Location $Root

    Write-TaskLog "Checking Docker engine"
    docker info | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Docker engine is not available"
    }

    Write-TaskLog "Starting lhu-weekly-email job"
    docker compose run --rm lhu-weekly-email 2>&1 | Tee-Object -FilePath $TaskLog -Append

    if ($LASTEXITCODE -ne 0) {
        throw "Docker job failed with exit code $LASTEXITCODE"
    }

    Write-TaskLog "Job finished successfully"
    exit 0
}
catch {
    Write-TaskLog "Job failed: $_"
    exit 1
}
```

---

## 19. Windows Task Scheduler 規格

等手動執行成功後，再建立 Task Scheduler。

Trigger：

```text
Weekly
Saturday
09:00
```

Action：

```text
Program:
powershell.exe
```

Arguments：

```text
-NoProfile -ExecutionPolicy Bypass -File "C:\path\to\lhu-email\scripts\run-lhu-weekly-email.ps1"
```

Start in：

```text
C:\path\to\lhu-email
```

注意：

1. Docker Desktop 必須可用。
2. 建議設定成使用目前 Windows 使用者執行。
3. 先不要設定成「不管使用者是否登入都執行」，除非確認 Docker Desktop 在該模式下可用。
4. 任務失敗時先看 `logs/lhu-weekly-email/task-scheduler.log`。

---

## 20. README.md 必須包含

README 至少包含：

```text
1. 專案目的
2. 目錄結構
3. 如何建立 secrets/lhu-weekly-email.env
4. 如何 build Docker image
5. 如何執行 smoke test
6. 如何手動執行正式 job
7. 如何設定 Windows Task Scheduler
8. 如何查看 logs/state/artifacts
9. 常見錯誤排查
```

README 指令範例：

```powershell
docker compose build
docker compose run --rm smoke
docker compose run --rm lhu-weekly-email
```

---

## 21. 實作階段要求

請分階段實作，不要一次混在一起。

### Phase 1：專案骨架

建立：

```text
package.json
Dockerfile
docker-compose.yml
.dockerignore
.gitignore
README.md
src/smoke-playwright.js
logs/.gitkeep
state/.gitkeep
sessions/.gitkeep
artifacts/.gitkeep
secrets/lhu-weekly-email.env.example
```

驗收：

```powershell
docker compose build
docker compose run --rm smoke
```

必須成功。

---

### Phase 2：共用工具

建立：

```text
src/lib/env.js
src/lib/date.js
src/lib/logger.js
src/lib/state.js
src/lib/mailer.js
```

驗收：

1. env 缺少必要值時會 fail fast。
2. logger 可以寫入 log。
3. state 可以寫入 JSON。
4. mailer 可以依照 env 建立 SMTP transport。

---

### Phase 3：正式 job

建立：

```text
src/jobs/lhu-weekly-email.js
```

驗收：

```powershell
docker compose run --rm lhu-weekly-email
```

成功時：

```text
1. 完成 LHU 登入
2. 寄出成功通知信
3. 寫入 logs
4. 寫入 state success
5. exit code = 0
```

失敗時：

```text
1. 寫入 error log
2. 寫入 state failed
3. 輸出 screenshot / HTML dump
4. exit code = 1
```

---

### Phase 4：Windows 排程

建立：

```text
scripts/run-lhu-weekly-email.ps1
```

驗收：

```powershell
.\scripts\run-lhu-weekly-email.ps1
```

成功後再手動建立 Task Scheduler。

---

## 22. 安全要求

1. 不要把真實帳號密碼寫進任何 JS、Dockerfile、README。
2. 不要 commit `secrets/lhu-weekly-email.env`。
3. 不要 commit logs、state、sessions、artifacts。
4. error log 不可印出完整密碼。
5. env validation 顯示缺少哪個 key，但不可顯示 secret value。
6. 若需要展示設定，只能展示 masked value。

---

## 23. 完成定義

專案完成時應符合：

```text
docker compose run --rm smoke
```

可成功執行 Playwright smoke test。

```text
docker compose run --rm lhu-weekly-email
```

可成功執行 LHU 登入與寄信任務。

```text
.\scripts\run-lhu-weekly-email.ps1
```

可從 Windows PowerShell 成功觸發 Docker job。

Task Scheduler 可每週六 09:00 觸發 PowerShell wrapper。

失敗時可從以下位置排查：

```text
logs/lhu-weekly-email/
state/lhu-weekly-email.json
artifacts/lhu-weekly-email/
```

---

## 24. 給 Codex IDE 的實作限制

請 Codex IDE 先完成 Phase 1 並停下來，不要直接做到正式登入。

第一輪只需要完成：

```text
1. 專案骨架
2. Dockerfile
3. docker-compose.yml
4. smoke-playwright.js
5. .gitignore
6. .dockerignore
7. README.md 初版
8. secrets/lhu-weekly-email.env.example
```

完成後，使用以下指令驗收：

```powershell
docker compose build
docker compose run --rm smoke
```

smoke test 成功後，再進入 Phase 2。
