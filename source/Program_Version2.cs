using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

var argv = Environment.GetCommandLineArgs();
// argv[0] is the exe itself; real args start at index 1.
// Filter out flag-style args to find the URL positional argument.
var urlArg = argv.Skip(1).FirstOrDefault(a => !a.StartsWith("--"));
var headless = argv.Any(a => a.Equals("--nogui", StringComparison.OrdinalIgnoreCase));

if (headless)
{
    // Attach to the parent console (e.g. pwsh/cmd); open a new one if not launched from one.
    if (!NativeMethods.AttachConsole(-1))
        NativeMethods.AllocConsole();

    // Re-open stdout/stderr so Console.WriteLine works after AttachConsole.
    Console.SetOut(new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true });
    Console.SetError(new StreamWriter(Console.OpenStandardError()) { AutoFlush = true });

    Console.WriteLine($"[Background] URL : {urlArg ?? "(none — idle)"}");
    Console.WriteLine("[Background] Press Ctrl+C to exit.");

    using var cts = new CancellationTokenSource();
    Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };

    using var http = new HttpClient(new HttpClientHandler
    {
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
    }) { Timeout = TimeSpan.FromSeconds(20) };
    http.DefaultRequestHeaders.UserAgent.ParseAdd("GtBoosterHtmlViewer/1.0 (+Windows; .NET)");

    while (!cts.Token.IsCancellationRequested)
    {
        if (urlArg is null)
        {
            // No URL provided — just keep the process alive without fetching.
            try { await Task.Delay(Timeout.Infinite, cts.Token); } catch (OperationCanceledException) { break; }
            break;
        }

        try
        {
            Console.Write($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] Fetching {urlArg} ... ");
            using var req  = new HttpRequestMessage(HttpMethod.Get, urlArg);
            using var resp = await http.SendAsync(req, cts.Token);

            var bytes       = await resp.Content.ReadAsByteArrayAsync(cts.Token);
            var contentType = resp.Content.Headers.ContentType?.ToString() ?? "(unknown)";
            Console.WriteLine($"{(int)resp.StatusCode} {resp.ReasonPhrase} | {contentType} | {bytes.Length:N0} bytes");
        }
        catch (OperationCanceledException) { break; }
        catch (Exception ex)
        {
            Console.WriteLine($"ERROR: {ex.GetType().Name}: {ex.Message}");
        }

        try { await Task.Delay(1000, cts.Token); } catch (OperationCanceledException) { break; }
    }

    Console.WriteLine("[Background] Stopped.");
}
else
{
    ApplicationConfiguration.Initialize();
    Application.Run(new MainForm(urlArg));
}

static class NativeMethods
{
    [DllImport("kernel32.dll")] internal static extern bool AttachConsole(int dwProcessId);
    [DllImport("kernel32.dll")] internal static extern bool AllocConsole();
}