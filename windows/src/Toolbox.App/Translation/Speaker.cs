using System.Speech.Synthesis;
using Toolbox.Core.Translation;

namespace Toolbox.App.Translation;

/// <summary>
/// TTS 朗读。按目标语言挑系统已装的语音；中文 voice 依赖系统语言包，没装只能报错
/// （README 已知差异）。新朗读会打断上一次的播报。
/// </summary>
internal sealed class Speaker : IDisposable
{
    private readonly SpeechSynthesizer _synth = new();
    private bool _disposed;

    /// <summary>开始朗读。返回 null 表示已开始；否则是给用户看的原因。</summary>
    public string? Speak(string text, string targetLanguage)
    {
        if (_disposed) return null;

        try
        {
            // 有些精简版系统连 SAPI 语音注册表都是空的，GetInstalledVoices 会直接抛
            var voices = _synth.GetInstalledVoices().Where(v => v.Enabled).ToList();
            var primary = TranslationLanguages.Primary(targetLanguage);
            var voice = voices.FirstOrDefault(v =>
                v.VoiceInfo.Culture.TwoLetterISOLanguageName.Equals(primary, StringComparison.OrdinalIgnoreCase));

            if (voice is null)
            {
                var label = TranslationLanguages.Label(targetLanguage);
                return voices.Count == 0
                    ? "系统没有可用的语音引擎，无法朗读"
                    : $"系统没有安装 {label} 的语音包，无法朗读";
            }

            _synth.SpeakAsyncCancelAll();
            _synth.SelectVoice(voice.VoiceInfo.Name);
            _synth.SpeakAsync(text);
            return null;
        }
        catch (Exception error)
        {
            return $"朗读失败：{error.Message}";
        }
    }

    public void Stop()
    {
        if (!_disposed) _synth.SpeakAsyncCancelAll();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _synth.Dispose();
    }
}
