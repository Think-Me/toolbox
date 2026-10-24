using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Controls;
using Toolbox.Core.Translation;

namespace Toolbox.App.Settings;

/// <summary>
/// 翻译设置页。保存时一次性写回引擎/语言/网络/AI 配置；
/// AI Key 走 DPAPI 单独存 ai.key，不进 settings.json（页面上的框留空 = 不修改）。
/// </summary>
internal partial class TranslationTab : UserControl
{
    private static readonly string[] NetworkLabels = ["自动（按域名）", "始终直连", "始终走代理"];

    private readonly Func<TranslationSettings> _settings;
    private readonly Action _save;
    private readonly Func<string?> _loadAiKey;
    private readonly Action<string> _saveAiKey;
    private readonly Action<string> _log;

    public TranslationTab(Func<TranslationSettings> settings, Action save,
                          Func<string?> loadAiKey, Action<string> saveAiKey, Action<string> log)
    {
        _settings = settings;
        _save = save;
        _loadAiKey = loadAiKey;
        _saveAiKey = saveAiKey;
        _log = log;

        InitializeComponent();
        Load();
    }

    private TranslationSettings Current => _settings();

    private void Load()
    {
        EngineCombo.ItemsSource = Enum.GetValues<TranslationEngine>()
            .Select(e => e.Label()).ToList();
        EngineCombo.SelectedIndex = (int)Current.Engine;

        LanguageCombo.ItemsSource = TranslationLanguages.Targets.Select(t => t.Label).ToList();
        LanguageCombo.SelectedIndex = Math.Max(0, TranslationLanguages.Targets
            .Select((t, i) => (t, i)).FirstOrDefault(x => x.t.Code == Current.TargetLanguage).i);

        NetworkCombo.ItemsSource = NetworkLabels;
        NetworkCombo.SelectedIndex = (int)Current.Network;
        ProxyPortBox.Text = Current.ProxyPort.ToString();

        AiBaseUrlBox.Text = Current.AiBaseUrl;
        AiModelBox.Text = Current.AiModel;
        AiKeyBox.Password = _loadAiKey() ?? "";
    }

    private void OnSaveClick(object sender, System.Windows.RoutedEventArgs e)
    {
        var settings = Current;

        if (EngineCombo.SelectedIndex is >= 0 and var engineIndex)
            settings.Engine = (TranslationEngine)engineIndex;

        if (LanguageCombo.SelectedIndex is >= 0 and var languageIndex &&
            languageIndex < TranslationLanguages.Targets.Count)
            settings.TargetLanguage = TranslationLanguages.Targets[languageIndex].Code;

        if (NetworkCombo.SelectedIndex is >= 0 and var networkIndex &&
            networkIndex < Enum.GetValues<TranslationNetwork>().Length)
            settings.Network = (TranslationNetwork)networkIndex;

        if (int.TryParse(ProxyPortBox.Text.Trim(), out var port) && port is >= 1 and <= 65535)
            settings.ProxyPort = port;

        settings.AiBaseUrl = AiBaseUrlBox.Text.Trim();
        settings.AiModel = AiModelBox.Text.Trim();

        var key = AiKeyBox.Password;
        if (key.Length > 0) _saveAiKey(key);

        _save();
        _log("翻译设置已保存");
        SaveStatus.Text = "已保存";
        SaveStatus.Foreground = System.Windows.Media.Brushes.SeaGreen;
    }
}
