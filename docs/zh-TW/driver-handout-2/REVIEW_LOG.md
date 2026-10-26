# 審稿紀錄（第二冊）

每一輪一個段落：日期、審查的章節、審稿人的發現（嚴重程度：必改／建議）、處理結果。

## 第 1 輪（2026-10-27）

**審查範圍**：整份 `build/handout.pdf`（61 頁，2026-10-27 03:40 建置；`sections/*.tex`、`numbers.tex`、`snippets.txt`
的修改時間都不晚於它，這個資料夾的 `git status` 是乾淨的，所以沒有重建；`build/handout.log` 沒有 Overfull）、
`handout.tex`、`sections/*.tex`、`sections/numbers.tex`、`snippets.txt` 與 `build/snippets/` 抽出的全部程式碼；
PDF 每一頁轉成圖檢查版面（只寫到暫存目錄）。

對照的紀錄：`results/raw/linux_driver_v11_20261027/` 的全部檔案（D1–D6、E0–E8、F0–F1、G1–G4、S1–S4 與兩份報告、
`board_hashes_D.txt`、`board_hashes_E.txt`、README；E2m 只對 README）與 `first_bitstream/`（README、F1、S4 兩份報告、
S5、`board_hashes_E.txt`）；`results/raw/thesis_model_20261012/` 的 timing／util 報告；`results/board_results.json` 的
`linux_driver_twn_fuse_v11_20261027`、`linux_driver_twn_fuse_20261026`、`timing_bitstream_52b400785924efe0`、
`resources_bitstream_52b400785924efe0`、`rebuilt_from_clone_20261011`、`opt1_archived_20261008`。

程式：`linux/driver/twn_fuse/` 的 `twn_fuse.c`、`twn_fuse_ioctl.h`、`smmu_dtb.sh`、`wjhuang,twn-fuse.yaml`、
`test/twn_bench.c`、`test/ab_measure.sh`、`test/binding_check.py`、`test/v11_check.sh`；`rtl/fuse/twn_csr.v`、
`twn_blockseq.v`（cycle 計數）、`twn_fuse_top.v`（AxPROT 的來源）、`rtl/src/twn_axi_rd.v`、`twn_axi_wr.v`、
`rtl/ip/twn_fuse_layer.v`；`vivado/build.cmd`、`build_bd_fuse.tcl`、`fuse_t1mem_pblock.xdc`、`package_fuse_ip.tcl`；
`linux/project-spec/meta-user/` 的 dtsi、`twn-fuse.bb`、Makefile、`twn-v11.cfg`、bbappend、`petalinuxbsp.conf`、
`twn-firstlogin.sh`、`board-config.bb`；`linux/build_linux.sh`、`board/make_boot.sh`、`board/deploy.sh`；
`sw/app/pl_hal_fuse.c`、`pl_hal_fuse_drv.c`、`mbv2_fuse_pipe.c`；`tools/make_synthetic_fixtures.py`；commit `7615324`
的四段由 `extract.py` 抽出後對照。

Kernel 與建置產物（WSL 內 PetaLinux 專案 `ternpose_v11`，唯讀）：kernel-source 的 `lib/devmem_is_allowed.c:20–27`、
`drivers/char/mem.c:68–80, 381`、`kernel/resource.c:1685–1687, 1696–1743`、`arch/arm64/Kconfig:134`、
`arch/arm64/mm/mmu.c:100–102, 542–543`、`arch/arm64/mm/pageattr.c:20–28`、`drivers/base/platform.c:171, 259–268`、
`kernel/sched/completion.c:34–35, 92–93`、`include/linux/completion.h:84–100`、`kernel/irq/chip.c:689–720`、
`kernel/irq/manage.c:1769, 1866–1908`、`fs/debugfs/inode.c:33, 507–519`、`include/linux/debugfs.h:48–64`、
`Documentation/filesystems/debugfs.rst:10–18`、`drivers/iommu/dma-iommu.c:625–653, 1442–1475`、
`drivers/iommu/iova.c:178` 起（`__alloc_and_insert_iova_range`）、`drivers/iommu/arm/arm-smmu/arm-smmu.c:55–68, 400–452,
1628–1631`、`include/linux/ratelimit_types.h:9–10`；`scripts/checkpatch.pl --no-tree --strict` 實際對 driver 跑過一次；
kernel-build-artifacts 的 `.config` 第 99–110、252、366、386、402、5725–5734、7149–7159、7390–7391 行；
`images/linux/system.dtb`（雜湊 `bc4255b1c54ae27e`，與開機組 E 相同；用小程式解析 `/memory@0`、smmu 與加速器節點）；
`images/linux/rootfs.cpio`（同一次建置，`rootfs.cpio.gz.u-boot` 的雜湊 `8c54689ab21fe45c` 與開機組 E 相同；讀了
`etc/ssh/sshd_config`、`etc/pam.d/common-password`、`etc/pam.d/passwd`、`etc/modules-load.d/twn_fuse.conf`）；Yocto
layers 的 `poky/meta/classes-recipe/module.bbclass:7–60`、`module-base.bbclass:7–22`、`kernel-module-split.bbclass:25–135`。

依指示沒有碰板子、沒有用網路、沒有安裝任何東西；除了這個檔案沒有改任何檔案。

審查對象是 commit `70cbcc8` 的講義原始碼與 03:40 建置的 PDF。審稿期間另有提交（`c73f462`、`71e0230`：`make_kit.sh` 去掉
debug 資訊、新增 `E9_release_kit.log`），講義原始碼只有 `10-release.tex` 被改（未提交：第 54 行後加了一個「踩過的坑」框）。
下面引用 `10-release.tex` 第 55 行以後的行號是改之前的；對照現在的檔案要加 4（R9 的 `:58`、`:67` → `:62`、`:71`；R11 的
`:70–84` → `:74–88`）。新增的框與 `E9_release_kit.log` 不在這一輪的審查範圍內。

**已查證正確、不列為問題的部分**（下一輪不必重查）：

- `numbers.tex` 的每個數字都對到出處行：D1 第 28–31 行（228.94／229.09／228.83／231.53，並由第 3–26 行重算平均相符）；
  D2 第 7–11、20 行（1.63、4168.3、4164.8、4129.0、3.5、35.8、454.6、10.9 %、316／4250／103／853／81）；D6 第 4–21 行
  （0.09–0.10、0.14–0.15、4.31–4.33、4.35–4.38）；E3 第 9–10、22–23 行（14.0、10.7、39.3、465.8）；E2 與 G2 第 37–39 行
  （平均 232.58、232.17）；`\relBoot`、`\relDtb` 與 `board_hashes_E.txt` 一致。各巨集註解寫的行號也正確。
