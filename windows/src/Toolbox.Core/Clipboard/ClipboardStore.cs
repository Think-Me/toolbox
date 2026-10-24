using Microsoft.Data.Sqlite;

namespace Toolbox.Core.Clipboard;

/// <summary>
/// 剪贴板历史存储。图片字节只落在 media 目录（按 sha256 命名），DB 里只存哈希。
/// </summary>
public sealed class ClipboardStore : IDisposable
{
    private const string Columns =
        "id, kind, text, media_sha, file_urls, byte_length, pixel_w, pixel_h, " +
        "source_process, source_app_name, pinned, created_at, last_copied_at, copy_count";

    private readonly SqliteConnection _connection;
    private readonly string _mediaDirectory;

    public ClipboardStore(string databasePath, string mediaDirectory)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(databasePath)!);
        Directory.CreateDirectory(mediaDirectory);
        _mediaDirectory = mediaDirectory;

        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared,
        };
        _connection = new SqliteConnection(builder.ToString());
        _connection.Open();
        Execute("PRAGMA journal_mode=WAL;");
        Execute("PRAGMA synchronous=NORMAL;");
        Execute("""
            CREATE TABLE IF NOT EXISTS clipboard_items (
              id TEXT PRIMARY KEY,
              kind TEXT NOT NULL,
              text TEXT,
              media_sha TEXT,
              file_urls TEXT,
              byte_length INTEGER NOT NULL DEFAULT 0,
              pixel_w INTEGER,
              pixel_h INTEGER,
              source_process TEXT,
              source_app_name TEXT,
              pinned INTEGER NOT NULL DEFAULT 0,
              created_at REAL NOT NULL,
              last_copied_at REAL NOT NULL,
              copy_count INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_clipboard_recent ON clipboard_items(pinned DESC, last_copied_at DESC);
            """);
    }

    public ClipboardItem? Latest()
    {
        using var cmd = _connection.CreateCommand();
        cmd.CommandText = $"SELECT {Columns} FROM clipboard_items ORDER BY last_copied_at DESC, rowid DESC LIMIT 1;";
        using var reader = cmd.ExecuteReader();
        return reader.Read() ? ReadItem(reader) : null;
    }

    /// <summary>与最近一条相同则只更新时间/次数，返回已存在的记录；否则插入。</summary>
    public ClipboardItem Add(ClipboardItem item)
    {
        var latest = Latest();
        if (latest is not null && ClipboardFilter.SameContent(latest, item))
        {
            Touch(latest.Id, item.LastCopiedAt);
            latest.LastCopiedAt = item.LastCopiedAt;
            latest.CopyCount += 1;
            return latest;
        }

        using var cmd = _connection.CreateCommand();
        cmd.CommandText = $"""
            INSERT INTO clipboard_items ({Columns})
            VALUES ($id, $kind, $text, $media_sha, $file_urls, $byte_length, $pixel_w, $pixel_h,
                    $source_process, $source_app_name, $pinned, $created_at, $last_copied_at, $copy_count);
            """;
        cmd.Parameters.AddWithValue("$id", item.Id.ToString());
        cmd.Parameters.AddWithValue("$kind", KindToDb(item.Kind));
        cmd.Parameters.AddWithValue("$text", (object?)item.Text ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$media_sha", (object?)item.MediaSha256 ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$file_urls", (object?)item.FilePathsJoined ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$byte_length", item.ByteLength);
        cmd.Parameters.AddWithValue("$pixel_w", (object?)item.PixelWidth ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$pixel_h", (object?)item.PixelHeight ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$source_process", (object?)item.SourceProcess ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$source_app_name", (object?)item.SourceAppName ?? DBNull.Value);
        cmd.Parameters.AddWithValue("$pinned", item.Pinned ? 1 : 0);
        cmd.Parameters.AddWithValue("$created_at", item.CreatedAt);
        cmd.Parameters.AddWithValue("$last_copied_at", item.LastCopiedAt);
        cmd.Parameters.AddWithValue("$copy_count", item.CopyCount);
        cmd.ExecuteNonQuery();
        return item;
    }

    public IReadOnlyList<ClipboardItem> List(string? query = null, int limit = 200)
    {
        using var cmd = _connection.CreateCommand();
        var hasQuery = !string.IsNullOrWhiteSpace(query);
        cmd.CommandText = hasQuery
            ? $"SELECT {Columns} FROM clipboard_items WHERE text LIKE $q ESCAPE '\\' " +
              "ORDER BY pinned DESC, last_copied_at DESC, rowid DESC LIMIT $limit;"
            : $"SELECT {Columns} FROM clipboard_items ORDER BY pinned DESC, last_copied_at DESC, rowid DESC LIMIT $limit;";
        if (hasQuery)
        {
            var escaped = query!.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_");
            cmd.Parameters.AddWithValue("$q", $"%{escaped}%");
        }
        cmd.Parameters.AddWithValue("$limit", Math.Clamp(limit, 1, 2000));

        var items = new List<ClipboardItem>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read()) items.Add(ReadItem(reader));
        return items;
    }

    public void Touch(Guid id, double at)
    {
        using var cmd = _connection.CreateCommand();
        cmd.CommandText = "UPDATE clipboard_items SET last_copied_at = $at, copy_count = copy_count + 1 WHERE id = $id;";
        cmd.Parameters.AddWithValue("$at", at);
        cmd.Parameters.AddWithValue("$id", id.ToString());
        cmd.ExecuteNonQuery();
    }

    public void SetPinned(Guid id, bool pinned)
    {
        using var cmd = _connection.CreateCommand();
        cmd.CommandText = "UPDATE clipboard_items SET pinned = $pinned WHERE id = $id;";
        cmd.Parameters.AddWithValue("$pinned", pinned ? 1 : 0);
        cmd.Parameters.AddWithValue("$id", id.ToString());
        cmd.ExecuteNonQuery();
    }

    public void Delete(Guid id)
    {
        using var cmd = _connection.CreateCommand();
        cmd.CommandText = "DELETE FROM clipboard_items WHERE id = $id;";
        cmd.Parameters.AddWithValue("$id", id.ToString());
        cmd.ExecuteNonQuery();
    }

    public int ClearUnpinned()
    {
        using var cmd = _connection.CreateCommand();
        cmd.CommandText = "DELETE FROM clipboard_items WHERE pinned = 0;";
        return cmd.ExecuteNonQuery();
    }

    /// <summary>
    /// 淘汰到 capacity 以内：只删非置顶，按 last_copied_at 从旧到新。
    /// 置顶数本身超过 capacity 时一条都不删——用户收藏的不能因容量数字丢掉。
    /// </summary>
    public int Prune(int capacity)
    {
        if (capacity <= 0) return 0;
        var total = Scalar("SELECT COUNT(*) FROM clipboard_items;");
        if (total <= capacity) return 0;
        var pinned = Scalar("SELECT COUNT(*) FROM clipboard_items WHERE pinned = 1;");
        if (capacity <= pinned) return 0;

        using var cmd = _connection.CreateCommand();
        cmd.CommandText = """
            DELETE FROM clipboard_items WHERE id IN (
              SELECT id FROM clipboard_items WHERE pinned = 0
              ORDER BY last_copied_at ASC, rowid ASC LIMIT $excess
            );
            """;
        cmd.Parameters.AddWithValue("$excess", total - capacity);
        return cmd.ExecuteNonQuery();
    }

    private long Scalar(string sql)
    {
        using var cmd = _connection.CreateCommand();
        cmd.CommandText = sql;
        return Convert.ToInt64(cmd.ExecuteScalar() ?? 0L);
    }

    public string SaveImage(byte[] png)
    {
        var sha = ClipboardItem.Sha256Hex(png);
        var path = ClipboardMedia.PathFor(_mediaDirectory, sha);
        if (!File.Exists(path)) File.WriteAllBytes(path, png);
        return sha;
    }

    public byte[]? LoadImage(string sha)
    {
        var path = ClipboardMedia.PathFor(_mediaDirectory, sha);
        return File.Exists(path) ? File.ReadAllBytes(path) : null;
    }

    public void Dispose() => _connection.Dispose();

    private void Execute(string sql)
    {
        using var cmd = _connection.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private static string KindToDb(ClipboardKind kind) => kind switch
    {
        ClipboardKind.Text => "text",
        ClipboardKind.Image => "image",
        ClipboardKind.FileUrls => "fileURLs",
        _ => "text",
    };

    private static ClipboardKind KindFromDb(string value) => value switch
    {
        "text" => ClipboardKind.Text,
        "image" => ClipboardKind.Image,
        "fileURLs" or "fileUrls" => ClipboardKind.FileUrls,
        _ => throw new InvalidDataException($"未知剪贴板类型：{value}"),
    };

    private static ClipboardItem ReadItem(SqliteDataReader r)
    {
        var item = new ClipboardItem
        {
            Id = Guid.Parse(r.GetString(0)),
            Kind = KindFromDb(r.GetString(1)),
            Text = r.IsDBNull(2) ? null : r.GetString(2),
            MediaSha256 = r.IsDBNull(3) ? null : r.GetString(3),
            FilePaths = r.IsDBNull(4) ? null : ClipboardItem.SplitPaths(r.GetString(4)),
            ByteLength = r.GetInt64(5),
            PixelWidth = r.IsDBNull(6) ? null : r.GetInt32(6),
            PixelHeight = r.IsDBNull(7) ? null : r.GetInt32(7),
            SourceProcess = r.IsDBNull(8) ? null : r.GetString(8),
            SourceAppName = r.IsDBNull(9) ? null : r.GetString(9),
            Pinned = r.GetInt32(10) != 0,
            CreatedAt = r.GetDouble(11),
            LastCopiedAt = r.GetDouble(12),
            CopyCount = r.GetInt32(13),
        };
        return item;
    }
}
