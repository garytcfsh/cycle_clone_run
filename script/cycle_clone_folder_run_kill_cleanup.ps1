param(
  [Parameter(Mandatory=$false)][ValidateRange(1,9999)][int]$N,
  [Parameter(Mandatory=$false)][ValidateRange(1,86400)][int]$RunSeconds,
  [Parameter(Mandatory=$false)][ValidateRange(0,86400)][int]$RepeatAfterSeconds,
  [Parameter(Mandatory=$false)][string]$SourceExe,
  # NEW: delay between starting each exe in milliseconds
  [Parameter(Mandatory=$false)][ValidateRange(0,600000)][int]$StartIntervalMs = 0,
  # NEW: pass arguments to the exe (string). Example: '--foo bar "C:\a b\c.txt"'
  [Parameter(Mandatory=$false)][string]$ExeArgs = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Pad3([int]$i) { $i.ToString("000") }

function Show-UsageExamples {
  $scriptPath = $PSCommandPath
  if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    $scriptPath = Join-Path (Get-Location).Path "cycle_clone_folder_run_kill_cleanup.ps1"
  }

  Write-Host ""
  Write-Host "Usage examples:"
  Write-Host "1) Basic run (3 instances, run 15s, no repeat delay):"
  Write-Host ("   powershell -ExecutionPolicy Bypass -File `"{0}`" -N 3 -RunSeconds 15 -RepeatAfterSeconds 0 -SourceExe `"D:\app\MyApp.exe`"" -f $scriptPath)
  Write-Host ""
  Write-Host "2) Start each exe with 250ms interval:"
  Write-Host ("   powershell -ExecutionPolicy Bypass -File `"{0}`" -N 5 -RunSeconds 20 -RepeatAfterSeconds 5 -SourceExe `"D:\app\MyApp.exe`" -StartIntervalMs 250" -f $scriptPath)
  Write-Host ""
  Write-Host "3) Pass arguments to exe (quoted as one string):"
  Write-Host ("   powershell -ExecutionPolicy Bypass -File `"{0}`" -N 2 -RunSeconds 10 -RepeatAfterSeconds 0 -SourceExe `"D:\app\MyApp.exe`" -StartIntervalMs 100 -ExeArgs '--mode test --input `"C:\data file.txt`"'" -f $scriptPath)
  Write-Host ""
}

$requiredParams = @("N", "RunSeconds", "RepeatAfterSeconds", "SourceExe")
$missingParams = @()
foreach ($rp in $requiredParams) {
  if (-not $PSBoundParameters.ContainsKey($rp)) {
    $missingParams += $rp
  }
}

if ($missingParams.Count -gt 0) {
  Write-Host "[ERROR] Missing required parameters: $($missingParams -join ', ')"
  Show-UsageExamples
  throw "Required parameters were not provided."
}

try {
  $SourceExe = (Resolve-Path -LiteralPath $SourceExe).Path
}
catch {
  Write-Host "[ERROR] SourceExe not found: $SourceExe"
  Show-UsageExamples
  throw
}

$srcDir  = Split-Path -Parent $SourceExe
$srcBase = [IO.Path]::GetFileNameWithoutExtension($SourceExe)
$srcExt  = [IO.Path]::GetExtension($SourceExe)

# IMPORTANT: put instances under the .ps1 folder to avoid recursive copying
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
  $scriptDir = (Get-Location).Path
}
$root = Join-Path $scriptDir ("instances_{0}" -f $srcBase)

Write-Host ("-"*60)
Write-Host "PS script dir : $scriptDir"
Write-Host "Source folder : $srcDir"
Write-Host "Source exe    : $SourceExe"
Write-Host "Instances root: $root"
Write-Host "Instances     : $N"
Write-Host "Run seconds   : $RunSeconds"
Write-Host "Repeat after  : $RepeatAfterSeconds"
Write-Host "Start interval: $StartIntervalMs ms"
Write-Host "Exe args      : $ExeArgs"
Write-Host ("-"*60)
Write-Host "Press Ctrl+C to stop. Cleanup will run in finally{}."
Write-Host ""

$script:StopRequested = $false

$cancelHandler = [ConsoleCancelEventHandler]{
  param($sender, $e)
  $script:StopRequested = $true
  $e.Cancel = $true
}
[Console]::add_CancelKeyPress($cancelHandler)

$cycleProcesses = New-Object System.Collections.Generic.List[System.Diagnostics.Process]

try {
  New-Item -ItemType Directory -Path $root -Force | Out-Null

  $excludeDirs = @(
    $root,
    (Join-Path $srcDir ("instances_{0}" -f $srcBase))
  ) | Where-Object { Test-Path -LiteralPath $_ }

  Write-Host "[SETUP] Preparing instance folders (clone dependencies) ..."
  for ($i=1; $i -le $N; $i++) {
    $idx = Pad3 $i
    $instDir = Join-Path $root ("inst_{0}" -f $idx)
    New-Item -ItemType Directory -Path $instDir -Force | Out-Null

    $args = @($srcDir, $instDir, "/MIR", "/R:1", "/W:1", "/NFL", "/NDL", "/NP")
    foreach ($d in $excludeDirs) { $args += @("/XD", $d) }

    & robocopy @args | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $instDir (exitcode=$LASTEXITCODE)" }

    $exeOriginal = Join-Path $instDir ($srcBase + $srcExt)
    $exeUnique   = Join-Path $instDir ("{0}_{1}{2}" -f $srcBase, $idx, $srcExt)

    if (Test-Path -LiteralPath $exeOriginal) {
      if (-not (Test-Path -LiteralPath $exeUnique)) {
        Rename-Item -LiteralPath $exeOriginal -NewName ("{0}_{1}{2}" -f $srcBase, $idx, $srcExt)
      }
    } elseif (-not (Test-Path -LiteralPath $exeUnique)) {
      throw "Cannot find exe in instance folder: $exeOriginal (or already-renamed: $exeUnique)"
    }
  }

  $cycle = 0
  while (-not $script:StopRequested) {
    $cycle++
    Write-Host ("===== Cycle {0} started at {1} =====" -f $cycle, (Get-Date))

    $cycleProcesses.Clear()

    for ($i=1; $i -le $N; $i++) {
      $idx = Pad3 $i
      $instDir = Join-Path $root ("inst_{0}" -f $idx)
      $exeUnique = Join-Path $instDir ("{0}_{1}{2}" -f $srcBase, $idx, $srcExt)

      if ([string]::IsNullOrWhiteSpace($ExeArgs)) {
        Write-Host "Starting: $exeUnique"
        $p = Start-Process -FilePath $exeUnique -WorkingDirectory $instDir -PassThru
      } else {
        Write-Host "Starting: $exeUnique  Args: $ExeArgs"
        # Pass raw argument string through -ArgumentList (string)
        $p = Start-Process -FilePath $exeUnique -WorkingDirectory $instDir -ArgumentList $ExeArgs -PassThru
      }

      $cycleProcesses.Add($p) | Out-Null

      if ($StartIntervalMs -gt 0 -and $i -lt $N) {
        Start-Sleep -Milliseconds $StartIntervalMs
      }
    }

    $end = (Get-Date).AddSeconds($RunSeconds)
    while ((Get-Date) -lt $end -and -not $script:StopRequested) {
      Start-Sleep -Milliseconds 200
    }

    Write-Host "Stopping started processes..."
    foreach ($p in @($cycleProcesses)) {
      try {
        if (-not $p.HasExited) {
          $null = $p.CloseMainWindow()
          Start-Sleep -Milliseconds 500
        }
      } catch {}
      try {
        if (-not $p.HasExited) {
          Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
      } catch {}
    }

    if ($script:StopRequested) { break }

    if ($RepeatAfterSeconds -gt 0) {
      Write-Host "Waiting $RepeatAfterSeconds seconds..."
      $end2 = (Get-Date).AddSeconds($RepeatAfterSeconds)
      while ((Get-Date) -lt $end2 -and -not $script:StopRequested) {
        Start-Sleep -Milliseconds 200
      }
    }
  }
}
finally {
  try { [Console]::remove_CancelKeyPress($cancelHandler) } catch {}

  Write-Host ""
  Write-Host "[CLEANUP] Stopping any remaining instance processes by name..."
  for ($i=1; $i -le $N; $i++) {
    $idx = Pad3 $i
    $name = "{0}_{1}" -f $srcBase, $idx
    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }

  Write-Host "[CLEANUP] Removing instance folders: $root"
  try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch {}

  Write-Host "Done."
}