- 衍生數字：+1.2 %、三組相差 0.26 fps、組內差 ≤ 0.94 fps、3.1 倍與 5.0 倍、每幀週期差約 0.04 ms、`write-in` 差約
  0.05 ms、MemTotal 差 261,632 kB（255.5 MB，比 256 MB 少 512 kB）、LUT 多 0.2 %、placement 差 0.177 ns、多 76 個 LUT、
  81 MB/s ≈ 每 8 bytes 99 ns、E6 的 37→1037 與 1841→2841、第一冊的 0.8 %／1.0 %（`linux_driver_twn_fuse_20261026`）。
- 第 4 節三次建置表格全部正確：`S4_timing_impl_fuse_v11.rpt` 第 10、142 行（Physopt postRoute，0.000／0.008）、
  `first_bitstream/S4_timing_impl_fuse_v11irq.rpt` 第 10、142 行（Routed，+0.037／0.008）、
  `thesis_model_20261012/timing_impl_fuse_ternpose.rpt` 第 142 行（0.000／0.002）、三份 util 報告第 36、41、109、124 行
  （44,057／44,081／44,157 LUT；36,339／36,253／36,203 FF；145；217）；S4 紀錄第 5–14 行的每一個 WNS；S5 的
  `WNS=-0.622 TNS=-443.497`；LUT 93 %、block RAM 97 %；pblock 是「偏好、不是圍欄」（`fuse_t1mem_pblock.xdc:11`）。
- 黑框範圍（R2 的三處除外）都印出文字所說的內容：D1 `1-2,27-31`；D2 `11-12,20`、`6-10`；D3 `68-71`；D5 `26-43`（第 27、
  37、38–43 行的說明正確）；E1 `4-13`、`11-15`、`11-13`、`16-31`（第 5、7–8、10、12、13 行的說明正確）；E3 `6-10,14-23`；
  E4 `4-25`、`26-36`、`37-41`（第 19 行 IRQ=3、第 42–43 行 4/4）；E6 `4-11`；E7 `1-4,8-23`；F0 `2-3,5-8,11-12,17-22`
  （0x12c0／0x1300／0x1740 拆成 TBU 4／4／5、master ID 1011／1100／1101 都算對）；F1 `14-21,51-54`；
  `first_bitstream/F1` `11-20`；G4 `37-40`；S1 `2,4-7,9-15`；S3 `24-34`、`1-3,23-45`；S4 `1,3-14`。
- 程式碼：`snippets.txt` 每一段的檔名與起訖行都和原始檔一致（含 `git:7615324:` 的四段）；`twn_fuse.c` 第 1 行（連換行）的
  md5 就是 `107a1738…`；`struct twn_status` 32 bytes、`TWN_IOC_STATUS` 不拿鎖只讀六個暫存器；`reinit_completion()` 在 START
  之前；`init_completion()` 在 `devm_request_irq()` 之前；`DMA_BIT_MASK(40)`；`TIMEOUT_US` 3 s、`POLL_US` 50；`NBLK_RESET` 17
  與 debugfs 的 1–17；`twn_mmap()` 的 `device_iommu_mapped()` 檢查；twn_bench 用 `getrusage(RUSAGE_SELF)` 與 240 MHz。
- RTL：`irq` 是暫存器輸出、level high、致能 AND done（`twn_csr.v:329–336`）；致能在 IRQ 暫存器（`:403–407`），reset 為 0
  （`:297–298`）；CTRL 每次寫入都覆蓋 `irq_en`（`:377`）；IRQ 讀出位元（`:515–516`）；HD_CTRL 讀出 [2]=done（`:525`）；
  `FUSE_OBS` 說明在 `:100–105`；`cyc_total` 只在 `S_RUN`／`S_DRAIN` 計數（`twn_blockseq.v:234, 301`）；四個 HP 埠的 AxPROT
  都來自 `twn_axi_rd.v:53`／`twn_axi_wr.v:57`（`twn_fuse_top.v:649, 712, 733, 1282–1331`），AR／AW 一共六組
  （`twn_fuse_layer.v:82–160`），與「六根 AxPROT[1]」相符；`<0x00 0x59 0x04>` → SPI 89、GIC 121、level high。
- Kernel 6.1.30：`platform_get_irq()` 只比 `_optional` 多印錯誤（`platform.c:259–268`）；completion 的計數語意
  （`completion.c:34–35, 92–93`、`completion.h:97–100`）；`/proc/interrupts` 對回傳 `IRQ_NONE` 的呼叫也計數
  （`chip.c:710` 在 `handle_irq_event()` 之前）；debugfs 掛載點預設 0700（`inode.c:33`）、`_unsafe` 的註解
  （`inode.c:507–519`）、`DEFINE_DEBUGFS_ATTRIBUTE` 用 `debugfs_attr_read/write`（`debugfs.h:48–64`）；`/dev/mem` 的
  `mmap` 逐頁呼叫 `devmem_is_allowed()`（`mem.c:68–80, 381`，arm64 用 generic 版，`Kconfig:134`），講義節錄的
  `devmem_is_allowed.c:20–27` 與原文相同，`iomem_is_exclusive()` 在 `resource.c:1696`、busy 加 `IO_STRICT_DEVMEM` 在
  `:1733–1738`；`/dev/mem` 映射 no-map 區得到 `pgprot_noncached`（`mmu.c:100–101`）；IOVA 由 DMA mask 往下、依大小對齊配置
  （`dma-iommu.c:625–653`、`iova.c:178` 起），8 MB → `0xff_ff80_0000`，`2^40` 寫進 40-bit 暫存器變 0 的解釋正確；可睡眠時
  走 `iommu_dma_alloc_remap()`、不從 CMA 配（`dma-iommu.c:1451–1455`），與 E／G 的 CmaFree 相符；`disable_bypass` 與 USFCFG
  （`arm-smmu.c:60–68, 1628–1631`）、`GFSYNR1` 回報 stream ID、「Unexpected global fault」這行表示
  `CONFIG_ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT` 沒開（`arm-smmu.c:438–447`，`.config:5732`）、context fault 格式（`:415`）；
  `.config` 的 `STRICT_DEVMEM`／`IO_STRICT_DEVMEM`（7390–7391）、`ARM_SMMU=y`（5730）、CMA 256 MB（7155）、`HZ=250`、
  `RODATA_FULL_DEFAULT_ENABLED=y`（402；線性對映因此逐頁映射，`mmu.c:542–543`、`pageattr.c:20–28`，所以「512 kB 是 256 MB
  的 PTE」這個推算在這顆 kernel 上說得通，問題只在 R3 的比較基準）。
