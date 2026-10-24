namespace Toolbox.Core.Clipboard;

/// <summary>
/// 面板里的选中行管理。单独抽出来是因为这类 off-by-one（列表变短后 index 越界、
/// 过滤后旧 index 指向另一条内容、数字键数到不存在的行）在真机上很难复现，只能靠测试兜住。
/// 纯值类型，不碰 UI。
/// </summary>
public struct ClipboardListSelection
{
    public ClipboardListSelection(int count)
    {
        Count = Math.Max(0, count);
        Index = 0;
    }

    public int Index { get; private set; }

    public int Count { get; private set; }

    public readonly bool IsValid => Count > 0 && Index >= 0 && Index < Count;

    /// <summary>行数变了（新增/删除条目），尽量留在原来的位置，越界就贴到最后一行。</summary>
    public void SetCount(int count)
    {
        Count = Math.Max(0, count);
        if (Index >= Count) Index = Math.Max(0, Count - 1);
    }

    /// <summary>过滤条件变了：行集整个换掉，旧 index 会指向毫不相干的条目，所以回顶。</summary>
    public void ApplyFilter(int count)
    {
        Count = Math.Max(0, count);
        Index = 0;
    }

    /// <summary>上下移动，两端环绕。取模两次是为了 C# 的负数取模。</summary>
    public void Move(int delta)
    {
        if (Count <= 0)
        {
            Index = 0;
            return;
        }
        Index = ((Index + delta) % Count + Count) % Count;
    }

    public void Select(int index)
    {
        if (Count <= 0)
        {
            Index = 0;
            return;
        }
        Index = Math.Min(Math.Max(index, 0), Count - 1);
    }

    /// <summary>
    /// Ctrl+1…Ctrl+9 快粘。第 n 行不存在时返回 null —— 不能静默选中没高亮的东西，
    /// 那样用户看到的选中行和实际粘贴的内容会对不上。Ctrl+0 故意不支持。
    /// </summary>
    public readonly int? QuickPick(int digit)
    {
        if (digit is < 1 or > 9) return null;
        var target = digit - 1;
        return target < Count ? target : null;
    }
}
