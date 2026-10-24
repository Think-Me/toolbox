using Toolbox.Core.Settings;
using Xunit;

namespace Toolbox.Core.Tests;

public sealed class HotkeyRegistrationTableTests
{
    private static HotkeyGesture CtrlAlt(int vk) => new(HotkeyModifiers.Control | HotkeyModifiers.Alt, vk);

    [Theory]
    [InlineData(HotkeyModifiers.Control, 0x56)]   // Ctrl+V
    [InlineData(HotkeyModifiers.Alt, 0x41)]       // Alt+A
    [InlineData(HotkeyModifiers.Win, 0x20)]       // Win+Space
    [InlineData(HotkeyModifiers.Control | HotkeyModifiers.Shift, 0x70)] // Ctrl+Shift+F1
    public void AcceptsModifierCombos(HotkeyModifiers modifiers, int vk) =>
        Assert.Null(HotkeyRegistrationTable.Validate(new HotkeyGesture(modifiers, vk)));

    /// <summary>裸 F 键不参与打字，可以直接用。</summary>
    [Theory]
    [InlineData(0x70)]
    [InlineData(0x77)]
    [InlineData(0x87)]
    public void AcceptsBareFunctionKeys(int vk) =>
        Assert.Null(HotkeyRegistrationTable.Validate(new HotkeyGesture(HotkeyModifiers.None, vk)));

    /// <summary>裸字母/数字会被每一次打字触发，必须拒绝；单独 Shift 也不算修饰键。</summary>
    [Theory]
    [InlineData(HotkeyModifiers.None, 0x56)]
    [InlineData(HotkeyModifiers.None, 0x31)]
    [InlineData(HotkeyModifiers.Shift, 0x56)]
    public void RejectsBareKeysAndShiftOnly(HotkeyModifiers modifiers, int vk) =>
        Assert.NotNull(HotkeyRegistrationTable.Validate(new HotkeyGesture(modifiers, vk)));

    [Fact]
    public void RejectsEmptyGesture() =>
        Assert.NotNull(HotkeyRegistrationTable.Validate(default));

    [Fact]
    public void ReportsTheOwningFeatureOnDuplicates()
    {
        var bindings = new Dictionary<HotkeyId, HotkeyGesture>
        {
            [HotkeyId.Screenshot] = CtrlAlt(0x41),
            [HotkeyId.ClipboardPanel] = CtrlAlt(0x56),
        };

        var message = HotkeyRegistrationTable.DetectConflict(HotkeyId.ClipboardPanel, CtrlAlt(0x41), bindings);

        Assert.NotNull(message);
        Assert.Contains("区域截图", message);
        Assert.Contains("Ctrl+Alt+A", message);
    }

    /// <summary>重录本行自己当前的手势必须放行 —— 否则"点开录制再按同一个键提交"会被自己拦下。</summary>
    [Fact]
    public void AllowsRerecordingItsOwnGesture()
    {
        var bindings = new Dictionary<HotkeyId, HotkeyGesture> { [HotkeyId.ClipboardPanel] = CtrlAlt(0x56) };
        Assert.Null(HotkeyRegistrationTable.DetectConflict(HotkeyId.ClipboardPanel, CtrlAlt(0x56), bindings));
    }

    [Fact]
    public void AcceptsAFreeGesture()
    {
        var bindings = new Dictionary<HotkeyId, HotkeyGesture> { [HotkeyId.ClipboardPanel] = CtrlAlt(0x56) };
        Assert.Null(HotkeyRegistrationTable.DetectConflict(HotkeyId.Screenshot, CtrlAlt(0x41), bindings));
    }

    [Fact]
    public void RoundTripsThroughSettings()
    {
        var settings = new HotkeySettings();
        var table = HotkeyRegistrationTable.From(settings);
        table.Set(HotkeyId.Screenshot, CtrlAlt(0x51));
        table.ApplyTo(settings);

        Assert.Equal(CtrlAlt(0x51), settings.Screenshot);
        Assert.Equal(CtrlAlt(0x51), HotkeyRegistrationTable.From(settings).Get(HotkeyId.Screenshot));
    }

    [Fact]
    public void DefaultsAreDistinctSoStartupRegistrationDoesNotSelfConflict()
    {
        var table = HotkeyRegistrationTable.From(new HotkeySettings());
        var distinct = table.Bindings.Values.Distinct().Count();
        Assert.Equal(table.Bindings.Count, distinct);
    }

    /// <summary>
    /// 名称以 HotkeySettings.All() 为准（设置页就靠它渲染），这里锁住"枚举顺序 = All() 顺序"，
    /// 以后加第五个热键时两边不同步会立刻失败。
    /// </summary>
    [Fact]
    public void DisplayNameMatchesTheSettingsLabels()
    {
        var labels = new HotkeySettings().All().Select(row => row.Name).ToArray();
        var ids = Enum.GetValues<HotkeyId>();

        Assert.Equal(labels.Length, ids.Length);
        for (var i = 0; i < ids.Length; i++)
            Assert.Equal(labels[i], HotkeyRegistrationTable.DisplayName(ids[i]));
    }
}