- Yocto：`KERNEL_MODULE_AUTOLOAD` 產生 `/etc/modules-load.d/<名稱>.conf`（`kernel-module-split.bbclass:96–116`；release rootfs
  確實有 `etc/modules-load.d/twn_fuse.conf` 與 `systemd-modules-load`）；`inherit module` 傳 `KERNEL_SRC`，以 `DEPMOD=echo`
  跑 `modules_install`（`module.bbclass:9, 54–60`），depmod 留到映像建立時。
- 其他：61 頁 ≤ 75 頁；PDF 沒有紅字、沒有「待補／待寫」；沒有中國大陸用語（記憶體、程式、介面、預設、檔案用法正確，
  「映射」全篇統一）；隱私：只出現公開的預設密碼 `twn-v1.1`，沒有 email、私人路徑或主機名稱；`checkpatch.pl --strict` 對
  `twn_fuse.c` 確實是 0／0／0；開機組 D／E／F／G 與 S 檔在導讀就地定義；每一節的八個部分都在、順序正確（第 3、8 節的
  「實際例子」拆成幾個具名小節）。

### 發現

**R1（必改）A/B 實驗「相鄰兩組只差一件事」與講義自己的表格矛盾**
- 位置：`01-ab.tex:6`（一句話「四組『一次只差一件事』的實驗」）、`:22`（「四組設定，相鄰兩組只差一件事」）、`:111`
  （面試回答）、`B-interview.tex:7`（第 1 題）；PDF p.6、p.10、p.57。
- 查證：同一節表格 `01-ab.tex:48` 寫 `drv_dev` 跟上一組（`uio_68`）差「等硬體的地方，以及 buffer 位置」兩件事；
  `ab_measure.sh:21–22` 也確認 `uio_68` → `drv_dev` 同時換了等硬體的地方（user space → kernel）與 buffer（保留區
  0x6800_0000 → CMA 0x5010_0000）。所以這兩件事沒有被分開，只能說「兩者合起來看不出影響」（也不能排除兩個效應正好相抵）。
- 改法：一句話與技術框改成「第 1→2 組只換 buffer 在保留區裡的位置；第 2→3 組同時換等硬體的地方與 buffer 來源；第 3→4 組
  只換 CPU 端屬性」；結論改成「輪詢位置加上 buffer 位置，合起來看不出影響」；面試回答與附錄 B 第 1 題同步。要真的一次只差
  一件事，可補一組「driver 版、buffer 放在保留區」或「UIO 版、buffer 在 CMA」。

**R2（必改）引用的行號範圍沒有印出文字所說的內容**
- `01-ab.tex:78`（PDF p.9）：框標題寫「前三次是 Normal non-cacheable，後三次是 `map_device=1`」，但 `{4-5,14-15}` 兩邊各只印
  出一次；接著 `:80` 寫「`write-in` 從 0.14 ms 變成 0.09 ms」，框裡看到的卻是 `write-in=0.15`（第 14 行）與
  `write-in=0.10`（第 4 行），讀者對不上。改法：範圍改成 `3-21`（19 行，在 25 行上限內），或
  `4-5,7-8,10-11,14-15,17-18,20-21`；正文改成「0.14–0.15 ms 變成 0.09–0.10 ms」（直接用 `numbers.tex` 的巨集）。
- `03-irq.tex:63–65`（PDF p.18）：正文說「434,176 bytes 逐位元相同」，但 `S2_hd_int_gate.log` 的 `{626,631,634}` 只有
  「bit-exact operators 4/4」；434,176 在第 86 行（`TOTAL  bytes compared 434176   bytes wrong 0   never written 0`）。
  改法：範圍加上 `86`。
- `05-debugfs.tex:70`（PDF p.31）：`Documentation/filesystems/debugfs.rst` 第 13--17 行。「不打算當成穩定 ABI」在第 14–16 行，
  「最好當成要長期維護」結束在第 18 行（`to be maintained forever.`）。改法：改成第 14–18 行。

**R3（必改）跨開機組、跨 bitstream、跨 kernel 的比較沒有標明不可比（清單 C4）**
- 第 2 節：`02-ioctl-cost.tex:24`（改善欄「第 3 節用中斷把它們降到 14.0 µs 與 10.7 µs」）、`:62`（「這個差從 35.8 µs 降到
  14.0 µs，降下來的部分才確定是輪詢造成的」）、`:71`（面試回答）、`B-interview.tex:11`；PDF p.12–14、p.57。35.8／454.6 µs
  是開機組 D（v1.0.0 的 bitstream 與 kernel、沒有 SMMU，`D2_bench.log:9–10`），14.0／10.7 µs 是開機組 E（新 bitstream、
  v1.1 kernel、SMMU 開，`E3_bench.log:9–10`）。同一次開機、同一個程式的輪詢數字是 `E3_bench.log:22–23` 的 39.3／465.8 µs，
  第 3 節用的就是它。改法：要說「降了多少」就引用 E3 的 39.3→14.0、465.8→10.7；保留 35.8 時標明「開機組 D，與第 3 節不是
  同一次開機、同一顆 bitstream，不可直接相減」。
- 第 3 節：`03-irq.tex:31`「吞吐量不變差：232.58 fps」、`:142`「fps 不變」；PDF p.16、p.23。開機組 E 沒有在同一次開機用
  `use_irq=0` 跑 pipeline；唯一的輪詢 pipeline 數字是開機組 D 的 231.53（`D1_ab_measure.log:31`），不同 bitstream、不同
  kernel。改法：寫明「沒有同一次開機的輪詢對照，與開機組 D 的 231.53 fps 不可比」，或在開機組 E 補跑 `use_irq=0` 的 pipeline。
