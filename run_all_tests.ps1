param(
  [string]$TestsDir = ".\onboarding",
  [string]$Package  = "com.coffeemeetsbagel",
  [string]$Maestro  = "C:\Users\terxi\maestro\maestro\bin\maestro.bat",
  [string]$Test     = "",
  [string]$ReportDir = ".\reports"
)

function LogInfo($msg)  { Write-Host ("[INFO]  " + $msg) }
function LogWarn($msg)  { Write-Host ("[WARN]  " + $msg) }
function LogError($msg) { Write-Host ("[ERROR] " + $msg) }

function FormatDuration($seconds) {
  $sec = [double]$seconds
  $min = [Math]::Round($sec / 60.0, 2)
  $secRounded = [Math]::Round($sec, 2)
  return "$min minutes ($secRounded seconds)"
}

if (-not (Test-Path $Maestro)) {
  throw "Maestro not found at: $Maestro"
}

# Resolve launch activity once (so it works even if it changes by build) FOR PROD??
$resolved = adb shell cmd package resolve-activity --brief $Package 2>$null
$activity = ($resolved | Where-Object { $_ -like "$Package/*" } | Select-Object -First 1).Trim()
Write-Host "Resolved activity: '$activity'"

if (-not $activity) {
  throw "Could not resolve launchable activity for $Package. Output:`n$($resolved -join "`n")"
}

# Ensure report directory exists
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

# Report paths (append-only)
$csvPath = Join-Path $ReportDir "maestro_runs.csv"
$logPath = Join-Path $ReportDir "maestro_runs.log"

# Run metadata
$runId = [guid]::NewGuid().ToString("N").Substring(0,8)
$runStart = Get-Date
$runStartIso = $runStart.ToString("s")
$timestamp = $runStart.ToString("yyyy-MM-dd_HH-mm-ss")

# Collect log content in memory first
$logBlock = @()
$logBlock += "===== RUN START [$runId] $runStartIso | TestsDir=$TestsDir | Package=$Package ====="

# Find all YAML files under onboarding
$tests = Get-ChildItem -Path $TestsDir -Recurse -File |
  Where-Object { $_.Extension -in ".yaml", ".yml" } |
  Sort-Object FullName

if (-not $tests -or $tests.Count -eq 0) {
  throw "No YAML/YML files found under $TestsDir"
}

if ($Test -ne "") {
  $tests = $tests | Where-Object {
    $_.Name -ieq $Test -or $_.FullName -like "*\$Test*"
  }
  if (-not $tests -or $tests.Count -eq 0) {
    throw "Test '$Test' not found under $TestsDir"
  }
}

$failed = @()
$results = @()

$allStart = Get-Date


foreach ($t in $tests) {
  $flowPath = $t.FullName
  $flowName = $t.Name

  LogInfo "Running flow: $flowName"

  $logBlock += ""
  $logBlock += "--- FLOW START [$runId] $(Get-Date -Format s) | $flowPath ---"

  # reset + launch before each test (fresh state) PROD ENV?
  adb shell pm clear $Package | Out-Null
  Start-Sleep -Seconds 1
  adb shell am start -W -n "$activity" | Out-Null
  Start-Sleep -Seconds 1

  # # Reset + launch before each test
  # adb shell pm clear $Package | Out-Null
  # adb shell am start -W -n "$Package/.activities.ActivityLogin" | Out-Null # adb shell am start -W -n com.coffeemeetsbagel/.activities.ActivityLogin | Out-Null

  $start = Get-Date

  # Put ALL Maestro debug artifacts in ONE place (per run, per flow)
  $debugOut = Join-Path $ReportDir ("artifacts\" + $timestamp + "_" + $runId + "\" + [IO.Path]::GetFileNameWithoutExtension($flowName))
  New-Item -ItemType Directory -Force -Path $debugOut | Out-Null

  $consoleLog = Join-Path $debugOut "full_console.log"

  # Remove stale log if it exists
  if (Test-Path $consoleLog) {
      Remove-Item $consoleLog -Force
  }

  # Run via cmd.exe so stdout/stderr are redirected raw
  $cmdLine = "`"$Maestro`" test `"$flowPath`" --debug-output `"$debugOut`" > `"$consoleLog`" 2>&1"
  cmd.exe /c $cmdLine
  $exitCode = $LASTEXITCODE

  $knownBugHit = $null
  $consoleText = ""

  # Only classify as special pass if THIS run failed
  if ($exitCode -ne 0 -and (Test-Path $consoleLog)) {
    $consoleText = Get-Content $consoleLog -Raw

    if ($consoleText -match 'Take screenshot KNOWN_BUG_LOCATION_ERROR\.\.\. COMPLETED') {
      $knownBugHit = "KNOWN_BUG_LOCATION_ERROR"
    }
    elseif ($consoleText -match 'Take screenshot KNOWN_BUG_OTP_6_DIGITS\.\.\. COMPLETED') {
      $knownBugHit = "KNOWN_BUG_OTP_6_DIGITS"
    }
    elseif (
      $consoleText -match 'Take screenshot ACCOUNT_CREATED\.\.\. COMPLETED' -or
      $consoleText -match 'THIS_TEXT_SHOULD_NEVER_EXIST_ACCOUNT_CREATED'
    ) {
      $knownBugHit = "ACCOUNT_CREATED"
    }
  }

  if ($knownBugHit) {
    if ($knownBugHit -eq "ACCOUNT_CREATED") {
      LogWarn "ACCOUNT CREATED"
      $logBlock += "ACCOUNT CREATED"
    }
    else {
      LogWarn "KNOWN BUG HIT: $knownBugHit"
      $logBlock += "KNOWN BUG HIT: $knownBugHit"
    }
  }

  # If failed, print only last 80 lines to terminal for quick debugging
  if ($exitCode -ne 0 -and -not $knownBugHit) {
    LogError "Maestro failed. Last 80 lines from $consoleLog :"
    Get-Content $consoleLog -Tail 80 | ForEach-Object { LogError $_ }
  }

  # Keep variable defined so later code doesn't break
  $maestroOutput = @()

  $end = Get-Date
  $durationSec = ($end - $start).TotalSeconds
  $durationPretty = FormatDuration $durationSec

  if ($knownBugHit) {
    $status = "PASSED"
  }
  elseif ($exitCode -eq 0) {
    $status = "PASSED"
  }
  else {
    $status = "FAILED"
  }

  if ($knownBugHit -eq "ACCOUNT_CREATED") {
    LogInfo "PASSED: $flowName | Account already created | Duration: $durationPretty"
  }
  elseif ($knownBugHit) {
    LogWarn "KNOWN BUG (counted as PASS): $flowName | $knownBugHit | Duration: $durationPretty"
  }
  elseif ($status -eq "FAILED") {
    LogError "FAILED: $flowName | Duration: $durationPretty"
    $failed += $flowPath
  }
  else {
    LogInfo "PASSED: $flowName | Duration: $durationPretty"
  }

  $results += [PSCustomObject]@{
    RunId          = $runId
    RunStart       = $runStartIso
    FlowFile       = $flowName
    FlowPath       = $flowPath
    Status         = $status
    ExitCode       = $exitCode
    DurationPretty = $durationPretty
    DurationSec    = [Math]::Round($durationSec, 2)
  }

  $logBlock += "$status | $flowName | $durationPretty | exit $exitCode"

  if ($status -eq "FAILED") {
    $logBlock += "----- MAESTRO OUTPUT (FAILURE) BEGIN -----"
    if ($maestroOutput) {
      $maestroOutput | ForEach-Object { $logBlock += $_ }
    }
    $logBlock += "----- MAESTRO OUTPUT (FAILURE) END -----"
  }

  $logBlock += "--- FLOW END [$runId] $(Get-Date -Format s) | $flowPath ---"
}

