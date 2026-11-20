param(
  [ValidateSet('auto', 'x64', 'arm64')]
  [string]$Arch = 'auto'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string[]]$Arguments = @()
  )
  Write-Host "==> $FilePath $($Arguments -join ' ')"
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($Arguments -join ' ')"
  }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path (Join-Path $ScriptDir '..')).Path
Set-Location $RootDir

if ($Arch -eq 'auto') {
  $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
  if ($osArch -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
    $Arch = 'arm64'
  } else {
    $Arch = 'x64'
  }
}

$pubspecPath = Join-Path $RootDir 'pubspec.yaml'
$versionLine = Get-Content $pubspecPath | Where-Object { $_ -match '^\s*version:\s*' } | Select-Object -First 1
if ($versionLine) {
  $Version = (($versionLine -replace '^\s*version:\s*', '').Trim().Split('+')[0]).Trim()
} else {
  $Version = '1.0.0'
}
if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = '1.0.0'
}

Write-Host "==> Target Windows architecture: $Arch (version $Version)"

Invoke-Checked 'flutter' @('--suppress-analytics', 'config', '--enable-windows-desktop')
Invoke-Checked 'flutter' @('--suppress-analytics', 'pub', 'get')
Invoke-Checked 'flutter' @('--suppress-analytics', 'build', 'windows', '--release')

$ReleaseDir = Join-Path $RootDir "build\windows\$Arch\runner\Release"
$ExePath = Join-Path $ReleaseDir 'sync_canvas_notebook.exe'
if (-not (Test-Path $ExePath)) {
  throw "Expected Flutter Windows release binary not found at: $ExePath"
}

# Validate PE header Machine architecture
$fs = [System.IO.File]::OpenRead($ExePath)
try {
  $reader = New-Object System.IO.BinaryReader($fs)
  $fs.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
  $peOffset = $reader.ReadInt32()
  $fs.Seek($peOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
  $peSig = $reader.ReadUInt32()
  if ($peSig -ne 0x00004550) {
    throw "Invalid PE signature in $ExePath`: 0x$($peSig.ToString('X8'))"
  }
  $machine = $reader.ReadUInt16()
} finally {
  $fs.Dispose()
}

$expectedMachine = if ($Arch -eq 'arm64') { 0xAA64 } else { 0x8664 }
if ($machine -ne $expectedMachine) {
  throw ("PE Machine mismatch for {0}: expected 0x{1:X4} ({2}), got 0x{3:X4}" -f $ExePath, $expectedMachine, $Arch, $machine)
}
Write-Host ("==> Verified PE Machine architecture: 0x{0:X4} ({1})" -f $machine, $Arch)

$DistDir = Join-Path $RootDir 'dist\windows'
$StageRoot = Join-Path $RootDir "build\windows_packaging\$Arch"
$StageAppDir = Join-Path $StageRoot 'SyncCanvas_Notebook'

if (Test-Path $StageRoot) {
  Remove-Item -Recurse -Force $StageRoot
}
New-Item -ItemType Directory -Force -Path $DistDir, $StageAppDir | Out-Null

Write-Host "==> Staging release payload into $StageAppDir"
Copy-Item -Path (Join-Path $ReleaseDir '*') -Destination $StageAppDir -Recurse -Force

# Bundle MSVC C++ Runtime DLLs if available from Visual Studio Redist
$vswhereCandidates = @(
  "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
  "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
)
$vswhere = $vswhereCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$crtDlls = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')

if ($vswhere) {
  $vsPath = (& $vswhere -latest -products * -property installationPath | Select-Object -First 1)
  if ($vsPath) {
    $crtPattern = Join-Path $vsPath "VC\Redist\MSVC\*\$Arch\Microsoft.VC*.CRT"
    $crtDirs = Get-Item -Path $crtPattern -ErrorAction SilentlyContinue | Sort-Object FullName -Descending
    foreach ($crtDir in $crtDirs) {
      $copiedAny = $false
      foreach ($dll in $crtDlls) {
        $srcDll = Join-Path $crtDir.FullName $dll
        $dstDll = Join-Path $StageAppDir $dll
        if ((Test-Path $srcDll) -and (-not (Test-Path $dstDll))) {
          Copy-Item -Path $srcDll -Destination $dstDll -Force
          Write-Host "    Bundled MSVC runtime DLL: $dll (from $($crtDir.Name))"
          $copiedAny = $true
        }
      }
      if ($copiedAny) {
        break
      }
    }
  }
}

$readmeContent = @"
SyncCanvas Notebook v$Version (Windows $Arch)
================================================

Launch:
  Double-click sync_canvas_notebook.exe to start the desktop whiteboard.

Quick Connect:
  1. Click "Connect" (top-right QR/Sync button) in the top bar.
  2. Switch on "Host Room" to share directly over LAN or Mobile Hotspot,
     or connect to an existing room via WebSocket URL, QR code, or UDP LAN radar (port 48788).

Project & Updates:
  https://github.com/moyx782/notebook-gemini
"@
[System.IO.File]::WriteAllText(
  (Join-Path $StageAppDir 'README-Windows.txt'),
  $readmeContent,
  (New-Object System.Text.UTF8Encoding $false)
)

# 1. Portable ZIP package
$ZipName = "SyncCanvas_Notebook-$Version-windows-$Arch-portable.zip"
$ZipPath = Join-Path $DistDir $ZipName
if (Test-Path $ZipPath) {
  Remove-Item -Force $ZipPath
}
Write-Host "==> Creating portable archive: $ZipName"
Compress-Archive -Path $StageAppDir -DestinationPath $ZipPath -Force

# 2. Locate or install Inno Setup 6 (ISCC.exe)
function Find-Iscc {
  $cmd = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
  if ($cmd) {
    return $cmd.Source
  }
  $localPrograms = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
  } else {
    $null
  }
  $candidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
    $localPrograms
  ) | Where-Object { $_ -and (Test-Path $_) }
  return ($candidates | Select-Object -First 1)
}

