# SteamDeckSSH 修正版說明

本版本以 mi5hmash/SteamDeckSSH（commit `bfabbd1`，v1.0.0）為基礎修改。

## 安全性修正
1. **移除公開的預設密碼 `GabeNewell#1`**
   帳號沒有密碼時，會跳出視窗讓你自己設定密碼（至少 8 個字元、需輸入兩次確認，且不接受 `GabeNewell#1`）。
2. **移除內建的別人的公鑰**
   `data/authorized_keys` 改成只有註解的空白檔。開啟金鑰模式（`KEY_AUTH=1`）時：
   - 若檔案裡還有原版附帶的那把公鑰 → 拒絕開啟並提示刪除
   - 若檔案裡沒有任何公鑰 → 拒絕開啟並提示先貼上
3. **移除密碼時改成先詢問**：原本沒密碼的帳號，在不再需要密碼時會問你要不要移除，不會自動移除。
4. **不再盲試密碼**：原版會先用預設密碼試 sudo，對已設密碼的人來說每次都會多一次失敗紀錄（可能觸發鎖定）。現在沒有記住的密碼就直接詢問。
5. 加密用的金鑰改用環境變數傳給 openssl，不會出現在 `ps` 的程序列表裡；`settings.json` 和 `.user.sec` 權限改為 600。
6. sshd 設定：
   - 密碼模式明確寫出 `PasswordAuthentication yes`
   - 兩種模式都加上 `MaxAuthTries 3`、`LoginGraceTime 30`
   - 移除已淘汰的 `Protocol 2`，以及金鑰模式中的 `ChallengeResponseAuthentication`
   - `ClientAliveCountMax 0` 改為 `3`（新版 OpenSSH 中 0 代表「永不斷線」，不是原作者想要的效果）
7. 密碼模式開啟前的確認視窗會提醒「只在信任的網路使用」。

## 錯誤修正
1. **`settings.json` 寫入失敗**：原版約 20% 機率因隨機金鑰含 `"` 或 `\` 而寫出空檔。現在改用 `jq --arg` 正確跳脫字元，隨機金鑰也只用英數字；如果偵測到損壞的舊檔，會自動重新產生。
2. **備份更安全**：
   - 已經有備份就不會覆蓋，腳本中途被中斷也不會把「改過的設定」當成原始設定
   - 原本不存在的檔案會用 `.none` 標記，關閉時刪除，不留殘檔
   - 沒有被本工具備份過的檔案，關閉時不會動（原版如果 SSH 是你手動開的，會把你的 KDE 電源設定刪掉）
   - 不論 `KEY_AUTH` 設定為何，關閉時都會還原所有備份（原版若在開、關之間改了 `KEY_AUTH`，`authorized_keys` 會殘留）
3. **啟動前先驗證設定**：先執行 `ssh-keygen -A` 補齊主機金鑰，再用 `sshd -t` 檢查設定。設定有問題就自動還原原始檔並停止，不會讓 SSH 壞掉。
4. 原版在 `cd` 到腳本目錄之前就先讀取 `.pfl`，所以從其他目錄執行會讀錯。`.pfl` 現在只會在真的開啟 SSH 時寫入，關閉時刪除。
5. `_Create a Shortcut on Desktop.sh`：`mkdir` 改為 `mkdir -p`，目錄已存在時不會報錯。

## 其他
- 移除 `_Installer.sh`：它永遠下載作者 GitHub 上的最新版，不是這份修正版。請手動安裝（見 README）。
- 移除方法見 README 的「Uninstallation」。

## 安裝與使用
1. 把整個資料夾複製到 Steam Deck（例如 `~/Documents/SteamDeckSSH`）。
2. （建議）先在 Konsole 執行 `passwd`，設定你自己的強密碼。
3. 如果要用金鑰登入：
   - 在電腦上執行 `ssh-keygen -t ed25519`
   - 把 `~/.ssh/id_ed25519.pub` 的內容貼到 `data/authorized_keys`
   - 第一次執行腳本產生 `settings.json` 後，把其中的 `KEY_AUTH` 改成 `"1"`
4. 對 `_Create a Shortcut on Desktop.sh` 按右鍵 →「在 Konsole 中執行」，桌面上會出現捷徑。
5. 從桌面捷徑執行。用完記得再執行一次，把 SSH 關掉。
6. 連線方式：`ssh -p 2122 deck@<Deck 的 IP>`
