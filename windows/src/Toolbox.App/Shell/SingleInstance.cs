namespace Toolbox.App.Shell;

/// <summary>
/// 单实例。命名 Mutex 判定"谁是第一个"，命名 EventWaitHandle 让第二个实例能把第一个叫醒。
/// 用 AutoReset 而不是 ManualReset：信号在监听线程启动之前发出也不会丢，而且不会重复触发。
/// 用 Local\ 前缀：同一台机器不同登录会话各跑一个，互不干扰。
/// </summary>
internal sealed class SingleInstance : IDisposable
{
    private const string MutexName = @"Local\Toolbox.Instance";
    private const string ActivateEventName = @"Local\Toolbox.Activate";

    private readonly Mutex? _mutex;
    private readonly EventWaitHandle? _activate;
    private readonly Thread? _listener;
    private bool _disposed;

    public bool IsPrimary { get; }

    /// <summary>第二个实例请求唤醒时触发。**在后台线程上触发**，调用方要自己切到 UI 线程。</summary>
    public event Action? ActivationRequested;

    private SingleInstance(bool primary, Mutex? mutex, EventWaitHandle? activate)
    {
        IsPrimary = primary;
        _mutex = mutex;
        _activate = activate;
        if (!primary) return;

        _listener = new Thread(Listen) { IsBackground = true, Name = "Toolbox 单实例监听" };
        _listener.Start();
    }

    public static SingleInstance Acquire()
    {
        var mutex = new Mutex(true, MutexName, out var createdNew);
        if (!createdNew)
        {
            // 上一个实例还活着。持有权在它那里，这里不要碰 ReleaseMutex。
            mutex.Dispose();
            return new SingleInstance(false, null, null);
        }

        return new SingleInstance(true, mutex,
            new EventWaitHandle(false, EventResetMode.AutoReset, ActivateEventName));
    }

    /// <summary>第二个实例调用：叫醒第一个，然后自己退出。</summary>
    public static void SignalPrimary()
    {
        if (!EventWaitHandle.TryOpenExisting(ActivateEventName, out var handle)) return;
        using (handle) handle.Set();
    }

    private void Listen()
    {
        try
        {
            while (true)
            {
                _activate!.WaitOne();
                try { ActivationRequested?.Invoke(); }
                catch { /* 监听线程不能因为一次回调失败就死掉 */ }
            }
        }
        catch (ObjectDisposedException) { }
        catch (ThreadInterruptedException) { }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        // 释放后再 Dispose 事件：否则监听线程会先拿到 ObjectDisposedException
        try { _activate?.Dispose(); } catch { }
        try { _mutex?.ReleaseMutex(); } catch { }
        _mutex?.Dispose();
    }
}
