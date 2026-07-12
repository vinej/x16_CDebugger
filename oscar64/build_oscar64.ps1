<#
.SYNOPSIS
    Compile a C program against the x16clib Oscar64 port, and optionally
    run it or the regression suite.

    This is the Oscar64 quarter of the library; build_ca65.ps1,
    build_llvm.ps1 and build_kickc.ps1 are the other three. Oscar64
    compiles the whole program at once and has no archive step, so like
    the KickC script there is no library build here: src_oscar64\ IS the
    library. Each header ends in `#pragma compile("...")`, which pulls
    its implementation into any program that includes it, and unused
    functions are stripped by the whole-program pass.

.EXAMPLE
    .\build_oscar64.ps1                             # compile examples\hello.c
    .\build_oscar64.ps1 -Test                       # headless regression suite
    .\build_oscar64.ps1 -Test -Windowed             # ...with real video
    .\build_oscar64.ps1 -Source mygame.c -Run
#>
param(
    [string]$Source = "examples\hello.c",
    [switch]$Run,
    [switch]$Test,
    [switch]$Windowed,
    [int]$Scale = 2
)

$ErrorActionPreference = "Stop"

# Always leave a real process exit code behind: `throw` does not set one,
# so a CI step running this script would see success after a failed test.
function Fail([string]$message) {
    Write-Host $message -ForegroundColor Red
    exit 1
}

$root   = $PSScriptRoot
$emu    = Join-Path $root "..\emulator\x16emu.exe"
$rom    = Join-Path $root "..\emulator\rom.bin"
$libsrc = Join-Path $root "src_oscar64"
$build  = Join-Path $root "build_oscar64"

# --- locate Oscar64 -----------------------------------------------------
# The repo-local ..\oscar64-sdk copy wins, then OSCAR64_HOME, then
# C:\oscar64. oscar64.exe finds its own include/ tree relative to the exe.
$o64 = $null
$candidates = @((Join-Path $root "..\oscar64-sdk"))
if ($env:OSCAR64_HOME) { $candidates += $env:OSCAR64_HOME }
$candidates += "C:\oscar64"
foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c "bin\oscar64.exe")) {
        $o64 = Join-Path $c "bin\oscar64.exe"; break
    }
}
if (-not $o64) {
    Fail "Oscar64 not found. Unzip a release to ..\oscar64-sdk, or set OSCAR64_HOME."
}

if (-not (Test-Path $build)) { New-Item -ItemType Directory -Path $build | Out-Null }

# --- compile ----------------------------------------------------------
# Oscar64 compiles the whole program every time -- there are no objects
# to reuse -- so the only staleness check worth doing is whether anything
# at all changed since the PRG was written.
function Build-Prg([string]$srcRel) {
    $srcAbs = Join-Path $root $srcRel
    if (-not (Test-Path $srcAbs)) { Fail "missing source: $srcRel" }
    $name = [IO.Path]::GetFileNameWithoutExtension($srcRel)
    $prg  = Join-Path $build "$name.prg"

    $newest = (Get-Item $srcAbs).LastWriteTimeUtc
    $deps = @(Get-ChildItem $libsrc -Recurse -File)
    if ($srcRel -like 'test_oscar64\*') {
        $deps += @(Get-ChildItem (Join-Path $root "test_oscar64") -Filter *.h -File)
    }
    foreach ($d in $deps) {
        if ($d.LastWriteTimeUtc -gt $newest) { $newest = $d.LastWriteTimeUtc }
    }
    if ((Test-Path $prg) -and ((Get-Item $prg).LastWriteTimeUtc -gt $newest)) {
        Write-Host "oscar64 $srcRel -> $prg (up to date)"
        return $prg
    }

    Write-Host "oscar64 $srcRel -> $prg"
    # -tm=x16 targets the Commander X16, -n generates native 6502 code
    # rather than interpreted bytecode, -i adds the library tree (each
    # header's #pragma compile pulls its .c in from there).
    #
    # -O2 is deliberately absent: Oscar64 1.32.272 crashes (a plain
    # access violation, no diagnostic) at -O2 on some translation units
    # of the test suite. The default -O1 with -n is already competitive.
    & $o64 -tm=x16 -n "-i=$libsrc" "-o=$prg" $srcAbs 2>&1 |
        ForEach-Object { Write-Host "      $_" }
    if ($LASTEXITCODE -ne 0) { Fail "oscar64 failed: $srcRel" }
    if (-not (Test-Path $prg)) { Fail "oscar64 reported success but $prg is missing" }
    Write-Host ("      {0} bytes" -f (Get-Item $prg).Length)
    return $prg
}

# -Test with no explicit -Source runs the whole suite: the same three
# programs as the KickC suite. Oscar64 has none of KickC's zero-page
# scarcity -- the split is kept so the two suites stay line-for-line
# comparable, and failures triage to a third of the tests.
$suites = @()
if ($Test -and -not $PSBoundParameters.ContainsKey('Source')) {
    $suites = @('test_oscar64\runner.c', 'test_oscar64\runner2.c', 'test_oscar64\runner3.c')
} else {
    $suites = @($Source)
}

foreach ($tool in @($emu, $rom)) {
    if (($Test -or $Run) -and -not (Test-Path $tool)) { Fail "missing: $tool" }
}

