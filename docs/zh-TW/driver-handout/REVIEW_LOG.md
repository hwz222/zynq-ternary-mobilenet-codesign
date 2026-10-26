# 審稿紀錄

每一輪一個段落：日期、審查的章節、審稿人的發現（嚴重程度：必改／建議）、處理結果。

## 第 1 輪（2026-10-27）

**審查範圍**：整份講義 `build/handout.pdf`（60 頁，2026-10-27 00:06 建置，比所有 `sections/*.tex` 都新）、
`sections/*.tex`、`snippets.txt` 抽出的程式碼。對照：`linux-driver` 分支工作樹的 `twn_fuse.c`、
`twn_fuse_ioctl.h`、`bind.sh`、`patch_dtb.sh`、`test/twn_errtest.c`、`test/board_check.sh`、driver 的
`README.md`；`sw/app` 的 `pl_hal_fuse.c`、`pl_hal_fuse_drv.c`、`pl_hal_fuse_enc.c`、`mbv2_fuse_ps.c`、
`Makefile.cross`（含 `git diff HEAD`）；`rtl/fuse/twn_csr.v`、`twn_blockseq.v`、`twn_fuse_top.v`、
`vivado/build_bd_fuse.tcl`；`results/raw/linux_driver_20261026/` 的全部 10 個紀錄檔；WSL 內 6.1.30 kernel
原始碼與 `$HOME/twn_kbuild/.config`（`make prepare` 產生的 kernel 設定）；PetaLinux 產生的 `pl.dtsi`。依指示沒有碰板子。

**已查證正確、不列為問題的部分**（給作者參考，下次不必重查）：`platform.c:1331` 的比對順序；
`asm/io.h:145` 的 `_PAGE_IOREMAP PROT_DEVICE_nGnRE`；`asm-generic/io.h:273` 的 `writel`，arm64 的
`__io_bw() = dma_wmb() = dmb(oshst)`、`__io_ar` 內含 `dma_rmb()`；`uio_core.c:786` 的 `pgprot_noncached`
（`pgtable.h:560`，Device-nGnRnE）；`pgtable.h:577` 的 `pgprot_dmacoherent`（Normal NC）；`mmu.c:97` 對
no-map 區回 `pgprot_noncached`；`direct.c:555` 與 559–576 的節錄；`dma_direct_alloc` 的
CMA → `arch_dma_prep_coherent` → remap 路徑；`contiguous.c:304`；`iopoll.h:36`、`:155`，
`usleep_range((50>>2)+1, 50)` = (13, 50)；`dd.c:658`／`:545`；`misc.c:138`；`ioctl-number.rst` 中 0xB8–0xBF
未登記；`_IOWR(0xBC, 3, 48 bytes)` = `0xC030BC03`；`.config` 的 `HZ=250`、`PREEMPT_NONE=y`、
`STRICT_DEVMEM` 未設、`ARCH_FORCE_MAX_ORDER=11`（`KMALLOC_MAX_SIZE` = 4 MB）、`ARM_SMMU` 未設、CMA 256 MB；
`twn_csr.v:266` 的 `irq_en`、`build_bd_fuse.tcl:211–213` 的 `irq_zero`、STATUS 位元配置、40-bit 位址（hi 只用
[7:0]）、NBLK reset 17、HP0–HP3（`vivado/build.cmd` 設 `FUSE_HP3_SPLIT=1`）、240 MHz、WNS 0.000 ns；
所有 `\lineof` 速查行號（R14 除外）；fps 平均 228.92／231.45、3.01 s、990,906、`0x5010_0000`、8 MB 都與 log 相符。

### 發現

**R1（必改）錯誤路徑測試是 14 項，不是 15 項，而且其中只有 12 項是「拒絕」**
- 位置：`00-intro.tex:110`（結果總覽「15/15 正確拒絕」）、`10-verify.tex:16`、`:31`、`:59`（「第 2 步的 15 行」）、
  `:114`、`:134`（面試回答）、`:147`（速查）、`B-interview.tex:23`（第 5 題）。PDF p.6、p.53–56、p.59。
- 查證：`test/twn_errtest.c` 第 48–90 行共 14 個 `CALL`（不加 `timeout` 參數時 12 個）；
  `board_check_patched_dtb.log` 與 `board_check_uio_dtb.log` 第 2 步都是 14 行 PASS。其中 `STATUS` 與
  `mmap the whole buffer` 兩項期待成功，不是拒絕。driver 的 `README.md:88` 寫「15/15 refusal checks」，同一個錯。
- 改法：全部改成「14 項（12 項該拒絕、2 項該成功），14/14 符合預期」；導讀表格的「15/15 正確拒絕」改成
  「14/14 符合預期」；第 10 節 log 說明改成「第 2 步的 14 行只留頭尾」。driver README 一併修正。

**R2（必改）第 6 節黑框的兩行 dmesg 沒有出處**
- 位置：`06-wait.tex:62–68`（PDF p.36）最後兩行 `descriptor table refused: error 1 at block 0` 與
  `frame timed out: CTRL 00000000 STATUS 000100c2`。
- 問題：README 寫作規則與清單 C2 都要求板上輸出是實際 log。這兩行在 `results/raw/linux_driver_20261026/` 的
  10 個檔案裡都找不到（在整個 repo grep `100c2`、`table refused`、`timed out: CTRL`，只命中講義本身與編譯產物）。
  依 RTL 解碼（STATUS [0]=0、[1]=1、[10:7]=1、[15:11]=0、[16]=1）數值是合理的，但合理不等於有紀錄。
- 改法：在板上重抓 dmesg、存進 `results/raw/linux_driver_20261026/` 後再引用；抓不到就刪掉這兩行，黑框標題改成只寫
  `twn_errtest`。

**R3（必改）引用了不存在的結果項目**
- 位置：`C-reproduce.tex:53`（PDF p.60）；driver `README.md:90` 也一樣。
- 查證：`results/board_results.json` 裡沒有 `linux_driver_twn_fuse_20261026`（grep `linux_driver` 0 筆；含
  `twn_fuse` 的 3 筆都是 `twn_fuse_top` 的資源表）。讀者照著找會撲空。
- 改法：先把這次的數字（fixture、14 項錯誤測試、3.01 s、5 次重載、10 × 64 MB、兩次 board check 的各三次 fps、
  各檔雜湊）寫進 `board_results.json` 再引用；寫入前，只引用 `results/raw/linux_driver_20261026/`。

**R4（必改）STATUS bit 16「是開發期間留下的」與證據矛盾**
- 位置：`08-sysfs.tex:62`（PDF p.46）。
- 查證：`ovr_sticky` 只有 PL reset 會清（`twn_csr.v:267`、`:289`）；PL reset 來自 `pl_resetn0`
  （`build_bd_fuse.tcl:134`），而且每次開機 FSBL 都會重新設定 PL。`reboot_before_dtb_change.txt` 顯示 15:41
  剛開機（up 0 min），15:42 的 `board_check_patched_dtb.log` 在第 2 步（只跑過第 1 步的 fixture）就讀到
  `STATUS 00010043`。也就是說，這次開機後的正常執行就把 bit 16 設起來了，不是開發期間的殘留。