- 第 7 節：`07-devmem.tex:6`、`:30`、`:50`、`:77`、`:82`、`B-interview.tex:31`；PDF p.37–40、p.58。MemTotal 1,773,764 kB
  （開機組 D，v1.0.0 的 kernel）對 2,035,396 kB（開機組 E，Image `0110440877a3738d`，多了 `ARM_SMMU`、`STRICT_DEVMEM` 等）是
  兩顆不同的 kernel；kernel 映像本身不算在 MemTotal 裡，所以 261,632 kB 的差也混著映像大小的變化，「少掉的 512 kB」不能只歸給
  線性對映的頁表（推算本身見上方已查證項）。改法：寫明「不同開機組、不同 kernel 設定」，512 kB 那段補一句「兩顆 kernel 映像
  大小的差也算在裡面，沒有拆開」。

**R4（必改）數字錯，或沒有出處**
- `02-ioctl-cost.tex:66`（PDF p.14）「『等待』這一項在不同次執行之間會差 10 µs 左右（例如 D2_bench.log 第 9 行與第 18 行）」：
  第 9 行 35.8、第 18 行 29.2，差 6.6 µs；而且兩行不是同一個程式的兩次執行，第 18 行是 `map_device=1` 重新載入後的另一種
  設定（第 12 行）。紀錄裡沒有同一設定重複執行的「等待」數字。改法：刪掉這個例子，或改成「不同設定之間差約 7 µs（第 9 行
  對第 18 行）；同一設定的重複性沒有量」。
- `02-ioctl-cost.tex:71`、`B-interview.tex:11`「多等 30 到 45 µs」：紀錄裡的值是 29.2（D2:18）、35.8（D2:9）、39.3
  （E3:22）、40.0（G3:22），沒有 45。改法：「約 30 到 40 µs」。
- `08-smmu.tex:92`（PDF p.45）「CmaFree 比開機組 G 多了剛好 8 MB（261,632 對 253,376 kB）」：差是 8,256 kB，比 8 MB 多
  64 kB（`E1_boot_state.log:19`、`G1_boot_state.log:18`）。改法：「多了 8,256 kB，其中 8 MB 是 driver 的 buffer；另外 64 kB
  沒有查（可能是 SMMU 打開後也改走 IOMMU 的 PS 裝置，推論）」。
- `04-timing.tex:70`（PDF p.26）「出貨版有 1 顆落在範圍外」：公開 repo 裡沒有出貨版建置的 `PBLOCK VERDICT`，只有
  `S4_build_timing.log:14` 的 5 顆與 `first_bitstream/S4_build_timing.log:11` 的 6 顆。改法：把出貨版那一行紀錄放進
  `results/raw/`（或寫進 `board_results.json` 的 timing 條目）再引用，找不到就刪掉；順便補上第一版是 6 顆。
- 較輕：`02-ioctl-cost.tex:50`「991,000 cycles ÷ 240 MHz」：4129.0 µs × 240 = 990,960，寫「約 991,000」。

**R5（必改）stream ID 的說明與量測、與印出來的程式矛盾**
- `08-smmu.tex:100`（PDF p.45）「PL 埠的 master ID 是 `1010`」：同一節 `:59` 與 `F0_smmu_find_stream_ids.log:18–20` 量到的
  是四個不同的 master ID：HP0 1010、HP1 1011、HP2 1100、HP3 1101（`smmu_dtb.sh:11–12` 也這樣寫）。照第 100 行去推 HP1–HP3，
  就會再犯一次第 59 行說的錯。改法：「HP0 的 master ID 是 1010，HP1–HP3 依序是 1011、1100、1101」。
- `08-smmu.tex:37`（PDF p.42）「在加速器節點寫入三個 stream ID」：下面印出的是現在的 `smmu_dtb.sh`，第 24 行寫入四個
  （e80、12c0、1300、1740），第 9–16 行的註解也是量到之後的值；第一次用的版本（0xe80、0x1280、0x1680，dtb
  `4889daa18dd6a320`）沒有印出來。改法：改成「第一次用的版本寫入推算的三個 ID（0xe80、0x1280、0x1680）；下面是量到 ID 之後
  的版本」，或用 `git:` 前綴抽出當時的版本。

**R6（必改）沒有保存紀錄的板上觀察寫成了事實（清單 C2）**
- `08-smmu.tex:45`（PDF p.42–43）「再用 `arm_smmu.disable_bypass=1` 開機……結果一樣：fixture 全錯，kernel log 裡一條 SMMU 錯誤
  都沒有」：`first_bitstream/README.md:14–15` 寫明這次開機「not kept as a log」，而且只說沒有 fault，沒有提到 fixture。這是
  「兩個現象合起來」那個推論的一半。
- `08-smmu.tex:55`（PDF p.43）「改成 Non-secure 交易之後，HP0 的交易開始被轉換，但另外三個埠仍然失敗」：沒有任何紀錄是
  「Non-secure bitstream＋推算的 ID、bypass 開著」的 fixture 結果；F0 只有 `disable_bypass=1` 下的 fault。HP0 被轉換的證據是
  `F0:21–22` 的 `cbfrsynra=0xe80`。
- 改法：第 45 行加「（這次開機沒有保存紀錄）」，並只寫 README 記下的事（沒有任何 fault）；第 55 行引用 F0 第 22 行作為 HP0
  的證據，「另外三個埠仍然失敗」改成「另外三個埠的 stream ID 沒有登記（F0 的 global fault）」。

**R7（必改）SMMU 的保護範圍說過頭：發佈映像的 bypass 是開著的（清單 D3）**
- 位置：`08-smmu.tex:6`（「PL 只能存取映射過的那 8 MB」）、`:104`（「它保證 PL 只能存取 driver 為它映射的頁，PL 的 RTL
  錯誤或惡意的描述子都碰不到 kernel 和其他 process 的記憶體」）、`:109`（面試回答）、`B-interview.tex:35`（第 8 題）、`:17`；
  PDF p.41、p.45–46、p.58。
- 查證：
  - 發佈的 kernel 沒有開 `CONFIG_ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT`（`.config:5732`），開機組 E 的命令列也沒有
    `arm_smmu.disable_bypass=1`（`E1_boot_state.log:3`），所以 `disable_bypass` 是 0（`arm-smmu.c:60–61`），沒有登記的 stream
    ID 一律 bypass（`arm-smmu.c:67`、`:1628–1631`）。專案自己的註解也這樣寫（`twn-v11.cfg:8–10`、`smmu_dtb.sh:15–16`）。
    stream ID 的低 6 位是 AXI ID（本節 `:18`），PL 只要送出非 0 的 AXI ID（RTL 錯誤、或另一顆 bitstream），交易就以實體位址
    直通整個 DDR。
  - Secure 交易（AxPROT[1]=0）完全不經過 Linux 設定的轉換，這正是本節第一次失敗的情形（`:47`）。第 104 行說擋得住的
    「RTL 錯誤」，恰好包含本節實際遇到、而 SMMU 擋不住的那一種。
  - `:17`「替 PS 外的匯流排主控端（這裡是 PL 的 HP 埠）」：ZynqMP 的 SMMU 也在 PS 的 DMA 主控端前面；`system-user.dtsi:15–16`
    寫明打開 SMMU 會把 Ethernet、SD、USB、DMA、DisplayPort 都放到它後面。這個副作用講義沒有提，也只有 ssh（Ethernet）間接用過。
