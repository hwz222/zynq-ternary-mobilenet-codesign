# twn_fuse Linux driver 開發講義（v1.1，繁體中文）

這是 [`linux/driver/twn_fuse`](../../../linux/driver/twn_fuse/) 的學習講義，對象是母語為台灣華語、英文為第二語言、
會寫 C 與 RTL、但沒寫過 Linux driver 的工程師。目標：用最短的時間看懂每一項 Linux driver 技術，並知道程式碼裡的
關鍵函式和邏輯在哪裡。

講義只講現在的 v1.1，一本、不超過 100 頁：從 UIO 到 kernel driver 的 probe、MMIO、DMA buffer、mmap、ioctl、
中斷、鎖、sysfs 與 debugfs、app 端的 HAL，再到限制 `/dev/mem`、SMMU、timing closure、驗證，以及開機自動載入與發佈。
舊的程式只出現在每一章「原本怎麼做」的框裡（v1.0.0 的 UIO 寫法，或 driver v1.0）。

先前分成兩冊（第一冊講 driver v1.0、第二冊講 v1.1 的延伸），兩冊在 tag `v1.1.0` 裡
（`docs/zh-TW/driver-handout/` 與 `docs/zh-TW/driver-handout-2/`，各自的審稿紀錄也在那裡）；這一本取代它們。

## 建置

需要 TeX Live（XeLaTeX、latexmk）與 Python 3。字型用 Windows 內建的 Microsoft JhengHei、Segoe UI、Consolas；
在其他系統上請改 `handout.tex` 開頭的字型設定。

    cd docs/zh-TW/driver-handout
    latexmk            # 先跑 extract.py 抽出程式碼，再編譯；輸出 build/handout.pdf

## 檔案

| 檔案 | 用途 |
|---|---|
| `handout.tex` | 主檔：版面、固定的框（原本怎麼做／用了什麼技術／改善了什麼／面試會問／踩過的坑）、程式碼與紀錄框、換頁規則 |
| `sections/` | 導讀、第 1–14 章、附錄 A 名詞表、B 面試題 30 秒版本、C 如何重現 |
| `sections/numbers.tex` | 講義裡會重複出現的量測數字，只寫在這裡一次，各附紀錄檔與行號 |
| `snippets.txt` | 講義引用哪些程式碼；沒有 `git:` 開頭的是現行版本，`git:3bdd485:` 是 v1.0.0，`git:7615324:` 是 driver v1.0 |
| `extract.py` | 從 repo 的實際原始碼抽出程式碼並保留行號，講義裡的程式碼因此永遠和 repo 一致 |
| `REVIEW_CHECKLIST.md` | 審稿人逐項檢查的清單 |
| `REVIEW_LOG.md` | 每一輪審稿的發現與處理結果 |

板上與模擬的紀錄在 [`results/raw/linux_driver_v11_20261027/`](../../../results/raw/linux_driver_v11_20261027/)
（v1.1）與 [`results/raw/linux_driver_20261026/`](../../../results/raw/linux_driver_20261026/)（driver v1.0，只用來比較），
講義用 `\boardfile` 直接讀出原文，不手抄。

## 寫作規則

每一章固定八個部分，順序不變：

1. **一句話**：讀完這一句就知道這章在講什麼。
2. **原本怎麼做**：舊的寫法與問題；框的標題寫明是 v1.0.0 還是 driver v1.0，程式碼用 `git:<commit>:` 釘住。
3. **用了什麼技術**：kernel API、Yocto 變數、Vivado 命令或 RTL 結構的名字。
4. **改善了什麼**：具體、可以驗證的改變，不寫空泛的好處；沒量的標「未量測」或「推算」。
5. **實際例子**：用 `\snip{}` 抽出現行的程式碼，逐段說明；附板上的實際紀錄。
6. **原理**：為什麼這樣做是對的，必要時一張圖；kernel 行為以 Linux 6.1 的原始碼為準。
7. **面試會問**：約 1 分鐘的完整回答；30 秒版本收在附錄 B。
8. **關鍵函式速查**：名稱、檔案與行號、做什麼。

一致性：

- 同一件事只在一章詳細說明，其他章只寫一句並指向那一章（例如 CMA 與 IOVA 在第 3 章、`/dev/mem` 在第 10 章）。
- 同一個東西整本只用一個名字；開機組（A–I、S）的定義只在導讀。
- 數字只寫在 `numbers.tex`；正文直接引用紀錄時寫出檔名與行號。
- 比較兩個數字時，寫明兩邊是不是同一組開機檔、同一個程式、同樣的次數；不同就寫出差在哪裡。

用語：

- 敘述用台灣繁體中文，技術名詞保留英文（probe、ioremap、mmap、ioctl、DMA、cache、mutex…），第一次出現時用一句中文解釋，並收進附錄 A。
- 不用中國大陸用語：記憶體（不是內存）、程式（不是程序）、介面（不是接口）、預設（不是默認）、檔案（不是文件）。
- 句子短，先講結論再講理由。不用沒解釋過的代號。

## 審稿流程

寫的人不能自己審。審稿人（一個沒有參與撰寫的 agent）以 `REVIEW_CHECKLIST.md` 逐項審查整份 PDF 與原始檔，
對照 repo 的程式碼、紀錄與 kernel 原始碼查證；發現逐條記進 `REVIEW_LOG.md`，標明嚴重程度。寫的人修正後，
審稿人再看一次，確認每一條都已處理或註明不改的理由，判定可以交付才交付。