- 改法：改成「bit 16 是 ring overrun 的黏著旗標（`twn_fuse_top.v:755–770`：某個列緩衝區在滿的時候被寫入，或被讀時
  已經不是要的那一列；只記錄、不停機）。重開機後跑完 fixture 就讀到 1；輸出仍然逐位元正確，原因尚未查明。」
  建議作者另開一項追查；在追查結果出來前，面試時不要說它無害。

**R5（必改）「只透過這三個函式碰暫存器」「只有這一個地方在等硬體」與程式不符**
- 位置：`02-mmio.tex:44`、`:126`（速查「唯一碰暫存器的地方」）；`06-wait.tex:40`、`:146`（速查「唯一的等待點」）。
- 查證：`twn_fuse.c:112` 的 `wait_bit` 把 `td->regs + reg` 直接交給 `readl_poll_timeout`（內部呼叫 `readl`，
  不經過 `rd()`）；`twn_fuse.c:153` 的 `twn_set_table` 另外用 `readl_poll_timeout` 等 `ST_CHECKED`（10 µs 間隔、
  100 ms 逾時）。
- 改法：第 2 節改成「除了兩處 `readl_poll_timeout`，driver 都透過 `rd()`／`wr()`／`wr_addr()` 碰暫存器」；第 6 節
  改成「等硬體的地方有兩個：`wait_bit()`（3 s）與 `twn_set_table()` 等表格檢查（100 ms）」，速查表補一列。

**R6（必改）「user space 完全碰不到暫存器」說過頭，限制沒有寫**
- 位置：`02-mmio.tex:32`；`04-mmap.tex:6`（「app 想碰也碰不到」）、`:101`、`:107–108`（面試回答）；
  `00-intro.tex:83`（圖說）；`B-interview.tex:18–19`（第 4 題）；`05-ioctl.tex:118–124` 的限制清單沒有這一條。
- 查證：第 3 節自己寫了這個 kernel 沒開 `CONFIG_STRICT_DEVMEM`（`.config:7387` 確認），所以
  `drivers/char/mem.c` 的 `range_is_allowed()` 一律放行，任何 root process 仍能 open `/dev/mem`、把
  `0xA000_0000` 映射進來；driver 的 `request_mem_region` 擋不住 `/dev/mem`。板上 `/dev/twn_fuse` 是
  `crw------- root`（`driver_state_demo.txt`），app 也都以 root 執行。`/proc/<pid>/maps` 只證明「這個 app
  沒有映射」，不證明「碰不到」。
- 改法：改成「正常使用路徑上，app 不需要、也不會映射暫存器」；第 4 節原理與第 5 節「保護的範圍」各加一條：
  「`CONFIG_STRICT_DEVMEM` 沒開，root 仍可經 `/dev/mem` 讀寫 CSR 與全部 DDR。driver 防的是 app 的錯誤，不是惡意的
  root；要堵住得開 `STRICT_DEVMEM`（再加 `IO_STRICT_DEVMEM`）並重建 kernel。」面試回答也補一句。

**R7（必改）第 3 節暗示 256 MB 保留區已經收回，實際上沒有**
- 位置：`03-dma.tex:21`（原本「保留了 256 MB，實際只用到 6 MB」）對 `:39`（改善「只配需要的大小」）。
- 查證：改過的 dtb 只差 `compatible` 一行（`dtb_diff.txt`），`system-user.dtsi` 的 256 MB no-map `pl_arena`
  在兩種 dtb 裡都還在，driver 版本沒有讓 kernel 拿回這 256 MB。另外 app 實際用到 `OFF_HD_OUT + 2 ×
  HD_OUT_SLOT_BYTES` = `0x540000`（約 5.3 MB）；6 MB 是 `FUSE_ARENA_NEED` 這個上限。
- 改法：改善欄改成「driver 自己只配 8 MB；dtb 的 256 MB 保留區為了 UIO 回退仍然保留，要收回得另外刪掉
  reserved-memory 節點」；原本欄改成「實際用到約 5.3 MB」。

**R8（必改）「app 收到錯誤碼，不會被強制結束」與講義自己印出的程式矛盾**
- 位置：`06-wait.tex:33`（改善欄）。對照第 9 節抽出的 `pl_hal_fuse_drv.c:102`
  `if (xioctl(TWN_IOC_BB_RUN, &r, "BB_RUN")) exit(1);`（PDF p.50），以及 `mbv2_fuse_ps.c:533` 對 HD_WAIT 也是
  `exit(1)`。
- 問題：driver 確實回 `-ETIMEDOUT`，但 driver 版 HAL 跟 v1.0.0 一樣直接 `exit(1)`，因為 `fuse_run_frame()` 的介面
  沒有錯誤回傳值。第 6 節「原本」批評的「逾時直接 exit(1)」在 driver 版本的 app 裡仍然存在。
- 改法：改成「driver 回 `-ETIMEDOUT`，呼叫端可以自己處理（`twn_errtest` 就是這樣測的）；目前的 HAL 為了不改
  `fuse_run_frame()` 的介面，仍然 `exit(1)`」。第 5 節改善欄的「app 可以自己決定怎麼處理」同樣加註。

**R9（必改）第 9 節前後矛盾：「一行都沒改」對「改動只有兩處」**
- 位置：`09-hal.tex:6`（一句話）、`:27`（改善欄）、面試回答「幾乎沒改」。
- 查證：`git diff HEAD -- sw/app/mbv2_fuse_ps.c`：新增 `FUSE_ARENA_NEED`、`fuse_arena_init` 的參數由
  `FUSE_ARENA_SZ_DEFAULT` 改成 `FUSE_ARENA_NEED`、新增 `_Static_assert`；`Makefile.cross` 與
  `board/build_apps.sh` 也改了。
- 改法：一句話改成「app 的演算法和位址計算都沒改，只改了要求的 buffer 大小，並加一個 `_Static_assert`」。

**R10（必改）第 10 節原理表與同節正文矛盾，而且漏了一項差異**
- 位置：`10-verify.tex:113`（「driver 只改了『誰寫暫存器』」）對 `:122–127`（「同時改了兩件事」）。
- 問題：表格說只改了誰寫暫存器，正文說還改了輪詢方式與 CPU 端記憶體屬性。另外 buffer 的實體位址也換了
  （`0x6000_0000` 的 no-map 區 → `0x5010_0000` 的 CMA），PL 的 DDR 存取落在不同位址，這也是分不開的差異之一。
- 改法：表格改成「資料路徑是同一顆 bitstream；driver 改的是 CPU 端（誰寫暫存器、怎麼輪詢、buffer 的位置與
  記憶體屬性）」；正文改成「至少同時改了三件事」，補上 buffer 位置。

**R11（必改）第 7 節改善欄引用了不存在的板上證據，第三點與同節「踩過的坑」矛盾**
- 位置：`07-lock.tex:26`（「裝置開著或 buffer 還映射著時，rmmod 會被拒絕（下方板上輸出）」）、`:28`（用
  231.5／228.9 fps 佐證兩把鎖讓重疊不受影響），對照 `:84`。
- 查證：`board_check.sh:35–38` 只測了「開著」（`sleep 3 < /dev/twn_fuse`），沒有測「close 之後仍然映射著」。原理
  （VMA 持有 `struct file`）是對的，但不能寫成有板上輸出。`:28` 的 fps 不能證明兩把鎖的作用：同一節的坑已經說明
  一把鎖也會重疊。
