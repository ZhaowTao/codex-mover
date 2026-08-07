# Test: repair-after-interruption + leftover cleanup (scratch, fake folders only)
$ErrorActionPreference = 'Stop'
$scriptFile = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'codex-mover.ps1'
$srcRoot = Join-Path $PSScriptRoot 'sources2'
$tgtRoot = Join-Path $PSScriptRoot 'target2'

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
        Set-Content -LiteralPath (Join-Path $dir "$n-2.txt") -Value ('world ' * 100)
        New-Item -ItemType Directory -Path (Join-Path $dir 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'sub\deep.txt') -Value 'deep'
        Set-Content -LiteralPath (Join-Path $dir '.hidden') -Value 'hidden'
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
    param([string]$Extra = '')
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

Reset-Test
New-Sources

Write-Host '=== Phase 1: initial migration ==='
$code = Invoke-Script
Assert ($code -eq 0) "initial migration exit 0 (got $code)"

Write-Host '=== Phase 2: simulate interrupted-run damage on a ==='
& cmd /c "rmdir `"$(Join-Path $srcRoot 'a')`"" | Out-Null
Assert (-not (Test-Path -LiteralPath (Join-Path $srcRoot 'a'))) 'junction a removed'
Remove-Item -LiteralPath (Join-Path $tgtRoot 'dir-a') -Recurse -Force
Assert (-not (Test-Path -LiteralPath (Join-Path $tgtRoot 'dir-a'))) 'target dir-a removed'
$backupRoot = Get-ChildItem -LiteralPath $tgtRoot -Directory -Filter '_backup-*' | Sort-Object Name -Descending | Select-Object -First 1
$srcA = Join-Path $srcRoot 'a'
New-Item -ItemType Directory -Path $srcA -Force | Out-Null
& robocopy (Join-Path $backupRoot.FullName 'dir-a') $srcA /E /XF 'a-1.txt' /NFL /NDL /NP /NJH /NJS | Out-Null
Assert ((Count-Items $srcA) -eq 4) "partial source a has 4 items (got $(Count-Items $srcA))"

Write-Host '=== Phase 3: re-run repairs and migrates automatically ==='
$code = Invoke-Script
Assert ($code -eq 0) "re-run exit 0 (got $code)"
$item = Get-Item -LiteralPath $srcA -Force
Assert ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) 'a is a junction again'
Assert ((Count-Items $srcA) -eq 5) "a has 5 items through junction (got $(Count-Items $srcA))"
Assert ((Get-Content -LiteralPath (Join-Path $srcA 'a-1.txt')) -eq 'hello a') 'a-1.txt restored and readable through junction'

Write-Host '=== Phase 4: leftover cleanup ==='
$leftover = Join-Path $srcRoot 'b.pre-migration-999999'
New-Item -ItemType Directory -Path $leftover -Force | Out-Null
Set-Content -LiteralPath (Join-Path $leftover 'junk.txt') -Value 'junk'
$code = Invoke-Script
Assert ($code -eq 0) "cleanup run exit 0 (got $code)"
Assert (-not (Test-Path -LiteralPath $leftover)) 'leftover folder cleaned'
Assert (Test-Path -LiteralPath (Join-Path $srcRoot 'b')) 'junction b still intact'

Write-Host ''
if ($failures.Count -eq 0) { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green; exit 0 }
Write-Host ("{0} TEST(S) FAILED" -f $failures.Count) -ForegroundColor Red
$failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
exit 1
