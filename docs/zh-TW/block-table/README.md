# Backbone block table 對照表（繁體中文）

driver 用 `TWN_IOC_SET_TABLE` 寫進 PL 的 block table（[`tools/gen_desctab.py`](../../../tools/gen_desctab.py)
產生的 17 列 × 16 個 32-bit 字）逐位元的對照表：table 的形狀與位址、每個字的位元配置、38 個欄位的編碼／單位／意義／
哪條硬體路徑讀它、block 1 與 block 2（有 residual）逐欄位分解、17 列解碼總覽、原始 272 個字，以及 PL 開機檢查的錯誤碼。

直接閱讀：[`block_table.pdf`](block_table.pdf)（9 頁）。

## 數值從哪裡來

表格不是手抄的。[`gen_block_table.py`](gen_block_table.py) 讀 `tools/fuse_desctab.h` 的 272 個字，每個欄位的位元位置
直接從 [`rtl/fuse/twn_desctab.v`](../../../rtl/fuse/twn_desctab.v) 的 `assign` 敘述讀出，解碼後寫出 `gen/*.tex`。
寫出之前要通過下列核對，任何一項不過就停止：

1. 解出的欄位重新編碼後和原字逐字相同（因此所有未用位元都是 0）。
2. 欄位和模型形狀檔 `p1_manifest.json`、權重索引 `fuse_weights_index.json` 逐列相同。檔案不在時跳過，PDF 也不列這一項。
3. 權重檔裡每個區域接在前一個區域之後（對齊值取自 `tools/pack_fuse_weights.py`），片上起點加長度不超過記憶體深度
   （深度與寬度取自 `twn_desctab.v`、`twn_wmem.v`）。
4. 相鄰兩個 block（含 block 16 接回 block 0）在片上記憶體的區域不重疊。

PDF 第 4、5 節的文字引用了幾個具體數字（block 1 的 offset 與片上起點、block 2 的 residual 係數等）；腳本也核對這些數字，
table 一改就會停下來，提醒重讀那兩節。

## 建置

`tools/fuse_desctab.h` 與兩個模型檔不進版控，先照 [`docs/REBUILD.md`](../../REBUILD.md) 第 1 步產生
（`run_p1.sh`、`pack_fuse_weights.py`、`gen_desctab.py`）。然後：

    cd docs/zh-TW/block-table
    python gen_block_table.py          # 模型檔在別處時加 --model-dir DIR
    latexmk -xelatex block_table.tex

需要 TeX Live（XeLaTeX、latexmk，套件 xeCJK、bytefield、longtable、booktabs）。字型是 Windows 內建的 Microsoft JhengHei；
其他系統請改 `block_table.tex` 開頭的 `\setCJK...font`。`gen/` 是產物，不進版控。

改了 table、`twn_desctab.v` 的欄位、或這份文件之後，要重新建置，並把 `block_table.pdf` 和原始碼放在同一個 commit。

## 檔案

| 檔案 | 用途 |
|---|---|
| `block_table.tex` | 文件本體 |
| `gen_block_table.py` | 解碼、核對、產生 `gen/*.tex` |
| `block_table.pdf` | 建置好的 PDF |
