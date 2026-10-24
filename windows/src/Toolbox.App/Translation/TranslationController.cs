using Toolbox.Core.Translation;

namespace Toolbox.App.Translation;

/// <summary>
/// 翻译请求的调度。**请求序号**是关键：上一次还没回来用户又划了新词，
/// 迟到的旧结果必须丢掉，否则旧译文会覆盖新译文（Mac 版踩过）。
/// </summary>
internal sealed class TranslationController : IDisposable
{
    private readonly TranslationService _service;
    private readonly Func<TranslationSettings> _settings;
    private int _requestId;

    /// <summary>(引擎短名, 错误, 译文)。错误非空时译文为 null。在后台线程触发。</summary>
    public event Action<string, string?, string?>? Completed;

    public TranslationController(Func<TranslationSettings> settings, string? aiKey = null)
        : this(new TranslationService(aiKey: aiKey), settings) { }

    public TranslationController(TranslationService service, Func<TranslationSettings> settings)
    {
        _service = service;
        _settings = settings;
    }

    public void Begin(string text)
    {
        var id = ++_requestId;
        var settings = _settings();

        Task.Run(async () =>
        {
            try
            {
                var result = await _service.TranslateAsync(text, null, settings, CancellationToken.None);
                Finish(id, result.Engine.ShortLabel(), null, result.Text);
            }
            catch (Exception error)
            {
                Finish(id, "", error.Message, null);
            }
        });
    }

    private void Finish(int id, string engine, string? error, string? text)
    {
        if (id != _requestId) return;   // 已经有更新的请求，旧结果作废
        Completed?.Invoke(engine, error, text);
    }

    public void Dispose() => _service.Dispose();
}
