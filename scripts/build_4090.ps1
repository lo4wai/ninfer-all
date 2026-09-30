# Build NInfer-3090 on Windows with the toolchain this project actually needs.
#
# Three things are not the defaults on a typical machine, and getting any of them wrong produces
# an error that does not name the real cause:
#
#   MSVC from VS 2022, selected by importing its x64 developer environment.
#
#   CUDA 12.8 or newer, selected explicitly through CUDACXX so an older toolkit on PATH is ignored.
#
#   The Ninja generator avoids dependence on Visual Studio's CUDA MSBuild integration.
#
# Running this from a plain PowerShell prompt is fine: it imports the BuildTools environment
# itself rather than requiring a Developer Prompt.
#
#   .\scripts\build.ps1                  clean, configure + build into build-ninja
#   .\scripts\build.ps1 -Test            ... then run the test suite
#   .\scripts\build.ps1 -Package         ... then build the release archive for VERSION
#   .\scripts\build.ps1 -Benchmarks      ... include bench\ (implied by -Package)
#   .\scripts\build.ps1 -Target ninfer-serve
#   .\scripts\build.ps1 -NoClean         keep the build tree and continue incrementally
[CmdletBinding()]
param(
    [switch]$Test,
    [switch]$Package,
    [switch]$Benchmarks,
    [switch]$NoClean,
    [string]$Target,
    [string]$BuildDir,
    [string]$LogFile,
    [string]$VcpkgRoot,
    [string]$VcpkgInstalledDir,
    [ValidateSet('80', '86', '89')][string]$Arch = '89'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $BuildDir) { $BuildDir = Join-Path $RepoRoot 'build-ninja' }
if (-not $LogFile) { $LogFile = Join-Path $RepoRoot ("build-windows-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }

# Resolve relative paths from the repository and refuse to recursively remove anything outside it.
$RepoRootFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\') + '\'
$BuildDirPath = if ([System.IO.Path]::IsPathRooted($BuildDir)) { $BuildDir } else { Join-Path $RepoRoot $BuildDir }
$BuildDirFull = [System.IO.Path]::GetFullPath($BuildDirPath)
if (-not $BuildDirFull.StartsWith($RepoRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "BuildDir must be inside the repository because this script clears it: $BuildDirFull"
}
$BuildDir = $BuildDirFull

if (-not $VcpkgRoot) {
    $VcpkgRootCandidates = @($env:VCPKG_ROOT, 'C:\dev\vcpkg', 'C:\vcpkg') |
        Where-Object { $_ }
    $VcpkgRoot = $VcpkgRootCandidates |
        Where-Object { Test-Path -LiteralPath (Join-Path $_ 'scripts\buildsystems\vcpkg.cmake') } |
        Select-Object -First 1
}
if (-not $VcpkgRoot) {
    throw 'Could not find vcpkg.cmake. Set VCPKG_ROOT or pass -VcpkgRoot.'
}
if (-not $VcpkgInstalledDir) {
    $VcpkgInstalledCandidates = @(
        (Join-Path $RepoRoot 'build-windows\vcpkg_installed'),
        (Join-Path $BuildDir 'vcpkg_installed')
    )
    $VcpkgInstalledDir = $VcpkgInstalledCandidates |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_ 'x64-windows-release\share\ffmpeg\vcpkg-cmake-wrapper.cmake')) -or
            (Test-Path -LiteralPath (Join-Path $_ 'x64-windows\share\ffmpeg\vcpkg-cmake-wrapper.cmake'))
        } |
        Select-Object -First 1
    if (-not $VcpkgInstalledDir) {
        $VcpkgInstalledDir = Join-Path $BuildDir 'vcpkg_installed'
    }
}

# RTX 4090 is sm_89. Use all logical processors for this compile-only workload.
$ProcessorCount = (Get-CimInstance -ClassName Win32_ComputerSystem).NumberOfLogicalProcessors
if (-not $ProcessorCount -or $ProcessorCount -lt 1) { $ProcessorCount = 1 }

$LogFilePath = if ([System.IO.Path]::IsPathRooted($LogFile)) { $LogFile } else { Join-Path $RepoRoot $LogFile }
$LogFilePath = [System.IO.Path]::GetFullPath($LogFilePath)
"NInfer Windows build started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" | Set-Content -LiteralPath $LogFilePath
"Build directory: $BuildDir`r`nCUDA target: sm_$Arch`r`nCompile jobs: $ProcessorCount`r`nVcpkg root: $VcpkgRoot`r`nVcpkg triplet: x64-windows-release`r`nVcpkg packages: $VcpkgInstalledDir" |
    Add-Content -LiteralPath $LogFilePath

# The packager ships bench\ninfer_bench.exe alongside the CLI and the server, but
# benchmarks are an opt-in subdirectory (NINFER_BUILD_BENCHMARKS defaults to OFF). Configuring
# without them and then packaging fails late, after the whole tree has been built, with
# "Missing release product: ...\bench\ninfer_bench.exe" - so make -Package imply the option rather
# than leaving the two settings to be kept consistent by hand.
$BuildBenchmarks = $Benchmarks -or $Package