$prgs = @()
foreach ($sfile in $suites) { $prgs += (Build-Prg $sfile) }
$out = $prgs[0]

# --- test ------------------------------------------------------------
if ($Test) {
    # Headless -testbench runs no video, so VERA raises neither VSYNC nor
    # a raster interrupt: tests that need one skip themselves and say so.
    # -Windowed opens a real display, at real speed, and those tests run.
    if ($Windowed) {
        Write-Host "x16emu (windowed: video, VSYNC and raster interrupts live)"
    } else {
        Write-Host "x16emu (headless testbench)"
    }

    # Point device 8 at a scratch directory so any load/save tests are
    # hermetic and never touch a real SD-card image.
    $fsroot = Join-Path $root "test_oscar64\fsroot"
    if (-not (Test-Path $fsroot)) { New-Item -ItemType Directory -Path $fsroot | Out-Null }
    Get-ChildItem $fsroot -File | Where-Object { $_.Name -ne '.gitkeep' } | Remove-Item -Force

    $stdin = Join-Path $env:TEMP "x16clib-empty.in"
    [IO.File]::WriteAllText($stdin, "")

    $totalPass = 0; $totalRun = 0; $totalSkip = 0; $anyFail = $false

    foreach ($prg in $prgs) {
        $stdout = Join-Path $build ("{0}-output.txt" -f [IO.Path]::GetFileNameWithoutExtension($prg))
        if (Test-Path $stdout) { Remove-Item $stdout -Force }

        # -echo works either way; it is what puts CHROUT on stdout.
        if ($Windowed) {
            $emuArgs = @('-rom', $rom, '-fsroot', $fsroot, '-prg', $prg,
                         '-run', '-echo', '-scale', $Scale)
        } else {
            $emuArgs = @('-rom', $rom, '-fsroot', $fsroot, '-prg', $prg,
                         '-run', '-warp', '-echo', '-testbench')
        }

        # x16emu -testbench only exits at stdin EOF, and it only reads
        # stdin once it has printed its own "RDY" prompt -- which it never
        # does if the guest program leaves BASIC in an odd state. So don't
        # wait on the process: watch its output for our DONE line.
        $proc = Start-Process -FilePath $emu -ArgumentList $emuArgs -NoNewWindow -PassThru `
                              -RedirectStandardInput $stdin -RedirectStandardOutput $stdout

        $deadline = (Get-Date).AddSeconds(120)
        $text = ""
        while ($true) {
            Start-Sleep -Milliseconds 200
            if (Test-Path $stdout) {
                $text = (Get-Content $stdout -Raw -ErrorAction SilentlyContinue) -replace "`r", ""
                if ($text -match '(?m)^DONE ') { break }
            }
            if ($proc.HasExited) { break }
            if ((Get-Date) -gt $deadline) {
                if (-not $proc.HasExited) { $proc.Kill() }
                Fail "$([IO.Path]::GetFileName($prg)) timed out after 120s -- no DONE line"
            }
        }
        if (-not $proc.HasExited) { $proc.Kill() }
        $proc.WaitForExit()

        # Names are [A-Z0-9_]. Don't use \S+: a result line ends without a
        # CR, so whatever the next test prints first lands on the same
        # line and would be captured as part of the name.
        $passes = ([regex]::Matches($text, '(?m)^PASS ([A-Z0-9_]+)')).Count
        $fails  = [regex]::Matches($text, '(?m)^FAIL ([A-Z0-9_]+)')
        $skips  = [regex]::Matches($text, '(?m)^SKIP ([A-Z0-9_]+)')
        $done   = [regex]::Match($text, '(?m)^DONE ([0-9A-F]{2})/([0-9A-F]{2})')

        foreach ($f in $fails) { Write-Host ("  FAIL {0}" -f $f.Groups[1].Value) -ForegroundColor Red }
        foreach ($s in $skips) { Write-Host ("  SKIP {0}" -f $s.Groups[1].Value) -ForegroundColor Yellow }

        if (-not $done.Success) {
            Fail "$([IO.Path]::GetFileName($prg)) produced no DONE line -- it never finished"
        }

        $reportedPass  = [Convert]::ToInt32($done.Groups[1].Value, 16)
        $reportedTotal = [Convert]::ToInt32($done.Groups[2].Value, 16)

        if ($reportedTotal -eq 0) { Fail "no tests ran in $([IO.Path]::GetFileName($prg))" }
        if ($passes -ne $reportedPass) {
            Fail "output is inconsistent: $passes PASS lines but DONE says $reportedPass"
        }
        if ($fails.Count -gt 0 -or $reportedPass -ne $reportedTotal) { $anyFail = $true }

        $totalPass += $reportedPass
        $totalRun  += $reportedTotal
        $totalSkip += $skips.Count
    }

    if ($anyFail) { Fail "$($totalRun - $totalPass) of $totalRun tests failed" }

    $summary = "      $totalPass/$totalRun tests passed"
    if ($totalSkip -gt 0) {
        $summary += ", $totalSkip skipped (not runnable headless)"
    }
    Write-Host $summary -ForegroundColor Green
    exit 0
}

# --- run --------------------------------------------------------------
if ($Run) {
    Write-Host "x16emu $out"
    & $emu -rom $rom -prg $out -run -scale $Scale
}