- 改法：`:26` 改成「裝置開著時 rmmod 被拒絕（板上已測）；只剩映射時也會被拒絕（由 VMA 持有 `struct file` 推得，
  未在板上測）」，或補一個「mmap 後 close(fd) 再 rmmod」的測試；`:28` 改成「兩把鎖讓兩個 thread 分別驅動兩個引擎時
  互不阻擋（設計上的保證，這個 app 量不出差別）」，刪掉 fps。

**R12（必改）多節的「原本怎麼做」沒有引用 v1.0.0 程式碼，也沒有指出問題在哪一行**
- 位置：第 4 節（`04-mmap.tex:9–18`，只有 maps log）、第 7 節（`07-lock.tex:9–11`）、第 8 節（`08-sysfs.tex:9–11`）、
  第 9 節（`09-hal.tex:9–11`）、第 10 節（`10-verify.tex:9–11`）完全沒有程式碼；第 2、3、5、6 節有程式碼，但沒有一節
  說「問題在第幾行」。
- 依據：README 寫作規則第 2 點、清單 B1。
- 改法：第 4 節引 `pl_hal_fuse.c:148–151`（open `/dev/mem`、映射 256 MB）與 `:130–133`（映射 `/dev/uio4`）；
  第 7 節引 `pl_hal_fuse.c:130` 的 `open(uio, O_RDWR | O_SYNC)`（沒有任何獨占）；第 8 節引 `fuse_read_counters()`；
  第 9 節引 v1.0.0 `Makefile.cross` 的 `COMMON` 行；第 10 節引 `board/deploy.sh:193`（verify）、`:200`（speed）。
  每個框加一句「問題在第 N 行」，例如第 3 節「第 148 行開 `/dev/mem`、第 150 行映射整塊 256 MB」，第 6 節「第 243 行與
  第 271 行的 `exit(1)`」。

**R13（必改）圖 1 左半部文字重疊，而且把 `/dev/mem` 畫成經過 UIO**
- 位置：`00-intro.tex:66–72`（PDF p.5）。
- 問題：兩條箭頭從 app 直穿 kernel 方塊，標籤「mmap /dev/uio4」「mmap /dev/mem」壓在「kernel：uio_pdrv_genirq 只負責
  把位址開出去」上，放大到 150 dpi 仍無法閱讀。另外 `/dev/mem` 是 `drivers/char/mem.c` 提供的，不是
  `uio_pdrv_genirq`；畫成穿過 UIO 方塊會誤導。
- 改法：kernel 層畫成兩個方塊（`uio_pdrv_genirq` → `/dev/uio4`；`mem.c` → `/dev/mem`），標籤放在 app 與 kernel 之間的
  空隙（例如 `pos=0.25`），不要壓在方塊上。

**R14（必改）速查行號指錯：`FUSE_ARENA_NEED`**
- 位置：`03-dma.tex:157`（PDF p.23，「`mbv2_fuse_ps.c`: 39」）。
- 查證：`\lineof{app_arena_map}` 是整段的起始行（第 39 行是 `#define OFF_WEIGHTS`）；`FUSE_ARENA_NEED` 在第 45 行。
- 改法：在 `snippets.txt` 為它另設 `at:#define FUSE_ARENA_NEED` 標籤給 `\lineof` 用。同類但較輕的：`09-hal.tex:102`
  「HAL 變數 `Makefile.cross`:20」指向註解（`HAL ?= uio` 在第 22 行）；`08-sysfs.tex:76`「以第 404 行起的
  `TWN_REG_ATTR(nblk, ...)`」，`nblk` 那行在第 411 行；`08-sysfs.tex:116` 速查名稱寫 `device_add_groups`，但
  `dd.c:658` 是 `really_probe()` 裡的呼叫處（函式本身在 `drivers/base/core.c`），名稱欄應寫「`really_probe()` 呼叫
  `device_add_groups`」。

**R15（必改）`mutex_lock_interruptible` 回傳的是 `-EINTR`，不是 `-ERESTARTSYS`**
- 位置：`07-lock.tex:15`、`:91`。
- 查證：`kernel/locking/mutex.c:667–668` `if (signal_pending_state(state, current)) { ret = -EINTR; ...}`，
  `:974`、`:998` 的註解也寫 `-EINTR`。是 `twn_fuse.c:352–353` 自己把它換成 `-ERESTARTSYS`。
- 改法：改成「被訊號打斷時回 `-EINTR`；driver 改回 `-ERESTARTSYS`，讓 kernel 依訊號的 `SA_RESTART` 設定決定要不要
  自動重做這個系統呼叫」。

**R16（必改）「被 swap 出去」不是要用 `copy_from_user` 的理由，在這顆 kernel 上說法不對**
- 位置：`05-ioctl.tex:111`、`:129`（面試回答）；`B-interview.tex:23`（第 5 題）。
- 查證：`arch/arm64/mm/fault.c:576–583`：只有「EL1 對 user 位址的 permission fault」而且不在 exception table 時才
  `die`。被 swap 出去的頁是 translation fault，會走正常的 `handle_mm_fault` 換回來，直接解指標也不會當掉（沒有 PAN 時
  更是如此）。exception table 只在 fault 無法處理（位址根本沒有映射）時才用到。現在的寫法讓讀者以為 swap 的 fault 是
  被 exception table 接住的。
- 改法：理由改成三條：(1) 位址可能沒有映射：直接解指標會 oops，`copy_from_user` 遇到時由 exception table 修復並回
  `-EFAULT`；(2) 位址可能指向 kernel：`access_ok` 擋掉；(3) 有 PAN 的 CPU 上直接存取會被硬體擋，A53 沒有，不能靠硬體。
  刪掉「swap」，或改成「頁不在記憶體時，fault handler 會把它換回來，這不是問題」。

**R17（必改）`cycles_total` 不是「START 到 done 的時間」**
- 位置：`08-sysfs.tex:59`（PDF p.46）。
- 查證：`cyc_total` 由 `twn_blockseq.v` 計數，只在每個 block 的 `S_RUN`（`:233–234`）與 `S_DRAIN`（`:300–301`）
  加一，block 之間的 `S_IDLE` 不算；frame 開始時清零（`:311`，`twn_fuse_top.v:261–262` 的 `cyc_clr = ap_start`）。
  所以 990,906 是 17 個 block 執行期間的 cycle 總和，4.13 ms 是 START→done 的下限。
- 改法：改成「17 個 block 執行中的 cycle 總和（不含 block 之間的空檔），約 4.13 ms；START 到 done 的實際時間看
  `TWN_IOC_BB_RUN` 回傳的 `ns`」。

**R18（必改）英文名詞與內部名稱沒有中文解釋，也沒有收進附錄 A**
- 位置：全篇；`A-glossary.tex`。
- 依據：README 用語規則第 1 點、清單 A3、A4。
- 沒有解釋或沒有收錄的（括號是第一次出現處）：AXI（導讀表格）、beat（第 4、5 節 log 的「one beat past the end」）、
  描述子表（第 5、6 節才出現，從未定義）、operator（`05-ioctl.tex:58`「operator 0」）、op61–64（第 9 節程式的
  `61 + op`）、NBLK（第 1 節 probe 第 2 步先用，第 2 節才解釋）、heatmap（導讀）、TWN 與 fuse（標題與所有檔名）、
  page fault 與 oops（第 2 節）、linear map（第 2 節有一句，未收錄）、uevent／udev（第 1 節）、SoC（第 1 節）、
  outer shareable（第 2 節）、dmb 與 dsb 的差別（第 2 節說 dmb 「較輕」但沒說輕在哪：dsb 等存取完成，dmb 只排順序；
  名詞表只列名稱）、CCI（第 3 節）、cache line 與 dc zva（p.20 第一次出現，p.23 才解釋）、PFN（第 4 節 kernel 節錄）、
  ISR 與 completion（第 6 節表格與面試回答）、GIC SPI（第 6 節表格）、ring overrun（第 8 節）、`FUSE_HEAD_PL`／
  `FUSE_BB2HD`（第 9、10 節 log）。