- 改法：第 104 行改成「只對帶著登記過的 stream ID 的 Non-secure 交易有效。這個 kernel 的 bypass 是開著的：AXI ID 不是 0、或
  AxPROT[1]=0 的交易不經轉換、直接碰到實體記憶體；要堵住得在命令列加 `arm_smmu.disable_bypass=1`（或開
  `ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT`），發佈映像沒有這樣做（寫出原因）」。一句話、面試回答、附錄 B 第 8 題同步加這個前提；
  `:17` 改成「替 CPU 以外的匯流排主控端（PS 的 DMA 周邊與 PL 的 HP 埠）」，並補一句 PS 周邊也被放到 SMMU 後面、沒有另外測。

**R8（必改）/dev/mem 的限制範圍說過頭（清單 D3）**
- 位置：`00-intro.tex:23`（導讀表「關掉 /dev/mem」）、`07-devmem.tex:2`（節標題「拿掉 /dev/mem」）、`:6`（「/dev/mem 再也
  不能映射 DDR」）、`:31`、`:32`（「加速器的暫存器與 DMA buffer 只有 driver 能碰；……到這一步才在整個系統上成立」）、`:82`
  （「擋掉所有 RAM」）、`B-interview.tex:31`（「擋 RAM」）；PDF p.4、p.37–38、p.40、p.58。
- 查證：`devmem_is_allowed()`（`lib/devmem_is_allowed.c:20–27`）只擋 `page_is_ram()` 為真的頁（System RAM）與 busy 的 I/O
  區間。發佈 `system.dtb` 的 `/memory@0` 是 `reg = <0x0 0x0 0x0 0x7ff00000>`：DDR 最上面 1 MB（0x7ff0_0000–0x7fff_ffff，
  PetaLinux 留給 ATF 的區域）不是 System RAM、也沒有人佔用，`STRICT_DEVMEM` 不會擋（由原始碼與 dtb 推得，未在板上測）。
  另外，root 只要 `rmmod twn_fuse`，0xA000_0000 的 64 KB 就不再 busy，`/dev/mem` 又能映射暫存器。`/dev/mem` 本身也還在，
  只是受限；本節 `:72` 自己也寫了「沒有被任何 driver 佔用的 I/O 區間仍然可以用 /dev/mem 存取」。
- 改法：標題與導讀改成「限制 /dev/mem」；`:6` 改成「不能再映射 kernel 管理的 RAM（System RAM），也不能映射 driver 正在佔用的
  暫存器」；`:32` 加上「在 driver 載入期間」，刪掉「整個系統上成立」或補「root 卸載 driver 後就失效」；`:82` 與附錄 B 改成
  「擋掉 System RAM」。可在板上補一個 `devmem 0x7ff00000` 的測試，看它是否另外被硬體（XMPU）擋下。

**R9（必改）首次登入改密碼的效果說過頭；「空密碼被拒絕」沒有證據（清單 B3、D3）**
- 位置：`10-release.tex:26`（「預設密碼不會被留著用」）、`:44`（「ssh 直接帶指令執行……不會被攔下（但仍然要密碼才能登入）」）、
  `:58`（「安全性來自『第一次用的人一定會改掉』」）、`:67`（面試回答「空密碼被拒絕」）、`B-interview.tex:43`；PDF p.52–53、
  p.55、p.58。
- 查證：
  - 發佈 rootfs 的 `etc/ssh/sshd_config` 是 `PermitRootLogin yes`、`PasswordAuthentication yes`。`twn-firstlogin.sh:6` 只在
    `[ -t 0 ]` 的登入 shell 生效；`ssh root@板子 指令`、`scp`／`sftp` 都不經過它，`ssh root@板子 sh -i` 這種非登入 shell 也不讀
    `/etc/profile.d`（推論，未在板上測）。所以「仍然要密碼」要的就是公開的 `twn-v1.1`：同一個網路上的任何人都能用它取得
    root，直到有人互動登入改掉；每次重開機又恢復。
  - 這次的紀錄本身就顯示了這一點：E1–E6 在 19:16 UTC 執行，早於這次開機的第一次互動登入（E7，19:28 UTC；
    `/run/twn-pw-changed` 在那時才建立，`E7_first_login.log:17–18`）；附錄 C 第 5 步（`C-reproduce.tex:43–44`）也是
    `export BOARD_PW=twn-v1.1` 之後經 ssh 操作。
  - `E7_first_login.log:11` 唯一的拒絕訊息是「Sorry, passwords do not match.」；第 2 行寫明那次是「空的新密碼＋不同的確認
    密碼」，被拒的原因是兩次不一致（PAM 先比對兩次輸入），不能證明空密碼本身會被拒絕。`10-release.tex:46` 的描述是對的，
    `:67` 的結論不對。
- 改法：`:26` 改成「互動登入一定要先改密碼；但用 ssh 直接執行指令、scp 不受影響，每次重開機也會回到預設密碼」；`:44` 的括號
  改成「但用的就是公開的預設密碼」；`:58` 補上這個限制；`:67` 與附錄 B 第 10 題改成「兩次輸入不一致被拒絕」。若要真的強制，
  可在建置時把 root 密碼設成已過期（`passwd -e root` 或 `chage -d 0 root`，`UsePAM yes` 的 sshd 會要求先改），或關掉 root
  的密碼 ssh；做或不做都在講義寫明。

**R10（必改）W=1 與 checkpatch「都沒有任何警告」沒有紀錄，重跑的結果也不同（清單 B3、C3）**
- 位置：`09-binding.tex:70`、`:83`（面試回答）；PDF p.50–51。
- 查證：`results/` 與整個 repo 找不到 `make W=1` 或 `checkpatch` 的輸出。審稿人用 6.1.30 的
  `scripts/checkpatch.pl --no-tree --strict -f` 重跑：`twn_fuse.c` 是 0 errors／0 warnings／0 checks，但 `twn_fuse_ioctl.h`
  有 1 個 WARNING（第 3 行，檔案裡寫了自己的檔名）與 1 個 CHECK（第 16 行 101 欄）。
