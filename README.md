# lhu-email

使用 Docker、Node.js 與 Playwright 登入龍華科技大學 Mail2000，寄出每週通知信。Windows Task Scheduler 會在排程到期時啟動 Docker Desktop、等待 Docker Engine ready、執行一次性 container，最後執行 `docker compose down`。

## 跨電腦使用

GitHub 可以共用程式碼與設定範本，但下列內容不會上傳，必須在每台新電腦個別建立：

- `secrets/lhu-weekly-email.env`：LHU 帳密、收件人及信件範本。
- Docker image：每台電腦重新 build。
- Windows Task Scheduler 任務：每台電腦個別安裝。
- `state/`、`logs/`、`sessions/`、`artifacts/`：只存在本機。

不要同時在兩台電腦啟用相同排程。`state/task-scheduler.json` 不會跨電腦同步，兩台電腦可能各寄一封。移轉時應先停用舊電腦的任務，再啟用新電腦。

## 新電腦需求

- Windows 10 或 Windows 11。
- Docker Desktop，使用 Linux containers。
- Docker Compose 2.24 以上。
- 可連線至 `ms.lhu.edu.tw` 及 `example.com`。
- 執行排程時必須有 Windows 使用者登入；Docker Desktop 不以 SYSTEM 帳號執行。

Node.js、Playwright 與 Chromium 都在 Docker image 內，新電腦不需要另外安裝 Node.js 或 Playwright browser。

## 目錄

```text
src/jobs/      登入檢查與正式寄信程式
scripts/       PowerShell wrapper 與排程安裝腳本
secrets/       可提交的 env 範本；真實 env 不進 Git
logs/          本機執行紀錄
state/         本機排程成功狀態
sessions/      保留給 Playwright session
artifacts/     失敗截圖
```

## 1. Clone 與建立 `.env`

Clone repository 後，在專案根目錄執行：

```powershell
Copy-Item .\secrets\lhu-weekly-email.env.example .\secrets\lhu-weekly-email.env
notepad .\secrets\lhu-weekly-email.env
```

填入：

```env
LHU_URL=https://ms.lhu.edu.tw/cgi-bin/login?index=1
LHU_USERNAME=你的 LHU 帳號
LHU_PASSWORD=你的 LHU 密碼

MAIL_TO=收件人@example.com
MAIL_SUBJECT_TEMPLATE=LHU weekly email {{TODAY_TAIPEI}}
MAIL_BODY_TEMPLATE=LHU weekly email {{TODAY_TAIPEI}}

TZ=Asia/Taipei

# 選填：排程失敗時通知的 Discord Webhook，見「8. 失敗通知」
DISCORD_WEBHOOK_URL=
```

`{{TODAY_TAIPEI}}` 會在寄信時替換成台北當天日期，例如 `2026-06-19`。

如果密碼包含空白或 `#`，可使用單引號保留完整內容：

```env
LHU_PASSWORD='your password#value'
```

此專案直接透過 LHU Mail2000 網頁寄信，不需要 SMTP 帳密。

## 2. Secrets 安全檢查

真實 env 已由 `.gitignore` 和 `.dockerignore` 排除，不會進 Git 或 Docker image。初始化 Git 後，在第一次 commit 前確認：

```powershell
git check-ignore -v .\secrets\lhu-weekly-email.env
git status --short
```

第一個指令必須顯示 `.gitignore` 規則。不要強制執行 `git add -f`，也不要把真實密碼貼到 issue、commit、README 或 CI log。

若 secret 曾被 commit，後續刪除檔案仍無法清除 Git history；應立即更換密碼並清理 repository history。

## 3. Build 與基本測試

確認 Docker Desktop 已啟動：

```powershell
docker info
docker compose version
docker compose build
docker compose run --rm smoke
```

smoke test 成功時會看到：

```json
{
  "ok": true,
  "status": 200,
  "title": "Example Domain",
  "url": "https://example.com/"
}
```

## 4. 測試 LHU 登入

此指令只登入，不寄信：

```powershell
docker compose run --rm lhu-login-check
```

登入失敗時，截圖會寫入 `artifacts/lhu-login-check/`。截圖可能包含私人資訊，不能提交至 Git。

## 5. Dry-run 與正式寄信

先執行 dry-run。它會登入並填妥寫信表單，但不按下寄送：

```powershell
docker compose run --rm -e LHU_SEND_EMAIL=false lhu-weekly-email
```

