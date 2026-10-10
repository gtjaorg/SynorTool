using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;

/// <summary>
/// 通过 Apple Translation 在本机翻译；本地翻译失败时回退到模型翻译。仅在原生主线程访问。
/// </summary>
internal static unsafe partial class AppleTranslation
{
    /// <summary>
    /// 启动一次本地翻译；同一时间只保留一个任务，新任务会取消旧任务。
    /// </summary>
    [LibraryImport("SynorAppleTranslation", EntryPoint = "synor_apple_translate_start", StringMarshalling = StringMarshalling.Utf8)]
    private static partial void StartNative(string json, delegate* unmanaged[Cdecl]<byte*, void> callback);

    /// <summary>
    /// 取消指定标识的本地翻译；标识不是当前任务时忽略。
    /// </summary>
    [LibraryImport("SynorAppleTranslation", EntryPoint = "synor_apple_translate_cancel", StringMarshalling = StringMarshalling.Utf8)]
    private static partial void CancelNative(string id);

    /// <summary>
    /// 当前本地翻译的请求标识与失败回退。
    /// </summary>
    private static (string Id, Action Fallback)? current;

    /// <summary>
    /// 用 Apple 本地模型翻译；出错时不转发错误，改为调用 <paramref name="fallback"/>。
    /// </summary>
    /// <param name="id">请求标识。</param>
    /// <param name="text">原文。</param>
    /// <param name="target">目标语言名称。</param>
    /// <param name="fallback">本地翻译失败后的模型翻译。</param>
    internal static void Translate(string id, string text, string target, Action fallback)
    {
        current = (id, fallback);
        StartNative(JsonSerializer.Serialize(new { id, text, target }), &OnEvent);
    }

    /// <summary>
    /// 取消本地翻译；取消不会触发回退。
    /// </summary>
    /// <param name="id">请求标识。</param>
    internal static void Cancel(string id)
    {
        if (current?.Id != id) return;
        current = null;
        CancelNative(id);
    }

    /// <summary>
    /// 接收本地翻译事件，转发给页面或在出错时回退。
    /// </summary>
    /// <param name="json">借用的 UTF-8 JSON，只在调用期间有效。</param>
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    private static void OnEvent(byte* json)
    {
        // 不允许托管异常跨越原生回调边界。
        try
        {
            var payload = Marshal.PtrToStringUTF8((nint)json) ?? "";
            using var document = JsonDocument.Parse(payload);
            var root = document.RootElement;
            var id = root.TryGetProperty("id", out var idValue) ? idValue.GetString() : null;
            if (id is null || current?.Id != id) return;
            if (root.TryGetProperty("error", out var error))
            {
                var fallback = current.Value.Fallback;
                current = null;
                Console.Error.WriteLine($"Apple 本地翻译失败，改用模型翻译：{error.GetString()}");
                fallback();
                return;
            }
            if (root.TryGetProperty("done", out _)) current = null;
            ChatClient.SendEvent(payload);
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"处理 Apple 本地翻译事件失败：{exception.Message}");
        }
    }
}