- 名詞表宣稱「依英文字母排序」，但 `ioremap` 排在 IOMMU 前、MMIO／MMU 排在 `mmap` 前、UIO 排在 uapi 前，都錯。
- 改法：導讀「先認識幾個名字」補 AXI／beat、描述子表、operator、TWN／fuse、heatmap；其餘在第一次出現處補一句中文，
  全部收進附錄 A；名詞表依不分大小寫的字母順序重排。

**R19（建議）PAN 的說法要對上 `.config`**
- 位置：`05-ioctl.tex:113`、面試回答。
- 查證：`.config:414` 是 `CONFIG_ARM64_PAN=y`，`:403` 的 `CONFIG_ARM64_SW_TTBR0_PAN` 未設。A53 沒有 PAN 硬體，
  所以前者在執行時偵測不到、不生效；後者沒開，也沒有軟體模擬。讀者自己 grep `.config` 看到 `PAN=y` 會困惑。
- 改法：補一句「kernel 有編進 PAN 支援，但 A53 沒有這個硬體功能，也沒開軟體模擬（SW_TTBR0_PAN）」。

**R20（建議）non-cacheable 是 kernel 依 device tree 決定的；HPC 方案不只換 port**
- 位置：`03-dma.tex:6`、`:119`、`:144`；`04-mmap.tex:96`；`B-interview.tex:15`。
- 查證：`drivers/of/device.c:201` 的 `of_dma_is_coherent()` → `arch/arm64/mm/dma-mapping.c:75`
  `dev->dma_coherent`；節點沒有 `dma-coherent`，kernel 才把裝置當成 non-coherent。kernel 並不知道 HP port。
- 改法：一句話與面試第 3 題改成「device tree 沒有 `dma-coherent`（因為 HP port 不經過 cache），kernel 就把 buffer
  映射成 non-cacheable」。HPC 那一列補上「PL 的 AXI master 還要送出 cacheable、shareable 的 AxCACHE／AxPROT」。
  `04-mmap.tex:96` 說不同 cache 屬性映射同一塊記憶體會不一致；建議同時說明 kernel 線性對映裡仍有一個 cacheable 別名，
  `arch_dma_prep_coherent` 先把它清乾淨，之後沒有人經由它存取。

**R21（建議）中斷改法表少了一個 RTL 陷阱**
- 位置：`06-wait.tex:115`。
- 查證：`twn_csr.v:358` 每次寫 CTRL 都執行 `irq_en <= w_hold[2]`，driver 寫 START（0x1）和清 done（0x2）都會把
  `irq_en` 清成 0；表中的 `hd_irq_en` 目前不存在。
- 改法：表格註明「driver 每次寫 CTRL 都要帶 bit 2，或把 `irq_en` 改成獨立暫存器」；head 的致能位元要新增（例如用 HD_CTRL
  寫入時目前被忽略的 bit 1）。

**R22（建議）直接解指標 `0xA0000000` 的解釋不精確**
- 位置：`02-mmio.tex:70`、`B-interview.tex:11`。
- 問題：在 arm64 上 `0xA0000000` 落在 user 那一半的位址範圍（TTBR0），kernel 查的是「當下 process 的頁表」，不是
  「kernel 頁表沒有這一項」。如果當下 process 剛好映射了這個位址，存取會靜默落在 user 記憶體上。
- 改法：補一句「這個數字當成虛擬位址屬於 user 位址範圍；周邊的實體位址必須先經 ioremap 取得一個 kernel 虛擬位址」。

**R23（建議）busy-wait 的理由說過頭**
- 位置：`06-wait.tex:97`。A53 有兩顆核心，空轉只占住一顆；「另一個 thread 就沒得跑」只在兩者排在同一顆核心時成立。
  改成「會白白占住一顆核心 4 ms，排在同一顆核心上的 thread 就沒得跑」。

**R24（建議）「只讓一個 process 開」精確說是「同一時間只有一次 `open()` 成功」**
- 位置：`07-lock.tex:6`、`:100`。fork、dup、經 Unix socket 傳遞的 fd 共用同一個 `struct file`，不會再經過
  `twn_open()`。建議加一句，面試被追問時才答得出來。

**R25（建議）ioctl 指令碼的大小檢查說過頭**
- 位置：`05-ioctl.tex:107`。「只要 struct 定義不一致，大小就對不上」不成立：欄位順序或型別改了、大小不變時偵測不到。
  改成「struct 大小改變時，指令碼就不同，driver 回 `ENOTTY`」。

**R26（建議）黑框 log 的轉錄細節（數值沒改，但和原檔不完全一致）**
- `01-dt-probe.tex:86–97`：合併了 `patched_dtb_boot.txt` 與 `patched_dtb_autobind.txt`；`# tr ...`、`# readlink ...`
  等指令列是補寫的；「no driver bound」是腳本在 readlink 失敗時印的訊息，不是 readlink 的輸出；框內的
  「<- insmod 之前…」是註解。
- `01-dt-probe.tex:103–108`：兩行輸出取自 board check 第 1 步，原始順序是先 uio 再 drv，指令列是補寫的。
- `03-dma.tex:72–78`：只貼出 10 次中最後 2 次 64 MB 的 probe 訊息，「每次拿到的都是同一個位址」只有 2 次的證據。
- `02-mmio.tex:59–66`、`03-dma.tex:64–68`：dmesg 拿掉了時間戳記；`driver_state_demo.txt` 的 dmesg 其實有三行。
- `08-sysfs.tex:67–70`：ls 輸出把 `supplier:platform:firmware:zynqmp-firmware:clock-controller` 換成句尾的「...」。
- `10-verify.tex:95–101`：回退 log 省略了 `0` 那一行，但沒有標「...」。
- `10-verify.tex:36` 的 228.92／231.45 fps 取自改過 dtb 那一次（`board_check_patched_dtb.log`），UIO dtb 那次是
  228.95／231.24，表格沒說是哪一次。
- `07-lock.tex:95`「rmmod 回報 `Module twn_fuse is in use`」不在任何 log（`board_check.sh:37` 把 stderr 丟進
  `/dev/null`）；kernel 端 `delete_module` 回的是 `EWOULDBLOCK`，訊息字串要看 rmmod 是 kmod 還是 busybox。
- 多數黑框標題只有日期、沒有 bitstream 雜湊（README 寫作規則最後一點、清單 C2）；導讀有一句總說明，勉強可接受。
- 改法：黑框只放原文，註解移到框外；標題加來源檔名（例如「`patched_dtb_autobind.txt`」）；補寫的指令列加說明；
  第 3 節改成「最後兩次」或貼出 10 行；rmmod 訊息改成「rmmod 失敗」或重抓實際訊息。

**R27（建議）第 10 節「ssh 輪詢會讓 fps 下降」在本 repo 沒有出處**
- 位置：`10-verify.tex:129`。附上出處（哪一份紀錄、降多少），或刪掉後半句。

