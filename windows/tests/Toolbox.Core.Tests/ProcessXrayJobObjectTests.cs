using System.Diagnostics;
using System.Runtime.InteropServices;
using Xunit;
using Toolbox.Core.Proxy;

namespace Toolbox.Core.Tests;

/// <summary>
/// ProcessXray 的进程生存期绑定（BUG-006 回归测试）。
/// App 死亡（崩溃/任务管理器结束/更新硬重启）时，xray 子进程必须被系统带走，
/// 否则成为孤儿进程继续占 10808/10809，下次启动引擎 bind 失败。
///
/// Job Object + JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE 是 Windows 唯一可靠的绑定：
/// 持有 job 句柄的本进程死亡 → 系统关闭句柄 → job 内所有进程被杀。
/// 这里用真实进程测：Launch 后子进程必须在本实例创建的 job 里且限额带 kill-on-close。
/// （不能只断言 IsProcessInJob —— testhost 宿主自身常在 job 里，子进程会继承污染断言。）
/// 「父进程死亡 → 子进程被带走」的完整验证在 App 级真机 E2E：强杀 App 断言 xray 消失。
/// </summary>
public sealed class ProcessXrayJobObjectTests : IDisposable
{
    private static readonly string WorkingDir = Path.Combine(Path.GetTempPath(), $"jobtest-{Guid.NewGuid():N}");
    private readonly ProcessXray _xray = new("ping.exe", "-n 60 127.0.0.1", WorkingDir);

    public ProcessXrayJobObjectTests() => Directory.CreateDirectory(WorkingDir);

    [Fact]
    public void LaunchedChildIsInKillOnCloseJob()
    {
        _xray.Launch();

        Assert.NotEqual(IntPtr.Zero, _xray.JobHandle);

        // 限额必须是 KILL_ON_JOB_CLOSE —— 这是「句柄关闭时杀光 job 内进程」的开关
        var info = new Native.JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        Assert.True(Native.QueryInformationJobObject(_xray.JobHandle, Native.JobObjectExtendedLimitInformation,
            ref info, (uint)Marshal.SizeOf<Native.JOBOBJECT_EXTENDED_LIMIT_INFORMATION>(), out _),
            "QueryInformationJobObject 调用失败");
        Assert.True((info.BasicLimitInformation.LimitFlags & Native.JobObjectLimitKillOnJobClose) != 0,
            "Job 缺少 JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE —— 父进程死亡时不会带走 xray（BUG-006）");

        // 子进程必须确实被 assign 进了**本实例的** job（排除宿主 job 继承的假阳性）
        var child = ChildProcess();
        Assert.NotNull(child);
        try
        {
            Assert.True(Native.IsProcessInJob(child.Handle, _xray.JobHandle, out var inOurJob),
                "IsProcessInJob 调用失败");
            Assert.True(inOurJob, "子进程没有被放进 ProcessXray 创建的 Job（BUG-006）");
        }
        finally
        {
            child.Dispose();
        }
    }

    [Fact]
    public void KillStillTerminatesChild()
    {
        _xray.Launch();

        var child = ChildProcess();
        Assert.NotNull(child);
        try
        {
            _xray.Kill();
            Assert.True(child.WaitForExit(10_000), "主动 Kill 后子进程应立刻退出");
        }
        finally
        {
            child.Dispose();
        }
    }

    private static Process? ChildProcess() => Process.GetProcessesByName("ping").FirstOrDefault();

    public void Dispose()
    {
        try { _xray.Kill(); } catch { }
        try { Directory.Delete(WorkingDir, true); } catch { }
    }

    private static class Native
    {
        public const int JobObjectExtendedLimitInformation = 9;
        public const uint JobObjectLimitKillOnJobClose = 0x2000;

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool QueryInformationJobObject(IntPtr job, int infoClass,
            ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint size, out uint returned);

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct IO_COUNTERS
        {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }
    }
}