- 改法：把 `make W=1` 與 `checkpatch.pl --strict -f twn_fuse.c twn_fuse_ioctl.h` 的輸出存進
  `results/raw/linux_driver_v11_20261027/`（例如 `S6_static_checks.log`）再引用；header 的兩項修掉，或寫明「只對
  `twn_fuse.c`」。

**R11（必改）三張速查表的「做什麼」欄被擠成一兩個字寬（清單 F2）**
- 位置：第 6.4 節（`06-autoload.tex:80–94`，PDF p.36）、第 7.4 節（`07-devmem.tex:85–99`，p.40：「kernel 選項片段」拆成三行，
  「開了 IO 選項後，busy 的區間也算獨佔」拆成九行）、第 10.4 節（`10-release.tex:70–84`，p.55）。
- 原因：「位置」欄是不換行的 `l`，放了 `linux/project-spec/meta-user/recipes-kernel/linux/linux-xlnx/` 這種長路徑，`X` 欄只剩
  幾 mm。
- 改法：「位置」欄改成可換行的 `X`（`\code{}` 已允許在 `/` 後換行），「做什麼」欄用固定寬度（例如 `p{45mm}`）；或把長路徑
  縮成 `recipes-kernel/linux/linux-xlnx/`，在表下註明共同前綴。

**R12（必改）英文名詞與代號沒有解釋，也沒有收進附錄 A；附錄 A 的節號有錯（清單 A3、A4、E2）**
- 第一冊的附錄 A 也沒有下列名詞。沒有中文解釋或沒有收錄的（括號是第一次出現處）：XSA（`03-irq.tex:22`）、threaded IRQ
  （`03:135`）、interrupt context（`03:135`，有一句但沒收錄）、placement／route（`04-timing.tex:6`）、netlist（`04:19`）、
  implementation strategy／directive（`04:17–18`）、LUT／CLB／block RAM tile／DSP（`04:12`、表格）、Design State（`04:68`）、
  TNS（`04:72`）、retiming（`04:82`，有一句但沒收錄）、vermagic（`06-autoload.tex:12`；附錄 B 第 6 題也用）、out-of-tree
  module（`06:17`）、systemd／`systemd-modules-load`（`06:19`）、SPDX（`06:40`）、depmod／`modules.alias`（`06:72`）、IOMMU
  group／domain（`08-smmu.tex:19`）、TLB（`08:94`，有一句但沒收錄）、vendor prefix、mainline（`09-binding.tex:62`）、MPII
  （`10-release.tex:6`）、write buffer（`01-ab.tex:93`）、rootfs（`00-intro.tex:47`）、U-Boot／bootargs／`mkimage`／`boot.scr`
  （`C-reproduce.tex:57, 75`）。AxPROT 在第 4 節（`04:56, 72, 76`）先出現、第 8 節才解釋，第 4 節要加一句或「見第 8 節」。
- 附錄 A：ECO 的節號寫 8（`A-glossary.tex:22`），實際在第 4 節；「IP-XACT 介面」（`:30`）在正文沒有出現（正文寫「Vivado 的
  interrupt 介面」），兩邊統一。
- 改法：第一次出現處各補一句中文，全部收進附錄 A。

**R13（必改）「順序反過來，就可能有一個沒有人處理的中斷」與 kernel 原始碼不符（清單 D1）**
- 位置：`03-irq.tex:137`（PDF p.23）。
- 查證：這條中斷沒有共用（`devm_request_irq(dev, td->irq, twn_isr, 0, …)`，`twn_fuse.c:624`）。`request_irq` 之前，這條線在
  GIC 端還沒啟動（`irq_startup()` 在 `__setup_irq()` 裡才呼叫，`kernel/irq/manage.c:1769`）；最後一個 handler 釋放時
  `__free_irq()` 會把線關掉（`manage.c:1904–1908` 的 `irq_shutdown()`）。所以 probe 或 remove 的順序反過來，都不會有一個送到
  CPU 卻沒有 handler 的中斷。這個順序在這裡是好習慣，真正會出事的是：(1) 共用中斷線：別的 handler 讓線保持啟動，沒人清的
  level 中斷會被判成「nobody cared」而關掉整條線；(2) handler 用到的資料要先初始化——`init_completion()`（`:617–618`）在
  `devm_request_irq()`（`:624`）之前，這點 driver 做對了，值得寫出來。
- 附帶（driver 的缺陷，可一併處理）：`twn_probe()` 在 `:627` 打開致能後，若 `misc_register()` 失敗（`:635–637`）直接回傳，
  致能留在 1；`platform_get_irq_optional()` 回 `-EPROBE_DEFER` 時，`:622–623` 會把它當成「沒有中斷」而退回輪詢，不會延後 probe。
- 改法：把理由改成上面兩點；限制清單補上這兩個失敗路徑（或修 driver：失敗時寫 `R_IRQ` 0，`-EPROBE_DEFER` 直接回傳）。

**R14（建議）沒有量的推論要標「未量測」**
- `03-irq.tex:121`「剩下的大部分是 PL 自己在 block 之間的空檔」：沒有量。block 之間的空檔沒有計數器（`twn_blockseq.v` 只在
  `S_RUN`／`S_DRAIN` 數 `cyc_total`，`:234, 301`），14 µs 裡還有中斷延遲、喚醒排程、讀六個 cycle 暫存器。改成「推測其中一部分
  是…，沒有拆開量」。
- `02-ioctl-cost.tex:64`、`03-irq.tex:15`「一幀要醒來上百次」：`usleep_range(13, 50)` 的 hrtimer 以上限 50 µs 為硬到期時間，
  閒置時多半在 50 µs 才醒，4.13 ms 約 80 次。改成「約 80 次（估計，未量測）」。
- `02-ioctl-cost.tex:16, 24`、`03-irq.tex:29`：`getrusage` 量的是這個 process 的 CPU 時間；`.config:108–110` 是
  `TICK_CPU_ACCOUNTING`、沒有 `IRQ_TIME_ACCOUNTING`，CPU 閒置時進來的 ISR 與 hrtimer 中斷算在 idle，不算在這個 process，所以
  10.7 µs 不含 ISR 本身的成本。建議加一句。

