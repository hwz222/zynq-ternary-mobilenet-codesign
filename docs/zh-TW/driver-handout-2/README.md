# twn_fuse driver 開發講義第二冊（v1.1，繁體中文）

第一冊（[`../driver-handout/`](../driver-handout/)）講 driver v1.0：用輪詢等硬體、手動載入、和 UIO 並存。
這一冊講 v1.1 加上的東西：拆開 fps 差異的量測、ioctl 的成本、中斷（從 RTL 到 ISR）、重建 bitstream 的
timing closure、debugfs、開機自動載入、拿掉 `/dev/mem`、SMMU、device-tree binding，以及發佈。
讀者與目標和第一冊相同：母語為台灣華語、英文為第二語言的工程師，用最短的時間看懂每一項技術，
並知道程式碼裡的關鍵函式和邏輯在哪裡。

## 建置

和第一冊相同（TeX Live 的 XeLaTeX、latexmk，Python 3；字型用 Windows 內建的 Microsoft JhengHei、Segoe UI、Consolas）。

    cd docs/zh-TW/driver-handout-2
    latexmk            # 先用第一冊的 extract.py 依本冊的 snippets.txt 抽出程式碼，再編譯；輸出 build/handout.pdf

## 檔案

| 檔案 | 用途 |
|---|---|
| `handout.tex` | 主檔：版面與第一冊相同；「原本怎麼做」框預設指 driver v1.0，可帶標題改指 v1.0.0 的 UIO 版本 |
| `sections/` | 每項技術一節，對應延伸清單第 1–10 項；附錄 A 名詞表、B 面試 30 秒版本、C 如何重現 |
| `sections/numbers.tex` | 講義裡會重複出現的量測數字，只寫在這裡一次，各附出處 |
| `snippets.txt` | 講義引用哪些程式碼；`git:7615324:` 開頭的是 driver v1.0 的版本 |
| `REVIEW_CHECKLIST.md` | 審稿人逐項檢查的清單 |
| `REVIEW_LOG.md` | 每一輪審稿的發現與處理結果 |

板上與模擬的紀錄都在 [`results/raw/linux_driver_v11_20261027/`](../../../results/raw/linux_driver_v11_20261027/)，
講義用 `\boardfile` 直接讀出原文，不手抄。

## 寫作規則

和第一冊相同：每一節固定八個部分（一句話、原本怎麼做、用了什麼技術、改善了什麼、實際例子、原理、
面試會問、關鍵函式速查），順序不變；台灣繁體中文用語，技術名詞保留英文並在第一次出現時用一句中文解釋；
程式碼一律從 repo 抽出；板上輸出一律貼實際 log，註明日期與開機檔的 SHA-256 前 16 個十六進位字元。

這一冊多兩條：

- 沒做到的項目照實寫成「沒做到」，並寫出原因與要怎麼補（例如需要額外安裝的工具）。
- 每個「改善」都要有量測或板上輸出；只由規格推得、沒有量的，標明「未量測」。

## 審稿流程

和第一冊相同：寫的人不能自己審。審稿人（沒有參與撰寫的 agent）以 `REVIEW_CHECKLIST.md` 逐項審查，
發現記進 `REVIEW_LOG.md`；修正後再審一次；全部完成後對整份 PDF 通讀審查，才交付。
