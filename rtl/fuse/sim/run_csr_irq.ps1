# run_csr_irq.ps1 -- unit gate for the interrupt output of twn_csr (register IRQ 0x0064 and the
# level-high irq port, v1.1), testbench tb\tb_csr_irq.v, with two destructive arms.
#
# Three runs: the intact arm must PASS; each defect arm must fail with a named failure.
#   CSR_IRQ_BREAK_MASK   irq ignores the enables (irq = ap_done | hd_done).
#   CSR_IRQ_BREAK_CTRL   the backbone enable follows CTRL[2], so the driver's START (0x1) and
#                        clear-done (0x2) writes turn the interrupt off.
#
# Usage: powershell -ExecutionPolicy Bypass -File rtl\fuse\sim\run_csr_irq.ps1
# Prerequisites: Vivado xvlog.bat / xelab.bat / xsim.bat. No generated inputs.
# Environment: VIVADO_BIN = Vivado bin directory (default C:\Xilinx\Vivado\2023.2\bin);
#   TWN_SIM_KEEP = if set, keep the work directory %TEMP%\twn_csrirq_<pid>.
# Result: one verdict per arm, then CSR_IRQ_GATE_SELFTEST_PASS (exit 0) or
#   CSR_IRQ_GATE_SELFTEST_FAIL (exit 1).
$env:PATH = "$(if ($env:VIVADO_BIN) { $env:VIVADO_BIN } else { 'C:\Xilinx\Vivado\2023.2\bin' });$env:PATH"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$workRoot = Join-Path $env:TEMP ("twn_csrirq_" + $PID)
function Run([string]$tag, [string[]]$defs) {
    $work = Join-Path $workRoot $tag
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $work | Out-Null
    Set-Location $work
    $a = @("--nolog","-sv") + $defs + @("$root\rtl\fuse\twn_csr.v", "$root\rtl\fuse\tb\tb_csr_irq.v")
    $r = & xvlog.bat @a 2>&1 | Out-String
    if ($r -match "ERROR") { Write-Host "$tag COMPILE ERROR"; Write-Host $r; return "ERR" }
    $r = & xelab.bat --nolog -debug off -s s tb_csr_irq 2>&1 | Out-String
    if ($r -match "ERROR") { Write-Host "$tag ELAB ERROR"; Write-Host $r; return "ERR" }
    $o = & xsim.bat s -runall --nolog 2>&1 | Out-String
    $named = @()
    foreach ($l in ($o -split "`r?`n")) {
        if ($l -match "^FAIL: ") { $named += $l; if ($named.Count -le 4) { Write-Host "    $tag | $l" } }
        elseif ($l -match "^(\[twn_csr\]|FAIL twn_csr:|tb_csr_irq: )") { Write-Host "    $tag | $l" }
    }
    if ($o -match "tb_csr_irq: PASS") { return "PASS" }
    if ($o -match "tb_csr_irq: (\d+) FAILURES") { return "FAIL($($Matches[1]))" }
    if ($named.Count -gt 0) { return "FAIL($($named.Count), no summary)" }
    return "UNKNOWN"
}
$good = Run "good" @()
$mask = Run "mask" @("-d","CSR_IRQ_BREAK_MASK")
$ctrl = Run "ctrl" @("-d","CSR_IRQ_BREAK_CTRL")
Write-Output ""
Write-Output "intact             = $good   (must be PASS)"
Write-Output "CSR_IRQ_BREAK_MASK = $mask   (must NOT be PASS)"
Write-Output "CSR_IRQ_BREAK_CTRL = $ctrl   (must NOT be PASS)"
Set-Location $env:TEMP
if (-not $env:TWN_SIM_KEEP) { Remove-Item -Recurse -Force -LiteralPath $workRoot -ErrorAction SilentlyContinue }
foreach ($v in @($good, $mask, $ctrl)) {
    if ($v -eq "ERR" -or $v -eq "UNKNOWN") { Write-Output "CSR_IRQ_GATE_SELFTEST_FAIL -- an arm did not build or printed no verdict"; exit 1 }
}
if ($good -eq "PASS" -and $mask -like "FAIL(*" -and $ctrl -like "FAIL(*") { Write-Output "CSR_IRQ_GATE_SELFTEST_PASS"; exit 0 }
Write-Output "CSR_IRQ_GATE_SELFTEST_FAIL -- the gate does not distinguish a defect"
exit 1