**R28（建議）改善欄中其他沒有板上證據的宣稱**
- `03-dma.tex:41`「`memset` 可以正常使用」：依架構規格成立（Normal NC 允許 `dc zva`），但 app 仍然用 NEON helper，
  driver 版本沒有驗證過。`08-sysfs.tex:24`「app 剛當掉之後也能 cat」：沒有測。清單 B3 要求對應到第 10 節。
- 改法：標註「依架構規格推得，未在板上測」，或補測。

**R29（建議）driver 沒有取用 PL 時脈，這個限制沒寫**
- 查證：PetaLinux 產生的 `pl.dtsi` 節點有 `clocks = <&zynqmp_clk 71>`、`clock-names = "ap_clk"`；`twn_probe`
  沒有 `devm_clk_get_enabled()`。目前能用，是因為 bootargs 有 `clk_ignore_unused`（`phase0_board.txt` 第 3 行）。
  拿掉這個參數後，kernel 的 `clk_disable_unused` 可能在開機後期關掉沒有人用的 pl0 時脈，之後讀 CSR 會讓 AXI 卡住。
- 改法：第 1 節原理或第 10 節「沒有證明」補一條限制（清單 D2）；面試若被問到時脈管理也答得出來。

**R30（建議）STATUS 欄位說明容易混淆**
- `twn_fuse.c:37`（第 2 節暫存器表）寫「[10:7] error [15:11] block」，第 8 節寫「bits 6:2 是最後一個 block 編號」，
  `twn_fuse_ioctl.h:24` 又寫「[6:2] block」。兩者都對，但是不同欄位（`cur_block` 與 `err_block`，
  `twn_csr.v:469–473`）。建議第 8 節列一張完整的 STATUS 欄位表。

**R31（建議）閱讀時間與篇幅**
- `00-intro.tex:37`「建議每天讀三到四節」與「一天 8 小時讀完」的目標不一致；清單 A5「一節 10 分鐘」與導讀「每節 30–45
  分鐘」互相矛盾，請作者決定以哪一個為準。
- 最占篇幅的是長程式碼：第 1 節 `twn_probe` 56 行加 `fuse_hal_init` 22 行、第 6 節原本 61 行（p.33–34）、第 7 節
  `twn_ioctl` 61 行加 `mbv2_fuse_frame_pl` 41 行（p.40–42）。建議用 `at:` 選擇器只抽關鍵幾行（例如
  `uio_run_frame` 只取 229–255 行），全份大約可省 5–6 頁。

**R32（建議）各節面試回答超過 30 秒**
- 以每秒 4 個中文字、每個英文名詞 0.4 秒估算：第 1–10 節的「面試會問」約 35–60 秒（第 5 節約 56 秒、第 10 節約 60 秒），
  超過導讀表格寫的「30 秒講得完」；附錄 B 的六題約 22–30 秒，符合。
- 改法：各節的框改標「完整版（約 1 分鐘）」，30 秒版本只留在附錄 B；或刪短。

**R33（建議）「一句話」框多數超過一句**
- 第 2、3、5、6、9 節是兩到三句。各留一句結論，其餘移到正文。

**R34（建議）版面小問題**
- p.16 圖中「MMU」標籤擠在兩個方塊之間（`02-mmio.tex:80`，8 mm 間距太窄）。
- `07-lock.tex:63–64` 的時間軸圖寬出 3 pt（`build/handout.log:1187` Overfull \hbox）。
- 黑框 log 跨頁斷開（p.42→43、p.46→47）。
- 目錄標題是英文「Contents」、圖說是「Figure 1」，正文卻寫「圖 1」：在 `handout.tex` 加
  `\renewcommand{\contentsname}{目錄}`、`\renewcommand{\figurename}{圖}`。
- p.22 三欄表格「streaming DMA」那一列的字距被拉開。
- 用詞「映射」與「對映」（`02-mmio.tex:70`）混用，建議統一。

**R35（建議）附錄 C 第 2 步的檔名對不上**
- `board/build_apps.sh` 在 `build/arm` 與 `build/arm-drv` 產生的都是 `mbv2_fuse_test`、`mbv2_fuse_pipe`，沒有 `_uio`／
  `_drv` 字尾；`board_check.sh` 要的是 `mbv2_fuse_test_uio` 等。`C-reproduce.tex` 要寫明複製時改名。

**R36（建議）`writel` 節錄的簡化沒有說明**
- `02-mmio.tex:96–103` 除了刪兩行追蹤，還把 `(u32 __force)__cpu_to_le32(value)` 簡化成 `value`
  （對照 `include/asm-generic/io.h:273–280`）。標題補「並省略位元組順序轉換」。

### 總評

主體技術內容大致正確：引用的 kernel 檔案與行號全部查得到，`.config` 數值、暫存器位址與位元、ioctl 編碼、
CMA 與 DMA 路徑、polling 的時間參數都正確；十節的八個部分順序齊全；60 頁在 75 頁上限內。

但目前**不能交付**：有 18 項必改。最嚴重的是數字與出處問題（R1 的 15 項、R2 找不到出處的 dmesg、R3 不存在的結果項目、
R4 錯誤的 bit 16 解釋），其次是過度宣稱與前後矛盾（R6 `/dev/mem` 仍可存取 CSR、R7 256 MB 沒收回、R8 app 仍會
exit、R9–R11），以及兩個面試時會被追問的 kernel 錯誤（R15 `-EINTR`、R16 swap）。

### 清單逐項結果

| 項目 | 結果 |
|---|---|
| A1 一句話 | 部分通過（R33） |
| A2 先講結論 | 通過 |
| A3 英文名詞有解釋且收進附錄 A | 不通過（R18） |
| A4 沒有未解釋的代號 | 不通過（R18） |
| A5 一節 10 分鐘 | 不通過（R31） |
| B1 原本引用 v1.0.0 程式碼並指出問題行 | 不通過（R12） |
| B2 列出 kernel API | 通過 |
| B3 改善可驗證並對應第 10 節 | 不通過（R8、R11、R28） |
| C1 程式碼由 `\snip{}` 抽出，標題行號一致 | 通過 |
| C2 板上輸出是實際 log | 不通過（R2、R26） |
| C3 文字中的數字找得到出處 | 不通過（R1、R3、R4、R27） |
| D1 kernel 行為與 6.1 一致 | 不通過（R15、R16；其餘引用皆正確） |
| D2 不誇大、限制寫清楚 | 不通過（R6、R7、R10、R29） |
| D3 硬體事實與 RTL、results 一致 | 不通過（R4、R17；位址、位元、時脈、WNS 正確） |
| E1 面試答案在本節、30 秒講得完 | 部分通過（附錄 B 通過；各節版本超時，R32） |
| E2 回答中的名詞前文解釋過 | 不通過（ISR、completion、CCI，R18） |
| F1 速查列出關鍵函式與行號 | 部分通過（R5、R14） |
| F2 排版、無殘留「待寫」 | 不通過（R13、R34）；沒有殘留「待寫」 |
| G1 台灣用語 | 通過（沒有內存／程序／接口／默認／文件等用語） |
| G2 沒有密碼、私人路徑、email | 通過 |

**處理結果**：見下方「第 1 輪處理」，待審稿人複查。

### 第 1 輪處理（2026-10-27，撰稿人）

