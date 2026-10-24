using System.Windows.Controls;

namespace Toolbox.App.Settings;

/// <summary>
/// 尚未实现的页签。**明确写出阶段号**而不是"即将上线"这类含糊说法 ——
/// 用户至少知道什么时候会有（Mac 版给占位菜单行加版本号是同一条思路）。
/// </summary>
public partial class PlaceholderTab : UserControl
{
    public PlaceholderTab() => InitializeComponent();

    /// <summary>阶段号，例如 "P1"。</summary>
    public string Phase
    {
        get => TitleText.Text;
        set => TitleText.Text = $"待 {value} 实现";
    }

    public string Description
    {
        get => BodyText.Text;
        set => BodyText.Text = value;
    }
}
