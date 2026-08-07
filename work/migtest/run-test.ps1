# Test harness for migrate-codex-to-g.ps1 (scratch test, uses fake folders only)
$ErrorActionPreference = 'Stop'
$scriptFile = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'codex-mover.ps1'
$srcRoot = Join-Path $PSScriptRoot 'sources'
$tgtRoot = Join-Path $PSScriptRoot 'target'

function Reset-Test {
    foreach ($p in @($srcRoot, $tgtRoot)) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
    }
}

function New-Sources {
    foreach ($n in 'a','b','c','d') {
        $dir = Join-Path $srcRoot $n
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir "$n-1.txt") -Value ('hello ' + $n)
        Set-Content -LiteralPath (Join-Path $dir "$n-2.txt") -Value ('world ' * 200)
        New-Item -ItemType Directory -Path (Join-Path $dir 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'sub\deep.txt') -Value 'deep'
        Set-Content -LiteralPath (Join-Path $dir '.hidden') -Value 'hidden file'
    }
}

function Build-HashtableArg {
    $pairs = foreach ($n in 'a','b','c','d') { "'{0}'='dir-{1}'" -f (Join-Path $srcRoot $n), $n }
    return "@{ " + ($pairs -join '; ') + " }"
}

function Count-Items {
    param([string]$Path)
    (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
}

function Invoke-Script {
    param([string]$Extra)
    $inner = "& '$scriptFile' -TargetRoot '$tgtRoot' -Sources $(Build-HashtableArg) -SkipProcessCheck $Extra"
    & powershell -NoProfile -ExecutionPolicy Bypass -Command $inner | Out-Host
    return $LASTEXITCODE
}

$failures = @()
function Assert {
    param([bool]$Cond, [string]$Msg)
    if ($Cond) { Write-Host "  PASS: $Msg" -ForegroundColor Green }
    else { Write-Host "  FAIL: $Msg" -ForegroundColor Red; $script:failures += $Msg }
}

Write-Host '=== Test 0: fresh fixture ==='
Reset-Test
New-Sources
$expectedCount = (Count-Items (Join-Path $srcRoot 'a'))
Assert ($expectedCount -eq 5) "fixture has 5 items per source (got $expectedCount)"

Write-Host '=== Test 1: dry run changes nothing ==='
$code = Invoke-Script -Extra '-DryRun'
Assert ($code -eq 0) "dry run exit code 0 (got $code)"
foreach ($n in 'a','b','c','d') {
    $p = Join-Path $srcRoot $n
    $item = Get-Item -LiteralPath $p -Force
    Assert (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) "dry run: $n not a junction"
}
Assert (-not (Test-Path -LiteralPath $tgtRoot)) 'dry run: target root not created'

Write-Host '=== Test 2: migration ==='
$code = Invoke-Script
Assert ($code -eq 0) "migration exit code 0 (got $code)"
foreach ($n in 'a','b','c','d') {
    $src = Join-Path $srcRoot $n
    $dst = Join-Path $tgtRoot ("dir-" + $n)
    $item = Get-Item -LiteralPath $src -Force
    Assert ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) "migrate: $n is now a junction"
    Assert (($item.Target).TrimEnd('\') -eq $dst) "migrate: $n points at $dst"
    Assert ((Count-Items $src) -eq $expectedCount) "migrate: $n readable through junction ($(Count-Items $src) items)"
    Assert ((Get-Content -LiteralPath (Join-Path $src "$n-1.txt")) -eq ("hello " + $n)) "migrate: $n content correct through junction"
}
$backupRoot = Get-ChildItem -LiteralPath $tgtRoot -Directory -Filter '_backup-*' | Select-Object -First 1
Assert ($null -ne $backupRoot) 'backup root exists'
foreach ($n in 'a','b','c','d') {
    $bak = Join-Path $backupRoot.FullName ("dir-" + $n)
    Assert ((Count-Items $bak) -eq $expectedCount) "backup: dir-$n has all items"
}
$leftovers = Get-ChildItem -LiteralPath $srcRoot -Directory -Force | Where-Object { $_.Name -like '*.pre-migration-*' }
Assert ($leftovers.Count -eq 0) 'no pre-migration leftovers on source side'

Write-Host '=== Test 3: re-run is idempotent ==='
$code = Invoke-Script
Assert ($code -eq 0) "re-run exit code 0 (got $code)"
foreach ($n in 'a','b','c','d') {
    $item = Get-Item -LiteralPath (Join-Path $srcRoot $n) -Force
    Assert ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) "re-run: $n still a junction"
}

Write-Host '=== Test 4: restore ==='
$code = Invoke-Script -Extra '-Restore'
Assert ($code -eq 0) "restore exit code 0 (got $code)"
foreach ($n in 'a','b','c','d') {
    $src = Join-Path $srcRoot $n
    $item = Get-Item -LiteralPath $src -Force
    Assert (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) "restore: $n is a real folder again"
    Assert ((Count-Items $src) -eq $expectedCount) "restore: $n has all items back"
    Assert ((Get-Content -LiteralPath (Join-Path $src "$n-1.txt")) -eq ("hello " + $n)) "restore: $n content intact"
    Assert (Test-Path -LiteralPath (Join-Path $tgtRoot ("dir-" + $n))) "restore: junction removal did not delete G-side data (dir-$n still exists)"
}

Write-Host ''
if ($failures.Count -eq 0) { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green; exit 0 }
Write-Host ("{0} TEST(S) FAILED" -f $failures.Count) -ForegroundColor Red
$failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
exit 1