板上證據全部重跑：定版 driver（`twn_fuse.ko` `8b3649080da3254d`，與第 1 輪審查時的版本相同二進位；之後只改過註解，
module 沒有 srcversion，所以二進位不變）在三次開機（原 dtb → 改過的 dtb → 回退）下重跑，紀錄換成
`results/raw/linux_driver_20261026/` 的 A1–A4、B1–B2、C1，每條指令都以 `# ` 開頭印在紀錄裡。講義的黑框改成
`\boardfile{檔名}{行範圍}` 直接讀紀錄檔原文，框上方標檔名與行號。重複出現的數字集中在 `sections/numbers.tex`。

| 編號 | 處理 |
|---|---|
| R1 | 已改：全部改成「14 項（12 項拒絕、2 項成功）」，用 `\errChecks`／`\errRefusals`；driver README 一併修正 |
| R2 | 已改：`board_check.sh` 在錯誤測試後印 `dmesg` 的兩行，第 6 節直接引用 `A2` 第 23–30 行 |
| R3 | 已改：`board_results.json` 新增 `linux_driver_twn_fuse_20261026`；`results/raw/linux_driver_20261026/README.md` 列出每個檔 |
| R4 | 已改並補證據：`A1` 開機後 STATUS = 0；`C1` 在 driver 從未載入的開機中，只跑 UIO 版本後變成 `0x00010043`。第 8 節改寫為「bitstream 本身的行為，與 driver 無關，原因未查明」，並附 STATUS 欄位表（R30） |
| R5 | 已改：第 2 節改成「除了兩處 `readl_poll_timeout`」；第 6 節列出兩個等待點，速查表補一列 |
| R6 | 已改：導讀圖下、第 2、4、5 節與面試回答都加上 `STRICT_DEVMEM` 沒開、root 仍可經 `/dev/mem` 存取的限制 |
| R7 | 已改：第 3 節寫明 256 MB 保留區仍在；實際用量改為約 5.3 MB（`0x540000`） |
| R8 | 已改：第 5、6、9 節寫明 HAL 收到錯誤仍 `exit(1)`，理由是不改 `fuse_run_frame()` 介面 |
| R9 | 已改：第 9 節一句話與改善欄改成「演算法和位址計算沒改，只改 buffer 大小，加 `_Static_assert`；另改建置檔」 |
| R10 | 已改：第 10 節表格與正文一致，列出三項同時改變（含 buffer 位置） |
| R11 | 已改並補測：`twn_errtest hold`（映射後關 fd）與 `board_check.sh` 第 3 步新增「只剩映射時 rmmod」，兩次開機都被拒絕；fps 不再拿來佐證兩把鎖 |
| R12 | 已改：第 4、7、8、9、10 節補 v1.0.0 程式碼（第 9 節從 commit `2dffd8a` 抽出），每節點出問題所在的行號 |
| R13 | 已改：圖 1 的 kernel 層分成 `uio_pdrv_genirq` 與 `mem.c` 兩塊，標籤移出方塊 |
| R14 | 已改：新增 `app_arena_need`、`app_make_hal_var`、`drv_attr_nblk` 標籤；`dd.c:658` 的名稱改成「`really_probe()` 呼叫 `device_add_groups`」 |
| R15 | 已改：寫明 `mutex_lock_interruptible` 回 `-EINTR`，driver 改回 `-ERESTARTSYS` 的理由 |
| R16 | 已改：刪掉 swap 的理由，改成三條（沒映射、指向 kernel、A53 沒 PAN），並註明 swap 出去的頁由 fault handler 換回 |
| R17 | 已改：`cycles_total` 改成「17 個 block 執行期間的總和，是 START→done 的下限」 |
| R18 | 已改：導讀名詞表補 AXI、beat、描述子表、operator、NBLK、heatmap、TWN／fuse；各名詞在第一次出現處補中文；附錄 A 擴充並依字母重排 |
| R19 | 已改：第 5 節補 `CONFIG_ARM64_PAN=y` 但 A53 偵測不到、`SW_TTBR0_PAN` 未設 |
| R20 | 已改：第 3 節說明 kernel 依 `dma-coherent` 判斷；HPC 列補 AxCACHE／AxPROT；第 3、4 節說明線性映射的 cacheable 別名 |
| R21 | 已改：第 6 節中斷表格補 `twn_csr.v:358` 的陷阱與 `hd_irq_en` 需新增 |
| R22 | 已改：第 2 節與附錄 B 補「這個數字當成虛擬位址屬於 user 那一半」 |
| R23 | 已改：改成「占住一顆核心，排在同一顆核心上的 thread 沒得跑」 |
| R24 | 已改：第 7 節改成「同一時間只有一次 `open()` 成功」，並說明 fork／dup 共用同一個開啟的檔案 |
| R25 | 已改：改成「struct 大小一改，指令碼就不同」，並說明只改欄位順序時偵測不到 |
| R26 | 已改：黑框全部改為直接讀紀錄檔原文；指令列由腳本印出；註解移到框外；`rmmod` 的訊息現在由 `board_check.sh` 記錄 |
| R27 | 已改：刪掉沒有出處的「fps 下降」說法，只保留「量測期間不連線」 |
| R28 | 已改：`memset` 註明「依架構規格推得，未在板上測」；刪掉「app 當掉之後也能 cat」 |
| R29 | 已改：第 1 節原理新增「PL 時脈」限制，說明為何這次不加 `devm_clk_get_enabled()`；driver README 的 Limits 一併寫入 |
| R30 | 已改：第 8 節加 STATUS 完整欄位表 |
| R31 | 部分採納：閱讀時間改成「全部約 6–7 小時，一天讀完」，清單 A5 改為「一天讀完、≤75 頁」。長程式碼沒有刪，因為頁數 65 頁仍在上限內，且讀者要知道完整的函式 |
| R32 | 已改：各節框標題改成「面試會問（完整版，約 1 分鐘）」，30 秒版本只在附錄 B |
| R33 | 已改：各節一句話框改成一句 |
| R34 | 部分採納：MMU 標籤間距、時間軸寬度、`目錄`／`圖`、映射用語已改；黑框跨頁斷開與三欄表格字距未改（不影響閱讀） |
| R35 | 已改：附錄 C 寫明複製時改名為 `_uio`／`_drv` |
| R36 | 已改：`writel` 節錄標題補「省略位元組順序轉換」 |

## 第 2 輪（2026-10-27）

**審查範圍**：重建後的 `build/handout.pdf`（65 頁，00:48:48 建置，比所有 `sections/*.tex` 都新；`handout.log` 沒有
Overfull、沒有未定義的參照）；全部 `sections/*.tex`、`numbers.tex`、`handout.tex` 的 `\boardfile`、`snippets.txt`、
`extract.py`；`results/raw/linux_driver_20261026/` 的 13 個檔案與其 README；`results/board_results.json` 的
`linux_driver_twn_fuse_20261026`；driver 的 `README.md`、`test/twn_errtest.c`、`test/board_check.sh`。每一個
`\boardfile` 的行範圍都逐行對照了原檔，文字裡寫死的行號都對照了 `build/snippets/*.tex`。依指示沒有碰板子。