# --- locate the toolchain ---------------------------------------------------------------------

$VcVarsCandidates = @(
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files (x86)\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat'
)
$VcVars = $VcVarsCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $VcVars) {
    throw @"
No Visual Studio 2022 x64 build environment found. Looked in:
$($VcVarsCandidates -join "`n")
Install "Desktop development with C++" from VS 2022 Build Tools or Community.
"@
}

$CudaRoot = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA'
$CudaCandidates = Get-ChildItem -LiteralPath $CudaRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^v(\d+)\.(\d+)$' -and [version]($_.Name.Substring(1)) -ge [version]'12.8' } |
    Sort-Object { [version]($_.Name.Substring(1)) } -Descending |
    ForEach-Object { Join-Path $_.FullName 'bin\nvcc.exe' }
$Nvcc = $CudaCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $Nvcc) {
    throw @"
No CUDA 12.8 or newer toolkit found under $CudaRoot.
CMakeLists requires CUDA >= 12.8. Install a supported CUDA toolkit or update CudaRoot in this script.
"@
}

# vcvars64.bat only exports into its own cmd process, so run it and copy the result back.
Write-Host "toolchain: $VcVars"
Write-Host "toolchain: $Nvcc"
"Visual Studio environment: $VcVars`r`nCUDA compiler: $Nvcc" | Add-Content -LiteralPath $LogFilePath
cmd /c "`"$VcVars`" >nul 2>&1 && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] }
}
$env:CUDACXX = $Nvcc

$cl = (Get-Command cl.exe -ErrorAction SilentlyContinue)
if ($cl) { Write-Host "toolchain: $($cl.Source)" }
if ($cl) { "C++ compiler: $($cl.Source)" | Add-Content -LiteralPath $LogFilePath }

# --- configure and build ----------------------------------------------------------------------

if (-not $NoClean -and (Test-Path -LiteralPath $BuildDir)) {
    Write-Host "removing $BuildDir"
    Remove-Item -LiteralPath $BuildDir -Recurse -Force
} elseif ($NoClean) {
    Write-Host "keeping build directory for incremental build: $BuildDir"
}

Push-Location $RepoRoot
try {
    # Quote the -D arguments: PowerShell does not reliably expand a variable inside a bare token
    # that begins with "-D", and cmake then sees the literal "$Arch".
    $BenchmarksOption = if ($BuildBenchmarks) { 'ON' } else { 'OFF' }
    cmake -S . -B $BuildDir -G Ninja '-DCMAKE_BUILD_TYPE=Release' "-DCMAKE_CUDA_ARCHITECTURES=$Arch" `
          "-DNINFER_BUILD_BENCHMARKS=$BenchmarksOption" `
          '-DNINFER_D3D12_RESIDENCY=ON' `
          "-DCMAKE_TOOLCHAIN_FILE=$(Join-Path $VcpkgRoot 'scripts\buildsystems\vcpkg.cmake')" `
          '-DVCPKG_TARGET_TRIPLET=x64-windows-release' "-DVCPKG_INSTALLED_DIR=$VcpkgInstalledDir" 2>&1 |
          Tee-Object -FilePath $LogFilePath -Append
    if ($LASTEXITCODE -ne 0) { throw "configure failed ($LASTEXITCODE)" }

    $buildArgs = @('--build', $BuildDir)
    if ($Target) { $buildArgs += @('--target', $Target) }
    $buildArgs += @('--parallel', "$ProcessorCount")
    cmake @buildArgs 2>&1 | Tee-Object -FilePath $LogFilePath -Append
    if ($LASTEXITCODE -ne 0) { throw "build failed ($LASTEXITCODE)" }

    if ($Test) {
        # One GPU, so keep the parallelism low: unrelated CUDA tests contend for memory and
        # produce failures that do not reproduce when the test is run on its own.
        ctest --test-dir $BuildDir -j2 --output-on-failure 2>&1 |
            Tee-Object -FilePath $LogFilePath -Append
        if ($LASTEXITCODE -ne 0) { throw "tests failed ($LASTEXITCODE)" }
    }

    if ($Package) {
        $packager = Join-Path $PSScriptRoot 'package-release.ps1'
        # The packager defaults to build-ninja\; point it at the tree we actually built, so
        # -BuildDir and -Package agree. build.sh already does this for the Linux packager.
        $PreviousBuildRoot = $env:NINFER_BUILD_ROOT
        $env:NINFER_BUILD_ROOT = $BuildDir
        try {
            & $packager 2>&1 | Tee-Object -FilePath $LogFilePath -Append
            if ($LASTEXITCODE -ne 0) { throw "packaging failed ($LASTEXITCODE)" }
        } finally {
            $env:NINFER_BUILD_ROOT = $PreviousBuildRoot
        }
    }
} finally {
    Pop-Location
}

Write-Host ''
Write-Host "built into $BuildDir"
Write-Host "log    : $LogFilePath"
Write-Host "jobs   : $ProcessorCount logical processors"
Write-Host "  server : $(Join-Path $BuildDir 'apps\ninfer-serve.exe')"
Write-Host "  cli    : $(Join-Path $BuildDir 'apps\ninfer.exe')"
