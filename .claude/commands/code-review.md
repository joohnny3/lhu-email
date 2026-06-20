---
allowed-tools: Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(git blame:*), Bash(git show:*)
description: 對本機未提交的變更做 code review（繁體中文）
disable-model-invocation: false
---

對目前 working tree 的未提交變更（git diff）進行 code review。

請全程使用「繁體中文」回覆。

執行步驟：

1. 先跑 `git status` 與 `git diff`（含 staged 與 unstaged）了解變更範圍。若沒有任何變更，告知使用者並停止。
2. 對每個被修改的檔案，讀取「被改動處所在的完整函式／區塊」以取得足夠上下文，必要時用 `git blame` 或 `git log` 補歷史脈絡。變更規模小（例如數十行內、單一檔案）時，直接 inline 審查即可，不需動用多個 agent。
3. 從以下角度審查，聚焦真正會出問題的點，忽略 linter／typechecker／formatter 能抓到的瑣事與風格 nitpick：
   - 正確性：邏輯、邊界條件、錯誤處理、重導向與 exit code 語意、變數作用域。
   - 既有約定：若專案有 CLAUDE.md，檢查是否遵循（請附上對應 CLAUDE.md 的路徑與引文）。
   - 歷史脈絡：對照 git 歷史，確認此次改動不會重新引入已修過的問題。
   - 程式碼註解：確認變更未違反原檔註解中的指引。
4. 對每個發現的問題，自行評估信心程度（0–100）。只回報信心 ≥ 80 的問題；低於此者視為 false positive 略過。
5. 輸出格式：

   先一句總結（例如「未發現正確性問題，可安全提交」或「發現 N 個問題」）。
   每個問題用以下結構，並聚焦本次實際改動的行：
   - 檔案與行號
   - 嚴重度（high／medium／low）
   - 問題描述
   - 觸發情境（什麼條件下會出錯，或為何只是建議）

false positive 範例（請排除，不要回報）：
- 既有問題（非本次改動引入）
- 看似 bug 但實際正確的寫法
- 資深工程師不會挑的吹毛求疵
- linter／typechecker／compiler 會自動抓到的（import、型別、格式、空行等）
- 一般性程式碼品質建議（測試覆蓋率、文件不足等），除非 CLAUDE.md 明確要求
- 使用者本次未修改的行上的問題

注意事項：
- 不要嘗試 build 或 typecheck，那些由 CI 另外處理。
- 不要把結果回貼到任何 GitHub PR——本指令只審查本機 diff，結果直接在對話中呈現。
- 審查完畢後，主動詢問是否要協助 commit。