**證據本身的查核**（照「先證明證據是這一次產生的」的原則）：
- 主機端 6 個產物的 SHA-256 前 16 碼，現在重算仍與 `host_hashes.txt` 相同；三次開機的 `board_hashes_{A,B,C}.txt`
  也一樣。`twn_fuse.ko` 在 00:33 重建，雜湊仍是 `8b3649080da3254d`；`twn_fuse.c` 自第 1 輪後沒有改過（所有 `drv_*`
  片段的起始行號都與第 1 輪相同）。
- 時間線前後一致：A 開機 16:35:41（up 0 min）、A2 標頭 16:35、dmesg 40.79 → 43.82 s；B 開機 16:37:18、
  B2 標頭 16:37；C 開機 16:38:28。C1 的 `lsmod` 數到 0，證明那次開機 driver 從未載入。
- `twn_errtest.c` 現在共 14 個 `CALL`（第 60–102 行）；`board_check.sh` 第 37–46 行的兩個 rmmod 測試時序正確
  （第一個持有者 3 秒後關閉，`hold` 才開檔），A2、B2 都沒有 `hold:` 的錯誤訊息。
- `numbers.tex` 的四個平均值重算無誤（230.04、231.87、229.32、231.58），與 `board_results.json`、driver README
  一致；`err_code` 1 = `E_SLOT_RANGE` 對得上 `rtl/fuse/twn_desctab.v:106`。

### 第 1 輪各項的複查

| 編號 | 結果 | 說明 |
|---|---|---|
| R1 | 已確認 | 導讀表、第 10 節、附錄 B 都改用 `\errChecks`／`\errRefusals`（14／12），PDF p.6、57、60、64 正確；driver README 也改了 |
| R2 | 已確認 | 兩行 dmesg 現在在 `A2` 第 27–28 行，第 6 節引用 23–30 行；兩行時間差 3.02 s 計算正確 |
| R3 | 已確認 | `board_results.json` 新增的這一筆存在，數字與 log 相符 |
| R4 | 已確認 | `A1` 第 9–10 行（開機後 0）與 `C1` 第 10–21 行（driver 從未載入，只跑 UIO 後變成 `0x00010043`）足以支持「bitstream 本身的行為」；殘留一句說法見 N8 |
| R5 | 已確認 | 第 2 節第 49 行、第 6 節第 40 行與速查第 141 行（`drv_table_poll` = 153 行）都正確 |
| R6 | 已確認 | 導讀第 96 行、第 2 節第 37 行、第 4 節第 99 行、第 5 節第 115 行、兩個面試回答都寫了 `STRICT_DEVMEM` 的限制 |
| R7 | 已確認 | 第 3 節第 21、39 行；`0x540000` 約 5.3 MB 正確 |
| R8 | 已確認 | 第 5 節第 32 行、第 6 節第 33 行、第 9 節第 50 行一致 |
| R9 | 已確認 | 一句話、改善欄、面試回答一致 |
| R10 | 已確認 | 第 10 節表格第 82 行與正文第 91–97 行一致，三項差異都列出 |
| R11 | 已確認 | 新增 `twn_errtest hold` 與 `board_check.sh` 第 42–45 行，A2、B2 第 33 行都是 refused；改善欄不再拿 fps 佐證兩把鎖 |
| R12 | 已確認 | 第 1–10 節都有 v1.0.0 程式碼並點出行號；抽查 19、119–123、132、78–79、93、140、148、150、80–81、243、247、271、130、283–288、20、196 行都對得上片段（版本標示見 N5） |
| R13 | 已確認 | 圖 1 分成 `uio_pdrv_genirq` 與 `mem.c` 兩塊，150 dpi 下沒有重疊 |
| R14 | 已確認 | `app_arena_need`=45、`app_make_hal_var`=22、`drv_attr_nblk`=411；`dd.c:658` 名稱改正 |
| R15 | 已確認 | 第 7 節第 19、91 行；`SA_RESTART` 的說明正確 |
| R16 | 已確認 | 第 5 節第 103 行與兩個面試回答都已改正 |
| R17 | 已確認 | 第 8 節第 54、117 行 |
| R18 | 已確認（有殘留） | 所列名詞都已解釋並收進附錄 A，名詞表重排後的順序正確；只剩兩個環境變數名稱沒有解釋，改列 N4 |
| R19 | 已確認 | 第 5 節第 105 行 |
| R20 | 已確認 | 第 3 節第 110、115、120 行，第 4 節第 92 行 |
| R21 | 已確認 | 第 6 節第 109 行 |
| R22 | 已確認 | 第 2 節第 68–73 行與附錄 B 第 2 題 |
| R23 | 已確認 | 第 6 節第 91 行 |
| R24 | 已確認 | 第 7 節第 6、93 行 |
| R25 | 已確認 | 第 5 節第 99 行 |
| R26 | 已確認（有殘留） | 黑框改為直接讀原檔、指令由腳本印出、註解移到框外、rmmod 訊息有紀錄；`B1` 第 4 行的 stderr 錯位沒有在講義說明，見 N3 |
| R27 | 已確認 | 第 10 節第 99 行 |
| R28 | 已確認 | 第 3 節第 41 行；第 8 節刪掉「app 當掉之後」 |
| R29 | 已確認 | 第 1 節第 137 行與 driver README 的 Limits；理由（`devm_clk_get_enabled` 在 rmmod 時會關掉時脈、讓 UIO 路徑失效）成立 |
| R30 | 已確認 | 第 8 節欄位表，數值與 RTL 一致 |
| R31 | 已確認（接受部分採納） | 清單 A5 已改成與委託說明一致的「一天 8 小時、≤75 頁」，65 頁在上限內；長程式碼保留可以接受 |
| R32 | 已確認 | `qa` 標題改成「完整版，約 1 分鐘」，附錄 B 改用 `qashort` |
| R33 | 已確認 | 十節的一句話框都只剩一句 |
| R34 | 部分未解決（接受） | 已改的部分確認；黑框跨頁仍在，而且有一處正文指向的行落在下一頁，改列 N7（建議） |
| R35 | 已確認 | 附錄 C 第 131–138 行 |
| R36 | 已確認 | 第 2 節第 97 行 |

### 新發現

**N1（必改）導讀把「指令列的開頭」印成 `##`**
- 位置：`00-intro.tex:37`，PDF p.4「行首是 ## 的那一行，是執行的指令本身」。
- 原因：`\code` 用 `\tl_to_str:n` 把參數轉成字串，巨集參數符號 `#` 會被加倍成 `##`。紀錄檔的指令列開頭其實是 `# `
  （例如 `A1_fresh_boot_uio_dtb.txt` 第 1 行），讀者照講義去找會找不到。全篇只有這一處 `\code{#}`。
- 改法：改成 `\texttt{\#}`，或寫「行首是 `#` 加一個空格」。

**N2（必改）第 4 節對黑框內容的描述錯了**
- 位置：`04-mmap.tex:22`（PDF p.26）「最後兩行就是上面兩個 `mmap` 的結果（前三行是程式本身）」。
- 查證：框裡是 `A4_uio_state.txt` 第 5–12 行，共 8 行：前三行是 `#` 開頭的指令，第 4–6 行才是程式本身的三段映射，
  最後兩行是 `/dev/mem` 與 `/dev/uio4`。
- 改法：改成「中間三行是程式本身」。