$allEnd = Get-Date
$totalSec = ($allEnd - $allStart).TotalSeconds
$totalPretty = FormatDuration $totalSec

$logBlock += "===== RUN END [$runId] $(Get-Date -Format s) | Total=$totalPretty | Passed=$(($results | Where-Object {$_.Status -eq 'PASSED'}).Count) | Failed=$(($results | Where-Object {$_.Status -eq 'FAILED'}).Count) ====="
$logBlock += ""

# INSERT NEW RUN AT TOP OF LOG FILE
if (Test-Path $logPath) {
  $existing = Get-Content $logPath -Raw
  Set-Content -Path $logPath -Value ($logBlock -join "`r`n")
  Add-Content -Path $logPath -Value $existing
}
else {
  Set-Content -Path $logPath -Value ($logBlock -join "`r`n")
}

# CSV remains append-only
if (-not (Test-Path $csvPath)) {
  $results | Export-Csv -Path $csvPath -NoTypeInformation
} else {
  $results | Export-Csv -Path $csvPath -NoTypeInformation -Append
}

LogInfo "========== TEST SUMMARY =========="
LogInfo "RunId: $runId"
LogInfo "Total duration: $totalPretty"

if ($failed.Count -gt 0) {
  LogWarn "Failed flows:"
  $failed | ForEach-Object { LogWarn " - $_" }
  exit 1
}

LogInfo "Console log saved to: $consoleLog"

LogInfo "ALL TESTS PASSED"
exit 0