**R15（建議）第 4 節的重現性證據與用詞**
- `04-timing.tex:78`「出貨版在 2026-10-11 從乾淨的 clone 重建，第一次 route 一樣是 −0.030 ns（`rebuilt_from_clone_20261011`）」：
  「一樣」的另一邊是 `opt1_archived_20261008`（bitstream `982dcc716319bc75`，第一次 route −0.030 ns、LUT 44,057），要一起引用；
  兩次的 bitstream 雜湊不同，「同樣的結果」指的是 WNS 與資源數。
- `04-timing.tex:72`、`:87`、`B-interview.tex:19`「這表示可以重現第一版那個 +0.037 ns 的設計」：S5 在 placement 中途就停了
  （`S5_rebuild_determinism.log:9`），只證明到合成報告與 placement 後第一個估計值相同。改成「到 placement 為止結果相同，推測
  可以重現（沒有跑完驗證）」。
- `04-timing.tex:76`、`:87`、`B-interview.tex:19`「AxPROT 從 0 改成 1」：AxPROT 是 3 bits，3'b001 是 privileged 而不是
  Non-secure；寫「AxPROT[1] 從 0 改成 1（3'b000 → 3'b010）」。

**R16（建議）第 8 節的其他問題**
- `08-smmu.tex:20`「driver 的程式完全不用改」、`:30`「driver 一行都不用改」：`twn_mmap()` 為了 IOMMU 加了
  `device_iommu_mapped()` 檢查（`twn_fuse.c:358–359`，本節速查 `:123` 也列了）。改成「資料路徑不用改；只有量測用的
  `map_device` 路徑加了一個檢查」。
- buffer 從哪裡配，說法不一：`07-devmem.tex:21`「driver 的 buffer 由 DMA API 從 CMA 配」、第 6 節印出的
  `system-user.dtsi:9–10`（「The driver allocates its own 8 MB from CMA」），對 `07-devmem.tex:50`、`08-smmu.tex:92`（SMMU 打開
  時不從 CMA）。發佈映像是 SMMU 開的，前兩處要加「沒有 SMMU 時」；dtsi 的註解建議一併改。
- `08-smmu.tex:57–59`：F0 的 `uniq -c` 是 6／1／3，加起來正好 10，等於 `DEFAULT_RATELIMIT_BURST`（`ratelimit_types.h:9–10`；
  `arm_smmu_global_fault()` 用 `__ratelimit`，5 秒內只印 10 次）。次數不是出現頻率，某個 ID 也可能被限流吃掉（F1 的「0 次
  global fault」把這個漏洞補上了）。建議加一句，免得讀者拿 `uniq -c` 的數字做推論。
- 速查 `:121` 的 `twn_axi_rd.v:50` 是 `arcache`，`arprot` 在第 53 行；`:123` 的 `twn_fuse.c:345` 是函式開頭，檢查在第 358 行。

**R17（建議）幾個機制的用詞不精確**
- `06-autoload.tex:21`「device tree overlay（`system-user.dtsi` 裡的 `&fuse_0 {...}`）」：這是建置時用標籤參照覆寫節點，不是
  執行期的 device tree overlay（`.dtbo`，PetaLinux 也有這個東西）。改成「在 dtsi 用 `&fuse_0` 參照標籤，編譯時覆寫節點屬性」。
- `06-autoload.tex:65`「udev 用它呼叫 `modprobe`」：systemd-udevd 用內建的 kmod（libkmod，規則是 `RUN{builtin}+="kmod load"`），
  不是執行 `modprobe`；結果相同，可寫「udev 用 libkmod 載入（效果等同 `modprobe`）」。
- `09-binding.tex:74`「在編譯階段就抓出這類錯誤」、`:78`「這兩種錯誤 binding 都能在編譯時擋下」：`dtc` 編譯時不看 binding，
  要另外跑 `make dtbs_check`（或本專案的 `binding_check.py`）。改成「開機前用 `dtbs_check` 就能抓到」。
- `07-devmem.tex:44`「只留下改 compatible 的那一段」：`system-user.dtsi` 還有 `&smmu`（第 24–26 行）與兩個 `&sdhci`（第 31–36 行）。

**R18（建議）E7 與合成 fixture 的描述**
- `10-release.tex:46`、`C-reproduce.tex:53`「在第一個密碼提示按 Ctrl-C」：第一個密碼提示是登入的 `Password:`
  （`E7_first_login.log:4`）；依第 2 行，Ctrl-C 是在第一個 `New password:` 按的。改成「在第一個 `New password:` 提示按 Ctrl-C」。
- `10-release.tex:54`「會先用同一個參考模型重算它」：`make_synthetic_fixtures.py:70–78` 只重算 MPII 的 fixture 0。改成「重算
  第 0 張 MPII fixture」。

**R19（建議）第 5 節一句話「app 一呼叫就失敗」不精確**
- `05-debugfs.tex:6`（PDF p.28）：driver v1.0 的 `fuse_set_nblk()` 回傳 −1，但 `fuse_read_pix_nz()`、`fuse_read_arr_cap()` 回傳
  0、不報錯（`v10_hal_stubs` 第 96–97 行）。原本框 `:12` 的「只能回傳失敗或 0」是對的，一句話改成一致的說法；靜默回傳 0 其實
  更容易誤導，值得點出。

**R20（建議）速查表的行號缺漏或指到註解（清單 F1）**
- 沒有行號：第 1 節的 `v11_check.sh split`（`test/v11_check.sh:71`）、第 2 節的 `r.ns`（`twn_fuse.c:242`）、第 4 節的 `FUSE_TAG`
  （`build.cmd:24`）、第 6 節的 `twn-fuse.bb` 與 `system-user.dtsi`、第 8 節的 `smmu_dtb.sh`、第 10 節的 `twn-firstlogin.sh` 與
  `make_kit.sh`。
- 指到註解行：第 6 節 `IMAGE_INSTALL` 寫 `petalinuxbsp.conf:6`（第 7 行才是）、複製原始碼 `build_linux.sh:103`（`for` 在第 104
  行）；第 10 節預設密碼 `build_linux.sh:133`（`BOARD_PW=twn-v1.1` 在第 138 行）；第 3 節 `irq` 暫存器 `twn_csr.v:329`（指派在
  第 335 行）。可在 `snippets.txt` 為這幾項另設 `at:` 標籤給 `\lineof`。