**N3（建議）第 1 節 `B1` 黑框需要一句說明，而且結尾停在指令上**
- 位置：`01-dt-probe.tex:78–80`（PDF p.11）。
- 問題：第 4 行 `ls: .../driver: No such file or directory` 印在 `# uptime` 底下，其實是第 8 行 `ls -l .../driver` 的
  stderr（`results/raw/.../README.md` 第 22–23 行有說明，講義沒有）。正文說「insmod 之前，driver 這個連結不存在」，
  證據正是這一行，讀者卻會以為 uptime 出錯、`ls -l` 沒有輸出。另外範圍 1–23 停在第 23 行的指令，它的輸出（24–28 行）
  沒有印出來。
- 改法：正文加一句「框裡第 4 行是第 8 行那個 `ls` 的錯誤訊息，stderr 比 stdout 先進了紀錄」；範圍改成 1–22 或 1–28。

**N4（建議）`FUSE_HEAD_PL`、`FUSE_BB2HD` 仍然沒有解釋（R18 的殘留）**
- 它們出現在第 1、4、8、9、10 節的黑框裡（例如 `A2` 第 4–8 行、第 39 行，`A3` 第 16、44 行），正文從未說明。
- 改法：導讀「先認識幾個名字」或附錄 A 加一列：「`FUSE_HEAD_PL=1`／`0`：head 在 PL／在 CPU 上跑；`FUSE_BB2HD=1`：
  打開 BB2HD 模式」。

**N5（建議）「v1.0.0 取自 commit `2dffd8a`」的版本標示不精確**
- 位置：`00-intro.tex:35`；`extract.py` 的 `shown()` 在框上印「`@ v1.0.0 (2dffd8a)`」（PDF p.53）。
- 查證：v1.0.0 的發佈 commit 是 `3bdd485`（`CHANGELOG.md` 第 33 行 `[1.0.0] - 2026-10-26`），`2dffd8a` 是之後改圖片的
  commit；兩者之間 `sw/`、`board/`、`linux/project-spec/` 完全相同（`git diff 3bdd485 2dffd8a` 為空），所以內容沒錯。
- 改法：`snippets.txt` 改用 `git:3bdd485:...`，或文字改成「v1.0.0（`3bdd485`；到 `2dffd8a` 為止這些檔案沒有改動）」。

**N6（建議）吞吐量差距的說法前後不一**
- 位置：`00-intro.tex:128`「多了大約 1%」；`10-verify.tex:91`「約 0.8%」（原 dtb）／「約 1.0%」（改過的 dtb）；
  第 10 節面試回答「不到 1%」。
- 改法：導讀改成「不到 1%（原 dtb 約 0.8%）」，三處用同一個說法；也可以把百分比放進 `numbers.tex`。

**N7（建議）黑框跨頁斷開，其中一處正文指向的行落在下一頁（R34 的殘留）**
- 第 6 節：正文說「框裡第 5、6 行是 driver 同時印在 `dmesg` 的訊息」，但 `A2` 23–30 的框在 p.38 只印了前 4 行，
  第 5、6 行在 p.39。其他：`A3` 26–43 的 `ls` 在 p.50 只有指令和一行輸出；`A3` 51–66（p.22→23）、`A2` 1–12（p.58→59）、
  `Makefile.cross` 片段（p.53→54）。
- 改法：至少第 6 節那個框不要斷頁（例如在 `\boardfile` 前加 `\needspace{12\baselineskip}`）。

**N8（建議）「已經記成待追查的項目」找不到紀錄**
- 位置：`08-sysfs.tex:81`。repo 裡除了講義和 `board_results.json` 的「cause not investigated」，沒有任何追查項目
  （grep `ring overrun`、`ovr_sticky` 於 `*.md`）。
- 改法：寫出記在哪裡（檔案或 issue），或改成「原因尚未查明」。

**N9（建議）driver README 的兩處細節**
- `linux/driver/twn_fuse/README.md`「Verified」：「under both device trees: … ten reloads with a 64 MB buffer」，但 64 MB
  重載只在原本的 dtb 下測過（`A3_driver_state.txt` 第 51–66 行；B 開機沒有這項）。
- 同一檔表格「who may use it: one process at a time」，講義已改成「同一時間只有一次 `open()` 成功」，README 沒有跟著改。

**N10（建議）`board_check.sh` 與 `bind.sh` 沒有列在板上雜湊裡**
- `board_hashes_{A,B,C}.txt` 列了 driver、四個 app、`twn_errtest`、資料與 fixture，但沒有產生 A2、B2 的
  `board_check.sh` 和它呼叫的 `bind.sh`。紀錄的格式與現在的腳本吻合，但沒有雜湊可證明是同一版。下次重跑時一併列入即可。

**N11（建議）990,917 沒有放進 `numbers.tex`**
- `08-sysfs.tex:54`、`:117` 兩處寫死，數值正確（`A3` 第 20 行）；為了和「重複的數字只寫一次」的規則一致，可以移進
  `numbers.tex`。

### 結論

**不能交付，但只差 N1 與 N2。** 這兩項都是一行文字的修正，改完不需要再審。N3–N11 是建議，可以留到下一版。

第 1 輪的 36 項中，34 項已確認修好；R18、R26 的殘留部分改列 N4、N3；R31 的部分採納我接受；R34 的殘留改列 N7。
技術內容、kernel 引用、板上證據與數字，這一輪都沒有發現錯誤。改成 `\boardfile` 直接讀紀錄檔之後，黑框與紀錄檔逐行一致，
重跑的三次開機也補上了第 1 輪缺的證據（dmesg、只剩映射時的 rmmod、bit 16 與 driver 無關、10 次重載全部列出）。

**清單結果更新**：A1、A2、A5、B1、B2、B3、C1、C3、D1、D2、D3、E1、E2、F1、G1、G2 通過；A3、A4 大致通過（N4）；
C2 大致通過（N3）；F2 待 N1 修正後通過（排版小問題見 N7）。

### 第 2 輪處理（2026-10-27，撰稿人）

| 編號 | 處理 |
|---|---|
| N1 | 已改：`00-intro.tex` 改用 `\texttt{\#}`，文字改成「行首是 # 加一個空格」 |
| N2 | 已改：`04-mmap.tex` 改成「前三行是指令；接著三行是程式本身的映射；最後兩行是兩個 mmap 的結果」 |
| N3 | 已改：B1 的框改成 1–22 行（不再停在沒有輸出的指令），框下補一句說明第 4 行是第 8 行 `ls` 的 stderr |
| N4 | 已改：導讀名詞表加入 `FUSE_HEAD_PL`、`FUSE_BB2HD` |
| N5 | 已改：v1.0.0 程式碼改從發佈 commit `3bdd485` 抽出（`Makefile.cross` 在兩個 commit 相同），導讀文字一併改 |
| N6 | 已改：導讀與第 10 節面試回答都改成「0.8%（另一次開機 1.0%）」 |
| N7 | 已改：`\boardfile` 放進 minipage，所有黑框（最多 25 行）都不再跨頁 |
| N8 | 已改：寫明記錄在 `board_results.json` 該筆的 `note` 欄位 |
| N9 | 已改：driver README 的 64 MB 測試改寫為只在原本的 dtb；表格改成 one open file at a time |
| N10 | 部分採納：不重跑；在 `results/raw/linux_driver_20261026/README.md` 註明兩支腳本取自這個 commit、不在雜湊清單內 |
| N11 | 已改：`\cyclesTotal` 放進 `numbers.tex`，兩處改用它 |

依第 2 輪結論，N1、N2 修正後不再送審。PDF 重新編譯為 65 頁，沒有 Overfull。
