// EcoFlow River 2 — battery level indicator in the Windows system tray.
// Data comes from the official EcoFlow Open API (https://developer.ecoflow.com).
// Build: build.bat (needs only .NET Framework 4.x, which ships with Windows 10/11).

using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: System.Reflection.AssemblyTitle("EcoFlow Tray")]
[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]

namespace EcoFlowTray
{
    // ------------------------------------------------------------------ config
    public class Config
    {
        public string AccessKey = "";
        public string SecretKey = "";
        public string SerialNumber = "";
        public string Host = "https://api-e.ecoflow.com";
        public int IntervalSec = 60;
        public int LowThreshold = 20;

        static string Dir { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "EcoFlowTray"); } }
        static string FilePath { get { return Path.Combine(Dir, "config.json"); } }

        public bool IsComplete { get { return AccessKey.Length > 0 && SecretKey.Length > 0; } }

        public static Config Load()
        {
            var c = new Config();
            try
            {
                if (!File.Exists(FilePath)) return c;
                var d = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(FilePath, Encoding.UTF8));
                c.AccessKey = Str(d, "accessKey");
                c.SecretKey = Unprotect(Str(d, "secretKey"));
                c.SerialNumber = Str(d, "sn");
                var h = Str(d, "host"); if (h.Length > 0) c.Host = h;
                int i;
                if (int.TryParse(Str(d, "intervalSec"), out i) && i >= 10) c.IntervalSec = i;
                if (int.TryParse(Str(d, "lowThreshold"), out i) && i >= 0 && i <= 100) c.LowThreshold = i;
            }
            catch { }
            return c;
        }

        public void Save()
        {
            Directory.CreateDirectory(Dir);
            var d = new Dictionary<string, object> {
                { "accessKey", AccessKey }, { "secretKey", Protect(SecretKey) }, { "sn", SerialNumber },
                { "host", Host }, { "intervalSec", IntervalSec }, { "lowThreshold", LowThreshold } };
            File.WriteAllText(FilePath, new JavaScriptSerializer().Serialize(d), Encoding.UTF8);
        }

        static string Str(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) && v != null ? v.ToString() : ""; }

        // the secret key is stored encrypted with Windows DPAPI (readable by the current user only)
        static string Protect(string s)
        {
            if (s.Length == 0) return "";
            return Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(s), null, DataProtectionScope.CurrentUser));
        }
        static string Unprotect(string s)
        {
            if (s.Length == 0) return "";
            try { return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(s), null, DataProtectionScope.CurrentUser)); }
            catch { return ""; }
        }
    }

    // --------------------------------------------------------------- api
    public class BatteryState
    {
        public int Soc = -1;
        public int WattsIn = -1, WattsOut = -1;
        public int ChargeMin = -1, DischargeMin = -1;
        public bool Online = true;
        public bool Live;            // true — data from the MQTT stream, false — cloud cache snapshot (may be stale)
        public bool Charging;
        public string Name = "River 2";
        public DateTime Time = DateTime.Now;

        // Builds the state from a flat dictionary of parameters like "pd.soc", "inv.inputWatts", etc.
        public static BatteryState From(Dictionary<string, object> q)
        {
            var st = new BatteryState();
            st.Soc = Int(q, "pd.soc", "bms_bmsStatus.soc", "bms_emsStatus.lcdShowSoc", "bms_emsStatus.f32LcdShowSoc");
            st.WattsOut = Int(q, "pd.wattsOutSum", "inv.outputWatts");
            st.WattsIn = Int(q, "pd.wattsInSum");
            if (st.WattsIn < 0)
            {
                // River 2 does not send wattsInSum over MQTT — add up AC input and MPPT input (solar/car)
                int ac = Int(q, "inv.inputWatts"), dc = Int(q, "mppt.inWatts");
                if (ac >= 0 || dc >= 0) st.WattsIn = Math.Max(0, ac) + Math.Max(0, dc);
            }
            int bIn = Int(q, "bms_bmsStatus.inputWatts"), bOut = Int(q, "bms_bmsStatus.outputWatts");
            st.Charging = (bIn >= 0 && bOut >= 0) ? bIn > bOut + 5 : (st.WattsIn > 5 && st.WattsIn >= st.WattsOut);
            if (st.Soc >= 100) st.Charging = false;   // at 100 % it is only trickle charging; mains powers the load directly

            // 5999 min is EcoFlow's placeholder for "not calculated"
            int chg = Int(q, "bms_emsStatus.chgRemainTime"), dsg = Int(q, "bms_emsStatus.dsgRemainTime"), pdRem = Int(q, "pd.remainTime");
            bool pdRemKnown = q.ContainsKey("pd.remainTime");
            st.ChargeMin = chg > 0 && chg < 5999 ? chg : (pdRemKnown && pdRem > 0 ? pdRem : -1);
            st.DischargeMin = dsg > 0 && dsg < 5999 ? dsg : (pdRemKnown && pdRem < 0 && pdRem != -1 ? -pdRem : -1);
            return st;
        }

        public static int Int(Dictionary<string, object> d, params string[] keys)
        {
            foreach (var k in keys)
            {
                object v;
                if (d.TryGetValue(k, out v) && v != null)
                {
                    double x;
                    if (double.TryParse(Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture),
                        System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out x))
                        return (int)Math.Round(x);
                }
            }
            return -1;
        }
    }

    public static class Log
    {
        static readonly object sync = new object();
        public static void Write(string msg)
        {
            try
            {
                lock (sync)
                {
                    string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "EcoFlowTray");
                    Directory.CreateDirectory(dir);
                    string f = Path.Combine(dir, "log.txt");
                    if (File.Exists(f) && new FileInfo(f).Length > 512 * 1024) File.Delete(f);
                    File.AppendAllText(f, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + Environment.NewLine, Encoding.UTF8);
                }
            }
            catch { }
        }
    }

    public class EcoFlowApi
    {
        readonly Config cfg;
        static readonly Random rnd = new Random();

        public EcoFlowApi(Config c) { cfg = c; }

        string Sign(string paramStr, out string nonce, out string ts)
        {
            nonce = rnd.Next(100000, 999999).ToString();
            ts = ((long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalMilliseconds).ToString();
            string s = (paramStr.Length > 0 ? paramStr + "&" : "") + "accessKey=" + cfg.AccessKey + "&nonce=" + nonce + "&timestamp=" + ts;
            using (var h = new HMACSHA256(Encoding.UTF8.GetBytes(cfg.SecretKey)))
                return BitConverter.ToString(h.ComputeHash(Encoding.UTF8.GetBytes(s))).Replace("-", "").ToLowerInvariant();
        }

        Dictionary<string, object> Get(string path, string query)
        {
            string nonce, ts;
            string sign = Sign(query, out nonce, out ts);
            var req = (HttpWebRequest)WebRequest.Create(cfg.Host.TrimEnd('/') + path + (query.Length > 0 ? "?" + query : ""));
            req.Method = "GET";
            req.Timeout = 15000;
            req.ReadWriteTimeout = 15000;
            req.Headers["accessKey"] = cfg.AccessKey;
            req.Headers["nonce"] = nonce;
            req.Headers["timestamp"] = ts;
            req.Headers["sign"] = sign;
            string body;
            try
            {
                using (var resp = (HttpWebResponse)req.GetResponse())
                using (var sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) body = sr.ReadToEnd();
            }
            catch (WebException ex)
            {
                if (ex.Response == null) throw new Exception("Cannot reach " + cfg.Host + ": " + ex.Message);
                using (var resp = ex.Response)
                using (var sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) body = sr.ReadToEnd();
            }
            var js = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
            var d = js.Deserialize<Dictionary<string, object>>(body);
            string code = d.ContainsKey("code") ? Convert.ToString(d["code"]) : "?";
            if (code != "0")
                throw new Exception("EcoFlow API: " + (d.ContainsKey("message") ? Convert.ToString(d["message"]) : body) + " (code " + code + ")");
            return d;
        }

        public List<Dictionary<string, object>> ListDevices()
        {
            var d = Get("/iot-open/sign/device/list", "");
            var list = new List<Dictionary<string, object>>();
            var arr = d.ContainsKey("data") ? d["data"] as ArrayList : null;
            if (arr != null) foreach (var o in arr) { var x = o as Dictionary<string, object>; if (x != null) list.Add(x); }
            return list;
        }

        // If no serial number is set, take the first River on the account and remember it.
        public void EnsureSerial()
        {
            if (cfg.SerialNumber.Length > 0) return;
            var devs = ListDevices();
            var dev = devs.FirstOrDefault(x => Convert.ToString(GetOr(x, "productName", "")).ToUpperInvariant().Contains("RIVER")) ?? devs.FirstOrDefault();
            if (dev == null) throw new Exception("No devices are linked to this account");
            cfg.SerialNumber = Convert.ToString(dev["sn"]);
            try { cfg.Save(); } catch { }
        }

        // Snapshot from the cloud cache. WARNING: the cloud refreshes it rarely (hours apart), so this is
        // only a fallback until live MQTT data arrives.
        public BatteryState FetchSnapshot()
        {
            EnsureSerial();
            bool online = true; string name = null;
            try
            {
                var me = ListDevices().FirstOrDefault(x => Convert.ToString(GetOr(x, "sn", "")) == cfg.SerialNumber);
                if (me != null)
                {
                    online = Convert.ToString(GetOr(me, "online", "1")) == "1";
                    var pn = Convert.ToString(GetOr(me, "productName", ""));
                    if (pn.Length > 0) name = pn;
                }
            }
            catch { }

            var resp = Get("/iot-open/sign/device/quota/all", "sn=" + Uri.EscapeDataString(cfg.SerialNumber));
            var q = resp.ContainsKey("data") ? resp["data"] as Dictionary<string, object> : null;
            if (q == null || q.Count == 0) throw new Exception("The station sent no data (switched off or offline?)");

            var st = BatteryState.From(q);
            st.Online = online;
            if (name != null) st.Name = name;
            st.Live = false;
            if (st.Soc < 0) throw new Exception("No battery level in the response (pd.soc)");
            return st;
        }

        // EcoFlow MQTT broker credentials for the live data stream.
        public Dictionary<string, object> GetCertification()
        {
            var d = Get("/iot-open/sign/certification", "");
            var data = d.ContainsKey("data") ? d["data"] as Dictionary<string, object> : null;
            if (data == null) throw new Exception("The server returned no MQTT credentials");
            return data;
        }

        public static object GetOr(Dictionary<string, object> d, string k, object def) { object v; return d.TryGetValue(k, out v) && v != null ? v : def; }
    }

    // --------------------------------------------------------------- live data (MQTT)
    // Minimal MQTT 3.1.1 client over TLS: subscribes to /open/<account>/<sn>/quota.
    // The station publishes changes there every 1–3 seconds.
    public class LiveFeed
    {
        readonly Config cfg;
        volatile bool stopped;
        TcpClient tcp;
        Stream stream;
        readonly object writeLock = new object();
        Thread thread;

        public event Action<Dictionary<string, object>> Params;   // keys already prefixed: "pd.soc", "inv.inputWatts"
        public event Action<string> Status;

        public LiveFeed(Config c) { cfg = c; }

        public void Start()
        {
            thread = new Thread(Run) { IsBackground = true, Name = "EcoFlow MQTT" };
            thread.Start();
        }

        public void Stop()
        {
            stopped = true;
            try { if (tcp != null) tcp.Close(); } catch { }
        }

        void Run()
        {
            int delay = 5;
            while (!stopped)
            {
                try
                {
                    Session();
                    delay = 5;
                }
                catch (Exception ex)
                {
                    if (stopped) break;
                    Log.Write("MQTT: " + ex.Message);
                    Fire(Status, "No live data: " + ex.Message);
                }
                finally
                {
                    try { if (tcp != null) tcp.Close(); } catch { }
                }
                for (int i = 0; i < delay * 10 && !stopped; i++) Thread.Sleep(100);
                delay = Math.Min(120, delay * 2);
            }
        }

        void Session()
        {
            var api = new EcoFlowApi(cfg);
            api.EnsureSerial();
            var cert = api.GetCertification();
            string acc = Convert.ToString(cert["certificateAccount"]);
            string pwd = Convert.ToString(cert["certificatePassword"]);
            string host = Convert.ToString(cert["url"]);
            int port = int.Parse(Convert.ToString(EcoFlowApi.GetOr(cert, "port", "8883")));
            string topic = "/open/" + acc + "/" + cfg.SerialNumber + "/quota";

            tcp = new TcpClient();
            var ar = tcp.BeginConnect(host, port, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(15000)) throw new Exception("connection to " + host + " timed out");
            tcp.EndConnect(ar);
            tcp.ReceiveTimeout = 90000;   // 90 s of silence — reconnect
            tcp.SendTimeout = 15000;
            var ssl = new SslStream(tcp.GetStream());
            ssl.AuthenticateAsClient(host, null, (System.Security.Authentication.SslProtocols)3072, false);
            stream = ssl;

            // CONNECT (clean session, user+password, keepalive 60 s)
            var m = new MemoryStream();
            Str(m, "MQTT"); m.WriteByte(4); m.WriteByte(0xC2); m.WriteByte(0); m.WriteByte(60);
            Str(m, acc + "_tray_" + Guid.NewGuid().ToString("N").Substring(0, 10));
            Str(m, acc); Str(m, pwd);
            Send(0x10, m.ToArray());

            var pinger = new System.Threading.Timer(_ => { try { Send(0xC0, new byte[0]); } catch { } }, null, 30000, 30000);
            try
            {
                var js = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
                while (!stopped)
                {
                    byte hdr; byte[] body;
                    ReadPacket(out hdr, out body);
                    int type = hdr >> 4;
                    if (type == 2) // CONNACK
                    {
                        if (body.Length < 2 || body[1] != 0) throw new Exception("broker rejected the login (code " + (body.Length > 1 ? body[1] : -1) + ")");
                        m = new MemoryStream(); m.WriteByte(0); m.WriteByte(1); Str(m, topic); m.WriteByte(1);
                        Send(0x82, m.ToArray());
                    }
                    else if (type == 9) // SUBACK
                    {
                        if (body.Length >= 3 && body[2] == 0x80) throw new Exception("subscription rejected");
                        Log.Write("MQTT: subscribed to " + cfg.SerialNumber);
                    }
                    else if (type == 3) // PUBLISH
                    {
                        int tl = (body[0] << 8) | body[1];
                        int off = 2 + tl;
                        int qos = (hdr >> 1) & 3;
                        if (qos > 0) { Send(0x40, new[] { body[off], body[off + 1] }); off += 2; }
                        string json = Encoding.UTF8.GetString(body, off, body.Length - off);
                        try { Handle(js.Deserialize<Dictionary<string, object>>(json)); } catch { }
                    }
                }
            }
            finally { pinger.Dispose(); }
        }

        void Handle(Dictionary<string, object> msg)
        {
            var p = EcoFlowApi.GetOr(msg, "params", null) as Dictionary<string, object>;
            if (p == null || p.Count == 0) return;
            string type = Convert.ToString(EcoFlowApi.GetOr(msg, "typeCode", ""));
            string prefix;
            switch (type)
            {
                case "pdStatus": prefix = "pd."; break;
                case "bmsStatus": prefix = "bms_bmsStatus."; break;
                case "emsStatus": prefix = "bms_emsStatus."; break;
                case "invStatus": prefix = "inv."; break;
                case "mpptStatus": prefix = "mppt."; break;
                default: prefix = ""; break;
            }
            var outp = new Dictionary<string, object>();
            foreach (var kv in p)
            {
                if (kv.Key.Contains(".")) outp[kv.Key] = kv.Value;          // already a full key
                else if (prefix.Length > 0) outp[prefix + kv.Key] = kv.Value;
            }
            if (outp.Count > 0) Fire(Params, outp);
        }

        static void Fire<T>(Action<T> a, T v) { if (a != null) try { a(v); } catch { } }

        void Send(byte type, byte[] body)
        {
            var ms = new MemoryStream(); ms.WriteByte(type);
            int len = body.Length;
            do { byte b = (byte)(len % 128); len /= 128; if (len > 0) b |= 128; ms.WriteByte(b); } while (len > 0);
            ms.Write(body, 0, body.Length);
            var a = ms.ToArray();
            lock (writeLock) { stream.Write(a, 0, a.Length); stream.Flush(); }
        }

        void ReadPacket(out byte hdr, out byte[] body)
        {
            var one = new byte[1];
            ReadN(one, 1); hdr = one[0];
            int len = 0, mul = 1;
            for (int i = 0; ; i++)
            {
                ReadN(one, 1);
                len += (one[0] & 127) * mul; mul *= 128;
                if ((one[0] & 128) == 0) break;
                if (i >= 3) throw new IOException("malformed MQTT packet");
            }
            body = new byte[len];
            ReadN(body, len);
        }

        void ReadN(byte[] buf, int n)
        {
            int o = 0;
            while (o < n)
            {
                int r = stream.Read(buf, o, n - o);
                if (r <= 0) throw new IOException("connection closed by the server");
                o += r;
            }
        }

        static void Str(MemoryStream m, string v)
        {
            var b = Encoding.UTF8.GetBytes(v);
            m.WriteByte((byte)(b.Length >> 8)); m.WriteByte((byte)b.Length); m.Write(b, 0, b.Length);
        }
    }

    // --------------------------------------------------------------- tray
    public class TrayApp : ApplicationContext
    {
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);

        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunName = "EcoFlowTray";

        readonly NotifyIcon tray = new NotifyIcon();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly SynchronizationContext ui;
        Config cfg = Config.Load();
        ToolStripMenuItem miStatus, miAuto;
        IntPtr iconHandle = IntPtr.Zero;
        string iconKey;
        BatteryState last;
        bool lowWarned, busy;

        // live MQTT data (written by the background thread, read on the UI thread)
        const int LiveStaleSec = 120;
        readonly object liveLock = new object();
        readonly Dictionary<string, object> live = new Dictionary<string, object>();
        DateTime liveTime = DateTime.MinValue;
        bool liveDirty, wasLive;
        string liveError;
        string deviceName = "River 2";
        LiveFeed feed;
        readonly System.Windows.Forms.Timer uiTimer = new System.Windows.Forms.Timer { Interval = 1000 };

        bool LiveFresh { get { lock (liveLock) return (DateTime.Now - liveTime).TotalSeconds < LiveStaleSec; } }

        public TrayApp()
        {
            ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
            Log.Write("Started");

            var menu = new ContextMenuStrip();
            miStatus = new ToolStripMenuItem("No data") { Enabled = false };
            menu.Items.Add(miStatus);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Refresh now", null, (s, e) => Refresh());
            menu.Items.Add("Settings…", null, (s, e) => ShowSettings());
            miAuto = new ToolStripMenuItem("Start with Windows", null, (s, e) => ToggleAutostart()) { Checked = IsAutostart() };
            menu.Items.Add(miAuto);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Exit", null, (s, e) => Quit());

            tray.ContextMenuStrip = menu;
            tray.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) OnLeftClick(); };
            tray.DoubleClick += (s, e) => ShowSettings();
            SetIcon(null, "…");
            tray.Text = "EcoFlow River 2";
            tray.Visible = true;

            // fallback cloud polling — runs only while there is no live stream
            timer.Tick += (s, e) => { if (!LiveFresh) Refresh(); };
            ApplyInterval();
            uiTimer.Tick += (s, e) => UiTick();
            uiTimer.Start();

            if (!cfg.IsComplete) ShowSettings(); else { Refresh(); StartFeed(); }
        }

        void ApplyInterval() { timer.Stop(); timer.Interval = Math.Max(10, cfg.IntervalSec) * 1000; timer.Start(); }

        void StartFeed()
        {
            if (feed != null) feed.Stop();
            lock (liveLock) { live.Clear(); liveTime = DateTime.MinValue; liveDirty = false; liveError = null; }
            wasLive = false;
            if (!cfg.IsComplete) return;
            feed = new LiveFeed(cfg);
            feed.Params += p =>
            {
                lock (liveLock)
                {
                    foreach (var kv in p) live[kv.Key] = kv.Value;
                    liveTime = DateTime.Now; liveDirty = true; liveError = null;
                }
            };
            feed.Status += s => { lock (liveLock) liveError = s; };
            feed.Start();
        }

        void UiTick()
        {
            Dictionary<string, object> copy = null; DateTime t;
            lock (liveLock)
            {
                t = liveTime;
                if (liveDirty) { copy = new Dictionary<string, object>(live); liveDirty = false; }
            }
            bool fresh = (DateTime.Now - t).TotalSeconds < LiveStaleSec;
            if (copy != null && fresh)
            {
                var st = BatteryState.From(copy);
                if (st.Soc < 0 && last != null) st.Soc = last.Soc;   // the first packets may arrive without the percentage
                if (st.Soc < 0) return;
                st.Name = deviceName; st.Live = true; st.Online = true; st.Time = t;
                if (!wasLive) Log.Write("Live data: " + st.Soc + "%, " + FlowText(st) + ", " + TimeText(st) + (st.Charging ? ", charging" : ""));
                wasLive = true;
                Show(st);
            }
            else if (wasLive && !fresh)
            {
                // the stream went silent — the station went offline or the internet dropped
                wasLive = false;
                Log.Write("No live data for " + LiveStaleSec + " s");
                Refresh();
            }
        }

        void OnLeftClick()
        {
            if (last != null && last.Live && LiveFresh) { ShowDetails(); return; }
            miStatus.Text = "Refreshing…";
            Refresh();
            if (feed == null && cfg.IsComplete) StartFeed();
        }

        void ShowDetails()
        {
            var st = last;
            string text = st.Soc + "%" + (st.Charging ? " — charging" : "") + "\n" + FlowText(st);
            string tm = TimeText(st);
            if (tm.Length > 0) text += "\n" + tm;
            text += "\nUpdated " + st.Time.ToString("HH:mm:ss");
            tray.ShowBalloonTip(5000, st.Name, text, ToolTipIcon.None);
        }

        void Refresh()
        {
            if (busy || !cfg.IsComplete) return;
            busy = true;
            var api = new EcoFlowApi(cfg);
            ThreadPool.QueueUserWorkItem(_ =>
            {
                BatteryState st = null; string err = null;
                try { st = api.FetchSnapshot(); } catch (Exception ex) { err = ex.Message; Log.Write("HTTP: " + err); }
                ui.Post(__ =>
                {
                    busy = false;
                    if (st != null) deviceName = st.Name;
                    if (LiveFresh) return;              // live data takes priority over the cache
                    if (st != null) Show(st); else ShowError(err);
                }, null);
            });
        }

        static string FlowText(BatteryState st)
        {
            if (st.WattsIn < 0 && st.WattsOut < 0) return "";
            return "In " + Math.Max(0, st.WattsIn) + "W  Out " + Math.Max(0, st.WattsOut) + "W";
        }

        static string TimeText(BatteryState st)
        {
            if (st.Charging && st.ChargeMin > 0) return "full in " + Hm(st.ChargeMin);
            if (!st.Charging && st.DischargeMin > 0) return Hm(st.DischargeMin) + " left";
            if (!st.Charging && st.WattsOut == 0) return "no load";
            return "";
        }

        void Show(BatteryState st)
        {
            last = st;
            SetIcon(st, st.Soc.ToString());

            if (!st.Online)
            {
                // the cloud returns the last stored snapshot — power/time in it are out of date
                SetTip(st.Name + ": " + st.Soc + "% (old data)\nStation is offline");
                miStatus.Text = st.Soc + "% — station is offline, showing the last known level";
                return;
            }

            string flow = FlowText(st);
            string time = TimeText(st);
            string when = st.Live ? st.Time.ToString("HH:mm:ss") : "cloud cache, may be out of date";

            string tip = st.Name + ": " + st.Soc + "%" + (st.Charging ? " ⚡" : "");
            if (flow.Length > 0) tip += "\n" + flow;
            if (time.Length > 0) tip += "\n" + time;
            tip += st.Live ? "\n" + when : "\n(cloud cache)";
            SetTip(tip);
            string err; lock (liveLock) err = liveError;
            miStatus.Text = st.Soc + "%   " + flow + (time.Length > 0 ? "   (" + time + ")" : "") + "   • " + when +
                            (!st.Live && err != null ? "   • " + err : "");

            if (!st.Charging && st.Soc <= cfg.LowThreshold && !lowWarned)
            {
                lowWarned = true;
                tray.ShowBalloonTip(8000, "EcoFlow River 2", "Low battery: " + st.Soc + "%", ToolTipIcon.Warning);
            }
            if (st.Soc > cfg.LowThreshold + 5 || st.Charging) lowWarned = false;
        }

        void ShowError(string err)
        {
            if (last == null) SetIcon(null, "?");
            SetTip("EcoFlow: error\n" + err);
            miStatus.Text = "Error: " + err;
        }

        static string Hm(int min) { return (min / 60) + "h " + (min % 60).ToString("00") + "m"; }

        void SetTip(string t) { tray.Text = t.Length > 63 ? t.Substring(0, 63) : t; }

        // draws the icon: the percentage on a coloured "battery" tile
        void SetIcon(BatteryState st, string text)
        {
            int sz = Math.Max(16, SystemInformation.SmallIconSize.Width);
            string key = text + "|" + (st == null ? "-" : st.Soc + "|" + st.Online + "|" + st.Charging) + "|" + sz;
            if (key == iconKey) return;   // live data arrives every 1–3 s — don't redraw unless something changed
            iconKey = key;
            using (var bmp = new Bitmap(sz, sz))
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                g.Clear(Color.Transparent);

                Color bg = Color.FromArgb(90, 90, 90);
                if (st != null)
                {
                    if (!st.Online) bg = Color.FromArgb(110, 110, 110);
                    else if (st.Charging) bg = Color.FromArgb(0, 120, 215);
                    else if (st.Soc <= cfg.LowThreshold) bg = Color.FromArgb(200, 30, 30);
                    else if (st.Soc <= 50) bg = Color.FromArgb(215, 140, 0);
                    else bg = Color.FromArgb(20, 150, 60);
                }

                float r = sz * 0.2f;
                using (var path = RoundRect(new RectangleF(0, 0, sz - 1, sz - 1), r))
                using (var b = new SolidBrush(bg))
                    g.FillPath(b, path);

                // level bar at the bottom
                if (st != null && st.Soc >= 0)
                {
                    float w = (sz - 4) * Math.Min(100, st.Soc) / 100f;
                    using (var b = new SolidBrush(Color.FromArgb(230, 255, 255, 255)))
                        g.FillRectangle(b, 2, sz - Math.Max(2, sz / 8) - 1, w, Math.Max(2, sz / 8));
                }

                float fs = text.Length >= 3 ? sz * 0.48f : sz * 0.66f;
                using (var f = new Font("Segoe UI", fs, FontStyle.Bold, GraphicsUnit.Pixel))
                using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                    g.DrawString(text, f, Brushes.White, new RectangleF(-1, -sz * 0.08f, sz + 2, sz), sf);

                IntPtr h = bmp.GetHicon();
                var old = tray.Icon;
                tray.Icon = Icon.FromHandle(h);
                if (old != null) old.Dispose();
                if (iconHandle != IntPtr.Zero) DestroyIcon(iconHandle);
                iconHandle = h;
            }
        }

        static GraphicsPath RoundRect(RectangleF r, float rad)
        {
            var p = new GraphicsPath(); float d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        // ---------------- settings
        bool settingsOpen;
        void ShowSettings()
        {
            if (settingsOpen) return;
            settingsOpen = true;
            using (var f = new SettingsForm(cfg))
            {
                if (f.ShowDialog() == DialogResult.OK)
                {
                    cfg = f.Result; cfg.Save();
                    last = null; lowWarned = false;
                    ApplyInterval(); Refresh(); StartFeed();
                }
            }
            settingsOpen = false;
        }

        // ---------------- autostart
        static bool IsAutostart()
        {
            using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) return k != null && k.GetValue(RunName) != null;
        }
        void ToggleAutostart()
        {
            using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (IsAutostart()) k.DeleteValue(RunName, false);
                else k.SetValue(RunName, "\"" + Application.ExecutablePath + "\"");
            }
            miAuto.Checked = IsAutostart();
        }

        void Quit()
        {
            timer.Stop(); uiTimer.Stop();
            if (feed != null) feed.Stop();
            tray.Visible = false;
            tray.Dispose();
            if (iconHandle != IntPtr.Zero) DestroyIcon(iconHandle);
            ExitThread();
        }
    }

    // --------------------------------------------------------------- settings form
    public class SettingsForm : Form
    {
        public Config Result;
        TextBox tbAccess, tbSecret, tbSn;
        ComboBox cbHost;
        NumericUpDown nuInterval, nuLow;

        public SettingsForm(Config c)
        {
            Text = "EcoFlow River 2 — Settings";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = new Font("Segoe UI", 9f);
            ClientSize = new Size(470, 330);
            TopMost = true;

            var info = new LinkLabel
            {
                Text = "Get your keys at developer.ecoflow.com → Become a Developer → Access Key / Secret Key " +
                       "(sign in with the same account as in the EcoFlow app).",
                Location = new Point(12, 10), Size = new Size(446, 36)
            };
            info.LinkArea = new LinkArea(info.Text.IndexOf("developer.ecoflow.com"), "developer.ecoflow.com".Length);
            info.LinkClicked += (s, e) => { try { System.Diagnostics.Process.Start("https://developer.ecoflow.com/us/security"); } catch { } };
            Controls.Add(info);

            int y = 56;
            tbAccess = AddText("Access Key:", c.AccessKey, ref y, false);
            tbSecret = AddText("Secret Key:", c.SecretKey, ref y, true);
            tbSn = AddText("Serial number:", c.SerialNumber, ref y, false);

            var btnFind = new Button { Text = "Find", Location = new Point(388, y - 32), Size = new Size(70, 25) };
            tbSn.Width = 230;
            btnFind.Click += (s, e) => FindDevices();
            Controls.Add(btnFind);

            Controls.Add(new Label { Text = "Server:", Location = new Point(12, y + 3), AutoSize = true });
            cbHost = new ComboBox { Location = new Point(150, y), Width = 308, DropDownStyle = ComboBoxStyle.DropDown };
            cbHost.Items.AddRange(new object[] { "https://api-e.ecoflow.com", "https://api-a.ecoflow.com", "https://api.ecoflow.com" });
            cbHost.Text = c.Host;
            Controls.Add(cbHost);
            y += 32;

            Controls.Add(new Label { Text = "Fallback poll, sec:", Location = new Point(12, y + 3), AutoSize = true });
            nuInterval = new NumericUpDown { Location = new Point(150, y), Width = 80, Minimum = 10, Maximum = 3600, Value = Math.Max(10, Math.Min(3600, c.IntervalSec)) };
            Controls.Add(nuInterval);
            y += 32;

            Controls.Add(new Label { Text = "Warn at, %:", Location = new Point(12, y + 3), AutoSize = true });
            nuLow = new NumericUpDown { Location = new Point(150, y), Width = 80, Minimum = 0, Maximum = 100, Value = c.LowThreshold };
            Controls.Add(nuLow);
            y += 34;

            Controls.Add(new Label
            {
                Text = "Leave the serial number empty to use the first River on the account. Server: api-e — Europe, api-a — Americas.",
                Location = new Point(12, y), Size = new Size(446, 34), ForeColor = SystemColors.GrayText
            });

            var ok = new Button { Text = "Save", Location = new Point(282, 292), Size = new Size(90, 28), DialogResult = DialogResult.None };
            var cancel = new Button { Text = "Cancel", Location = new Point(378, 292), Size = new Size(80, 28), DialogResult = DialogResult.Cancel };
            ok.Click += (s, e) =>
            {
                Result = Collect();
                if (!Result.IsComplete) { MessageBox.Show(this, "Enter the Access Key and Secret Key.", Text); return; }
                DialogResult = DialogResult.OK;
            };
            Controls.Add(ok); Controls.Add(cancel);
            AcceptButton = ok; CancelButton = cancel;
        }

        TextBox AddText(string label, string val, ref int y, bool secret)
        {
            Controls.Add(new Label { Text = label, Location = new Point(12, y + 3), AutoSize = true });
            var tb = new TextBox { Location = new Point(150, y), Width = 308, Text = val, UseSystemPasswordChar = secret };
            Controls.Add(tb);
            y += 32;
            return tb;
        }

        Config Collect()
        {
            return new Config
            {
                AccessKey = tbAccess.Text.Trim(),
                SecretKey = tbSecret.Text.Trim(),
                SerialNumber = tbSn.Text.Trim(),
                Host = cbHost.Text.Trim().Length > 0 ? cbHost.Text.Trim().TrimEnd('/') : "https://api-e.ecoflow.com",
                IntervalSec = (int)nuInterval.Value,
                LowThreshold = (int)nuLow.Value
            };
        }

        void FindDevices()
        {
            var c = Collect();
            if (!c.IsComplete) { MessageBox.Show(this, "Enter the Access Key and Secret Key first.", Text); return; }
            Cursor = Cursors.WaitCursor;
            try
            {
                var devs = new EcoFlowApi(c).ListDevices();
                if (devs.Count == 0) { MessageBox.Show(this, "No devices found.", Text); return; }
                var sb = new StringBuilder();
                foreach (var d in devs)
                    sb.AppendLine(Convert.ToString(d.ContainsKey("sn") ? d["sn"] : "") + "  —  " +
                                  Convert.ToString(d.ContainsKey("productName") ? d["productName"] : (d.ContainsKey("deviceName") ? d["deviceName"] : "")) +
                                  (Convert.ToString(d.ContainsKey("online") ? d["online"] : "") == "1" ? "  (online)" : "  (offline)"));
                var pick = devs.FirstOrDefault(x => Convert.ToString(x.ContainsKey("productName") ? x["productName"] : "").ToUpperInvariant().Contains("RIVER")) ?? devs[0];
                tbSn.Text = Convert.ToString(pick["sn"]);
                MessageBox.Show(this, "Found:\n\n" + sb + "\nSelected: " + tbSn.Text, Text);
            }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error); }
            finally { Cursor = Cursors.Default; }
        }
    }

    // --------------------------------------------------------------- entry
    static class Program
    {
        [STAThread]
        static void Main()
        {
            bool created;
            using (new Mutex(true, "EcoFlowTray_SingleInstance", out created))
            {
                if (!created) return;
                ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; // TLS 1.2
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayApp());
            }
        }
    }
}
