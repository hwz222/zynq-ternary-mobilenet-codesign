# Runs the comparison arms one after another (launched detached by the caller).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
$py = if ($env:PYTHON) { $env:PYTHON } else { 'python' }
foreach ($c in @('d1_tern_pose', 'd2_tern_imnet', 'd3_int8_imnet', 'd4_tern_imnet_bb1')) {
    New-Item -ItemType Directory -Force "checkpoints\diag_$c" | Out-Null
    & $py -m src.train "configs/diag/$c.json" > "checkpoints\diag_$c\console.log" 2> "checkpoints\diag_$c\console.err"
}
'ALL' | Out-File runs\diag_done.txt
