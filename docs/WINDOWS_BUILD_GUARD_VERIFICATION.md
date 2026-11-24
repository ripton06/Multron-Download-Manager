# Windows Cargo guard runtime verification

Verification date: 24 November 2026.

Current status: **passed, 20 verification cases** for the final installed guard. The harness is scripts/test-windows-cargo-guard.ps1. It uses small std-only Rust projects, explicit job overrides, build aliases, observed process trees, and the installed native guard. No GUI automation or full Multron build is involved.

## Final installed version

Command:

    & scripts/install-windows-cargo-guard.ps1 -PythonPath <Python 3.11 or newer>
    & scripts/test-windows-cargo-guard.ps1

Evidence:

    C:\Temp\codex-cargo-guard-verification\2c2fd5776694\verification.json

Verified installed SHA-256:

    FFC77C756D39886A2D68385078506C55196B6685D2E6D2E126DC9CAE4AC69AAC

Both the Cargo PATH proxy and the installed Rustup toolchain Cargo have that hash. On this Windows computer with eight logical processors, all 236 owned process observations reported BelowNormal and affinity 15. They included 86 actual rustc instances and 24 MSVC link.exe instances. The controlled foreign native Cargo PID 1864 was detected across its unrelated executable path; the observer waited 9.086 seconds until it finished. No foreign processes were stopped.

The 20 cases include different-project build/test serialization, string and nested array aliases, a manifest path containing a space, a preserved empty argument, forced color, signed/short-cluster/usize-max/default jobs values, package list mode, preserved publish dry-run and help flags, global value arguments, native alias-introduced directory semantics, isolation from an eight-token external Windows jobserver, install and restore journal recovery, clippy, fix, nested advertised CARGO, active foreign detection/wait, same-tree supervisors, own-root cleanup and observed compiler/linker limits. The publish case checks normalized arguments only; it never executes publish.

The lossless alias resolver separately passed 36 stdlib Python tests, including its real isolated CLI and exact UTF-8/NUL/LF output. Native Cargo 1.97.1 (c980f4866) expands aliases before applying CLI configuration; a real CLI-only alias to version was rejected as no such command, matching the resolver. String aliases use Rust whitespace splitting; array argument boundaries are retained. An alias-introduced -C is parsed by Cargo but does not change its initial directory; valid prefixes are removed without changing that behavior, while missing or repeated values fail closed.

The installer retains original executables and journals. The coordinator also preserved repair sources under C:\Users\HomeComputer\.codex\tools\cargo-build-guard\source. The shared mutex is Global\CodexCargoBuildGuard. New root invocations discard foreign jobserver variables, then force CARGO_BUILD_JOBS=1 and CLI jobs=1. A suspended process enters a restricted named Windows Job before resuming; nested invocations share only an inherited Job whose membership is verified.

The PowerShell installer and verifier restore their caller's original priority and affinity after their build work. Both restore functions were exercised against actual process properties, and both scripts passed syntax parsing. Thus running these maintenance scripts in an existing terminal does not keep its later applications constrained. Fixture cleanup destinations use the run date and an explicit relocation manifest.

Only disposable generated fixture target directories are moved within C after a successful run. Sources, state, logs and verification JSON are retained. Failed harness-only runs stopped on wrapped expected exceptions or Windows path separators; those harness defects were corrected, and their evidence was retained. They did not identify another unrestricted build.

## Previous successful verification

Command:

    & scripts/test-windows-cargo-guard.ps1 -KeepFixtureCache

Evidence:

    C:\Temp\codex-cargo-guard-verification\5e0a0bbaae6a\verification.json

Verified installed guard SHA-256:

    6F57B20502E343E53E453CAEFBC3E3A4AE9B5256B3CE45C05CE7C90DAF3FF9BF

Windows had 8 logical processors. All 146 captured owned process observations reported BelowNormal and affinity 15, including 52 rustc processes and 17 actual MSVC link.exe processes. Some rustc instances were Cargo's compiler probes; the linker observations include real build-script and application links.

| Case | Result |
| --- | --- |
| Two different build/test projects and explicit jobs=8 | Serialized; jobs and NUM_JOBS equal 1 |
| Alias ci = check --jobs 8, plus caller -j8 | Expanded and constrained to 1 |
| clippy -j8 | Passed, constrained to 1 |
| fix -j8 | Passed, constrained to 1 |
| Build script calls its advertised CARGO with -j8 | Guarded nested call passed; separate target avoided Cargo's own file lock |
| Active native Cargo at saved-original path | PID 292 detected; observer waited about 9.7 seconds |
| Following different project while foreign fixture active | Waited until the active fixture finished |
| Same-tree cargo-clippy supervisor | Completed without waiting on its own ancestor |
| Terminate only the owned guard root | Its 5 Job descendants disappeared |

The active-native fixture used the installed restricted-job helper while holding the same shared mutex, jobs=1, BelowNormal and affinity 15. A separate observer exercised ForeignBuilds and WaitForForeignBuilds against its actual PID. No saved-original Cargo was launched bare or without the resource/coordination controls.

