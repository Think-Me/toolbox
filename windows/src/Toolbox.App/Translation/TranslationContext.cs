using Toolbox.Core.Translation;

namespace Toolbox.App.Translation;

/// <summary>翻译浮窗需要的全部外部能力。收成一个对象，窗口不碰全局状态。</summary>
internal sealed class TranslationContext
{
    /// <summary>每次读都拿最新设置（引擎/目标语言可能刚在别处被改过）。</summary>
    public required Func<TranslationSettings> Settings { get; init; }

    /// <summary>读当前选中的文本，null 表示没有选区。</summary>
    public required Func<string?> ReadSelection { get; init; }

    /// <summary>设置有改动（比如浮窗里切了引擎）后由浮窗调用，落盘。</summary>
    public required Action<TranslationSettings> PersistSettings { get; init; }

    public required Func<IntPtr> GetTargetWindow { get; init; }

    public required Action<string> Report { get; init; }

    public required Action MarkSelfWrite { get; init; }
}
