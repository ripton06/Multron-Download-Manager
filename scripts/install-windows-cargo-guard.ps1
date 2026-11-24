param([switch]$Restore, [string]$PythonPath)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This build launcher is for Windows.' }

$taskGuardDirectory = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\tools\cargo-build-guard'
$taskRoutesFile = Join-Path $taskGuardDirectory 'routes.tsv'
$taskMutex = [Threading.Mutex]::new($false, 'Global\CodexCargoBuildGuard')
$taskLocked = $false
$taskWorker = [Diagnostics.Process]::GetCurrentProcess()
$taskOriginalPriority = $taskWorker.PriorityClass
$taskOriginalAffinity = $taskWorker.ProcessorAffinity

function Restore-TaskHostLimits([Diagnostics.Process]$TaskHost, [Diagnostics.ProcessPriorityClass]$TaskPriority, [IntPtr]$TaskAffinity) {
    $TaskHost.ProcessorAffinity = $TaskAffinity
    $TaskHost.PriorityClass = $TaskPriority
}

function Get-TaskActiveBuilds {
    Get-CimInstance Win32_Process | Where-Object {
        if ($_.Name -notmatch '^(cargo|cargo-native-original|cargo-clippy|rustc|rustdoc|clippy-driver)\.exe$') { return $false }
        try {
            $taskRegistration = [Threading.EventWaitHandle]::OpenExisting("Global\CodexCargoBuildGuardLauncher-$($_.ProcessId)")
            $taskRegistration.Dispose()
            return $false
        } catch { return $true }
    }
}