$IsccPath = Find-Iscc
if (-not $IsccPath) {
  Write-Host "==> ISCC.exe not found locally; installing Inno Setup 6.7.4 into user profile..."
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $innoUrl = 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_4/innosetup-6.7.4.exe'
  $tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
  $setupTmp = Join-Path $tempRoot 'innosetup-6.7.4.exe'
  $innoDir = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6'
  } else {
    Join-Path $tempRoot 'Inno Setup 6'
  }

  Invoke-WebRequest -Uri $innoUrl -OutFile $setupTmp -UseBasicParsing
  $proc = Start-Process -FilePath $setupTmp -ArgumentList @(
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
    '/CURRENTUSER',
    "/DIR=$innoDir"
  ) -Wait -PassThru
  if ($proc.ExitCode -ne 0) {
    throw "Inno Setup silent installation failed with exit code $($proc.ExitCode)"
  }
  $IsccPath = Join-Path $innoDir 'ISCC.exe'
  if (-not (Test-Path $IsccPath)) {
    throw "ISCC.exe still not found at expected path: $IsccPath"
  }
}

Write-Host "==> Using Inno Setup compiler: $IsccPath"
$IssFile = Join-Path $RootDir 'packaging\windows\installer.iss'
$IconFile = Join-Path $RootDir 'windows\runner\resources\app_icon.ico'

Invoke-Checked $IsccPath @(
  "/DMyAppVersion=$Version",
  "/DMyAppArch=$Arch",
  "/DMySourceDir=$StageAppDir",
  "/DMyOutputDir=$DistDir",
  "/DMyIconFile=$IconFile",
  $IssFile
)

$SetupExeName = "SyncCanvas_Notebook_Setup_${Version}_windows_${Arch}.exe"
$SetupExePath = Join-Path $DistDir $SetupExeName
if (-not (Test-Path $SetupExePath)) {
  throw "Expected Inno Setup installer not generated at: $SetupExePath"
}

# 3. Generate SHA256SUMS for this architecture
$SumFile = Join-Path $DistDir "SHA256SUMS-windows-$Arch.txt"
$sumLines = @()
foreach ($artifactName in @($SetupExeName, $ZipName)) {
  $artifactPath = Join-Path $DistDir $artifactName
  $hash = (Get-FileHash -Path $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $sumLines += "$hash  $artifactName"
}
[System.IO.File]::WriteAllText(
  $SumFile,
  (($sumLines -join "`n") + "`n"),
  (New-Object System.Text.UTF8Encoding $false)
)

Write-Host "==> Windows packaging complete:"
Get-Item $SetupExePath, $ZipPath, $SumFile | Format-Table Name, Length -AutoSize
