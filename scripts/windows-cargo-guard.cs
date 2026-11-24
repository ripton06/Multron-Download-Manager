using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

[assembly: System.Reflection.AssemblyTitle("Codex Cargo Build Guard")]
[assembly: System.Reflection.AssemblyProduct("Codex Cargo Build Guard")]
[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]

public sealed class CargoBuildGuard
{
    public const string MutexName = @"Global\CodexCargoBuildGuard";
    public const string LauncherPrefix = @"Global\CodexCargoBuildGuardLauncher-";
    public const string JobVariable = "CODEX_CARGO_BUILD_GUARD_JOB";
    public const string JobsVariable = "CARGO_BUILD_JOBS";
    public const uint BelowNormal = 0x4000;
    private static readonly string GuardDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "tools", "cargo-build-guard");

    public static int Main(string[] arguments)
    {
        try
        {
            ApplyLauncherLimits();
            using (var registration = new EventWaitHandle(false, EventResetMode.ManualReset, LauncherPrefix + Process.GetCurrentProcess().Id))
            {
                if (arguments.Length == 1 && arguments[0] == "--guard-status")
                {
                    PrintStatus();
                    return 0;
                }
                Environment.SetEnvironmentVariable(JobsVariable, "1");
                Environment.SetEnvironmentVariable("CARGO", Process.GetCurrentProcess().MainModule.FileName);
                var inheritedJob = OpenInheritedJob();
                if (inheritedJob != IntPtr.Zero)
                {
                    Child child;
                    try
                    {
                        var executable = ResolveOriginal();
                        child = StartInJob(executable, PrepareArguments(executable, arguments, inheritedJob), inheritedJob);
                    }
                    finally { CloseHandle(inheritedJob); }
                    return WaitForChild(child, IntPtr.Zero, false);
                }
                Environment.SetEnvironmentVariable("CARGO_MAKEFLAGS", null);
                Environment.SetEnvironmentVariable("MAKEFLAGS", null);
                Environment.SetEnvironmentVariable("MFLAGS", null);
                using (var mutex = new Mutex(false, MutexName))
                {
                    Acquire(mutex);
                    try
                    {
                        WaitForForeignBuilds();
                        var executable = ResolveOriginal();
                        var jobName = @"Global\CodexCargoBuildGuardJob-" + Process.GetCurrentProcess().Id + "-" + Guid.NewGuid().ToString("N");
                        var job = CreateRestrictedJob(jobName);
                        try
                        {
                            Environment.SetEnvironmentVariable(JobVariable, jobName);
                            return RunInJob(executable, PrepareArguments(executable, arguments, job), job, true);
                        }
                        finally { CloseHandle(job); }
                    }
                    finally { mutex.ReleaseMutex(); }
                }
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("[cargo-guard] " + error.Message);
            return 70;
        }
    }

    public static void ApplyLauncherLimits()
    {
        var process = Process.GetCurrentProcess();
        process.PriorityClass = ProcessPriorityClass.BelowNormal;
        var mask = AffinityMask();
        if (!SetProcessAffinityMask(process.Handle, mask)) throw Win32("Could not limit launcher affinity");
    }

    public static UIntPtr AffinityMask()
    {
        UIntPtr current;
        UIntPtr system;
        if (!GetProcessAffinityMask(GetCurrentProcess(), out current, out system)) throw Win32("Could not read processor affinity");
        var bits = system.ToUInt64();
        var count = 0;
        for (var value = bits; value != 0; value >>= 1) count += (int)(value & 1);
        var limited = count > 4 ? 15UL : current.ToUInt64();
        if ((limited & bits) != limited || limited == 0) throw new InvalidOperationException("The first four logical processors are unavailable; refusing an unrestricted build");
        return new UIntPtr(limited);
    }

    private static string ResolveOriginal()
    {
        var executable = Path.GetFullPath(Process.GetCurrentProcess().MainModule.FileName);
        var routes = Path.Combine(GuardDirectory, "routes.tsv");
        string fallback = null;
        foreach (var line in File.ReadAllLines(routes))
        {
            var pair = line.Split('\t');
            if (pair.Length != 2) continue;
            if (fallback == null) fallback = pair[1];
            if (String.Equals(pair[0], executable, StringComparison.OrdinalIgnoreCase))
            {
                if (!File.Exists(pair[1])) throw new FileNotFoundException("The saved Cargo executable is missing", pair[1]);
                return pair[1];
            }
        }
        if (Path.GetFileName(executable).Equals("cargo-build-guard.exe", StringComparison.OrdinalIgnoreCase) && fallback != null) return fallback;
        throw new InvalidOperationException("This Cargo launcher is not registered; run install-windows-cargo-guard.ps1");
    }

    public static string[] LimitJobs(string[] arguments)
    {
        var commands = new HashSet<string>(StringComparer.Ordinal) { "build", "b", "check", "c", "test", "t", "clippy", "fix", "bench", "run", "r", "doc", "d", "rustc", "rustdoc", "install", "package", "publish" };
        var command = CommandIndex(arguments);
        if (command < 0 || !commands.Contains(arguments[command])) return arguments;
        var output = new List<string>();
        for (var i = 0; i <= command; i++) output.Add(arguments[i]);
        output.Add("-j");
        output.Add("1");
        var passthrough = false;
        for (var i = command + 1; i < arguments.Length; i++)
        {
            var argument = arguments[i];
            if (argument == "--") passthrough = true;
            if (!passthrough)
            {
                if (argument == "-j" || argument == "--jobs") { if (i + 1 < arguments.Length) i++; continue; }
                if (argument.StartsWith("--jobs=", StringComparison.Ordinal)) continue;
                string prefix;
                bool consumesValue;
                if (JobCluster(argument, out prefix, out consumesValue))
                {
                    if (prefix.Length > 1) output.Add(prefix);
                    if (consumesValue && i + 1 < arguments.Length) i++;
                    continue;
                }
            }
            output.Add(argument);
        }
        return output.ToArray();
    }

    private static string[] PrepareArguments(string executable, string[] arguments, IntPtr job)
    {
        var direct = new HashSet<string>(StringComparer.Ordinal) { "build", "check", "test", "fix", "bench", "run", "doc", "rustc", "rustdoc", "install", "package", "publish", "clean", "fetch", "new", "init", "update", "search", "uninstall", "metadata", "tree", "verify-project", "generate-lockfile", "locate-project", "login", "logout", "owner", "add", "remove", "vendor", "version", "help", "report", "yank", "info", "read-manifest" };
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var firstCommand = CommandIndex(arguments);
        var originalGlobals = new List<string>();
        for (var i = 0; i < firstCommand; i++) originalGlobals.Add(arguments[i]);
        var directoryArguments = 0;
        WithoutAliasDirectory(originalGlobals.ToArray(), ref directoryArguments);
        for (var depth = 0; depth < 16; depth++)
        {
            var index = CommandIndex(arguments);
            if (index < 0 || direct.Contains(arguments[index])) return LimitJobs(arguments);
            var name = arguments[index];
            if (!seen.Add(name)) throw new InvalidOperationException("Recursive Cargo alias: " + name);
            var pythonFile = Path.Combine(GuardDirectory, "python-path.txt");
            var resolver = Path.Combine(GuardDirectory, "cargo-alias-resolver.py");
            if (!File.Exists(pythonFile) || !File.Exists(resolver)) throw new InvalidOperationException("The lossless Cargo alias resolver is missing; reinstall the build guard");
            var python = File.ReadAllText(pythonFile).Trim();
            if (!File.Exists(python)) throw new FileNotFoundException("The alias resolver's Python runtime is unavailable", python);
            var resolverArguments = new List<string> { "-I", "-X", "utf8", resolver, name };
            resolverArguments.AddRange(originalGlobals);
            var resolved = CaptureOutput(python, resolverArguments.ToArray(), job);
            if (resolved == "N\n" || resolved == "S\n") return LimitJobs(arguments);
            if (!resolved.StartsWith("A\n", StringComparison.Ordinal) || !resolved.EndsWith("\0", StringComparison.Ordinal)) throw new InvalidOperationException("Invalid response from Cargo alias resolver");
            var expansion = resolved.Substring(2, resolved.Length - 3).Split('\0');
            if (expansion.Length == 0) throw new InvalidOperationException("Empty Cargo alias: " + name);
            var aliasBody = new List<string>(expansion);
            for (var i = index + 1; i < arguments.Length; i++) aliasBody.Add(arguments[i]);
            var expanded = new List<string>();
            for (var i = 0; i < index; i++) expanded.Add(arguments[i]);
            expanded.AddRange(WithoutAliasDirectory(aliasBody.ToArray(), ref directoryArguments));
            arguments = expanded.ToArray();
        }
        throw new InvalidOperationException("Cargo alias nesting exceeds the guarded limit");
    }

    private static int CommandIndex(string[] arguments)
    {
        for (var i = 0; i < arguments.Length; i++)
        {
            var argument = arguments[i];
            if (argument == "--") return i + 1 < arguments.Length ? i + 1 : -1;
            if (argument == "--color" || argument == "--config" || argument == "--explain") { i++; continue; }
            if (argument.StartsWith("--", StringComparison.Ordinal) || argument.StartsWith("+", StringComparison.Ordinal)) continue;
            if (!argument.StartsWith("-", StringComparison.Ordinal)) return i;
            var offset = ShortValueOffset(argument);
            if (offset > 0 && offset + 1 == argument.Length) i++;
        }
        return -1;
    }

    private static int ShortValueOffset(string argument)
    {
        if (argument.Length < 2 || argument[0] != '-' || argument[1] == '-') return -1;
        for (var offset = 1; offset < argument.Length; offset++)
        {
            var flag = argument[offset];
            if (flag == 'C' || flag == 'Z') return offset;
            if (flag != 'q' && flag != 'v' && flag != 'h' && flag != 'V') break;
        }
        return -1;
    }

    private static string[] WithoutAliasDirectory(string[] arguments, ref int directoryArguments)
    {
        var output = new List<string>();
        var command = CommandIndex(arguments);
        var prefixLength = command < 0 ? arguments.Length : command;
        for (var i = 0; i < prefixLength; i++)
        {
            var argument = arguments[i];
            if (argument == "--color" || argument == "--config" || argument == "--explain")
            {
                output.Add(argument);
                if (i + 1 < prefixLength) output.Add(arguments[++i]);
                continue;
            }
            var offset = ShortValueOffset(argument);
            if (offset < 0) { output.Add(argument); continue; }
            var separate = offset + 1 == argument.Length;
            if (argument[offset] == 'Z')
            {
                output.Add(argument);
                if (separate && i + 1 < prefixLength) output.Add(arguments[++i]);
                continue;
            }
            if (++directoryArguments > 1) throw new InvalidOperationException("Repeated -C arguments in a Cargo alias cannot be expanded faithfully");
            if (separate)
            {
                if (i + 1 >= prefixLength || arguments[i + 1].StartsWith("-", StringComparison.Ordinal)) throw new InvalidOperationException("A Cargo alias has a missing -C argument");
                i++;
            }
            var retainedFlags = argument.Substring(0, offset);
            if (retainedFlags.Length > 1) output.Add(retainedFlags);
        }
        for (var i = prefixLength; i < arguments.Length; i++) output.Add(arguments[i]);
        return output.ToArray();
    }

    private static bool JobCluster(string argument, out string prefix, out bool consumesValue)
    {
        prefix = "";
        consumesValue = false;
        if (argument.Length < 3 || argument[0] != '-' || argument[1] == '-') return false;
        for (var i = 1; i < argument.Length; i++)
        {
            if (argument[i] == 'j')
            {
                var number = argument.Substring(i + 1).TrimStart('=');
                if (number.Length != 0 && number != "default")
                {
                    var start = number[0] == '+' || number[0] == '-' ? 1 : 0;
                    if (start == number.Length) return false;
                    for (var offset = start; offset < number.Length; offset++)
                        if (number[offset] < '0' || number[offset] > '9') return false;
                }
                prefix = argument.Substring(0, i);
                consumesValue = number.Length == 0;
                return true;
            }
            if (argument[i] != 'q' && argument[i] != 'v' && argument[i] != 'r' && argument[i] != 'f' && argument[i] != 'l' && argument[i] != 'n' && argument[i] != 'h') return false;
        }
        return false;
    }

    private static void Acquire(Mutex mutex)
    {
        var reported = DateTime.MinValue;
        while (true)
        {
            try { if (mutex.WaitOne(250)) return; }
            catch (AbandonedMutexException) { return; }
            if ((DateTime.UtcNow - reported).TotalSeconds >= 5)
            {
                Console.Error.WriteLine("[cargo-guard] Waiting for the shared Cargo build lock");
                reported = DateTime.UtcNow;
            }
        }
    }

    public static void WaitForForeignBuilds()
    {
        var reported = DateTime.MinValue;
        while (true)
        {
            var active = ForeignBuilds();
            if (active.Count == 0) return;
            if ((DateTime.UtcNow - reported).TotalSeconds >= 5)
            {
                Console.Error.WriteLine("[cargo-guard] Waiting for active Cargo/Rust processes: " + String.Join(", ", active.ToArray()));
                reported = DateTime.UtcNow;
            }
            Thread.Sleep(250);
        }
    }

    public static List<string> ForeignBuilds()
    {
        var active = new List<string>();
        var processes = Snapshot();
        var parents = new Dictionary<uint, uint>();
        foreach (var process in processes) parents[process.Id] = process.Parent;
        var ancestors = new HashSet<uint>();
        var id = (uint)Process.GetCurrentProcess().Id;
        uint parent;
        while (parents.TryGetValue(id, out parent) && parent != 0 && ancestors.Add(parent)) id = parent;
        foreach (var process in processes)
        {
            var name = Path.GetFileNameWithoutExtension(process.Name);
            if (!(name.Equals("cargo", StringComparison.OrdinalIgnoreCase) || name.Equals("cargo-native-original", StringComparison.OrdinalIgnoreCase) || name.Equals("cargo-clippy", StringComparison.OrdinalIgnoreCase) || name.Equals("rustc", StringComparison.OrdinalIgnoreCase) || name.Equals("rustdoc", StringComparison.OrdinalIgnoreCase) || name.Equals("clippy-driver", StringComparison.OrdinalIgnoreCase))) continue;
            if (IsLauncher(process.Id) || ancestors.Contains(process.Id)) continue;
            active.Add(process.Name + " (" + process.Id + ")");
        }
        return active;
    }

    public static bool IsLauncher(uint id)
    {
        try { using (var registered = EventWaitHandle.OpenExisting(LauncherPrefix + id)) return true; }
        catch (WaitHandleCannotBeOpenedException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    private static IntPtr OpenInheritedJob()
    {
        var name = Environment.GetEnvironmentVariable(JobVariable);
        if (String.IsNullOrEmpty(name)) return IntPtr.Zero;
        var job = OpenJobObject(5, false, name);
        if (job == IntPtr.Zero) return IntPtr.Zero;
        bool member;
        if (!IsProcessInJob(GetCurrentProcess(), job, out member) || !member) { CloseHandle(job); return IntPtr.Zero; }
        return job;
    }

    public static IntPtr CreateRestrictedJob(string name)
    {
        var job = CreateJobObject(IntPtr.Zero, name);
        if (job == IntPtr.Zero) throw Win32("Could not create a restricted build job");
        var limits = new ExtendedLimits();
        limits.Basic.LimitFlags = 0x10 | 0x20 | 0x2000;
        limits.Basic.Affinity = AffinityMask();
        limits.Basic.PriorityClass = BelowNormal;
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits))))
        {
            var error = Win32("Could not limit the complete build process tree");
            CloseHandle(job);
            throw error;
        }
        return job;
    }

    public static void CloseBuildJob(IntPtr job)
    {
        if (job != IntPtr.Zero) CloseHandle(job);
    }

    public static int RunInJob(string executable, string[] arguments, IntPtr job, bool waitForChildren)
    {
        return WaitForChild(StartInJob(executable, arguments, job), job, waitForChildren);
    }

    private static int WaitForChild(Child child, IntPtr job, bool waitForChildren)
    {
        try
        {
            if (WaitForSingleObject(child.Process, 0xFFFFFFFF) == 0xFFFFFFFF) throw Win32("Could not wait for Cargo");
            uint code;
            if (!GetExitCodeProcess(child.Process, out code)) throw Win32("Could not read Cargo's exit code");
            if (waitForChildren)
            {
                while (true)
                {
                    var accounting = new JobAccounting();
                    if (!QueryInformationJobObject(job, 1, ref accounting, (uint)Marshal.SizeOf(typeof(JobAccounting)), IntPtr.Zero)) throw Win32("Could not wait for the remaining build children");
                    if (accounting.ActiveProcesses == 0) break;
                    if (OnlyPrivateTelemetryRemains(job, accounting.ActiveProcesses))
                    {
                        if (!TerminateJobObject(job, code)) throw Win32("Could not close the build's private MSVC telemetry helper");
                    }
                    Thread.Sleep(100);
                }
            }
            return unchecked((int)code);
        }
        finally { child.Dispose(); }
    }

    private static bool OnlyPrivateTelemetryRemains(IntPtr job, uint active)
    {
        var capacity = Math.Max(8, (int)active + 4);
        var size = 8 + IntPtr.Size * capacity;
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            uint returned;
            if (!QueryInformationJobObject(job, 3, buffer, (uint)size, out returned)) return false;
            var count = Marshal.ReadInt32(buffer, 4);
            if (count == 0 || count != active || count > capacity) return false;
            var owner = (uint)Process.GetCurrentProcess().Id;
            var entries = Snapshot();
            var ancestors = new HashSet<uint>();
            var cursor = owner;
            while (true)
            {
                var entry = entries.Find(value => value.Id == cursor);
                if (entry.Parent == 0 || !ancestors.Add(entry.Parent)) break;
                cursor = entry.Parent;
            }
            for (var i = 0; i < count; i++)
            {
                var id = (uint)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size).ToInt64();
                if (id == owner || ancestors.Contains(id)) return false;
                try
                {
                    using (var process = Process.GetProcessById((int)id))
                    {
                        var path = process.MainModule.FileName;
                        if (!Path.GetFileName(path).Equals("VCTIP.EXE", StringComparison.OrdinalIgnoreCase) || path.IndexOf(@"\Microsoft Visual Studio\", StringComparison.OrdinalIgnoreCase) < 0 || path.IndexOf(@"\VC\Tools\MSVC\", StringComparison.OrdinalIgnoreCase) < 0) return false;
                        bool member;
                        if (!IsProcessInJob(process.Handle, job, out member) || !member) return false;
                    }
                }
                catch (ArgumentException) { return false; }
                catch (InvalidOperationException) { return false; }
                catch (System.ComponentModel.Win32Exception) { return false; }
            }
            return true;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static Child StartInJob(string executable, string[] arguments, IntPtr job)
    {
        return StartInJob(executable, arguments, job, IntPtr.Zero);
    }

    private static Child StartInJob(string executable, string[] arguments, IntPtr job, IntPtr output)
    {
        var command = new StringBuilder(Quote(executable));
        foreach (var argument in arguments) command.Append(" ").Append(Quote(argument));
        var startup = new StartupInfo();
        startup.Size = (uint)Marshal.SizeOf(typeof(StartupInfo));
        startup.Flags = 0x100;
        startup.Input = GetStdHandle(-10);
        startup.Output = output == IntPtr.Zero ? GetStdHandle(-11) : output;
        startup.Error = GetStdHandle(-12);
        ProcessInformation created;
        var creationFlags = 0x4 | BelowNormal;
        if (GetConsoleWindow() == IntPtr.Zero) creationFlags |= 0x08000000;
        if (!CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, true, creationFlags, IntPtr.Zero, null, ref startup, out created)) throw Win32("Could not start Cargo in suspended state");
        var child = new Child(created);
        try
        {
            bool member;
            if (!IsProcessInJob(child.Process, job, out member)) throw Win32("Could not inspect the new build process");
            if (!member && !AssignProcessToJobObject(job, child.Process)) throw Win32("Could not assign the build process to the restricted job");
            if (!SetProcessAffinityMask(child.Process, AffinityMask())) throw Win32("Could not set build affinity before startup");
            if (!SetPriorityClass(child.Process, BelowNormal)) throw Win32("Could not set build priority before startup");
            if (ResumeThread(created.Thread) == 0xFFFFFFFF) throw Win32("Could not resume the restricted build");
            CloseHandle(created.Thread);
            child.Thread = IntPtr.Zero;
            return child;
        }
        catch
        {
            TerminateProcess(child.Process, 70);
            child.Dispose();
            throw;
        }
    }

    private static string CaptureOutput(string executable, string[] arguments, IntPtr job)
    {
        var attributes = new SecurityAttributes();
        attributes.Size = (uint)Marshal.SizeOf(typeof(SecurityAttributes));
        attributes.Inherit = true;
        IntPtr read;
        IntPtr write;
        if (!CreatePipe(out read, out write, ref attributes, 0)) throw Win32("Could not capture Cargo alias definitions");
        Child child = null;
        try
        {
            if (!SetHandleInformation(read, 1, 0)) throw Win32("Could not protect the alias output pipe");
            child = StartInJob(executable, arguments, job, write);
            CloseHandle(write);
            write = IntPtr.Zero;
            string value;
            using (var handle = new Microsoft.Win32.SafeHandles.SafeFileHandle(read, true))
            {
                read = IntPtr.Zero;
                using (var stream = new FileStream(handle, FileAccess.Read))
                using (var reader = new StreamReader(stream, Encoding.UTF8)) value = reader.ReadToEnd();
            }
            if (WaitForSingleObject(child.Process, 0xFFFFFFFF) == 0xFFFFFFFF) throw Win32("Could not wait for alias discovery");
            uint code;
            if (!GetExitCodeProcess(child.Process, out code) || code != 0) throw new InvalidOperationException("Cargo alias discovery failed; the requested command was not started");
            return value;
        }
        finally { if (child != null) child.Dispose(); if (read != IntPtr.Zero) CloseHandle(read); if (write != IntPtr.Zero) CloseHandle(write); }
    }

    public static string Quote(string argument)
    {
        var output = new StringBuilder("\"");
        var slashes = 0;
        foreach (var character in argument)
        {
            if (character == '\\') { slashes++; continue; }
            if (character == '"') output.Append('\\', slashes * 2 + 1);
            else output.Append('\\', slashes);
            output.Append(character);
            slashes = 0;
        }
        output.Append('\\', slashes * 2).Append('"');
        return output.ToString();
    }

    public static List<ProcessEntry> Snapshot()
    {
        var snapshot = CreateToolhelp32Snapshot(2, 0);
        if (snapshot == new IntPtr(-1)) throw Win32("Could not inspect active builds across projects");
        try
        {
            var output = new List<ProcessEntry>();
            var entry = new ProcessEntry();
            entry.Size = (uint)Marshal.SizeOf(typeof(ProcessEntry));
            if (!Process32First(snapshot, ref entry)) throw Win32("Could not enumerate active builds");
            do { output.Add(entry); entry.Size = (uint)Marshal.SizeOf(typeof(ProcessEntry)); } while (Process32Next(snapshot, ref entry));
            return output;
        }
        finally { CloseHandle(snapshot); }
    }

    private static void PrintStatus()
    {
        var process = Process.GetCurrentProcess();
        Console.WriteLine("Priority=" + process.PriorityClass + " Affinity=" + process.ProcessorAffinity.ToInt64() + " CARGO_BUILD_JOBS=1 Mutex=" + MutexName);
        Console.WriteLine("Active builds: " + String.Join(", ", ForeignBuilds().ToArray()));
    }

    private static Exception Win32(string message) { return new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), message); }

    public sealed class Child : IDisposable
    {
        public IntPtr Process;
        public IntPtr Thread;
        public uint Id;
        public Child(ProcessInformation information) { Process = information.Process; Thread = information.Thread; Id = information.Id; }
        public void Dispose() { if (Thread != IntPtr.Zero) { CloseHandle(Thread); Thread = IntPtr.Zero; } if (Process != IntPtr.Zero) { CloseHandle(Process); Process = IntPtr.Zero; } }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct ProcessEntry
    {
        public uint Size;
        public uint Usage;
        public uint Id;
        public UIntPtr Heap;
        public uint Module;
        public uint Threads;
        public uint Parent;
        public int Priority;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ProcessInformation { public IntPtr Process; public IntPtr Thread; public uint Id; public uint ThreadId; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public uint Size;
        public string Reserved;
        public string Desktop;
        public string Title;
        public uint X, Y, Width, Height, XCount, YCount, Fill, Flags;
        public ushort Show, ReservedSize;
        public IntPtr ReservedBytes, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits { public long ProcessTime, JobTime; public uint LimitFlags; public UIntPtr MinimumWorkingSet, MaximumWorkingSet; public uint ActiveLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits { public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
    [StructLayout(LayoutKind.Sequential)]
    private struct JobAccounting { public long UserTime, KernelTime, PeriodUserTime, PeriodKernelTime; public uint PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses; }
    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes { public uint Size; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }

    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessAffinityMask(IntPtr process, out UIntPtr current, out UIntPtr system);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetProcessAffinityMask(IntPtr process, UIntPtr mask);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetPriorityClass(IntPtr process, uint priority);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr OpenJobObject(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int type, ref ExtendedLimits information, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool QueryInformationJobObject(IntPtr job, int type, ref JobAccounting information, uint size, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool QueryInformationJobObject(IntPtr job, int type, IntPtr information, uint size, out uint returned);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool member);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GetStdHandle(int id);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CreatePipe(out IntPtr read, out IntPtr write, ref SecurityAttributes attributes, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateProcess(string executable, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation information);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint id);
    [DllImport("kernel32.dll", EntryPoint = "Process32FirstW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Process32First(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", EntryPoint = "Process32NextW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry entry);
}
