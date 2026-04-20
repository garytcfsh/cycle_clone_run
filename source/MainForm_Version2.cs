using System.Net;
using System.Text;

public sealed class MainForm : Form
{
    private readonly string? Url;
    private readonly HttpClient _http;
    private readonly System.Windows.Forms.Timer _timer;

    private readonly Label _lblStatus;
    private readonly NumericUpDown _numInterval;
    private readonly Button _btnRefresh;
    private readonly Button _btnStartStop;
    private readonly TextBox _txtContent;

    private bool _running = true;
    private bool _fetching = false;

    public MainForm(string? url)
    {
        Url = url;
        Text = "GTBooster HTML Viewer";
        Width = 1100;
        Height = 800;

        _http = new HttpClient(new HttpClientHandler
        {
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate
        })
        {
            Timeout = TimeSpan.FromSeconds(20)
        };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("GtBoosterHtmlViewer/1.0 (+Windows; .NET)");

        // --- Top status line
        _lblStatus = new Label
        {
            AutoSize = false,
            Dock = DockStyle.Top,
            Height = 28,
            TextAlign = ContentAlignment.MiddleLeft,
            Padding = new Padding(10, 0, 10, 0),
            Text = "Ready"
        };

        // --- Controls panel
        var topPanel = new Panel { Dock = DockStyle.Top, Height = 44, Padding = new Padding(10, 8, 10, 8) };

        _btnRefresh = new Button { Text = "Refresh now", Width = 120, Left = 10, Top = 8 };
        _btnRefresh.Click += async (_, __) => await RefreshAsync();

        _btnStartStop = new Button { Text = "Stop", Width = 90, Left = 140, Top = 8 };
        _btnStartStop.Click += (_, __) => ToggleTimer();

        var lblInterval = new Label { Text = "Interval (sec):", AutoSize = true, Left = 250, Top = 12 };
        _numInterval = new NumericUpDown
        {
            Left = 340,
            Top = 8,
            Width = 80,
            Minimum = 1,
            Maximum = 3600,
            Value = 1
        };
        _numInterval.ValueChanged += (_, __) => _timer!.Interval = (int)_numInterval.Value * 1000;

        topPanel.Controls.AddRange(new Control[] { _btnRefresh, _btnStartStop, lblInterval, _numInterval });

        // --- HTML text area (raw)
        _txtContent = new TextBox
        {
            Dock = DockStyle.Fill,
            Multiline = true,
            ScrollBars = ScrollBars.Both,
            WordWrap = false,
            Font = new Font("Consolas", 10),
            ReadOnly = true
        };

        Controls.Add(_txtContent);
        Controls.Add(topPanel);
        Controls.Add(_lblStatus);

        // --- Timer refresh
        _timer = new System.Windows.Forms.Timer();
        _timer.Interval = (int)_numInterval.Value * 1000;
        _timer.Tick += async (_, __) => await RefreshAsync();

        Shown += async (_, __) =>
        {
            if (Url is null)
            {
                _lblStatus.Text = "No URL specified — idle.";
                _btnRefresh.Enabled = false;
                _btnStartStop.Enabled = false;
                return;
            }
            _timer.Start();
            await RefreshAsync();
        };

        FormClosing += (_, __) =>
        {
            _timer.Stop();
            _http.Dispose();
        };
    }

    private void ToggleTimer()
    {
        _running = !_running;
        if (_running)
        {
            _btnStartStop.Text = "Stop";
            _timer.Start();
        }
        else
        {
            _btnStartStop.Text = "Start";
            _timer.Stop();
        }
    }

    private async Task RefreshAsync()
    {
        if (_fetching || Url is null) return;
        _fetching = true;

        _timer.Stop(); // avoid overlapping ticks while we fetch
        _btnRefresh.Enabled = false;

        try
        {
            _lblStatus.Text = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] Fetching {Url} ...";

            using var req = new HttpRequestMessage(HttpMethod.Get, Url);
            using var resp = await _http.SendAsync(req);

            // Respect server-declared charset if possible.
            Encoding enc = Encoding.UTF8;
            var charset = resp.Content.Headers.ContentType?.CharSet;
            if (!string.IsNullOrWhiteSpace(charset))
            {
                try { enc = Encoding.GetEncoding(charset); } catch { /* fallback to UTF-8 */ }
            }

            var bytes = await resp.Content.ReadAsByteArrayAsync();
            var html = enc.GetString(bytes);

            var statusLine = $"{(int)resp.StatusCode} {resp.ReasonPhrase}";
            var contentType = resp.Content.Headers.ContentType?.ToString() ?? "(unknown)";

            _lblStatus.Text = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {statusLine} | {contentType} | {bytes.Length:N0} bytes";
            _txtContent.Text = html;
        }
        catch (TaskCanceledException ex)
        {
            _lblStatus.Text = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] TIMEOUT/CANCELED: {ex.Message}";
        }
        catch (Exception ex)
        {
            _lblStatus.Text = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] ERROR: {ex.GetType().Name}: {ex.Message}";
        }
        finally
        {
            _btnRefresh.Enabled = true;
            _fetching = false;

            if (_running)
                _timer.Start();
        }
    }
}