**R21（建議）版面**
- 標題與黑框分在兩頁：p.21→22（`03-irq.tex:113`「板上：開機組 E。」）、p.30→31（`05-debugfs.tex:58`）、p.49→50
  （`09-binding.tex:48`）、p.53→54（`10-release.tex:46`）。可用 `\needspace`，或把引言放進同一個 minipage。
- 程式框只剩一行跨到下一頁：p.8 頂端 `ab_measure.sh` 第 37 行 `done`、p.30 頂端 `twn_nblk_set` 第 518 行 `}`。
- `csr_irq_doc`（p.16）多抽了第 39–41 行（分隔線、`` `timescale ``、`` `default_nettype ``），改用 `at4:`。

**R22（建議）「原本怎麼做」沒有指出問題在哪一行（清單 B1）**
- 第 3 節（印了 `v10_wait_bit`、`v10_wait_done`，可指「第 202 行的 `wait_bit()` 就是那個輪詢」）、第 5 節（`v10_hal_stubs`
  第 91–97 行）、第 8 節（只有 log，可引 `in_arena()`）；第 2 節的原本框沒有任何程式（可引第一冊 `twn_bb_run()` 量 `r.ns` 的
  那幾行，說明當時有量但沒有拆開）。

**R23（建議）「一句話」框多半不只一句（清單 A1）**
- 第 1、2、4、5、8、9 節是三句。各留一句結論，其餘移到正文。

**R24（建議）黑框的日期、雜湊，與「# 開頭是指令」的慣例（清單 C2）**
- 多數黑框沒有印出紀錄的第 1 行（日期與開機檔雜湊），只靠導讀的開機組表格對應；README 規則要求註明日期與開機檔的
  SHA-256。可讓 `\boardfile` 的標題自動帶上開機組代號，或每節第一次引用某個檔案時把第 1 行一起印出。
- 導讀 `00-intro.tex:37` 說「行首是 # 加一個空格的那一行是執行的指令」，但 `E7:2`（實際按的鍵）、`S4:2`、`S5:2, 4, 6`
  （說明文字）也是 `# ` 開頭；導讀補一句「S 檔與 E7 的 `# ` 行是說明」。

**R25（建議）附錄 C 有兩步做不出相同的結果**
- 第 4 步（`C-reproduce.tex:33`）：要複製的檔案少了 `bind.sh`（D1 的 `ab_measure.sh` 要用）與 `twn_bench`（D2 要用）；
  `board_hashes_D.txt:2, 5` 都有它們。
- 第 6 步（`:57`）「在開機組 E 的開機檔上，把 `boot.scr` 換成……」：與導讀對開機組 F 的定義不同（`00-intro.tex:47`：BOOT.BIN
  `18a066f87cfbad8d`，第一次建出的 kernel 與 rootfs）；而且開機組 E 的 `system.dtb` 已經登記了量到的四個 ID，照做不會出現 F0
  的 global fault。要重現 F0 得用只登記推算 ID（0xe80、0x1280、0x1680）的 dtb（F0 的 `4889daa18dd6a320`），這一步沒有給
  產生方法。

### 清單逐項結果

| 項目 | 結果 |
|---|---|
| A1 一句話 | 部分通過（R23） |
| A2 先講結論 | 通過 |
| A3 英文名詞有解釋且收進附錄 A | 不通過（R12） |
| A4 沒有未解釋的代號 | 部分通過（開機組 D–G、S 檔、`v11irq`／`v11` 都就地定義；XSA、vermagic 等見 R12） |
| A5 8 小時、≤ 75 頁 | 通過（61 頁；導讀估 5–6 小時） |
| B1 原本引用程式並指出問題行 | 部分通過（R22） |
| B2 列出 kernel API、Yocto 變數、Vivado 命令、RTL 結構 | 通過 |
| B3 改善可驗證，沒量的標未量測 | 不通過（R6、R9、R10、R14） |
| C1 程式碼由 `\snip{}` 抽出、行號一致 | 通過 |
| C2 板上輸出是實際紀錄、有日期與雜湊 | 部分通過（R6；R24） |
| C3 數字找得到出處、`numbers.tex` 行號正確 | 不通過（R2、R4；`numbers.tex` 本身全部正確） |
| C4 比較時寫明是不是同一把尺 | 不通過（R1、R3） |
| D1 kernel 行為與 6.1 一致 | 不通過（R13；其餘引用皆查證正確） |
| D2 RTL 與 ISR 對得上 | 通過 |
| D3 不誇大、限制寫清楚 | 不通過（R7、R8、R9） |
| D4 timing 數字與比較基準 | 通過（R15 為引用與措辭的建議） |
| E1 面試題有答案、30 秒版在附錄 B | 通過，但附錄 B 第 1、2、7、8、10 題帶著 R1、R4、R8／R3、R7、R9 的錯 |
| E2 回答中的名詞前文解釋過 | 部分通過（vermagic 等，R12） |
| F1 速查有關鍵函式與行號 | 部分通過（R16、R20） |
| F2 排版、沒有殘留「待寫」 | 不通過（R11；另見 R21）；沒有 Overfull、紅字或「待寫」 |
| G1 台灣用語 | 通過 |
| G2 沒有密碼、私人路徑、email | 通過（只有公開的預設密碼） |

### 總評

主體技術內容紮實：`numbers.tex` 的每個數字、第 4 節的全部 timing 與資源數字、絕大多數黑框範圍、所有程式碼行號、RTL 的中斷
設計，以及 completion、debugfs、`devmem_is_allowed`、dma-iommu 的 IOVA 配置、arm-smmu 的 fault 回報都查證正確；十節的八個部分
齊全，61 頁在上限內，用語與隱私都通過。但目前**不能交付**：有 13 項必改。最嚴重的是三個保護範圍說過頭——R7（發佈映像的
SMMU bypass 開著，AXI ID 不是 0 或 Secure 的交易直通 DDR）、R8（`STRICT_DEVMEM` 只擋 System RAM，DDR 頂端 1 MB 與卸載後的暫存器
仍可映射）、R9（公開的預設密碼在非互動 ssh 上一直有效）——讀者照著講會在面試時講錯安全性結論；其次是比較的尺不一致（R1、R3）、
數字或出處錯（R2、R4、R5、R6、R10）、一個與 kernel 原始碼不符的解釋（R13），以及兩項讓讀者卡住的問題（R11 速查表、R12 名詞）。
12 項建議可與必改一起處理。修正後請送第 2 輪複查。
