using System.Diagnostics;

namespace Toolbox.Core.Proxy;

/// <summary>
/// 被托管的进程。抽象出来是为了让「崩溃 → 退避重启 → 超限放弃」这套生命周期
/// 能用假进程同步测，而不是靠真 sleep 和真 xray。
/// </summary>
public interface IXrayProcess
{
    bool IsRunning { get; }
    void Launch();
    void Kill();
    /// <summary>进程退出时回调（无论正常还是崩溃）。由 runner 决定算不算异常退出。</summary>
    Action? OnExit { get; set; }
}

/// <summary>真进程：包一个 Process 跑 `xray run -c config.json`。</summary>
public sealed class ProcessXray : IXrayProcess
{
    private readonly string _executable;
    private readonly string _arguments;
    private readonly string _workingDirectory;
    private System.Diagnostics.Process? _process;

    public ProcessXray(string executable, string arguments, string workingDirectory)
    {
        _executable = executable;
        _arguments = arguments;
        _workingDirectory = workingDirectory;
    }

    public bool IsRunning => _process is { HasExited: false };

    public Action? OnExit { get; set; }

    /// <summary>主动 Kill 后 Exited 仍会在threadpool上触发，用这个标志把它当噪声丢弃。</summary>
    private volatile bool _killed;

    public void Launch()
    {
        _killed = false;
        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = _executable,
                Arguments = _arguments,
                WorkingDirectory = _workingDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            },
            EnableRaisingEvents = true,
        };
        process.Exited += (_, _) =>
        {
            // Exited 在线程池触发；主动 Kill 的退出由 runner 的标志忽略
            if (_killed) return;
            OnExit?.Invoke();
        };
        if (!process.Start()) throw new InvalidOperationException("进程启动失败");
        _process = process;
    }

    public void Kill()
    {
        _killed = true;
        if (_process is { HasExited: false } process) process.Kill(entireProcessTree: true);
        _process = null;
    }
}

/// <summary>
/// 托管单个 xray 进程：启动/停止/改配置重启/崩溃退避重启/超限放弃。
///
/// 生命周期必须收口在这里，别处不许再各自起 xray —— 否则会出现两个进程抢同一
/// 个 SOCKS 端口、或 App 退出后留孤儿继续占端口（下次启动直接 bind 失败）。
/// 所有状态变化都通过锁串行化（退出回调来自线程池）。
/// </summary>
public sealed class XrayRunner
{
    public enum State
    {
        Stopped,
        Running,
        Failed,
    }

    private readonly object _gate = new();
    private readonly Func<IXrayProcess> _factory;
    private readonly string _configFile;
    private readonly Action<Action> _schedule;   // 退避延迟；测试里立即执行
    private readonly int _maxAttempts;
    private IXrayProcess? _process;
    private int _attempts;
    private bool _stoppingIntentionally;
    private State _state = State.Stopped;

    public XrayRunner(Func<IXrayProcess> factory, string configFile,
                      Action<Action>? schedule = null, int maxAttempts = 5)
    {
        _factory = factory;
        _configFile = configFile;
        _schedule = schedule ?? (work => System.Threading.Tasks.Task.Delay(2000).ContinueWith(_ => work()));
        _maxAttempts = maxAttempts;
    }

    public State CurrentState
    {
        get { lock (_gate) return _state; }
    }

    public bool IsRunning
    {
        get { lock (_gate) return _state == State.Running; }
    }

    public string? FailureMessage { get; private set; }

    /// <summary>状态变化回调（线程池线程上触发，UI 侧自行调度）。</summary>
    public Action<XrayRunner.State, string?>? OnStateChange { get; set; }

    /// <summary>写配置并启动（幂等：已在跑则视为重启，先停后起）。</summary>
    public void Start(string config)
    {
        lock (_gate)
        {
            if (_state == State.Running) StopInternal();
            if (!WriteConfig(config))
            {
                Transition(State.Failed, FailureMessage);
                return;
            }
            LaunchProcess();
        }
    }

    /// <summary>改配置 → 重启。</summary>
    public void Update(string config)
    {
        lock (_gate)
        {
            if (_state == State.Stopped)
            {
                Start(config);
                return;
            }
            _stoppingIntentionally = true;
            _process?.Kill();
            _stoppingIntentionally = false;
            _attempts = 0;
            if (!WriteConfig(config))
            {
                Transition(State.Failed, FailureMessage);
                return;
            }
            LaunchProcess(resetAttempts: true);
        }
    }

    public void Stop()
    {
        lock (_gate) StopInternal();
    }

    private void StopInternal()
    {
        _stoppingIntentionally = true;
        _process?.Kill();
        _process = null;
        _stoppingIntentionally = false;
        _attempts = 0;
        FailureMessage = null;
        Transition(State.Stopped, null);
    }

    private bool WriteConfig(string config)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_configFile)!);
            File.WriteAllText(_configFile, config);
            return true;
        }
        catch (Exception error)
        {
            FailureMessage = $"写 config 失败: {error.Message}";
            return false;
        }
    }

    private void LaunchProcess(bool resetAttempts = false)
    {
        var process = _factory();
        process.OnExit = () => HandleExit(process);
        try
        {
            process.Launch();
        }
        catch (Exception error)
        {
            FailureMessage = $"启动 xray 失败: {error.Message}";
            Transition(State.Failed, FailureMessage);
            return;
        }
        _process = process;
        // 退避重启不清零：连续崩溃要能累积到放弃阈值
        if (resetAttempts) _attempts = 0;
        FailureMessage = null;
        Transition(State.Running, null);
    }

    private void HandleExit(IXrayProcess process)
    {
        lock (_gate)
        {
            // 主动 stop/update 触发的退出，不当崩溃处理
            if (_stoppingIntentionally) return;
            if (!ReferenceEquals(process, _process)) return;   // 旧进程的迟到回调，忽略
            _process = null;
            _attempts++;
            if (_attempts >= _maxAttempts)
            {
                FailureMessage = $"xray 连续崩溃 {_attempts} 次，已停止重试";
                Transition(State.Failed, FailureMessage);
                return;
            }

            // 仍算运行中（正在退避重启）
            Transition(State.Running, null);
            _schedule(() =>
            {
                lock (_gate)
                {
                    if (_stoppingIntentionally || _process != null) return;
                    if (!File.Exists(_configFile)) return;
                    LaunchProcess();
                }
            });
        }
    }

    private void Transition(State state, string? message)
    {
        _state = state;
        OnStateChange?.Invoke(state, message);
    }
}
