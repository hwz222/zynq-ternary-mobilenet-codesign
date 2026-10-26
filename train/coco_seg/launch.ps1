# Start a training run detached from the terminal (a run launched as a background shell job can
# lose its data-loader workers and hang silently). Prints the PID; output goes to
# checkpoints/<exp_id>/console.log. Usage:  powershell -File launch.ps1 configs/<run>.json
param([Parameter(Mandatory = $true)][string]$Config)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$py = if ($env:PYTHON) { $env:PYTHON } else { 'python' }
$exp = (Get-Content (Join-Path $here $Config) -Raw | ConvertFrom-Json).exp_id
$out = Join-Path $here "checkpoints\$exp"
New-Item -ItemType Directory -Force $out | Out-Null
$p = Start-Process -FilePath $py -ArgumentList '-m', 'src.train', $Config -WorkingDirectory $here `
    -RedirectStandardOutput (Join-Path $out 'console.log') -RedirectStandardError (Join-Path $out 'console.err') `
    -WindowStyle Hidden -PassThru
"started $exp pid $($p.Id)"