function Assert-TaskCargoPath([string]$TaskPath, [string[]]$TaskRoots) {
    $taskFull = [IO.Path]::GetFullPath($TaskPath)
    if ([IO.Path]::GetFileName($taskFull) -ne 'cargo.exe') { throw "Unexpected Cargo target: $taskFull" }
    $taskAllowed = $false
    foreach ($taskAllowedRoot in $TaskRoots) {
        $taskPrefix = [IO.Path]::GetFullPath($taskAllowedRoot).TrimEnd('\') + '\'
        if ($taskFull.StartsWith($taskPrefix, [StringComparison]::OrdinalIgnoreCase)) { $taskAllowed = $true }
    }
    if (-not $taskAllowed) { throw "Cargo target is outside the configured Cargo/Rustup directories: $taskFull" }
    return $taskFull
}

function Set-TaskCargoExecutable([string]$TaskTarget, [string]$TaskSource, [string]$TaskArchive) {
    $taskReplacement = $TaskTarget + '.codex-guard-new-' + [guid]::NewGuid().ToString('N')
    Copy-Item -LiteralPath $TaskSource -Destination $taskReplacement
    if (((Get-Item -LiteralPath $TaskTarget).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Move-Item -LiteralPath $TaskTarget -Destination $TaskArchive
        try { Move-Item -LiteralPath $taskReplacement -Destination $TaskTarget }
        catch { if (-not (Test-Path -LiteralPath $TaskTarget)) { Move-Item -LiteralPath $TaskArchive -Destination $TaskTarget }; throw }
    } else { [IO.File]::Replace($taskReplacement, $TaskTarget, $TaskArchive, $true) }
}

function Set-TaskAtomicText([string]$TaskFile, [string]$TaskText) {
    $taskNext = $TaskFile + '.next-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($taskNext, $TaskText, [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $TaskFile) { [IO.File]::Replace($taskNext, $TaskFile, ($TaskFile + '.backup-' + [guid]::NewGuid().ToString('N')), $true) }
    else { [IO.File]::Move($taskNext, $TaskFile) }
}

function Recover-TaskMissingEntries([string[]]$TaskRoots) {
    foreach ($taskJournalName in @('install-journal.json','restore-journal.json')) {
        $taskJournalPath = Join-Path $taskGuardDirectory $taskJournalName
        if (-not (Test-Path -LiteralPath $taskJournalPath)) { continue }
        $taskRecovery = [IO.File]::ReadAllText($taskJournalPath) | ConvertFrom-Json
        foreach ($taskEntry in @($taskRecovery.Targets)) {
            $taskTarget = Assert-TaskCargoPath $taskEntry.Target $TaskRoots
            if (Test-Path -LiteralPath $taskTarget) { continue }
            $taskArchive = [IO.Path]::GetFullPath($taskEntry.Archive)
            if ([IO.Path]::GetDirectoryName($taskArchive) -ne [IO.Path]::GetDirectoryName($taskTarget) -or -not [IO.Path]::GetFileName($taskArchive).StartsWith('cargo.exe.codex-guard-',[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid recovery archive in Cargo journal.' }
            if (-not (Test-Path -LiteralPath $taskArchive)) { throw "Missing Cargo entry cannot be recovered from its journal: $taskTarget" }
            Move-Item -LiteralPath $taskArchive -Destination $taskTarget
            Write-Host ('Recovered interrupted Cargo entry: ' + $taskTarget)
        }
    }
}

try {
    $taskWorker.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
    if ([Environment]::ProcessorCount -gt 4) { $taskWorker.ProcessorAffinity = [IntPtr]15 }
    $taskReported = [datetime]::MinValue
    while (-not $taskLocked) {
        try { $taskLocked = $taskMutex.WaitOne(250) }
        catch [Threading.AbandonedMutexException] { $taskLocked = $true }
        if (-not $taskLocked -and ([datetime]::UtcNow - $taskReported).TotalSeconds -ge 5) {
            Write-Host 'Waiting for the shared Cargo build lock.'
            $taskReported = [datetime]::UtcNow
        }
    }
    $taskReported = [datetime]::MinValue
    while ($true) {
        $taskActive = @(Get-TaskActiveBuilds)
        if ($taskActive.Count -eq 0) { break }
        if (([datetime]::UtcNow - $taskReported).TotalSeconds -ge 5) {
            Write-Host ('Waiting for active Cargo/Rust processes: ' + (($taskActive | ForEach-Object { "$($_.Name) ($($_.ProcessId))" }) -join ', '))
            $taskReported = [datetime]::UtcNow
        }
        Start-Sleep -Milliseconds 250
    }

    New-Item -ItemType Directory -Path $taskGuardDirectory -Force | Out-Null
    $taskCargoDirectory = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cargo' }
    $taskRustupDirectory = if ($env:RUSTUP_HOME) { $env:RUSTUP_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.rustup' }
    $taskRoots = @((Join-Path $taskCargoDirectory 'bin'), (Join-Path $taskRustupDirectory 'toolchains'))
    Recover-TaskMissingEntries $taskRoots
    $taskRoutes = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $taskRoutesFile) {
        foreach ($taskLine in [IO.File]::ReadAllLines($taskRoutesFile)) {
            $taskPair = $taskLine.Split("`t")
            if ($taskPair.Length -eq 2) { $taskRoutes[$taskPair[0]] = $taskPair[1] }
        }
    }
    $taskId = [guid]::NewGuid().ToString('N')
    if ($Restore) {
        $taskRestorePlan = [Collections.Generic.List[object]]::new()
        foreach ($taskPair in $taskRoutes.GetEnumerator()) {
            $taskTarget = Assert-TaskCargoPath $taskPair.Key $taskRoots
            if (-not (Test-Path -LiteralPath $taskPair.Value)) { throw "The original Cargo backup is missing: $($taskPair.Value)" }
            if ((Get-Item -LiteralPath $taskTarget).VersionInfo.ProductName -ne 'Codex Cargo Build Guard') {
                if ((Get-FileHash -LiteralPath $taskTarget -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $taskPair.Value -Algorithm SHA256).Hash) { continue }
                throw "Cargo has changed since guard installation: $taskTarget"
            }
            $taskRestorePlan.Add([pscustomobject]@{Target=$taskTarget;Original=$taskPair.Value;Archive=($taskTarget + '.codex-guard-restored-' + $taskId)})
        }
        $taskRestored = [Collections.Generic.List[object]]::new()
        Set-TaskAtomicText (Join-Path $taskGuardDirectory 'restore-journal.json') ([pscustomobject]@{Id=$taskId;Stage='Prepared';Targets=$taskRestorePlan.ToArray()} | ConvertTo-Json -Depth 6)
        try {
            foreach ($taskEntry in $taskRestorePlan) {
                Set-TaskCargoExecutable $taskEntry.Target $taskEntry.Original $taskEntry.Archive
                $taskRestored.Add($taskEntry)
            }
        } catch {
            for ($taskIndex = $taskRestored.Count - 1; $taskIndex -ge 0; $taskIndex--) {
                $taskEntry = $taskRestored[$taskIndex]
                Set-TaskCargoExecutable $taskEntry.Target $taskEntry.Archive ($taskEntry.Target + '.restore-rollback-' + $taskId)
            }
            throw
        }
        Write-Host ('Restored original Cargo executables: ' + $taskRestored.Count)
        Set-TaskAtomicText (Join-Path $taskGuardDirectory 'restore-journal.json') ([pscustomobject]@{Id=$taskId;Stage='Complete';Targets=$taskRestorePlan.ToArray()} | ConvertTo-Json -Depth 6)
        return
    }

    $taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $taskCompiler)) { throw 'The bundled Windows .NET Framework C# compiler was not found.' }
    $taskBuildDirectory = Join-Path $taskGuardDirectory ('builds\' + $taskId)
    New-Item -ItemType Directory -Path $taskBuildDirectory -Force | Out-Null
    $taskStage = Join-Path $taskBuildDirectory 'cargo-build-guard.exe'
    & $taskCompiler /nologo /optimize+ /platform:x64 /target:exe "/out:$taskStage" (Join-Path $PSScriptRoot 'windows-cargo-guard.cs')
    if ($LASTEXITCODE -ne 0) { throw 'The native Cargo build guard did not compile.' }

    $taskPythonPathFile = Join-Path $taskGuardDirectory 'python-path.txt'
    $taskPython = $PythonPath
    if (-not $taskPython -and (Test-Path -LiteralPath $taskPythonPathFile)) { $taskPython = [IO.File]::ReadAllText($taskPythonPathFile).Trim() }
    if (-not $taskPython) { $taskPython = (Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source }
    if (-not $taskPython -or -not (Test-Path -LiteralPath $taskPython)) { throw 'A Python runtime with stdlib tomllib is required for lossless Cargo alias resolution. Pass -PythonPath.' }
    $taskPython = [IO.Path]::GetFullPath($taskPython)
    & $taskPython -I -X utf8 -c 'import tomllib'
    if ($LASTEXITCODE -ne 0) { throw 'The selected Python runtime does not provide tomllib.' }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'cargo-alias-resolver.py') -Destination (Join-Path $taskGuardDirectory 'cargo-alias-resolver.py') -Force
    Set-TaskAtomicText $taskPythonPathFile ($taskPython + [Environment]::NewLine)

    $taskProxy = Assert-TaskCargoPath (Join-Path $taskCargoDirectory 'bin\cargo.exe') $taskRoots
    $taskTargets = [Collections.Generic.List[string]]::new()
    $taskTargets.Add($taskProxy)
    $taskToolchains = Join-Path $taskRustupDirectory 'toolchains'
    if (Test-Path -LiteralPath $taskToolchains) {
        foreach ($taskCandidate in (& rg --files --hidden --no-ignore -g cargo.exe $taskToolchains)) {
            if ($taskCandidate -match '\\bin\\cargo\.exe$') { $taskTargets.Add((Assert-TaskCargoPath $taskCandidate $taskRoots)) }
        }
    }
    $taskPrepared = [Collections.Generic.List[object]]::new()
    $taskOtherProxies = [Collections.Generic.List[object]]::new()
    foreach ($taskProxyName in @('rustup.exe','rustc.exe','cargo-clippy.exe')) {
        $taskOtherProxy = Join-Path $taskCargoDirectory ('bin\' + $taskProxyName)
        if (Test-Path -LiteralPath $taskOtherProxy) { $taskOtherProxies.Add([pscustomobject]@{Path=$taskOtherProxy;Sha256=(Get-FileHash -LiteralPath $taskOtherProxy -Algorithm SHA256).Hash}) }
    }
    foreach ($taskTarget in $taskTargets) {
        $taskIsGuard = (Get-Item -LiteralPath $taskTarget).VersionInfo.ProductName -eq 'Codex Cargo Build Guard'
        if ($taskIsGuard) {
            if (-not $taskRoutes.ContainsKey($taskTarget) -or -not (Test-Path -LiteralPath $taskRoutes[$taskTarget])) { throw "The original Cargo backup is missing for $taskTarget" }
        } elseif (-not ($taskRoutes.ContainsKey($taskTarget) -and (Test-Path -LiteralPath $taskRoutes[$taskTarget]) -and (Get-FileHash -LiteralPath $taskTarget -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $taskRoutes[$taskTarget] -Algorithm SHA256).Hash)) {
            $taskOriginalDirectory = Join-Path $taskGuardDirectory ('originals\' + $taskId + '\' + $taskPrepared.Count)
            New-Item -ItemType Directory -Path $taskOriginalDirectory -Force | Out-Null
            $taskOriginalName = if ($taskTarget -eq $taskProxy) { 'cargo.exe' } else { 'cargo-native-original.exe' }
            $taskOriginal = Join-Path $taskOriginalDirectory $taskOriginalName
            Copy-Item -LiteralPath $taskTarget -Destination $taskOriginal
            $taskRoutes[$taskTarget] = $taskOriginal
        }
        if ($taskTarget -ne $taskProxy -and [IO.Path]::GetFileNameWithoutExtension($taskRoutes[$taskTarget]) -eq 'cargo') {
            $taskNativeOriginal = Join-Path ([IO.Path]::GetDirectoryName($taskRoutes[$taskTarget])) 'cargo-native-original.exe'
            if (Test-Path -LiteralPath $taskNativeOriginal) {
                if ((Get-FileHash -LiteralPath $taskNativeOriginal -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $taskRoutes[$taskTarget] -Algorithm SHA256).Hash) { throw 'Saved native Cargo name collision.' }
            } else { Copy-Item -LiteralPath $taskRoutes[$taskTarget] -Destination $taskNativeOriginal }
            $taskRoutes[$taskTarget] = $taskNativeOriginal
        }
        $taskPrepared.Add([pscustomobject]@{Target=$taskTarget;Archive=($taskTarget + '.codex-guard-old-' + $taskId)})
    }

    $taskApplied = [Collections.Generic.List[object]]::new()
    $taskRouteLines = [Collections.Generic.List[string]]::new()
    $taskRouteLines.Add($taskProxy + "`t" + $taskRoutes[$taskProxy])
    foreach ($taskPair in $taskRoutes.GetEnumerator()) { if ($taskPair.Key -ne $taskProxy) { $taskRouteLines.Add($taskPair.Key + "`t" + $taskPair.Value) } }
    $taskJournal = [pscustomobject]@{Id=$taskId;Stage='Prepared';Routes=$taskRouteLines.ToArray();Targets=$taskPrepared.ToArray();Applied=@()}
    $taskJournalFile = Join-Path $taskGuardDirectory 'install-journal.json'
    Set-TaskAtomicText $taskJournalFile ($taskJournal | ConvertTo-Json -Depth 6)
    Set-TaskAtomicText $taskRoutesFile (($taskRouteLines -join [Environment]::NewLine) + [Environment]::NewLine)
    $taskJournal.Stage='RoutesPublished'
    Set-TaskAtomicText $taskJournalFile ($taskJournal | ConvertTo-Json -Depth 6)
    $taskPreviousJobs = $env:CARGO_BUILD_JOBS
    $taskPreviousJob = $env:CODEX_CARGO_BUILD_GUARD_JOB
    $taskPreflightJob = [IntPtr]::Zero
    try {
        [Reflection.Assembly]::LoadFile($taskStage) | Out-Null
        $taskPreflightName = 'Global\CodexCargoBuildGuardPreflight-' + $taskId
        $taskPreflightJob = [CargoBuildGuard]::CreateRestrictedJob($taskPreflightName)
        $env:CARGO_BUILD_JOBS='1'
        $env:CODEX_CARGO_BUILD_GUARD_JOB=$taskPreflightName
        if ([CargoBuildGuard]::RunInJob($taskRoutes[$taskProxy], [string[]]@('--version'), $taskPreflightJob, $true) -ne 0) { throw 'The saved Cargo proxy failed its restricted preflight.' }
    } finally {
        if ($taskPreflightJob -ne [IntPtr]::Zero) { [CargoBuildGuard]::CloseBuildJob($taskPreflightJob) }
        $env:CARGO_BUILD_JOBS=$taskPreviousJobs
        $env:CODEX_CARGO_BUILD_GUARD_JOB=$taskPreviousJob
    }
    try {
        foreach ($taskEntry in $taskPrepared) {
            Set-TaskCargoExecutable $taskEntry.Target $taskStage $taskEntry.Archive
            $taskApplied.Add($taskEntry)
            $taskJournal.Applied=$taskApplied.ToArray()
            Set-TaskAtomicText $taskJournalFile ($taskJournal | ConvertTo-Json -Depth 6)
        }
        $taskLauncher = Join-Path $taskGuardDirectory 'cargo-build-guard.exe'
        if (Test-Path -LiteralPath $taskLauncher) { Move-Item -LiteralPath $taskLauncher -Destination (Join-Path $taskBuildDirectory 'previous-guard.exe') }
        Copy-Item -LiteralPath $taskStage -Destination $taskLauncher
        foreach ($taskOtherProxy in $taskOtherProxies) {
            if ((Get-FileHash -LiteralPath $taskOtherProxy.Path -Algorithm SHA256).Hash -ne $taskOtherProxy.Sha256) { throw 'A non-Cargo Rustup proxy changed during installation.' }
        }
        Set-TaskAtomicText (Join-Path $taskGuardDirectory 'preserved-proxies.json') ($taskOtherProxies | ConvertTo-Json -Depth 4)
        $taskJournal.Stage='Complete'
        Set-TaskAtomicText $taskJournalFile ($taskJournal | ConvertTo-Json -Depth 6)
    } catch {
        for ($taskIndex = $taskApplied.Count - 1; $taskIndex -ge 0; $taskIndex--) {
            $taskEntry = $taskApplied[$taskIndex]
            Move-Item -LiteralPath $taskEntry.Target -Destination ($taskEntry.Target + '.codex-guard-failed-' + $taskId)
            Move-Item -LiteralPath $taskEntry.Archive -Destination $taskEntry.Target
        }
        throw
    }
    Write-Host ('Installed the shared Cargo guard for ' + $taskPrepared.Count + ' Cargo entry points.')
    Write-Host ('Launcher: ' + (Join-Path $taskGuardDirectory 'cargo-build-guard.exe'))
    Write-Host 'Limits: BelowNormal, affinity 15 on machines with more than four logical processors, CARGO_BUILD_JOBS=1 and -j 1.'
} finally {
    if ($taskLocked) { $taskMutex.ReleaseMutex() }
    $taskMutex.Dispose()
    Restore-TaskHostLimits $taskWorker $taskOriginalPriority $taskOriginalAffinity
}
