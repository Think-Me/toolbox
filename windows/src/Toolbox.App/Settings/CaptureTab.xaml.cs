using System.Windows;
using System.Windows.Controls;
using Toolbox.Core.Settings;

namespace Toolbox.App.Settings;

/// <summary>截图与贴图设置页。自动动作在选区确认的那一刻生效（下一次截图起）。</summary>
internal partial class CaptureTab : UserControl
{
    private readonly CaptureSettings _settings;
    private readonly Action _save;

    public CaptureTab(CaptureSettings settings, Action save)
    {
        _settings = settings;
        _save = save;
        InitializeComponent();
        Reload();
    }

    private void Reload()
    {
        CopyCheck.IsChecked = _settings.CopyAfterCapture;
        PinCheck.IsChecked = _settings.PinAfterCapture;
        SaveCheck.IsChecked = _settings.SaveToPictures;
        SaveDirBox.Text = _settings.SaveDirectory;
        MosaicBlockSizeBox.Text = _settings.MosaicBlockSize.ToString();
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(MosaicBlockSizeBox.Text.Trim(), out var blockSize) ||
            blockSize is < 4 or > 64)
        {
            SaveStatus.Text = "块大小需要是 4–64 之间的整数";
            SaveStatus.Foreground = System.Windows.Media.Brushes.Firebrick;
            return;
        }

        _settings.CopyAfterCapture = CopyCheck.IsChecked == true;
        _settings.PinAfterCapture = PinCheck.IsChecked == true;
        _settings.SaveToPictures = SaveCheck.IsChecked == true;
        _settings.SaveDirectory = SaveDirBox.Text.Trim();
        _settings.MosaicBlockSize = blockSize;

        _save();
        Reload();
        SaveStatus.Text = "已保存，下一次截图生效";
        SaveStatus.Foreground = System.Windows.Media.Brushes.SeaGreen;
    }
}