The parent and nested build-script state both advertised:

    C:\Users\HomeComputer\.rustup\toolchains\1.97.1-x86_64-pc-windows-msvc\bin\cargo.exe

That path was the installed guard. Both shared Job Global\CodexCargoBuildGuardJob-2288-1a1dae3f5ab84fab82071b8a5bc81f71, CARGO_BUILD_JOBS=1, NUM_JOBS=1, priority 16384 and affinity 15.

Own-root termination was tested without terminating the tree directly: only the owned guard root was killed. Job Global\CodexCargoBuildGuardJob-15812-18dafd3a4eaf4da393b9d41af0353cb7 had members 7368, 10792, 13500, 12468 and 11088 before root termination and none afterward.

A final independent check found the shared mutex acquirable and no active Cargo, native-original Cargo, rustc, linker or guard processes. Other applications and Codex processes were not stopped or reprioritized.

After verification, only generated target directories from the verifier's five runs were renamed within C into:

    C:\Cache_To_Delete\2026-11-24\cargo-guard-verification

The 26 source/destination entries are recorded in C:\Temp\codex-cargo-guard-verification\5e0a0bbaae6a\fixture-cache-relocation.json. Fixture sources, state, JSON and logs remain at their evidence locations. No application release candidates or other projects' caches were moved.

Two harness issues were fixed during verification: process metadata can disappear during an observation, and the original long worktree fixture path produced a 265-character MSVC output path. The harness now handles process-exit races and uses a short C:\Temp fixture root. Top-level observation serialization was recovered from the already saved successful case data, and its variable-shadowing bug was corrected for subsequent runs; no runtime result was invented or rerun to change the outcome.

## Earlier failing implementation evidence

## First runtime result

Command:

    & scripts/test-windows-cargo-guard.ps1 -KeepFixtureCache

The first build script failed with:

    CARGO points to an unguarded original

The installed guard's CARGO environment assignment did not survive to the actual build-script environment as a guarded entry point. This is a real nested-invocation coverage failure, not successful verification of that requirement. The exact full CARGO value was not captured: the failed first fixture wrote its state after the assertion. The generator now writes state before assertions for a future explicitly authorized run.

After native Cargo had exited, the first guard remained alive and held the shared mutex; the second guard continued printing Waiting for the shared Cargo build lock. The harness timed out after 120 seconds. The remaining Job member was not identified before owned-process cleanup; a console-host lifetime dependency is a hypothesis, not a confirmed cause.

## Confirmed observations

The initial attempt captured:

| Process | Observed count | Priority | Affinity |
| --- | ---: | --- | ---: |
| rustc.exe | 4 | BelowNormal | 15 |
| link.exe | 1 | BelowNormal | 15 |
| native/guard Cargo processes | 5 | BelowNormal | 15 |
| build-script-build.exe | 1 | BelowNormal | 15 |

The actual linker observed was Microsoft Visual Studio Build Tools 2022, MSVC 14.44.35207, HostX64\x64\link.exe. The first build script passed its CARGO_BUILD_JOBS=1, NUM_JOBS=1, priority 0x4000 and affinity 15 assertions before rejecting the advertised Cargo path.

Both remaining test guard processes were cleaned up by the harness. No foreign, application or Codex processes were stopped. A subsequent process check found no active Cargo/rustc/linker/guard processes.

## Evidence and remaining checks

Evidence from the failed run is retained at:

    temp/cargo-guard-verification/c5b7bc7a3697497cb437fe6eaa6dde1f/verification.json

The first and second stderr logs in that directory record the failing assertion and shared-mutex wait.

## One authorized narrow diagnostic repeat

The coordinator authorized exactly one 15-second repeat of the updated harness:

    & scripts/test-windows-cargo-guard.ps1 -TimeoutSeconds 15 -KeepFixtureCache

It reproduced the same first failing assertion and then timed out. The recorded build-script state was:

    jobs=1
    workers=1
    priority=16384
    affinity=15
    cargo=C:\Users\HomeComputer\.codex\tools\cargo-build-guard\originals\5753f4e1a07448218b866daf42af1cff\1\cargo.exe
    job=Global\CodexCargoBuildGuardJob-8252-5f724f823bae47b1866c47dbae52c8e1

The last process in that named Job, after native Cargo exited, was **VCTIP.EXE**, PID 7804:

    C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\bin\HostX64\x64\VCTIP.EXE

It had BelowNormal priority and affinity 15. Thus the persisted Job member was the MSVC telemetry helper, rather than the earlier hypothesized console host.

Evidence:

    temp/cargo-guard-verification/19e4458d2cc945eca12fbb00adfc6015/verification.json
    temp/cargo-guard-verification/19e4458d2cc945eca12fbb00adfc6015/guard_first.state

Owned fixture guards were cleaned up by the harness. The shared mutex was independently acquirable afterward. No further repeat or implementation change was performed by the verifier.

## Verification scope

The successful run covers the installed Windows Cargo mechanism and tiny local projects. It does not constitute a new full Multron repository test/build or prove behavior for other toolchains and operating systems. The historical failed runs remain useful evidence of the CARGO-path and MSVC telemetry lifetime defects fixed by the coordinator.
