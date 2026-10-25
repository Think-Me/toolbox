namespace Toolbox.Core.Proxy;

/// <summary>
/// 版本号比较。xray 用 v26.3.27、规则库用日期式 202510010040，
/// 都不是能直接字符串比的语义版本，得拆成数字段逐个比。
/// </summary>
public static class ProxyVersion
{
    /// <summary>"v26.3.27" → [26,3,27]；取所有纯数字段。规则库日期段超 int 范围，用 long。</summary>
    public static long[] Components(string? s)
    {
        if (string.IsNullOrEmpty(s)) return [];
        return s.Split(['.', 'v', '-', ' '], StringSplitOptions.RemoveEmptyEntries)
            .Where(p => p.All(char.IsDigit))
            .Select(long.Parse)
            .ToArray();
    }

    /// <summary>candidate 是否严格比 current 新。缺 current 视为需要更新。</summary>
    public static bool IsNewer(string? candidate, string? current)
    {
        if (string.IsNullOrEmpty(candidate)) return false;
        if (string.IsNullOrEmpty(current)) return true;

        var a = Components(candidate);
        var b = Components(current);
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var x = i < a.Length ? a[i] : 0;
            var y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }
}
