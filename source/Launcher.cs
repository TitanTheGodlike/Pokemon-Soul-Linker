// What the Soul Link window does: settings, finding BizHawk and the game, join codes, hosting and
// joining (starting the link), randomized runs, downloads and sharing. The window itself is Window.cs.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// your settings: profiles\<profile>.json, shared with the BizHawk script (which stores its own fields there)
static class Settings {
  public static string FilePath;
  static Dictionary<string, object> Load() {
    try {
      if (File.Exists(FilePath)) {
        var d = Shared.ParseObject(Shared.Json(int.MaxValue), File.ReadAllText(FilePath, Encoding.UTF8));
        if (d != null) return d;
      }
    } catch { }
    return new Dictionary<string, object>();
  }
  // a setting, or null if it isn't there (or is empty)
  public static object Get(string name) {
    object v = Shared.Field(Load(), name);
    if (v == null || Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture) == "") return null;
    return v;
  }
  public static string Str(string name) {
    object v = Get(name);
    return v == null ? "" : Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture);
  }
  public static bool Bool(string name) { return Shared.Bool(Get(name)); }
  public static int Int(string name, int fallback) { object v = Get(name); return v == null ? fallback : Shared.Int(v); }
  // Save("name", value, "name", value, ...) - keeps the fields the BizHawk script stores (id, rules, ...)
  public static void Save(params object[] pairs) {
    var d = Load();
    for (int i = 0; i + 1 < pairs.Length; i += 2) d[(string)pairs[i]] = pairs[i + 1];
    File.WriteAllText(FilePath, Shared.Json(int.MaxValue).Serialize(d), Shared.Utf8);   // (no byte-order mark: Lua reads it too)
  }
}

class JoinTarget { public string Address; public int Port; public string Secret; }
class ReleaseAsset { public string Name, Url, Tag; }
class HostResult { public List<KeyValuePair<string, string>> Codes; public string Note; }

static class Launcher {
  public static string Root, ProfileName, Runtime, GamePidFile;
  public static bool NoRouter;
  public const int DefaultPort = 47800;
  const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  public const string VCRuntimeUrl = "https://aka.ms/vs/17/release/vc_redist.x64.exe";   // (Microsoft's own download link)
  static readonly Dictionary<string, string> GameCodes = new Dictionary<string, string> {
    { "IRB", "B" }, { "IRA", "W" }, { "IRE", "B2" }, { "IRD", "W2" },
    { "ADA", "D" }, { "APA", "P" }, { "CPU", "Pt" }, { "IPK", "HG" }, { "IPG", "SS" } };
  public const string Poke = "Pokémon";

  public static int Run(string[] args) {
    ProfileName = "default";
    for (int i = 0; i < args.Length; i++) {
      string k = args[i].TrimStart('-').ToLowerInvariant();
      if (k == "profile" && i + 1 < args.Length) ProfileName = args[++i];
      else if (k == "norouter") NoRouter = true;   // (don't ask the router to open the port: testing on one PC)
    }
    try {
      if (!Regex.IsMatch(ProfileName, "^[0-9A-Za-z_.-]{1,64}$")) throw new Exception("That profile name can't be used.");
      Root = Shared.Root;
      Settings.FilePath = Path.Combine(Root, "profiles", ProfileName + ".json");
      Runtime = Path.Combine(Root, "runtime", ProfileName);
      Directory.CreateDirectory(Path.Combine(Root, "profiles"));
      Directory.CreateDirectory(Runtime);
      GamePidFile = Path.Combine(Runtime, "game.pid");
      ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
      // first run: look for BizHawk and the game in the usual places
      if (Settings.Str("bizhawk") == "") { string b = FindBizHawk(); if (b != "") Settings.Save("bizhawk", b); }
      if (Settings.Str("rom") == "") { string g = FindGame(); if (g != "") Settings.Save("rom", g); }
      // (older versions made a "Soul Link" shortcut that started PowerShell; this program replaces it)
      Shared.Delete(Path.Combine(Root, "Soul Link.lnk"));
      Application.EnableVisualStyles();
      Application.Run(new Window());
      return 0;
    } catch (Exception e) {
      MessageBox.Show("Soul Link couldn't start:\n" + e.Message, "Soul Link", MessageBoxButtons.OK, MessageBoxIcon.Error);
      return 1;
    }
  }

  // keep the window responding during long steps
  public static void Pump() { if (Application.MessageLoop) Application.DoEvents(); }
  static DateTime lastPump = DateTime.MinValue;
  static void PumpOften() {   // (in loops: at most every 30 ms)
    if ((DateTime.Now - lastPump).TotalMilliseconds < 30) return;
    lastPump = DateTime.Now;
    Pump();
  }