確認輸出的收件人、主旨與內文正確後，再正式寄送：

```powershell
docker compose run --rm lhu-weekly-email
```

正式 job 失敗時，截圖會寫入 `artifacts/lhu-weekly-email/`。

## 6. 安裝 Windows 排程

預設排程為每週六 09:00。排程到期時會：

```text
Task Scheduler
→ 判斷本週是否已成功執行
→ 確認連得到 LHU_URL 的主機，最多等 30 秒
→ 啟動 Docker Desktop
→ 等待 Docker Engine ready，最多 300 秒
→ docker compose run --rm lhu-weekly-email
→ 失敗時送出通知
→ docker compose down --remove-orphans
```

如果排程時間 Windows 關機或使用者未登入，任務會在下次登入 60 秒後補跑。補跑前會讀取 `state/task-scheduler.json`，避免同一週重複寄送。

安裝目前 Windows 使用者的排程：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-lhu-weekly-email-task.ps1
```

如確定沒有其他 WSL 工作需要保留，可讓任務結束後執行 `wsl --shutdown`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-lhu-weekly-email-task.ps1 -ShutdownWsl
```

`wsl --shutdown` 會關閉所有 WSL distributions，因此預設不啟用。

## 7. 驗證 Windows 排程

查看任務狀態：

```powershell
Get-ScheduledTask -TaskName "LHU Weekly Email"
Get-ScheduledTaskInfo -TaskName "LHU Weekly Email"
```

手動觸發 Task Scheduler：

```powershell
Start-ScheduledTask -TaskName "LHU Weekly Email"
```

查看最新 log：

```powershell
Get-Content -Tail 30 .\logs\lhu-weekly-email\task-scheduler.log
```

`LastTaskResult = 0` 或工作排程器顯示 `0x0` 代表任務正常結束。若本週已寄送，手動觸發只會留下 `Current weekly slot has already completed; skipping`，不會重寄。

## 8. 失敗通知

排程失敗時會通知原因。先嘗試 Discord；沒有設定 Webhook 或送不出去（例如電腦沒有網路）時，改用 Windows 通知。

| 類別 | 判斷方式 |
| --- | --- |
| 網路 | 開跑前 30 秒內連不到 `LHU_URL` 的主機；不會啟動 Docker |
| 網站改版 | 找不到預期的登入欄位、寫信按鈕或表單；隔 15 秒重試一次仍失敗才回報 |
| 帳密失效 | 送出登入後仍停在登入頁；不重試，避免帳號被鎖 |
| 寄送未確認 | 已按下傳送但無法確認結果；不重試，避免重複寄信 |

啟用 Discord 通知：在 Discord 頻道的「編輯頻道 → 整合 → Webhook」建立 Webhook，將網址寫入 `secrets/lhu-weekly-email.env`：

```env
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
```

Webhook 網址等同密碼，拿到的人都能對該頻道發訊息，不要提交至 Git。

送出一則測試通知，不會登入也不會寄信：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run-lhu-weekly-email.ps1 -TestNotification
```

通知文字在 `scripts/failure-messages.json`。每次執行的結果會寫入 `state/lhu-weekly-email-result.json`。

## 9. 移轉到另一台電腦

1. 在舊電腦停用或刪除 `LHU Weekly Email` 排程。
2. Push 程式碼到 GitHub；不要上傳真實 env、state、log 或 artifacts。
3. 在新電腦 clone repository。
4. 透過安全方式複製 `.env`，或從 `.env.example` 重新建立。
5. 若本週已寄送，可安全複製舊電腦的 `state/task-scheduler.json`，避免新電腦補寄；不要將 state commit 到 Git。
6. 在新電腦依序執行 build、smoke、登入檢查及 dry-run。
7. 確認舊電腦排程已停用後，再安裝新電腦排程。

停用舊電腦排程：

```powershell
Disable-ScheduledTask -TaskName "LHU Weekly Email"
```

永久刪除：

```powershell
Unregister-ScheduledTask -TaskName "LHU Weekly Email" -Confirm:$false
```

## 10. GitHub 初次上傳

目前資料夾若尚未初始化 Git：

```powershell
git init
git check-ignore -v .\secrets\lhu-weekly-email.env
git add .
git status
git commit -m "Initial lhu-email automation"
```

確認 `git status` 沒有出現以下內容後，才能 push：

```text
secrets/lhu-weekly-email.env
logs/
state/task-scheduler.json
sessions/
artifacts/
```
