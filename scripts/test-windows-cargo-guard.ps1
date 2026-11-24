param([int]$TimeoutSeconds = 120, [switch]$KeepFixtureCache)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows Cargo guard verification requires Windows.' }
$taskRepository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$taskGuard = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\tools\cargo-build-guard\cargo-build-guard.exe'
if (-not (Test-Path -LiteralPath $taskGuard)) { throw 'Install the Cargo guard before verification.' }
$taskRun = [guid]::NewGuid().ToString('N')
$taskDirectory = Join-Path 'C:\Temp\codex-cargo-guard-verification' $taskRun.Substring(0,12)
if (Test-Path -LiteralPath $taskDirectory) { throw 'Verification directory already exists.' }
New-Item -ItemType Directory -Path $taskDirectory -Force | Out-Null
$taskUtf8 = [Text.UTF8Encoding]::new($false)
$taskWorker = [Diagnostics.Process]::GetCurrentProcess()
$taskOriginalPriority = $taskWorker.PriorityClass
$taskOriginalAffinity = $taskWorker.ProcessorAffinity
[Reflection.Assembly]::LoadFile($taskGuard) | Out-Null
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CargoGuardVerificationNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    public static uint ExitCode(IntPtr process) {
        uint code;
        if (!GetExitCodeProcess(process, out code)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return code;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr OpenJobObject(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool QueryInformationJobObject(IntPtr job, int type, IntPtr information, uint size, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool CloseHandle(IntPtr handle);
    public static uint[] JobProcesses(string name) {
        var job=OpenJobObject(4,false,name);
        if(job==IntPtr.Zero) return new uint[0];
        var memory=Marshal.AllocHGlobal(8192);
        try {
            if(!QueryInformationJobObject(job,3,memory,8192,IntPtr.Zero)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            var count=Marshal.ReadInt32(memory,4);
            if(count<0 || count>(8192-8)/IntPtr.Size) throw new InvalidOperationException("Invalid job process count");
            var output=new uint[count];
            for(var i=0;i<count;i++) output[i]=(uint)Marshal.ReadIntPtr(memory,8+i*IntPtr.Size).ToInt64();
            return output;
        } finally { Marshal.FreeHGlobal(memory); CloseHandle(job); }
    }
}
'@
$script:TaskObserved = [Collections.Generic.Dictionary[string,object]]::new()
$script:TaskParents = [Collections.Generic.Dictionary[uint,uint]]::new()
$script:TaskOverlap = $false
$script:TaskJobMembers = [Collections.Generic.Dictionary[string,object]]::new()
$taskCases = [Collections.Generic.List[object]]::new()
$taskOwned = [Collections.Generic.List[object]]::new()
$taskSavedEnvironment = @{}
foreach ($taskName in @('CARGO_BUILD_JOBS','CARGO_TARGET_DIR','CARGO','CARGO_MAKEFLAGS','MAKEFLAGS','MFLAGS','CARGO_TERM_COLOR','CODEX_CARGO_BUILD_GUARD_JOB','GUARD_VERIFY_LOG','GUARD_VERIFY_NESTED_MANIFEST','GUARD_VERIFY_NESTED_TARGET','GUARD_VERIFY_WAIT_OUTPUT','GUARD_VERIFY_GUARD_EXE')) { $taskSavedEnvironment[$taskName] = [Environment]::GetEnvironmentVariable($taskName) }

function Assert-Task([bool]$TaskCondition, [string]$TaskMessage) {
    if (-not $TaskCondition) { throw $TaskMessage }
}

function Restore-TaskHostLimits([Diagnostics.Process]$TaskHost, [Diagnostics.ProcessPriorityClass]$TaskPriority, [IntPtr]$TaskAffinity) {
    $TaskHost.ProcessorAffinity = $TaskAffinity
    $TaskHost.PriorityClass = $TaskPriority
}

function New-TaskFixture([string]$TaskName, [int]$TaskSleep = 0, [int]$TaskFunctions = 200, [string]$TaskDirectoryName = $TaskName) {
    $taskPath = Join-Path $taskDirectory $TaskDirectoryName
    New-Item -ItemType Directory -Path (Join-Path $taskPath 'src') -Force | Out-Null
    $taskManifest = @'
[package]
name = "__NAME__"
version = "0.0.0"
edition = "2021"
build = "build.rs"

[profile.dev]
debug = 1
incremental = false
'@.Replace('__NAME__', $TaskName.Replace('-', '_'))
    [IO.File]::WriteAllText((Join-Path $taskPath 'Cargo.toml'), $taskManifest, $taskUtf8)
    $taskBuild = @'
use std::{env, fs, path::PathBuf, process::Command, thread, time::{Duration, SystemTime, UNIX_EPOCH}};
#[link(name = "kernel32")]
extern "system" {
    fn GetCurrentProcess() -> isize;
    fn GetPriorityClass(process: isize) -> u32;
    fn GetProcessAffinityMask(process: isize, current: *mut usize, system: *mut usize) -> i32;
}
fn now() -> u128 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() }
fn main() {
    let label = env::var("CARGO_PKG_NAME").unwrap();
    let root = PathBuf::from(env::var("GUARD_VERIFY_LOG").unwrap());
    let handle = unsafe { GetCurrentProcess() };
    let priority = unsafe { GetPriorityClass(handle) };
    let (mut affinity, mut system) = (0usize, 0usize);
    assert_ne!(unsafe { GetProcessAffinityMask(handle, &mut affinity, &mut system) }, 0);
    let jobs = env::var("CARGO_BUILD_JOBS").unwrap_or_default();
    let workers = env::var("NUM_JOBS").unwrap_or_default();
    let cargo = env::var("CARGO").unwrap_or_default();
    let job = env::var("CODEX_CARGO_BUILD_GUARD_JOB").unwrap_or_default();
    let makeflags = env::var("CARGO_MAKEFLAGS").unwrap_or_default();
    let legacy_makeflags = env::var("MAKEFLAGS").unwrap_or_default();
    let mflags = env::var("MFLAGS").unwrap_or_default();
    fs::write(root.join(format!("{label}.state")), format!("pid={}\njobs={jobs}\nworkers={workers}\npriority={priority}\naffinity={affinity}\ncargo={cargo}\njob={job}\nmakeflags={makeflags}\nlegacy_makeflags={legacy_makeflags}\nmflags={mflags}\n", std::process::id())).unwrap();
    assert_eq!(jobs, "1");
    assert_eq!(workers, "1");
    assert_eq!(priority, 0x4000);
    if system.count_ones() > 4 { assert_eq!(affinity, 15); }
    assert!(!cargo.contains("\\originals\\"), "CARGO points to an unguarded original");
    fs::write(root.join(format!("{label}.started")), now().to_string()).unwrap();
    if let Ok(manifest) = env::var("GUARD_VERIFY_NESTED_MANIFEST") {
        if !manifest.is_empty() {
            let result = Command::new(&cargo)
                .args(["build", "--manifest-path", &manifest, "-j", "8", "--offline"])
                .env("CARGO_TARGET_DIR", env::var("GUARD_VERIFY_NESTED_TARGET").unwrap())
                .env_remove("GUARD_VERIFY_NESTED_MANIFEST")
                .env_remove("GUARD_VERIFY_NESTED_TARGET")
                .status().unwrap();
            assert!(result.success(), "nested Cargo failed");
        }
    }
    thread::sleep(Duration::from_secs(__SLEEP__));
    fs::write(root.join(format!("{label}.finished")), now().to_string()).unwrap();
    println!("cargo:rerun-if-env-changed=GUARD_VERIFY_LOG");
}
'@.Replace('__SLEEP__', $TaskSleep.ToString())
    [IO.File]::WriteAllText((Join-Path $taskPath 'build.rs'), $taskBuild, $taskUtf8)
    $taskSource = [Text.StringBuilder]::new()
    for ($taskIndex = 0; $taskIndex -lt $TaskFunctions; $taskIndex++) { [void]$taskSource.AppendLine("fn value_$taskIndex(x: u64) -> u64 { std::hint::black_box(x).wrapping_add($taskIndex) }") }
    [void]$taskSource.AppendLine('fn calculate() -> u64 { let mut value = 1u64;')
    for ($taskIndex = 0; $taskIndex -lt $TaskFunctions; $taskIndex++) { [void]$taskSource.AppendLine("value = value_$taskIndex(value);") }
    [void]$taskSource.AppendLine('value }')
    [void]$taskSource.AppendLine('fn main() { println!("{}", calculate()); }')
    [void]$taskSource.AppendLine('#[test] fn fixture_runs() { assert!(calculate() > 0); }')
    [IO.File]::WriteAllText((Join-Path $taskPath 'src\main.rs'), $taskSource.ToString(), $taskUtf8)
    return [pscustomobject]@{Name=$TaskName;Path=$taskPath;Manifest=(Join-Path $taskPath 'Cargo.toml');Label=$TaskName.Replace('-','_');Target=(Join-Path $taskPath 'target')}
}

function Start-TaskProcess([string]$TaskTag, [string]$TaskExecutable, [string[]]$TaskArguments, [string]$TaskWorkingDirectory) {
    $taskQuoted = ($TaskArguments | ForEach-Object { [CargoBuildGuard]::Quote($_) }) -join ' '
    $taskProcess = Start-Process -FilePath $TaskExecutable -ArgumentList $taskQuoted -WorkingDirectory $TaskWorkingDirectory -WindowStyle Hidden -RedirectStandardOutput (Join-Path $taskDirectory ($TaskTag+'.stdout.log')) -RedirectStandardError (Join-Path $taskDirectory ($TaskTag+'.stderr.log')) -PassThru
    $taskRecord = [pscustomobject]@{Tag=$TaskTag;Id=[uint]$taskProcess.Id;Process=$taskProcess;Native=$null;Started=[DateTime]::UtcNow;Finished=$null;Code=$null}
    $taskOwned.Add($taskRecord)
    return $taskRecord
}

function Test-TaskExited($TaskProcess) {
    if ($TaskProcess.Native) { return [CargoGuardVerificationNative]::ExitCode($TaskProcess.Native.Process) -ne 259 }
    $TaskProcess.Process.Refresh()
    return $TaskProcess.Process.HasExited
}

function Get-TaskCode($TaskProcess) {
    if ($TaskProcess.Native) { return [CargoGuardVerificationNative]::ExitCode($TaskProcess.Native.Process) }
    $TaskProcess.Process.WaitForExit()
    return $TaskProcess.Process.ExitCode
}

function Observe-TaskProcesses([object[]]$TaskRoots) {
    $taskSnapshot = @([CargoBuildGuard]::Snapshot())
    foreach ($taskEntry in $taskSnapshot) { $script:TaskParents[$taskEntry.Id] = $taskEntry.Parent }
    $taskRootMap = @{}
    foreach ($taskRoot in $TaskRoots) { $taskRootMap[$taskRoot.Id] = $taskRoot.Tag }
    $taskActiveCargo = [Collections.Generic.HashSet[string]]::new()
    foreach ($taskEntry in $taskSnapshot) {
        $taskName = [IO.Path]::GetFileNameWithoutExtension($taskEntry.Name).ToLowerInvariant()
        if ($taskName -notin @('cargo','cargo-native-original','cargo-build-guard','rustc','clippy-driver','cargo-clippy','link','lld-link','rust-lld','build-script-build','build_script_build','conhost')) { continue }
        $taskCursor = $taskEntry.Id
        $taskWalk = [Collections.Generic.HashSet[uint]]::new()
        $taskTag = $null
        while ($taskCursor -ne 0 -and $taskWalk.Add($taskCursor)) {
            if ($taskRootMap.ContainsKey($taskCursor)) { $taskTag = $taskRootMap[$taskCursor]; break }
            if (-not $script:TaskParents.ContainsKey($taskCursor)) { break }
            $taskCursor = $script:TaskParents[$taskCursor]
        }
        if (-not $taskTag) { continue }
        try {
            $taskProcess = [Diagnostics.Process]::GetProcessById([int]$taskEntry.Id)
            $taskPriority=$taskProcess.PriorityClass
            $taskAffinity=$taskProcess.ProcessorAffinity
            if ($null -eq $taskPriority -or $null -eq $taskAffinity) { $taskProcess.Dispose(); continue }
            $taskObservation = [pscustomobject]@{Tag=$taskTag;Pid=$taskEntry.Id;Parent=$taskEntry.Parent;Name=$taskEntry.Name;Path=$taskProcess.MainModule.FileName;Priority=$taskPriority.ToString();Affinity=$taskAffinity.ToInt64()}
            $script:TaskObserved[$taskTag+'|'+$taskEntry.Id] = $taskObservation
            $taskProcess.Dispose()
            if ($taskName -in @('cargo','cargo-native-original') -and -not [CargoBuildGuard]::IsLauncher($taskEntry.Id)) { [void]$taskActiveCargo.Add($taskTag) }
        } catch [System.ArgumentException] { } catch [System.InvalidOperationException] { } catch [System.ComponentModel.Win32Exception] { } catch [Management.Automation.RuntimeException] { }
    }
    if ($taskActiveCargo.Count -gt 1) { $script:TaskOverlap = $true }
    foreach ($taskState in (Get-ChildItem -LiteralPath $taskDirectory -File -Filter '*.state')) {
        $taskJobLine=Get-Content -LiteralPath $taskState.FullName | Where-Object { $_.StartsWith('job=') } | Select-Object -First 1
        if (-not $taskJobLine) { continue }
        $taskJobName=$taskJobLine.Substring(4)
        if (-not $taskJobName.StartsWith('Global\CodexCargoBuildGuard',[StringComparison]::Ordinal)) { continue }
        try {
            $taskMembers=[Collections.Generic.List[object]]::new()
            foreach ($taskMemberId in [CargoGuardVerificationNative]::JobProcesses($taskJobName)) {
                try {
                    $taskMember=[Diagnostics.Process]::GetProcessById([int]$taskMemberId)
                    $taskMemberPriority=$taskMember.PriorityClass
                    $taskMemberAffinity=$taskMember.ProcessorAffinity
                    if ($null -eq $taskMemberPriority -or $null -eq $taskMemberAffinity) { $taskMember.Dispose(); continue }
                    $taskMembers.Add([pscustomobject]@{Pid=$taskMemberId;Name=$taskMember.ProcessName;Path=$taskMember.MainModule.FileName;Priority=$taskMemberPriority.ToString();Affinity=$taskMemberAffinity.ToInt64()})
                    $taskMember.Dispose()
                } catch [System.ArgumentException] { } catch [System.InvalidOperationException] { } catch [System.ComponentModel.Win32Exception] { } catch [Management.Automation.RuntimeException] { }
            }
            $script:TaskJobMembers[$taskJobName]=[pscustomobject]@{Job=$taskJobName;CapturedUtc=[DateTime]::UtcNow.ToString('o');Members=$taskMembers.ToArray()}
        } catch [System.ComponentModel.Win32Exception] { }
    }
}

function Wait-TaskProcesses([object[]]$TaskProcesses) {
    $taskDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Observe-TaskProcesses $TaskProcesses
        $taskPending = $false
        foreach ($taskProcess in $TaskProcesses) {
            if (-not (Test-TaskExited $taskProcess)) { $taskPending = $true }
            elseif ($null -eq $taskProcess.Code) { $taskProcess.Code=Get-TaskCode $taskProcess; $taskProcess.Finished=[DateTime]::UtcNow }
        }
        if ($taskPending -and [DateTime]::UtcNow -ge $taskDeadline) { throw ('Verification timed out: '+(($TaskProcesses | ForEach-Object Tag) -join ', ')) }
        if ($taskPending) { Start-Sleep -Milliseconds 15 }
    } while ($taskPending)
    foreach ($taskProcess in $TaskProcesses) { Assert-Task ($taskProcess.Code -eq 0) ("Fixture failed: "+$taskProcess.Tag+"; read "+(Join-Path $taskDirectory ($taskProcess.Tag+'.stderr.log'))) }
}

function Get-TaskState($TaskFixture) {
    $taskStateFile = Join-Path $taskDirectory ($TaskFixture.Label+'.state')
    Assert-Task (Test-Path -LiteralPath $taskStateFile) ('Fixture state was not written: '+$TaskFixture.Name)
    $taskState = @{}
    foreach ($taskLine in [IO.File]::ReadAllLines($taskStateFile)) { $taskPair=$taskLine.Split('=',2); if ($taskPair.Length -eq 2) { $taskState[$taskPair[0]]=$taskPair[1] } }
    Assert-Task ($taskState.jobs -eq '1' -and $taskState.workers -eq '1') ('Cargo jobs were not constrained: '+$TaskFixture.Name)
    Assert-Task ($taskState.priority -eq '16384' -and $taskState.affinity -eq '15') ('Build-script limits were not inherited: '+$TaskFixture.Name)
    Assert-Task ((Get-Item -LiteralPath $taskState.cargo).VersionInfo.ProductName -eq 'Codex Cargo Build Guard') ('Published CARGO is not a guarded executable: '+$TaskFixture.Name)
    return $taskState
}

$taskForeignJob = [IntPtr]::Zero
$taskExternalSemaphore = $null
$taskMutex = [Threading.Mutex]::new($false,[CargoBuildGuard]::MutexName)
$taskHasMutex = $false
$taskSuccess = $false
try {
    $taskWorker.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
    if ([Environment]::ProcessorCount -gt 4) { $taskWorker.ProcessorAffinity = [IntPtr]15 }
    Assert-Task ((Get-PSDrive C).Free -gt 200MB) 'Insufficient space for tiny verification fixtures.'
    Assert-Task ([CargoBuildGuard]::ForeignBuilds().Count -eq 0) 'Another Rust build is active; run verification after it finishes.'
    $env:GUARD_VERIFY_LOG=$taskDirectory
    $env:GUARD_VERIFY_NESTED_MANIFEST=$null
    $env:GUARD_VERIFY_NESTED_TARGET=$null
    $env:CARGO_BUILD_JOBS='8'
    $env:CODEX_CARGO_BUILD_GUARD_JOB=$null
    $taskFirst=New-TaskFixture 'guard-first' 3 500
    $taskSecond=New-TaskFixture 'guard-second' 1 500
    $env:CARGO_TARGET_DIR=$taskFirst.Target
    $taskA=Start-TaskProcess 'first' $taskGuard @('build','--manifest-path',$taskFirst.Manifest,'-j','8','--offline') $taskFirst.Path
    $env:CARGO_TARGET_DIR=$taskSecond.Target
    $taskB=Start-TaskProcess 'second' $taskGuard @('test','--manifest-path',$taskSecond.Manifest,'--jobs=8','--offline') $taskSecond.Path
    Wait-TaskProcesses @($taskA,$taskB)
    $taskFirstState=Get-TaskState $taskFirst
    $taskSecondState=Get-TaskState $taskSecond
    $taskStartA=[long](Get-Content -LiteralPath (Join-Path $taskDirectory ($taskFirst.Label+'.started')))
    $taskEndA=[long](Get-Content -LiteralPath (Join-Path $taskDirectory ($taskFirst.Label+'.finished')))
    $taskStartB=[long](Get-Content -LiteralPath (Join-Path $taskDirectory ($taskSecond.Label+'.started')))
    $taskEndB=[long](Get-Content -LiteralPath (Join-Path $taskDirectory ($taskSecond.Label+'.finished')))
    Assert-Task (-not $script:TaskOverlap -and ($taskEndA -le $taskStartB -or $taskEndB -le $taskStartA)) 'Independent builds overlapped.'
    $taskCases.Add([pscustomobject]@{Name='two-project-serialization-and-explicit-jobs';Passed=$true;FirstStart=$taskStartA;FirstEnd=$taskEndA;SecondStart=$taskStartB;SecondEnd=$taskEndB;FirstState=$taskFirstState;SecondState=$taskSecondState})
    Write-Host 'PASS: two projects serialized, build/test explicit job overrides constrained.'

    $taskAlias=New-TaskFixture 'guard-alias'
    New-Item -ItemType Directory -Path (Join-Path $taskAlias.Path '.cargo') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $taskAlias.Path '.cargo\config.toml'), '[alias]'+[Environment]::NewLine+'ci = "check --jobs 8"'+[Environment]::NewLine, $taskUtf8)
    $env:CARGO_TARGET_DIR=$taskAlias.Target
    $taskAliasProcess=Start-TaskProcess 'alias' $taskGuard @('ci','--manifest-path',$taskAlias.Manifest,'-j8','--offline') $taskAlias.Path
    Wait-TaskProcesses @($taskAliasProcess)
    $taskCases.Add([pscustomobject]@{Name='alias-job-override';Passed=$true;State=(Get-TaskState $taskAlias)})
    Write-Host 'PASS: alias ci=check --jobs 8 constrained.'

    $taskArray=New-TaskFixture 'guard-array' 0 200 'array project'
    New-Item -ItemType Directory -Path (Join-Path $taskArray.Path '.cargo') -Force | Out-Null
    $taskArrayArguments=@('check','--manifest-path',$taskArray.Manifest,'--features','','--jobs','8')
    $taskArrayConfig='[alias]'+[Environment]::NewLine+'array = '+(ConvertTo-Json -InputObject $taskArrayArguments -Compress)+[Environment]::NewLine+'outer = ["array", "-qj+16"]'+[Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $taskArray.Path '.cargo\config.toml'),$taskArrayConfig,$taskUtf8)
    $env:CARGO_TERM_COLOR='always'
    $env:CARGO_TARGET_DIR=$taskArray.Target
    $taskArrayProcess=Start-TaskProcess 'array' $taskGuard @('--color','always','outer','-j+8','--offline') $taskArray.Path
    Wait-TaskProcesses @($taskArrayProcess)
    $env:CARGO_TERM_COLOR=$taskSavedEnvironment['CARGO_TERM_COLOR']
    $taskCases.Add([pscustomobject]@{Name='lossless-array-nested-alias-spaces-empty-argument-and-color';Passed=$true;Arguments=$taskArrayArguments;State=(Get-TaskState $taskArray)})
    Write-Host 'PASS: nested array alias preserved a spaced path and empty argument under forced color.'

    foreach ($taskJobCase in @(@{Name='signed';Argument='-j+8'},@{Name='cluster';Argument='-qj8'},@{Name='large';Argument='-j18446744073709551615'},@{Name='default';Argument='-jdefault'})) {
        $taskFixture=New-TaskFixture ('guard-'+$taskJobCase.Name)
        $env:CARGO_TARGET_DIR=$taskFixture.Target
        $taskProcess=Start-TaskProcess $taskJobCase.Name $taskGuard @('check','--manifest-path',$taskFixture.Manifest,$taskJobCase.Argument,'--offline') $taskFixture.Path
        Wait-TaskProcesses @($taskProcess)
        $taskCases.Add([pscustomobject]@{Name='jobs-'+$taskJobCase.Name;Passed=$true;Input=$taskJobCase.Argument;State=(Get-TaskState $taskFixture)})
        Write-Host ('PASS: '+$taskJobCase.Argument+' constrained.')
    }

    $taskPackage=New-TaskFixture 'guard-package-list'
    $env:CARGO_TARGET_DIR=$taskPackage.Target
    $taskPackageProcess=Start-TaskProcess 'package-list' $taskGuard @('package','-lj8','--allow-dirty','--manifest-path',$taskPackage.Manifest,'--offline') $taskPackage.Path
    Wait-TaskProcesses @($taskPackageProcess)
    $taskPackageFiles=[IO.File]::ReadAllText((Join-Path $taskDirectory 'package-list.stdout.log')).Replace('\','/')
    Assert-Task ($taskPackageFiles.Contains('Cargo.toml') -and $taskPackageFiles.Contains('src/main.rs')) 'The package -l flag was lost while constraining the jobs cluster.'
    $taskCases.Add([pscustomobject]@{Name='package-list-jobs-cluster';Passed=$true;Input='-lj8'})
    Write-Host 'PASS: package -lj8 preserved list mode and constrained jobs.'

    $taskPublishArguments=[CargoBuildGuard]::LimitJobs([string[]]@('publish','-nj8'))
    Assert-Task (($taskPublishArguments -join '|') -eq 'publish|-j|1|-n') 'The publish dry-run flag was lost or its jobs cluster was not constrained.'
    $taskHelpArguments=[CargoBuildGuard]::LimitJobs([string[]]@('check','-hj8'))
    Assert-Task (($taskHelpArguments -join '|') -eq 'check|-j|1|-h') 'The help flag was lost while constraining the jobs cluster.'
    $taskCases.Add([pscustomobject]@{Name='dry-run-and-help-jobs-clusters-preserve-flags';Passed=$true;Publish=$taskPublishArguments;Help=$taskHelpArguments;PublishNotExecuted=$true})
    Write-Host 'PASS: dry-run/help jobs clusters preserved their flags; publish was not executed.'

    $taskGlobals=[CargoBuildGuard].GetMethod('CommandIndex',[Reflection.BindingFlags]'NonPublic,Static')
    foreach ($taskGlobalArguments in @(@('-qC','missing','external'),@('-qZ','unstable-options','external'),@('--explain','E0308','external'))) {
        Assert-Task ($taskGlobals.Invoke($null,@(,[string[]]$taskGlobalArguments)) -eq 2) 'A global option value was mistaken for the command.'
    }
    $taskStripDirectory=[CargoBuildGuard].GetMethod('WithoutAliasDirectory',[Reflection.BindingFlags]'NonPublic,Static')
    $taskStripArguments=[object[]]::new(2)
    $taskStripArguments[0]=[string[]]@('-qCmissing','check','-j8')
    $taskStripArguments[1]=0
    $taskStripped=[string[]]$taskStripDirectory.Invoke($null,$taskStripArguments)
    Assert-Task (($taskStripped -join '|') -eq '-q|check|-j8' -and $taskStripArguments[1] -eq 1) 'Alias-introduced -C changed native directory semantics.'
    foreach ($taskInvalidPrefix in @(@('-C'),@('-C','a','-C','b','check'))) {
        $taskRejected=$false
        $taskInvalidArguments=[object[]]::new(2)
        $taskInvalidArguments[0]=[string[]]$taskInvalidPrefix
        $taskInvalidArguments[1]=0
        try { [void]$taskStripDirectory.Invoke($null,$taskInvalidArguments) }
        catch {
            $taskDiagnostic=$_.ToString()
            if ($taskDiagnostic.Contains('missing -C argument') -or $taskDiagnostic.Contains('Repeated -C arguments')) { $taskRejected=$true }
            else { throw }
        }
        Assert-Task $taskRejected 'An invalid alias directory prefix was accepted.'
    }
    $taskSuffix=[string[]]@('check','-C','missing')
    $taskSuffixArguments=[object[]]::new(2)
    $taskSuffixArguments[0]=$taskSuffix
    $taskSuffixArguments[1]=0
    Assert-Task (($taskStripDirectory.Invoke($null,$taskSuffixArguments) -join '|') -eq 'check|-C|missing') 'A post-command -C was moved into the global prefix.'
    $taskDirectoryAlias=New-TaskFixture 'guard-directory-alias'
    New-Item -ItemType Directory -Path (Join-Path $taskDirectoryAlias.Path '.cargo') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $taskDirectoryAlias.Path '.cargo\config.toml'),'[alias]'+[Environment]::NewLine+'ci = ["-qCmissing-directory", "check", "-j8"]'+[Environment]::NewLine,$taskUtf8)
    $env:CARGO_TARGET_DIR=$taskDirectoryAlias.Target
    $taskDirectoryAliasProcess=Start-TaskProcess 'directory-alias' $taskGuard @('ci','--offline') $taskDirectoryAlias.Path
    Wait-TaskProcesses @($taskDirectoryAliasProcess)
    $taskCases.Add([pscustomobject]@{Name='global-option-values-and-native-alias-directory-semantics';Passed=$true;State=(Get-TaskState $taskDirectoryAlias)})
    Write-Host 'PASS: global option values consumed; valid alias -C retained native cwd semantics.'

    $taskCliProbe=Start-TaskProcess 'cli-alias-probe' $taskGuard @('--config','alias.guard_cli_config_probe=["version"]','guard_cli_config_probe') $taskDirectory
    $taskCliDeadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while(-not (Test-TaskExited $taskCliProbe)) { Observe-TaskProcesses @($taskCliProbe); Assert-Task ([DateTime]::UtcNow -lt $taskCliDeadline) 'CLI alias probe timed out.'; Start-Sleep -Milliseconds 15 }
    $taskCliProbe.Code=Get-TaskCode $taskCliProbe
    $taskCliProbe.Finished=[DateTime]::UtcNow
    $taskCliError=[IO.File]::ReadAllText((Join-Path $taskDirectory 'cli-alias-probe.stderr.log'))
    Assert-Task ($taskCliProbe.Code -ne 0 -and $taskCliError.Contains('no such command')) 'Native Cargo alias selection now uses CLI config; update the resolver before continuing.'
    $taskCases.Add([pscustomobject]@{Name='native-cli-config-alias-selection-before-configure';Passed=$true;Code=$taskCliProbe.Code})
    Write-Host 'PASS: native CLI-only version alias is invisible before configure.'

    $taskExternal=New-TaskFixture 'guard-external-jobserver'
    $taskSemaphoreName='codex_guard_external_'+$taskRun
    $taskExternalSemaphore=[Threading.Semaphore]::new(8,8,$taskSemaphoreName)
    $taskExternalFlags='-j8 --jobserver-auth='+$taskSemaphoreName
    $env:CARGO_MAKEFLAGS=$taskExternalFlags
    $env:MAKEFLAGS=$taskExternalFlags
    $env:MFLAGS=$taskExternalFlags
    $env:CARGO_TARGET_DIR=$taskExternal.Target
    $taskExternalProcess=Start-TaskProcess 'external-jobserver' $taskGuard @('check','--manifest-path',$taskExternal.Manifest,'-j8','--offline') $taskExternal.Path
    Wait-TaskProcesses @($taskExternalProcess)
    $taskExternalState=Get-TaskState $taskExternal
    Assert-Task (-not $taskExternalState.makeflags.Contains($taskSemaphoreName) -and $taskExternalState.legacy_makeflags -eq '' -and $taskExternalState.mflags -eq '') 'The external multi-token jobserver reached the build script.'
    foreach($taskName in @('CARGO_MAKEFLAGS','MAKEFLAGS','MFLAGS')) { [Environment]::SetEnvironmentVariable($taskName,$taskSavedEnvironment[$taskName]) }
    $taskExternalSemaphore.Dispose()
    $taskExternalSemaphore=$null
    $taskCases.Add([pscustomobject]@{Name='external-eight-token-jobserver-isolation';Passed=$true;State=$taskExternalState})
    Write-Host 'PASS: external eight-token jobserver removed before Cargo; effective jobs=1.'

    $taskInstallerTokens=$null
    $taskInstallerErrors=$null
    $taskInstallerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'install-windows-cargo-guard.ps1'),[ref]$taskInstallerTokens,[ref]$taskInstallerErrors)
    Assert-Task ($taskInstallerErrors.Count -eq 0) 'Installer syntax failed.'
    foreach($taskFunctionName in @('Assert-TaskCargoPath','Recover-TaskMissingEntries')) {
        $taskFunction=$taskInstallerAst.Find({param($taskNode) $taskNode -is [Management.Automation.Language.FunctionDefinitionAst] -and $taskNode.Name -eq $taskFunctionName},$true)
        Assert-Task ($null -ne $taskFunction) ('Installer recovery function missing: '+$taskFunctionName)
        Invoke-Expression $taskFunction.Extent.Text
    }
    $taskGuardDirectory=Join-Path $taskDirectory 'journal-recovery'
    New-Item -ItemType Directory -Path $taskGuardDirectory | Out-Null
    $taskRecoveryRoots=@((Join-Path $taskGuardDirectory 'cargo\bin'),(Join-Path $taskGuardDirectory 'rustup\toolchains'))
    $taskRecovered=[Collections.Generic.List[object]]::new()
    foreach($taskJournalName in @('install-journal.json','restore-journal.json')) {
        $taskParent=Join-Path $taskGuardDirectory ($taskJournalName.Replace('.json','')+'\bin')
        $taskRecoveryRoots+=$taskParent
        New-Item -ItemType Directory -Path $taskParent -Force | Out-Null
        $taskRecoveryTarget=Join-Path $taskParent 'cargo.exe'
        $taskRecoveryArchive=$taskRecoveryTarget+'.codex-guard-old-fixture'
        [IO.File]::WriteAllText($taskRecoveryArchive,'saved-fixture-'+$taskJournalName,$taskUtf8)
        $taskJournal=[pscustomobject]@{Stage='Prepared';Targets=@([pscustomobject]@{Target=$taskRecoveryTarget;Archive=$taskRecoveryArchive})}
        [IO.File]::WriteAllText((Join-Path $taskGuardDirectory $taskJournalName),($taskJournal | ConvertTo-Json -Depth 5),$taskUtf8)
        $taskRecovered.Add([pscustomobject]@{Target=$taskRecoveryTarget;Expected=('saved-fixture-'+$taskJournalName)})
    }
    Recover-TaskMissingEntries $taskRecoveryRoots
    Recover-TaskMissingEntries $taskRecoveryRoots
    foreach($taskRecovery in $taskRecovered) { Assert-Task ([IO.File]::ReadAllText($taskRecovery.Target) -eq $taskRecovery.Expected) 'Interrupted journal recovery lost the saved executable.' }
    $taskCases.Add([pscustomobject]@{Name='missing-entry-install-and-restore-journal-recovery';Passed=$true;Recovered=$taskRecovered.ToArray()})
    Write-Host 'PASS: missing entries recovered from install/restore journals, idempotently.'

    foreach ($taskCommand in @('clippy','fix')) {
        $taskFixture=New-TaskFixture ('guard-'+$taskCommand)
        $env:CARGO_TARGET_DIR=$taskFixture.Target
        $taskArguments=@($taskCommand,'--manifest-path',$taskFixture.Manifest,'-j8','--offline')
        if ($taskCommand -eq 'fix') { $taskArguments+=@('--allow-no-vcs','--allow-dirty') }
        $taskProcess=Start-TaskProcess $taskCommand $taskGuard $taskArguments $taskFixture.Path
        Wait-TaskProcesses @($taskProcess)
        $taskCases.Add([pscustomobject]@{Name=$taskCommand+'-job-override';Passed=$true;State=(Get-TaskState $taskFixture)})
        Write-Host ('PASS: '+$taskCommand+' job override constrained.')
    }

    $taskNested=New-TaskFixture 'guard-nested'
    $taskParent=New-TaskFixture 'guard-parent'
    $env:CARGO_TARGET_DIR=$taskParent.Target
    $env:GUARD_VERIFY_NESTED_MANIFEST=$taskNested.Manifest
    $env:GUARD_VERIFY_NESTED_TARGET=$taskNested.Target
    $taskParentProcess=Start-TaskProcess 'nested' $taskGuard @('build','--manifest-path',$taskParent.Manifest,'-j8','--offline') $taskParent.Path
    $env:GUARD_VERIFY_NESTED_MANIFEST=$null
    $env:GUARD_VERIFY_NESTED_TARGET=$null
    Wait-TaskProcesses @($taskParentProcess)
    $taskCases.Add([pscustomobject]@{Name='nested-published-cargo';Passed=$true;ParentState=(Get-TaskState $taskParent);NestedState=(Get-TaskState $taskNested)})
    Write-Host 'PASS: nested published CARGO constrained with a distinct target directory.'

    $taskForeign=New-TaskFixture 'guard-foreign' 6
    $taskAfterForeign=New-TaskFixture 'guard-after-foreign'
    $taskRoutes=[IO.File]::ReadAllLines((Join-Path ([IO.Path]::GetDirectoryName($taskGuard)) 'routes.tsv'))
    $taskOriginal=$null
    foreach ($taskRoute in $taskRoutes) { $taskPair=$taskRoute.Split([char]9); if ($taskPair.Length -eq 2 -and $taskPair[0] -like '*\.rustup\toolchains\*\bin\cargo.exe') { $taskOriginal=$taskPair[1]; break } }
    Assert-Task ($null -ne $taskOriginal) 'No saved native toolchain Cargo route found.'
    while (-not $taskHasMutex) { try { $taskHasMutex=$taskMutex.WaitOne(250) } catch [Threading.AbandonedMutexException] { $taskHasMutex=$true } }
    Assert-Task ([CargoBuildGuard]::ForeignBuilds().Count -eq 0) 'Foreign Rust build appeared before controlled fixture.'
    $taskForeignJobName='Global\CodexCargoBuildGuardVerification-'+$taskRun
    $taskForeignJob=[CargoBuildGuard]::CreateRestrictedJob($taskForeignJobName)
    $env:CARGO_BUILD_JOBS='1'
    $env:CARGO=$taskGuard
    $env:CARGO_TARGET_DIR=$taskForeign.Target
    $env:CODEX_CARGO_BUILD_GUARD_JOB=$taskForeignJobName
    Push-Location -LiteralPath $taskForeign.Path
    try { $taskNative=[CargoBuildGuard]::StartInJob($taskOriginal,[string[]]@('build','--manifest-path',$taskForeign.Manifest,'-j','1','--offline'),$taskForeignJob) }
    finally { Pop-Location }
    $taskForeignProcess=[pscustomobject]@{Tag='foreign';Id=$taskNative.Id;Process=$null;Native=$taskNative;Started=[DateTime]::UtcNow;Finished=$null;Code=$null}
    $taskOwned.Add($taskForeignProcess)
    $taskForeignDeadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath (Join-Path $taskDirectory ($taskForeign.Label+'.started')))) { Observe-TaskProcesses @($taskForeignProcess); Assert-Task ([DateTime]::UtcNow -lt $taskForeignDeadline) 'Foreign fixture did not start.'; Start-Sleep -Milliseconds 15 }
    $taskDetected=@([CargoBuildGuard]::ForeignBuilds().ToArray())
    Assert-Task (@($taskDetected | Where-Object { $_ -match ('\('+[regex]::Escape($taskForeignProcess.Id.ToString())+'\)') }).Count -gt 0) 'Native Cargo at a saved-original path was not detected.'
    $taskWaitScript=Join-Path $taskDirectory 'foreign-wait.ps1'
    [IO.File]::WriteAllText($taskWaitScript,@'
$ErrorActionPreference='Stop'
[Reflection.Assembly]::LoadFile($env:GUARD_VERIFY_GUARD_EXE) | Out-Null
[CargoBuildGuard]::ApplyLauncherLimits()
$taskBegin=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$taskDetected=@([CargoBuildGuard]::ForeignBuilds().ToArray())
[CargoBuildGuard]::WaitForForeignBuilds()
[pscustomobject]@{Begin=$taskBegin;End=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds();Detected=$taskDetected} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $env:GUARD_VERIFY_WAIT_OUTPUT -Encoding utf8
'@,$taskUtf8)
    $env:GUARD_VERIFY_GUARD_EXE=$taskGuard
    $env:GUARD_VERIFY_WAIT_OUTPUT=Join-Path $taskDirectory 'foreign-wait.json'
    $taskWaiter=Start-TaskProcess 'foreign-wait' (Get-Process -Id $PID).Path @('-NoProfile','-File',$taskWaitScript) $taskDirectory
    $env:CARGO_BUILD_JOBS='8'
    $env:CARGO_TARGET_DIR=$taskAfterForeign.Target
    $env:CODEX_CARGO_BUILD_GUARD_JOB=$null
    $taskFollowing=Start-TaskProcess 'after-foreign' $taskGuard @('build','--manifest-path',$taskAfterForeign.Manifest,'-j8','--offline') $taskAfterForeign.Path
    while (-not (Test-TaskExited $taskForeignProcess)) { Observe-TaskProcesses @($taskForeignProcess,$taskFollowing); Assert-Task ([DateTime]::UtcNow -lt $taskForeignDeadline) 'Foreign fixture timed out.'; Start-Sleep -Milliseconds 15 }
    $taskForeignProcess.Code=Get-TaskCode $taskForeignProcess
    $taskForeignProcess.Finished=[DateTime]::UtcNow
    [CargoBuildGuard]::CloseBuildJob($taskForeignJob)
    $taskForeignJob=[IntPtr]::Zero
    $taskMutex.ReleaseMutex()
    $taskHasMutex=$false
    Assert-Task ($taskForeignProcess.Code -eq 0) 'Controlled foreign fixture failed.'
    Wait-TaskProcesses @($taskFollowing,$taskWaiter)
    $taskWaitResult=Get-Content -LiteralPath $env:GUARD_VERIFY_WAIT_OUTPUT -Raw | ConvertFrom-Json
    $taskForeignEnd=[long](Get-Content -LiteralPath (Join-Path $taskDirectory ($taskForeign.Label+'.finished')))
    $taskFollowingStart=[long](Get-Content -LiteralPath (Join-Path $taskDirectory ($taskAfterForeign.Label+'.started')))
    Assert-Task ($taskWaitResult.End -ge $taskForeignEnd -and $taskWaitResult.End-$taskWaitResult.Begin -ge 1000) 'Foreign-build wait returned before the active build finished.'
    Assert-Task ($taskFollowingStart -ge $taskForeignEnd) 'Guarded next project started while the controlled foreign build was active.'
    $taskCases.Add([pscustomobject]@{Name='active-native-foreign-detection-and-wait';Passed=$true;ForeignCargoPid=$taskForeignProcess.Id;Detected=$taskDetected;Wait=$taskWaitResult;ForeignState=(Get-TaskState $taskForeign);FollowingState=(Get-TaskState $taskAfterForeign)})
    Write-Host 'PASS: active native Cargo detected across paths and waited for.'

    $taskSupervisorFixture=New-TaskFixture 'guard-supervisor'
    $taskSupervisorSource=Join-Path $taskDirectory 'supervisor.cs'
    [IO.File]::WriteAllText($taskSupervisorSource,@'
using System;
using System.Diagnostics;
public sealed class Supervisor {
    public static int Main(string[] args) {
        var process=Process.GetCurrentProcess();
        process.PriorityClass=ProcessPriorityClass.BelowNormal;
        if(Environment.ProcessorCount>4) process.ProcessorAffinity=new IntPtr(15);
        var start=new ProcessStartInfo(args[0],args[1]);
        start.WorkingDirectory=args[2];
        start.UseShellExecute=false;
        start.CreateNoWindow=true;
        using(var child=Process.Start(start)) { child.WaitForExit(); return child.ExitCode; }
    }
}
'@,$taskUtf8)
    $taskSupervisor=Join-Path $taskDirectory 'cargo-clippy.exe'
    & (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /platform:x64 /target:exe "/out:$taskSupervisor" $taskSupervisorSource
    Assert-Task ($LASTEXITCODE -eq 0) 'Controlled supervisor did not compile.'
    $taskChildArguments=(@('check','--manifest-path',$taskSupervisorFixture.Manifest,'-j8','--offline') | ForEach-Object { [CargoBuildGuard]::Quote($_) }) -join ' '
    $env:CARGO_TARGET_DIR=$taskSupervisorFixture.Target
    $taskSupervisorProcess=Start-TaskProcess 'supervisor' $taskSupervisor @($taskGuard,$taskChildArguments,$taskSupervisorFixture.Path) $taskSupervisorFixture.Path
    Wait-TaskProcesses @($taskSupervisorProcess)
    $taskCases.Add([pscustomobject]@{Name='cargo-supervisor-ancestor';Passed=$true;State=(Get-TaskState $taskSupervisorFixture)})
    Write-Host 'PASS: same-tree Cargo supervisor does not deadlock its child.'

    $taskTerminateFixture=New-TaskFixture 'guard-terminate' 15
    $env:CARGO_TARGET_DIR=$taskTerminateFixture.Target
    $taskTerminateProcess=Start-TaskProcess 'terminate' $taskGuard @('build','--manifest-path',$taskTerminateFixture.Manifest,'-j8','--offline') $taskTerminateFixture.Path
    $taskTerminateDeadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not (Test-Path -LiteralPath (Join-Path $taskDirectory ($taskTerminateFixture.Label+'.started')))) {
        Observe-TaskProcesses @($taskTerminateProcess)
        Assert-Task (-not (Test-TaskExited $taskTerminateProcess)) 'Termination fixture exited before its active build state.'
        Assert-Task ([DateTime]::UtcNow -lt $taskTerminateDeadline) 'Termination fixture did not start.'
        Start-Sleep -Milliseconds 15
    }
    $taskTerminateState=Get-TaskState $taskTerminateFixture
    $taskTerminationJob=$taskTerminateState.job
    $taskTerminationMembers=@([CargoGuardVerificationNative]::JobProcesses($taskTerminationJob))
    Assert-Task ($taskTerminationMembers.Count -gt 0) 'No owned Job members were present before root termination.'
    $taskTerminateProcess.Process.Kill()
    [void]$taskTerminateProcess.Process.WaitForExit(5000)
    $taskCleanupDeadline=[DateTime]::UtcNow.AddSeconds(5)
    do {
        $taskRemainingMembers=@([CargoGuardVerificationNative]::JobProcesses($taskTerminationJob))
        if ($taskRemainingMembers.Count -eq 0) { break }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $taskCleanupDeadline)
    Assert-Task ($taskRemainingMembers.Count -eq 0) 'Owned Job members survived guard root termination.'
    $taskCases.Add([pscustomobject]@{Name='owned-root-termination-cleanup';Passed=$true;Job=$taskTerminationJob;MembersBefore=$taskTerminationMembers;MembersAfter=$taskRemainingMembers})
    Write-Host 'PASS: terminating only the owned guard root clears its Job descendants.'

    $taskAllObservations=@($script:TaskObserved.Values)
    $taskRustc=@($taskAllObservations | Where-Object Name -eq 'rustc.exe')
    $taskLinkers=@($taskAllObservations | Where-Object { $_.Name -in @('link.exe','lld-link.exe','rust-lld.exe') })
    Assert-Task ($taskRustc.Count -gt 0) 'No actual rustc descendant was observed.'
    Assert-Task ($taskLinkers.Count -gt 0) 'No actual linker descendant was observed.'
    $taskBad=@($taskAllObservations | Where-Object { $_.Priority -ne 'BelowNormal' -or $_.Affinity -ne 15 })
    Assert-Task ($taskBad.Count -eq 0) 'Observed descendants escaped priority/affinity limits.'
    $taskCases.Add([pscustomobject]@{Name='actual-rustc-and-linker-limits';Passed=$true;RustcCount=$taskRustc.Count;LinkerCount=$taskLinkers.Count;Observed=$taskAllObservations})
    $taskSuccess=$true
} finally {
    if ($null -ne $taskExternalSemaphore) { $taskExternalSemaphore.Dispose() }
    if ($taskForeignJob -ne [IntPtr]::Zero) { [CargoBuildGuard]::CloseBuildJob($taskForeignJob) }
    if ($taskHasMutex) { $taskMutex.ReleaseMutex() }
    $taskMutex.Dispose()
    foreach ($taskProcess in $taskOwned) {
        if ($taskProcess.Native) { $taskProcess.Native.Dispose() }
        elseif ($taskProcess.Process) {
            if (-not $taskSuccess) {
                try { if (-not $taskProcess.Process.HasExited) { $taskProcess.Process.Kill($true); [void]$taskProcess.Process.WaitForExit(5000) } } catch [System.InvalidOperationException] { }
            }
            $taskProcess.Process.Dispose()
        }
    }
    foreach ($taskName in $taskSavedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($taskName,$taskSavedEnvironment[$taskName]) }
    Restore-TaskHostLimits $taskWorker $taskOriginalPriority $taskOriginalAffinity
    $taskReport=[pscustomobject]@{Success=$taskSuccess;Run=$taskRun;FixtureDirectory=$taskDirectory;Guard=$taskGuard;GuardSha256=(Get-FileHash -LiteralPath $taskGuard -Algorithm SHA256).Hash;LogicalProcessors=[Environment]::ProcessorCount;Cases=$taskCases.ToArray();Observations=@($script:TaskObserved.Values);LastJobMembers=@($script:TaskJobMembers.Values);FinishedUtc=[DateTime]::UtcNow.ToString('o');CFreeGiB=[math]::Round((Get-PSDrive C).Free/1GB,2)}
    $taskReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $taskDirectory 'verification.json') -Encoding utf8
    Write-Host ('Verification report: '+(Join-Path $taskDirectory 'verification.json'))
}
if ($taskSuccess) {
    Write-Host ('PASS: '+$taskCases.Count+' verification cases.')
    if (-not $KeepFixtureCache) {
        $taskTrash=[IO.Path]::GetFullPath((Join-Path 'C:\Cache_To_Delete' ('verified-cargo-guard-'+(Get-Date -Format 'yyyy-MM-dd')+'-'+$taskRun)))
        Assert-Task ($taskTrash.StartsWith('C:\Cache_To_Delete\verified-cargo-guard-',[StringComparison]::OrdinalIgnoreCase)) 'Unexpected fixture cache destination.'
        Assert-Task ([IO.Path]::GetPathRoot($taskDirectory) -eq [IO.Path]::GetPathRoot($taskTrash)) 'Fixture cache relocation must stay on C.'
        $taskRelocations=[Collections.Generic.List[object]]::new()
        foreach ($taskFixturePath in (Get-ChildItem -LiteralPath $taskDirectory -Directory)) {
            $taskTarget=[IO.Path]::GetFullPath((Join-Path $taskFixturePath.FullName 'target'))
            if (-not (Test-Path -LiteralPath $taskTarget)) { continue }
            Assert-Task ($taskTarget.StartsWith($taskDirectory+'\',[StringComparison]::OrdinalIgnoreCase)) 'Fixture cache escaped the verification directory.'
            Assert-Task (((Get-Item -LiteralPath $taskTarget).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Fixture cache is a link.'
            $taskEntries=@(Get-ChildItem -LiteralPath $taskTarget -Recurse -Force)
            Assert-Task (@($taskEntries | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -eq 0) 'Fixture cache contains a link.'
            $taskFiles=@($taskEntries | Where-Object { -not $_.PSIsContainer })
            $taskDestination=Join-Path $taskTrash $taskFixturePath.Name
            Assert-Task (-not (Test-Path -LiteralPath $taskDestination)) 'Fixture cache destination already exists.'
            New-Item -ItemType Directory -Path $taskTrash -Force | Out-Null
            Move-Item -LiteralPath $taskTarget -Destination $taskDestination
            $taskRelocations.Add([pscustomobject]@{Source=$taskTarget;ForManualDeletion=$taskDestination;Files=$taskFiles.Count;Bytes=($taskFiles | Measure-Object Length -Sum).Sum})
        }
        $taskRelocations.ToArray() | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $taskDirectory 'fixture-cache-relocation.json') -Encoding utf8
        Write-Host ('Only generated fixture cache was relocated for manual removal: '+$taskTrash)
    }
}