  // ------------------------------------------------------------------ finding files
  static string[] UsualFolders() {
    string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    return new[] { Path.Combine(home, "Downloads"), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
      Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments) };
  }
  // files matching any of $patterns in dir and up to $depth folders below it
  static List<FileInfo> FindFiles(string dir, string[] patterns, int depth) {
    var acc = new List<FileInfo>();
    FindInto(dir, patterns, depth, acc);
    return acc;
  }
  static void FindInto(string dir, string[] patterns, int depth, List<FileInfo> acc) {
    if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return;
    var di = new DirectoryInfo(dir);
    foreach (var p in patterns) { try { acc.AddRange(di.GetFiles(p)); } catch { } }
    if (depth <= 0) return;
    DirectoryInfo[] subs;
    try { subs = di.GetDirectories(); } catch { return; }
    foreach (var d in subs) {
      if ((d.Attributes & FileAttributes.ReparsePoint) != 0) continue;
      FindInto(d.FullName, patterns, depth - 1, acc);
    }
  }

  public static string FindBizHawk() {
    string saved = Settings.Str("bizhawk");
    if (saved != "" && File.Exists(saved)) return saved;
    foreach (var c in new[] { Path.Combine(Root, "BizHawk", "EmuHawk.exe"), Path.Combine(Path.GetDirectoryName(Root) ?? Root, "BizHawk", "EmuHawk.exe") })
      if (File.Exists(c)) return c;
    foreach (var dir in UsualFolders()) {
      var hit = FindFiles(dir, new[] { "EmuHawk.exe" }, 3).FirstOrDefault();
      if (hit != null) return hit.FullName;
    }
    return "";
  }
  public static string FindGame() {
    string saved = Settings.Str("rom");
    if (saved != "" && File.Exists(saved)) return saved;
    foreach (var dir in UsualFolders()) {
      var hit = FindFiles(dir, new[] { "*.nds", "*.zip" }, 3)
        .Where(f => Regex.IsMatch(f.Name, "Pok.mon.*(Black|White|Diamond|Pearl|Platinum|Heart ?Gold|Soul ?Silver)", RegexOptions.IgnoreCase))
        .OrderBy(f => f.Extension.Equals(".nds", StringComparison.OrdinalIgnoreCase) ? 0 : 1).FirstOrDefault();
      if (hit != null) return hit.FullName;
    }
    return "";
  }

  // ------------------------------------------------------------------ join codes
  // address + port in 10 letters, then "-" and the room key (6 letters)
  public static string ToCode(string ip, int port) {
    ulong n = 0;
    foreach (var b in ip.Split('.')) n = n * 256 + ulong.Parse(b);
    n = n * 65536 + (ulong)port;
    var s = new char[10];
    for (int i = 9; i >= 0; i--) { s[i] = Alphabet[(int)(n % 32)]; n /= 32; }
    var t = new string(s);
    return t.Substring(0, 5) + "-" + t.Substring(5);
  }
  // a random room key: 6 letters (30 bits), part of every join code
  public static string NewSecret() {
    var b = new byte[6];
    using (var rng = new RNGCryptoServiceProvider()) rng.GetBytes(b);
    var s = new StringBuilder();
    foreach (var x in b) s.Append(Alphabet[x % 32]);
    return s.ToString();
  }
  // what the link checks: the code's room key, plus the optional room password
  public static string RoomKey(string secret, string password) {
    string pw = (password ?? "").Trim();
    if (secret != "" && pw != "") return secret + "|" + pw;
    if (secret != "") return secret;
    return pw;
  }
  public static JoinTarget FromCode(string c) {
    string t = (c ?? "").Trim();
    var m = Regex.Match(t, @"^([A-Za-z0-9\.\-]+\.[A-Za-z0-9\-]+)(:(\d+))?$");
    if (t.Contains(".") && m.Success) {   // a plain address (or address:port)
      int p = DefaultPort;
      if (m.Groups[3].Success && (!int.TryParse(m.Groups[3].Value, out p) || p < 1 || p > 65535)) return null;
      return new JoinTarget { Address = m.Groups[1].Value, Port = p, Secret = "" };
    }
    t = Regex.Replace(t.ToUpperInvariant(), "[^0-9A-Z]", "").Replace('O', '0');
    t = Regex.Replace(t, "[IL]", "1");
    if (t.Length != 10 && t.Length != 16) return null;
    string secret = t.Length == 16 ? t.Substring(10) : "";
    t = t.Substring(0, 10);
    ulong n = 0;
    foreach (char ch in t) {
      int i = Alphabet.IndexOf(ch);
      if (i < 0) return null;
      n = n * 32 + (ulong)i;
    }
    int port = (int)(n % 65536); n /= 65536;
    var oct = new string[4];
    for (int i = 3; i >= 0; i--) { oct[i] = (n % 256).ToString(); n /= 256; }
    return new JoinTarget { Address = string.Join(".", oct), Port = port, Secret = secret };
  }

  // ------------------------------------------------------------------ network
  // this PC's address on its network (the one used for the internet)
  public static string GetLanIp() {
    try {
      using (var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp)) {
        s.Connect("192.0.2.1", 9);   // (nothing is sent: this only asks Windows which address it would use)
        var ep = s.LocalEndPoint as IPEndPoint;
        if (ep != null && !ep.Address.Equals(IPAddress.Any)) return ep.Address.ToString();
      }
    } catch { }
    return null;
  }
  public static string GetTailscaleIp() {
    try {
      foreach (var ni in NetworkInterface.GetAllNetworkInterfaces()) {
        if (ni.OperationalStatus != OperationalStatus.Up) continue;
        foreach (var a in ni.GetIPProperties().UnicastAddresses) {
          string ip = a.Address.ToString();
          if (a.Address.AddressFamily == AddressFamily.InterNetwork && Regex.IsMatch(ip, @"^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.")) return ip;
        }
      }
    } catch { }
    return null;
  }
  public static bool IsPrivate(string ip) {
    return Regex.IsMatch(ip, @"^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|127\.)");
  }
  // ask the router (UPnP) to forward the port to this PC; returns the internet address or null
  static string OpenRouterPort(int port, string lan) {
    try {
      var t = Type.GetTypeFromProgID("HNetCfg.NATUPnP");
      if (t == null) return null;
      dynamic nat = Activator.CreateInstance(t);
      dynamic maps = nat.StaticPortMappingCollection;
      if (maps == null) return null;
      try { maps.Remove(port, "TCP"); } catch { }
      dynamic m = maps.Add(port, "TCP", port, lan, true, "Soul Link");
      if (m != null) { string ext = m.ExternalIPAddress; if (!string.IsNullOrEmpty(ext)) return ext; }
      foreach (dynamic x in maps) { if ((int)x.ExternalPort == port && (string)x.Protocol == "TCP") return (string)x.ExternalIPAddress; }
    } catch { }
    return null;
  }
  static void CloseRouterPort(int port) {
    try {
      var t = Type.GetTypeFromProgID("HNetCfg.NATUPnP");
      if (t == null) return;
      dynamic nat = Activator.CreateInstance(t);
      dynamic maps = nat.StaticPortMappingCollection;
      if (maps != null) maps.Remove(port, "TCP");
    } catch { }
  }

  // ------------------------------------------------------------------ the game
  // your game in BizHawk (the link to the others runs on its own: see StartLink)
  public static Process StartGame(string mode) {
    string game = Settings.Str("rom"), emu = Settings.Str("bizhawk");
    if (game == "" || !File.Exists(game)) throw new Exception("Pick your Pokemon game file first.");
    if (emu == "" || !File.Exists(emu)) throw new Exception("Pick BizHawk (EmuHawk.exe) first, or press 'Get BizHawk'.");
    var psi = new ProcessStartInfo(emu, "--lua=\"" + Path.Combine(Root, "SoulLink.lua") + "\" \"" + game + "\"") {
      WorkingDirectory = Path.GetDirectoryName(emu), UseShellExecute = false };
    psi.EnvironmentVariables["SOULLINK_PROFILE"] = ProfileName;
    psi.EnvironmentVariables["SOULLINK_TEST"] = mode == "test" ? "1" : "";
    // BizHawk's Lua Console gets hidden by the script itself (unless the settings say to keep it)
    psi.EnvironmentVariables["SOULLINK_HIDE_CONSOLE"] = Settings.Bool("showLuaConsole") ? "" : "1";
    var p = Process.Start(psi);
    // the link keeps going while the game runs, even if the window is closed
    File.WriteAllText(GamePidFile, p.Id.ToString(), Encoding.ASCII);
    return p;
  }
  public static bool GameRunning() {
    string t = Shared.ReadShared(GamePidFile);
    int gp;
    return t != null && int.TryParse(t.Trim(), out gp) && gp > 0 && Shared.Alive(gp);
  }

  // your player id (shared with the BizHawk script, which makes one up too if it starts first)
  public static string MyId() {
    string id = Settings.Str("id");
    if (id == "") { id = new Random().Next(0, int.MaxValue).ToString("x8"); Settings.Save("id", id); }
    return id;
  }
  // the name others see in the lobby (in the game they see your trainer name)
  public static string LobbyName() {
    string n = Settings.Str("lobbyName");
    if (n == "") n = Environment.UserName ?? "";
    n = Regex.Replace(n, @"[^\p{L}\p{N} ._\-]", "").Trim();
    if (n.Length > 20) n = n.Substring(0, 20).Trim();
    return n == "" ? "Player" : n;
  }

  // the game code in a game file's header (IRB, IRA, IRE, IRD...; also inside a .zip),
  // "" for a file that isn't an NDS game, null if it can't be read
  public static string GameCode(string path) {
    if (string.IsNullOrEmpty(path)) return null;
    try { if (!File.Exists(path)) return null; } catch { return null; }
    var buf = new byte[16];
    try {
      if (path.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) {
        using (var z = ZipFile.OpenRead(path)) {
          var e = z.Entries.FirstOrDefault(x => x.Name.EndsWith(".nds", StringComparison.OrdinalIgnoreCase));
          if (e == null) return "";
          using (var s = e.Open()) ReadFully(s, buf);
        }
      } else {
        using (var fs = File.OpenRead(path)) ReadFully(fs, buf);
      }
    } catch { return null; }
    return Encoding.ASCII.GetString(buf, 12, 3);
  }
  static void ReadFully(Stream s, byte[] buf) {
    int got = 0, n;
    while (got < buf.Length && (n = s.Read(buf, got, buf.Length - got)) > 0) got += n;
  }
  // B, W, B2 or W2 ("" if unknown)
  public static string GameVersion(string path) {
    string c = GameCode(path), v;
    return c != null && GameCodes.TryGetValue(c, out v) ? v : "";
  }
  // which game a file is, for the check next to the game box (null if it can't be read)
  public static string GameName(string path) {
    string c = GameCode(path), v;
    if (c == null) return null;
    return GameCodes.TryGetValue(c, out v) ? Poke + " " + Shared.GameNames[v] : "";
  }
  public static string MixedMessage(string hostGame, string yours) {
    string hr = Shared.Region(hostGame);
    if (hr == "") return "Mixed games aren't supported: the host plays a game from another region.";
    string games = Shared.RegionGames(hr);
    string t = "Mixed games aren't supported: this lobby plays " + Poke + " " + games;
    if (yours != null && Shared.GameNames.ContainsKey(yours)) t += " and your game is " + Poke + " " + Shared.GameNames[yours];
    return t + ". Pick a " + games + " game file to join.";
  }

  // ------------------------------------------------------------------ the link
  // the link to the others: it is the lobby first, then carries your game's state once it runs.
  // It's this same program, started again; it stops once both this window and your game are closed.
  static void StartLink(string mode, string address, int port, string key, bool router, string room) {
    var a = new StringBuilder();
    a.Append("-Mode ").Append(mode).Append(" -Address ").Append(address).Append(" -Port ").Append(port)
     .Append(" -Profile ").Append(ProfileName).Append(" -ParentPid ").Append(Process.GetCurrentProcess().Id)
     .Append(" -Id ").Append(MyId()).Append(" -Name \"").Append(LobbyName()).Append("\" -GamePidFile \"").Append(GamePidFile).Append("\"");
    string gv = GameVersion(Settings.Str("rom"));
    if (gv != "") a.Append(" -Game ").Append(gv);
    if (router) a.Append(" -RemoveRouterPort");
    if (!string.IsNullOrEmpty(room)) a.Append(" -Room ").Append(room);
    var psi = new ProcessStartInfo(Application.ExecutablePath, a.ToString()) { UseShellExecute = false, WorkingDirectory = Root };
    psi.EnvironmentVariables["SOULLINK_KEY"] = key;   // (the room key stays off the command line)
    Process.Start(psi).Dispose();
  }

  // the link running for this profile (also one started by an earlier window): its process id, or 0
  public static int LinkPid(out string mode) {
    mode = "";
    try {
      string t = Shared.ReadShared(Path.Combine(Runtime, "link.pid"));
      if (t == null) return 0;
      var parts = t.Trim().Split(' ');
      int pid;
      if (!int.TryParse(parts[0], out pid)) return 0;
      if (parts.Length > 1) mode = parts[1];
      using (var p = Process.GetProcessById(pid)) {
        if (p.HasExited || p.ProcessName != Process.GetCurrentProcess().ProcessName) return 0;
      }
      return pid;
    } catch { return 0; }
  }
  public static bool LinkRunning() { string m; return LinkPid(out m) != 0; }

  // stop hosting/joining: the link stops (a running game keeps running) and closes the router port
  public static int StopLink() {
    string mode;
    int pid = LinkPid(out mode);
    if (pid != 0) {
      try { File.WriteAllText(Path.Combine(Runtime, "lobby_cmd.txt"), "quit", Encoding.ASCII); } catch { }
      DateTime deadline = DateTime.Now.AddSeconds(4);
      string m2;
      while (LinkPid(out m2) != 0 && DateTime.Now < deadline) { Thread.Sleep(50); Pump(); }
      if (LinkPid(out m2) != 0) {   // (it didn't answer)
        try { using (var p = Process.GetProcessById(pid)) p.Kill(); } catch { }
        if (mode == "host") CloseRouterPort(Settings.Int("port", DefaultPort));
        Shared.Delete(Path.Combine(Runtime, "link.pid"));
      }
    }
    foreach (var f in new[] { "in.json", "lobby.json", "lobby_cmd.txt" }) Shared.Delete(Path.Combine(Runtime, f));
    return pid != 0 ? 1 : 0;
  }

  // open a lobby: prepares the run, opens the router port and starts the link (not the game yet)
  public static HostResult DoHost(string key, Action<string> say, Func<string> getJar) {
    if (LinkRunning()) StopLink();
    int port = Settings.Int("port", DefaultPort);
    var room = PrepareRun(getJar, say);
    string roomB64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(Shared.Json(int.MaxValue).Serialize(room)));
    say("Opening port " + port + " on your router...");
    string lan = GetLanIp();
    string ext = lan != null && !NoRouter ? OpenRouterPort(port, lan) : null;
    string ts = GetTailscaleIp();
    string secret = NewSecret();
    var codes = new List<KeyValuePair<string, string>>();
    if (ext != null && !IsPrivate(ext)) codes.Add(new KeyValuePair<string, string>("Internet", ToCode(ext, port) + "-" + secret));
    if (ts != null) codes.Add(new KeyValuePair<string, string>("Tailscale", ToCode(ts, port) + "-" + secret));
    if (lan != null) codes.Add(new KeyValuePair<string, string>("Same Wi-Fi / LAN", ToCode(lan, port) + "-" + secret));
    if (codes.Count == 0) codes.Add(new KeyValuePair<string, string>("This PC", ToCode("127.0.0.1", port) + "-" + secret));
    Settings.Save("mode", "host", "port", port, "key", key, "hostCode", codes[0].Value, "hostCodeKind", codes[0].Key);
    StartLink("host", "127.0.0.1", port, RoomKey(secret, key), ext != null, roomB64);
    string note;
    if (codes.Any(c => c.Key == "Internet")) note = "Friends anywhere can join with the code.";
    else if (ts != null) note = "Friends outside your network: give them the Tailscale code (they need Tailscale too).";
    else note = "Only players on your network can join: your router didn't open port " + port + " (see the README).";
    return new HostResult { Codes = codes, Note = note };
  }

  public static JoinTarget DoJoin(string codeText, string key, Action<string> say, Func<string> getJar) {
    var t = FromCode(codeText);
    if (t == null) throw new Exception("That join code doesn't look right.");
    Settings.Save("mode", "join", "lastCode", codeText.Trim(), "key", key);
    // a randomized run: your own game gets randomized with the host's settings (once per run)
    say("Asking the host about the run...");
    string roomKey = RoomKey(t.Secret, key);
    var room = GetRoomInfo(t.Address, t.Port, roomKey);
    string mine = GameVersion(OriginalGame());
    string hostGame = Shared.Str(Shared.Field(room, "game"));
    if (room != null && Shared.Region(hostGame) != "" && Shared.Region(mine) != "" && Shared.Region(hostGame) != Shared.Region(mine))
      throw new Exception(MixedMessage(hostGame, mine));
    Shared.Delete(Path.Combine(Runtime, "refused.txt"));
    string rcode = Shared.Str(Shared.Field(room, "randomizer")), rrun = Shared.Str(Shared.Field(room, "run"));
    if (rcode != "") {
      if (!Regex.IsMatch(rcode, "^SLR1:[A-Za-z0-9+/=]{4,20000}$") || !Regex.IsMatch(rrun, "^[0-9A-Za-z_-]{1,32}$"))
        throw new Exception("The host's randomizer settings don't look right, so they weren't used.");
      EnsureRandomized(rcode, rrun, getJar, say);
    } else UseOriginalGame();
    if (LinkRunning()) StopLink();
    StartLink("join", t.Address, t.Port, roomKey, false, null);
    return t;
  }

  // ask the host what kind of run this is (its game, randomizer settings); null if it doesn't say
  static Dictionary<string, object> GetRoomInfo(string address, int port, string key) {
    try {
      using (var c = new TcpClient()) {
        var ar = c.BeginConnect(address, port, null, null);
        DateTime deadline = DateTime.Now.AddSeconds(5);
        while (!ar.AsyncWaitHandle.WaitOne(50)) { Pump(); if (DateTime.Now > deadline) return null; }
        c.EndConnect(ar);
        var s = c.GetStream();
        var hello = Shared.Utf8.GetBytes("hello " + key + "\n");
        s.Write(hello, 0, hello.Length);
        var text = new StringBuilder();
        var buf = new byte[65536];
        var chars = new char[65536 + 8];
        var dec = Shared.Utf8.GetDecoder();
        deadline = DateTime.Now.AddSeconds(4);
        while (DateTime.Now < deadline && text.Length < 400000) {
          if (c.Available == 0) {
            if (c.Client.Poll(0, SelectMode.SelectRead) && c.Available == 0) break;   // (closed)
            Thread.Sleep(30); Pump();
            continue;
          }
          int n = s.Read(buf, 0, Math.Min(buf.Length, c.Available));
          if (n <= 0) break;
          text.Append(chars, 0, dec.GetChars(buf, 0, n, chars, 0));
          string all = text.ToString();
          int start = 0, i;
          while ((i = all.IndexOf('\n', start)) >= 0) {
            string line = all.Substring(start, i - start).TrimEnd('\r');
            start = i + 1;
            if (line.StartsWith("room ")) {
              var parts = line.Split(new[] { ' ' }, 3);
              return parts.Length == 3 ? Shared.ParseObject(Shared.Json(400000), parts[2]) : null;
            }
          }
        }
      }
    } catch { }
    return null;
  }

  // ------------------------------------------------------------------ downloads
  // Downloads come in pieces and say how far they got, so the window keeps responding.
  public static void GetDownload(string url, string outFile, string what, Action<string> say) {
    var req = (HttpWebRequest)WebRequest.Create(url);
    req.UserAgent = "SoulLink";
    req.Timeout = 30000; req.ReadWriteTimeout = 30000;
    string part = outFile + ".part";
    long total, got = 0;
    using (var resp = req.GetResponse()) {
      total = resp.ContentLength;
      using (var input = resp.GetResponseStream())
      using (var fs = File.Create(part)) {
        var buf = new byte[65536];
        DateTime next = DateTime.MinValue;
        int n;
        while ((n = input.Read(buf, 0, buf.Length)) > 0) {
          fs.Write(buf, 0, n); got += n;
          PumpOften();
          if (DateTime.Now >= next) {
            next = DateTime.Now.AddMilliseconds(400);
            say(total > 0 ? string.Format("{0}... {1:N0} of {2:N0} MB", what, got / 1048576.0, total / 1048576.0)
                          : string.Format("{0}... {1:N0} MB", what, got / 1048576.0));
          }
        }
      }
    }
    if (total > 0 && new FileInfo(part).Length != total) { Shared.Delete(part); throw new Exception("the download was cut off. Try again."); }
    Shared.Delete(outFile);
    File.Move(part, outFile);
  }
  // unpack a zip into dest (replacing what's there), saying how far it got
  public static void ExpandZip(string zip, string dest, string what, Action<string> say) {
    string basePath = Path.GetFullPath(dest).TrimEnd('\\') + "\\";
    using (var z = ZipFile.OpenRead(zip)) {
      var all = z.Entries.ToList();
      int i = 0;
      DateTime next = DateTime.MinValue;
      foreach (var e in all) {
        i++;
        string target = Path.GetFullPath(Path.Combine(basePath, e.FullName));
        if (!target.StartsWith(basePath, StringComparison.OrdinalIgnoreCase)) continue;   // (no paths outside dest)
        if (e.FullName.EndsWith("/") || e.FullName.EndsWith("\\")) { Directory.CreateDirectory(target); continue; }
        Directory.CreateDirectory(Path.GetDirectoryName(target));
        e.ExtractToFile(target, true);
        PumpOften();
        if (DateTime.Now >= next) { next = DateTime.Now.AddMilliseconds(400); say(string.Format("{0}... {1}%", what, 100 * i / all.Count)); }
      }
    }
  }
  // the newest release file of a GitHub project whose name matches the pattern
  public static ReleaseAsset GetReleaseAsset(string repo, string namePattern) {
    var req = (HttpWebRequest)WebRequest.Create("https://api.github.com/repos/" + repo + "/releases/latest");
    req.UserAgent = "SoulLink"; req.Accept = "application/vnd.github+json";
    req.Timeout = 30000; req.ReadWriteTimeout = 30000;
    string json;
    using (var resp = req.GetResponse())
    using (var r = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) json = r.ReadToEnd();
    var rel = Shared.ParseObject(Shared.Json(int.MaxValue), json);
    var assets = Shared.Field(rel, "assets") as object[];
    if (assets != null) {
      foreach (var a in assets) {
        var d = a as Dictionary<string, object>;
        string name = Shared.Str(Shared.Field(d, "name"));
        if (Regex.IsMatch(name, namePattern, RegexOptions.IgnoreCase))
          return new ReleaseAsset { Name = name, Url = Shared.Str(Shared.Field(d, "browser_download_url")), Tag = Shared.Str(Shared.Field(rel, "tag_name")) };
      }
    }
    throw new Exception("GitHub didn't list a download for " + repo + ".");
  }
  // BizHawk: downloaded into the Soul Link folder; returns EmuHawk.exe
  public static string GetBizHawkDownload(Action<string> say, out string tag) {
    string dest = Path.Combine(Root, "BizHawk");
    foreach (var p in Process.GetProcessesByName("EmuHawk")) {
      try { if (p.MainModule.FileName.StartsWith(dest, StringComparison.OrdinalIgnoreCase)) throw new Exception("close BizHawk first, then press Get BizHawk again."); }
      catch (System.ComponentModel.Win32Exception) { }
      finally { p.Dispose(); }
    }
    say("Asking GitHub for the latest BizHawk...");
    var a = GetReleaseAsset("TASEmulators/BizHawk", @"win-x64\.zip$");
    string zip = Path.Combine(Path.GetTempPath(), a.Name);
    GetDownload(a.Url, zip, "Downloading BizHawk " + a.Tag, say);
    try { ExpandZip(zip, dest, "Unpacking BizHawk", say); } finally { Shared.Delete(zip); }
    var exe = FindFiles(dest, new[] { "EmuHawk.exe" }, 4).FirstOrDefault();
    if (exe == null) throw new Exception("EmuHawk.exe wasn't in the download.");
    tag = a.Tag;
    return exe.FullName;
  }
  public static string GetRandomizerDownload(Action<string> say) {
    var a = GetReleaseAsset("Ajarmar/universal-pokemon-randomizer-zx", @"\.zip$");
    string zip = Path.Combine(Path.GetTempPath(), a.Name);
    GetDownload(a.Url, zip, "Downloading the randomizer", say);
    string dest = Path.Combine(Root, "Randomizer");
    try { ExpandZip(zip, dest, "Unpacking the randomizer", say); } finally { Shared.Delete(zip); }
    var jar = FindFiles(dest, new[] { "PokeRandoZX.jar" }, 4).FirstOrDefault();
    return jar == null ? "" : jar.FullName;
  }
  // BizHawk needs Microsoft's Visual C++ 2015-2022 runtime (x64); many PCs have it, a fresh one may not
  public static bool HasVCRuntime() {
    foreach (var k in new[] { @"SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64", @"SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" }) {
      try {
        using (var key = Registry.LocalMachine.OpenSubKey(k)) {
          if (key != null && Shared.Int(key.GetValue("Installed")) == 1) return true;
        }
      } catch { }
    }
    return false;
  }

  // ------------------------------------------------------------------ randomized runs (Universal Pokemon Randomizer ZX)
  public static string FindRandomizer() {
    string saved = Settings.Str("upr");
    if (saved != "" && File.Exists(saved)) return saved;
    var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    foreach (var dir in new[] { Path.Combine(Root, "Randomizer"), Path.Combine(home, "Downloads"), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory) }) {
      var hit = FindFiles(dir, new[] { "PokeRandoZX.jar" }, 3).FirstOrDefault();
      if (hit != null) return hit.FullName;
    }
    return "";
  }
  // java.exe (or javaw.exe for a window) from PATH or JAVA_HOME
  public static string FindJava(bool window) {
    string exe = window ? "javaw.exe" : "java.exe";
    var dirs = new List<string>();
    string jh = Environment.GetEnvironmentVariable("JAVA_HOME");
    if (!string.IsNullOrEmpty(jh)) dirs.Add(Path.Combine(jh, "bin"));
    dirs.AddRange((Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'));
    foreach (var d in dirs) {
      try { string p = Path.Combine(d.Trim().Trim('"'), exe); if (d.Trim() != "" && File.Exists(p)) return p; } catch { }
    }
    return null;
  }
  public static string OriginalGame() {
    string o = Settings.Str("romOriginal");
    if (o != "" && File.Exists(o)) return o;
    return Settings.Str("rom");
  }
  // the randomizer needs a plain .nds; unpack a .zip copy of the game once
  static string PlainNds(string game) {
    if (!game.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) return game;
    string dir = Path.Combine(Root, "runtime", "randomized", "source");
    Directory.CreateDirectory(dir);
    using (var z = ZipFile.OpenRead(game)) {
      var e = z.Entries.FirstOrDefault(x => x.Name.EndsWith(".nds", StringComparison.OrdinalIgnoreCase));
      if (e == null) throw new Exception("There's no .nds game in that .zip.");
      string outFile = Path.Combine(dir, Path.GetFileName(e.Name));
      if (!File.Exists(outFile)) e.ExtractToFile(outFile);
      return outFile;
    }
  }
  // randomizer settings (.rnqs): remembered, or found near the randomizer and in your usual folders
  public static string FindRandomizerSettings() {
    string saved = Settings.Str("rnqs");
    if (saved != "" && File.Exists(saved)) return saved;
    string skip = Path.Combine(Root, "runtime");
    var places = new List<KeyValuePair<string, int>>();
    string jar = FindRandomizer();
    if (jar != "") {
      string d = Path.GetDirectoryName(jar);
      places.Add(new KeyValuePair<string, int>(d, 2));
      places.Add(new KeyValuePair<string, int>(Path.GetDirectoryName(d), 1));
    }
    var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    foreach (var d in new[] { Path.Combine(Root, "Randomizer"), Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
        Path.Combine(home, "Downloads"), Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory) })
      places.Add(new KeyValuePair<string, int>(d, 2));
    foreach (var drv in DriveInfo.GetDrives()) {
      try { if (drv.DriveType == DriveType.Fixed && drv.IsReady) places.Add(new KeyValuePair<string, int>(drv.RootDirectory.FullName, 1)); } catch { }
    }
    foreach (var pl in places) {
      var best = FindFiles(pl.Key, new[] { "*.rnqs" }, pl.Value)
        .Where(f => !f.FullName.StartsWith(skip, StringComparison.OrdinalIgnoreCase))
        .OrderByDescending(f => f.LastWriteTime).FirstOrDefault();
      if (best != null) { Settings.Save("rnqs", best.FullName); return best.FullName; }
    }
    return "";
  }
  static string SettingsCode(string file) { return "SLR1:" + Convert.ToBase64String(File.ReadAllBytes(file)); }
  static string ShortHash(string text) {
    using (var sha = SHA1.Create()) {
      var h = sha.ComputeHash(Encoding.UTF8.GetBytes(text));
      return string.Concat(h.Take(4).Select(b => b.ToString("x2")));
    }
  }
  static void NewRun() { Shared.Delete(Path.Combine(Runtime, "run.json")); }
  public static void UseOriginalGame() { string o = OriginalGame(); if (o != "") Settings.Save("rom", o); }

  // Your own game randomized with these settings, for this run. Made once and reused for the whole
  // run, so encounters and your save stay the same between sessions. A new run gets a new copy.
  static string EnsureRandomized(string code, string run, Func<string> getJar, Action<string> say) {
    string orig = OriginalGame();
    if (orig == "" || !File.Exists(orig)) throw new Exception("Pick your Pokemon game file first.");
    string h = ShortHash(code + "|" + run + "|" + Path.GetFileName(orig));
    string outDir = Path.Combine(Root, "runtime", "randomized");
    Directory.CreateDirectory(outDir);
    string baseName = Path.GetFileNameWithoutExtension(Regex.Replace(orig, @"\.zip$", ".nds", RegexOptions.IgnoreCase));
    string outFile = Path.Combine(outDir, baseName + " (randomized " + h + ").nds");
    if (!File.Exists(outFile)) {
      string java = FindJava(false);
      if (java == null) throw new Exception("Randomized runs need Java. Install it from adoptium.net (Temurin), then try again.");
      string jar = getJar();
      if (string.IsNullOrEmpty(jar)) throw new Exception("Randomized runs need the randomizer.");
      string src = PlainNds(orig);
      string settings = Path.Combine(outDir, h + ".rnqs");
      File.WriteAllBytes(settings, Convert.FromBase64String(code.Substring(5)));
      say("Randomizing your game for this run... (a few seconds)");
      string tmp = outFile + ".part.nds";
      Shared.Delete(tmp);
      string errText = RunAndWait(java, "-Xmx2048M -jar \"" + jar + "\" cli -s \"" + settings + "\" -i \"" + src + "\" -o \"" + tmp + "\"",
        Path.GetDirectoryName(jar), Path.Combine(outDir, "randomizer.log"), Path.Combine(outDir, "randomizer.err"));
      Shared.Delete(settings);
      if (!File.Exists(tmp)) {
        string why = string.Join(" ", (errText ?? "").Split('\n').Select(l => l.Trim()).Where(l => l != "").Take(3));
        throw new Exception("The randomizer didn't make a game. " + why);
      }
      // older randomized copies (other runs) only take up space
      foreach (var old in Directory.GetFiles(outDir, "*(randomized *).nds")) Shared.Delete(old);
      File.Move(tmp, outFile);
      NewRun();   // a new randomized game is a new run (and a new save)
    }
    Settings.Save("romOriginal", orig, "rom", outFile);
    return outFile;
  }
  // run a command-line program without a window, keeping this window responding; returns its errors
  static string RunAndWait(string exe, string args, string dir, string logFile, string errFile) {
    var psi = new ProcessStartInfo(exe, args) { WorkingDirectory = dir, UseShellExecute = false, CreateNoWindow = true,
      RedirectStandardOutput = true, RedirectStandardError = true };
    using (var p = Process.Start(psi)) {
      var output = p.StandardOutput.ReadToEndAsync();
      var errors = p.StandardError.ReadToEndAsync();
      while (!p.WaitForExit(100)) Pump();
      p.WaitForExit();
      try { File.WriteAllText(logFile, output.Result); File.WriteAllText(errFile, errors.Result); } catch { }
      return errors.Result;
    }
  }

  // host side: the run you host (randomizer settings + run id); also sets which game file to play
  public static Dictionary<string, object> PrepareRun(Func<string> getJar, Action<string> say) {
    var room = new Dictionary<string, object>();
    room["v"] = 1;
    if (Settings.Bool("randomized")) {
      string set = FindRandomizerSettings();
      if (set == "") throw new Exception("Pick randomizer settings first (Settings... next to 'Randomized run').");
      string run = Settings.Str("randRun");
      if (run == "") { run = Guid.NewGuid().ToString("N").Substring(0, 8); Settings.Save("randRun", run); }
      room["randomizer"] = SettingsCode(set);
      room["run"] = run;
      EnsureRandomized((string)room["randomizer"], run, getJar, say);
    } else UseOriginalGame();
    room["game"] = GameVersion(Settings.Str("rom"));   // (joiners with a game from another region can't join)
    return room;
  }

  // ------------------------------------------------------------------ sharing
  // "Soul Link.zip" on your Desktop: everything a friend needs (they use their own game file)
  public static string MakeShareZip() {
    return MakeShareZip(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Soul Link.zip"));
  }
  public static string MakeShareZip(string dest) {
    string tmp = dest + ".part";
    Shared.Delete(tmp);
    using (var zip = ZipFile.Open(tmp, ZipArchiveMode.Create)) {
      Action<string, string> add = (file, name) => zip.CreateEntryFromFile(file, "Soul Link/" + name, CompressionLevel.Optimal);
      add(Path.Combine(Root, "Soul Link.exe"), "Soul Link.exe");
      foreach (var f in new[] { "SoulLink.lua", "README.md", "LICENSE" }) if (File.Exists(Path.Combine(Root, f))) add(Path.Combine(Root, f), f);
      foreach (var f in Directory.GetFiles(Path.Combine(Root, "lib"), "*.lua")) add(f, "lib/" + Path.GetFileName(f));
      string art = Path.Combine(Root, "lib", "art");
      foreach (var f in Directory.GetFiles(art, "*", SearchOption.AllDirectories))
        add(f, "lib/art/" + f.Substring(art.Length + 1).Replace('\\', '/'));
      // the source code, so anyone can see (and rebuild) what the program does
      string src = Path.Combine(Root, "source");
      foreach (var f in Directory.GetFiles(src, "*.cs").Concat(Directory.GetFiles(src, "*.ico"))) add(f, "source/" + Path.GetFileName(f));
    }
    Shared.Delete(dest);
    File.Move(tmp, dest);
    return dest;
  }
}
