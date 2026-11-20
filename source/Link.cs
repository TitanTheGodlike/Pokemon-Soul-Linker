// The network link between the players ("Soul Link.exe -Mode host|join ...", started by the window).
// One player hosts, everyone else joins. It passes each game's state to the others and writes what
// it receives into runtime\<profile>\in.json for the BizHawk script to read. It is also the lobby:
// it runs as soon as you host or join (before anyone starts their game), tells everyone who is in
// the room (runtime\<profile>\lobby.json, for the window) and passes the host's "start the game for
// everyone" on. It keeps running while your game runs, and stops once the window and the game are
// both closed (or when the window says "quit" in lobby_cmd.txt).
//
// Lines on the wire:  "<type> <playerId> <json>\n"
//   pos | state  a game's position / Nuzlocke state (from the BizHawk script)
//   lobby        who someone is: name, game, host or not, playing or still in the lobby
//   bye          someone left (only the host sends these)
//   go           the host started the game for everyone (only the host sends these)
//   hello | room room key check / what kind of run this is (the host's game, randomizer settings)
//   refuse       the host turns a player away: their game is from another region (only games whose
//                areas line up can be linked, so mixed games aren't supported)
//
// Safety (the host's port is open to the internet while hosting):
//   - a connection must send "hello <room key>" within a few seconds; the key is part of the join
//     code, so only people with the code get in. Wrong keys make that address wait before trying again.
//   - every message is checked: known type, a sane player id, size limits, and valid JSON whose
//     t/id match the line. It is then written out again cleanly, so nothing a player sends can break
//     the files the game and the window read.
//   - each connection speaks for one player only: it can't send lines for anyone else, "bye" or "go".
//   - limits on connections and on how fast one connection may send.
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

class Peer {
  public TcpClient Client;
  public NetworkStream Stream;
  public Decoder Dec = new UTF8Encoding(false).GetDecoder();
  public StringBuilder Buf = new StringBuilder();
  public string Id;
  public bool Ok;
  public string Addr = "?";
  public DateTime Since = DateTime.Now;
  public int Second;
  public int LineCount;
  public DateTime? Gone;   // turned away (a game from another region): closed for them after 3 seconds
}

static class Link {
  // ---- arguments (the room key comes in the SOULLINK_KEY environment variable)
  static string Mode = "host", Address = "127.0.0.1", Profile = "default", Key = "", Room = "";
  static string Id = "", Name = "", Game = "", GamePidFile = "";
  static int Port = 47800, ParentPid = 0;
  static bool RemoveRouterPort = false;

  // ---- limits
  const int MaxLine = 131072;                 // longest line accepted (a big Nuzlocke state is ~20 KB)
  static readonly Dictionary<string, int> MaxSize = new Dictionary<string, int> { { "pos", 2048 }, { "lobby", 1024 }, { "state", 131072 } };
  const int MaxPeers = 12;                    // connections at once (logged in or not)
  const int AuthSeconds = 6;                  // time to send the room key
  const int MaxLinesPerSecond = 60;           // a game sends ~12; more means something is wrong
  static readonly Regex IdPattern = new Regex("^[0-9A-Za-z_-]{1,32}$");

  static readonly UTF8Encoding Enc = Shared.Utf8;
  static readonly JavaScriptSerializer Json = Shared.Json(400000);
  static string runtime;
  static StreamWriter log;

  // "type id" -> json (pos, state, lobby; everyone except bye), in the order first seen
  static readonly List<string> order = new List<string>();
  static readonly Dictionary<string, string> latest = new Dictionary<string, string>();
  static readonly List<Peer> peers = new List<Peer>();
  static string ownPos, ownState, ownId, ownLobby;
  static bool dirty = true;
  static string status = "";
  static int go = 0;
  static bool gameAlive = false;
  static readonly Dictionary<string, DateTime> waitUntil = new Dictionary<string, DateTime>();
  static string roomLine;
  static string roomRegion;
  static string refusedName, refusedGame;
  static DateTime refusedUntil;
  static DateTime nextParentCheck = DateTime.MinValue;

  static void Set(string k, string v) { if (!latest.ContainsKey(k)) order.Add(k); latest[k] = v; }
  static void Unset(string k) { if (latest.Remove(k)) order.Remove(k); }

  static void Log(string msg) {
    if (log == null) return;
    try { log.WriteLine("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + msg); } catch { }
  }

  public static int Run(string[] args) {
    try { ParseArgs(args); } catch { return 2; }
    Key = Environment.GetEnvironmentVariable("SOULLINK_KEY") ?? "";
    runtime = Path.Combine(Shared.Root, "runtime", Profile);
    Directory.CreateDirectory(runtime);
    try {
      var fs = new FileStream(Path.Combine(runtime, "link.log"), FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
      log = new StreamWriter(fs, Enc) { AutoFlush = true };
    } catch { }
    roomRegion = Shared.Region(Game);
    if (!string.IsNullOrEmpty(Room)) {
      try { roomLine = "room host " + Encoding.UTF8.GetString(Convert.FromBase64String(Room)); } catch { }
    }
    try {
      Delete("in.json"); Delete("lobby.json"); Delete("lobby_cmd.txt");
      foreach (var f in Directory.GetFiles(runtime, "out_*.txt")) Shared.Delete(f);
      // (the window finds this link by it)
      File.WriteAllText(Path.Combine(runtime, "link.pid"), System.Diagnostics.Process.GetCurrentProcess().Id + " " + Mode, Encoding.ASCII);
      UpdateGame();
      ownLobby = OwnLobby();
      if (ownLobby != null) Remember(ownLobby, false);
      if (Mode == "host") RunHost(); else RunJoin();
      return 0;
    } catch (Exception e) {
      Log("Stopped: " + e.Message);
      Delete("link.pid");
      return 1;
    }
  }

  static void ParseArgs(string[] a) {
    for (int i = 0; i < a.Length; i++) {
      string k = a[i].TrimStart('-').ToLowerInvariant();
      if (k == "removerouterport") { RemoveRouterPort = true; continue; }
      if (i + 1 >= a.Length) throw new ArgumentException("missing value for " + a[i]);
      string v = a[++i];
      switch (k) {
        case "mode": Mode = v.ToLowerInvariant(); break;
        case "address": Address = v; break;
        case "port": Port = int.Parse(v); break;
        case "profile": Profile = v; break;
        case "parentpid": ParentPid = int.Parse(v); break;
        case "room": Room = v; break;
        case "id": Id = v; break;
        case "name": Name = v; break;
        case "game": Game = v; break;
        case "gamepidfile": GamePidFile = v; break;
        default: throw new ArgumentException("unknown argument " + a[i - 1]);
      }
    }
    if (!Regex.IsMatch(Profile, "^[0-9A-Za-z_.-]{1,64}$")) throw new ArgumentException("bad profile name");
  }

  // ------------------------------------------------------------------ files
  static void Delete(string file) { Shared.Delete(Path.Combine(runtime, file)); }
  static string ReadOutbox(string file) {
    string t = Shared.ReadShared(Path.Combine(runtime, file));
    return t == null ? null : t.Trim();
  }
  static bool WriteAtomic(string file, string text) { return Shared.WriteAtomic(Path.Combine(runtime, file), text); }

  // stop the link: tidy up after it (and close the router port it was given)
  static void Quit(string why) {
    Log(why);
    if (RemoveRouterPort) CloseRouterPort();
    Delete("lobby.json"); Delete("link.pid");
    Environment.Exit(0);
  }

  // ------------------------------------------------------------------ checking messages
  // a printable, short name (no control characters, no line breaks, no brackets: nobody can fake
  // the "(host)" / "(you)" labels the window adds)
  static string CleanName(object s, int max) {
    string t = s as string ?? "";
    t = Regex.Replace(t, @"\p{C}", "");
    t = Regex.Replace(t, @"[()\[\]{}<>]", "");
    t = Regex.Replace(t, @"\s+", " ").Trim();
    if (t.Length > max) t = t.Substring(0, max);
    return t;
  }

  static Dictionary<string, object> ParseObject(string json) { return Shared.ParseObject(Json, json); }
  static object Field(Dictionary<string, object> o, string k) { return Shared.Field(o, k); }

  // check one message and write it out again cleanly; null if it isn't acceptable
  static string CleanJson(string type, string who, string json, bool fromPeer) {
    int max;
    if (!MaxSize.TryGetValue(type, out max)) return null;
    if (!IdPattern.IsMatch(who)) return null;
    if (json.Length > max) return null;
    var o = ParseObject(json);
    if (o == null) return null;
    if ((Field(o, "id") as string) != who || (Field(o, "t") as string) != type) return null;
    if (type == "lobby") {
      // only the fields the lobby shows; a player can't make themselves the host
      string g = Field(o, "game") as string ?? "";
      var c = new Dictionary<string, object>();
      c["t"] = "lobby"; c["id"] = who; c["name"] = CleanName(Field(o, "name"), 20);
      c["game"] = Shared.GameNames.ContainsKey(g) ? g : "";
      c["host"] = Shared.Bool(Field(o, "host")) && !fromPeer;
      c["playing"] = Shared.Bool(Field(o, "playing"));
      o = c;
    } else if (o.ContainsKey("name")) {
      o["name"] = CleanName(o["name"], 16);
    }
    try { return Json.Serialize(o); } catch { return null; }
  }

  // remember a line (pos/state/lobby, or the host's bye); returns the player id, or null if rejected
  static string Remember(string line, bool fromPeer) {
    var parts = line.Split(new[] { ' ' }, 3);
    if (parts.Length < 3) return null;
    string type = parts[0], who = parts[1], json = parts[2];
    if (type == "bye") {
      if (fromPeer || !IdPattern.IsMatch(who)) return null;
      foreach (var k in order.ToArray()) if (k.EndsWith(" " + who)) Unset(k);
    } else {
      string clean = CleanJson(type, who, json, fromPeer);
      if (clean == null) return null;
      Set(type + " " + who, clean);
    }
    dirty = true;
    return who;
  }

  // the line as it was remembered (cleaned), to pass on
  static string CleanLine(string line) {
    var parts = line.Split(new[] { ' ' }, 3);
    string k = parts[0] + " " + (parts.Length > 1 ? parts[1] : "");
    string v;
    return latest.TryGetValue(k, out v) ? k + " " + v : line;
  }

  // ------------------------------------------------------------------ connections
  static Peer NewPeer(TcpClient c) {
    c.NoDelay = true;
    c.SendTimeout = 3000;
    var p = new Peer { Client = c, Stream = c.GetStream(), Ok = Key == "" };
    try { p.Addr = ((IPEndPoint)c.Client.RemoteEndPoint).Address.ToString(); } catch { }
    return p;
  }

  static bool SendRaw(Peer p, string line) {
    try {
      var bytes = Enc.GetBytes(line + "\n");
      p.Stream.Write(bytes, 0, bytes.Length);
      return true;
    } catch { return false; }
  }

  static List<string> ReadLines(Peer p) {
    var lines = new List<string>();
    var bytes = new byte[65536];
    var chars = new char[65536 + 8];
    while (p.Client.Available > 0) {
      int n = p.Stream.Read(bytes, 0, Math.Min(bytes.Length, p.Client.Available));
      if (n <= 0) break;
      int cn = p.Dec.GetChars(bytes, 0, n, chars, 0);
      p.Buf.Append(chars, 0, cn);
      int start = 0, i;
      string s = p.Buf.ToString();
      while ((i = s.IndexOf('\n', start)) >= 0) {
        lines.Add(s.Substring(start, i - start).TrimEnd('\r'));
        start = i + 1;
      }
      if (start > 0) { p.Buf.Clear(); p.Buf.Append(s, start, s.Length - start); }
      if (p.Buf.Length > MaxLine) throw new IOException("line too long");   // (checked while reading, not after)
      if (lines.Count > 200) throw new IOException("too many lines at once");
    }
    return lines;
  }

  // too many lines per second from one connection: something is wrong with it
  static bool TooFast(Peer p, int n) {
    int sec = (int)Math.Floor((DateTime.Now - DateTime.Today).TotalSeconds);
    if (sec != p.Second) { p.Second = sec; p.LineCount = 0; }
    p.LineCount += n;
    return p.LineCount > MaxLinesPerSecond;
  }

  static bool IsClosed(Peer p) {
    try { return p.Client.Client.Poll(0, SelectMode.SelectRead) && p.Client.Available == 0; }
    catch { return true; }
  }

  static void Close(Peer p) { try { p.Client.Close(); } catch { } }

  static void Broadcast(string line, Peer except) {
    foreach (var p in peers.ToArray()) if (p != except && p.Ok && p.Gone == null) SendRaw(p, line);
  }

  // ------------------------------------------------------------------ what the others read
  // for the BizHawk script: everyone else's position and state (the lobby isn't its business)
  static bool WriteInbox() {
    var msgs = new List<string>();
    foreach (var k in order) {
      if (ownId != null && k.EndsWith(" " + ownId)) continue;
      if (k.StartsWith("lobby ")) continue;
      msgs.Add(latest[k]);
    }
    return WriteAtomic("in.json", "{\"status\":" + Json.Serialize(status) + ",\"msgs\":[" + string.Join(",", msgs) + "]}");
  }

  // for the window: who is in the room
  static void WriteLobby() {
    var players = new List<object>();
    foreach (var k in order.ToArray()) {
      if (!k.StartsWith("lobby ")) continue;
      string pid = k.Substring(6);
      var o = ParseObject(latest[k]);
      if (o == null) continue;
      string trainer = "";
      string posKey = "pos " + pid, pos;
      if (latest.TryGetValue(posKey, out pos)) trainer = CleanName(Field(ParseObject(pos), "name"), 16);
      var e = new Dictionary<string, object>();
      e["id"] = pid; e["name"] = Shared.Str(Field(o, "name")); e["game"] = Shared.Str(Field(o, "game"));
      e["host"] = Shared.Bool(Field(o, "host"));
      e["playing"] = Shared.Bool(Field(o, "playing")) || latest.ContainsKey(posKey);
      e["trainer"] = trainer; e["me"] = pid == Id;
      players.Add(e);
    }
    var obj = new Dictionary<string, object>();
    obj["status"] = status; obj["mode"] = Mode; obj["go"] = go; obj["players"] = players;
    if (refusedName != null) obj["refused"] = new Dictionary<string, object> { { "name", refusedName }, { "game", refusedGame } };
    WriteAtomic("lobby.json", Json.Serialize(obj));
  }

  static void WriteFiles() {
    if (WriteInbox()) dirty = false;
    WriteLobby();
  }

  // ------------------------------------------------------------------ this player
  static List<string> CheckOwn() {
    var changed = new List<string>();
    foreach (var kind in new[] { "pos", "state" }) {
      string line = ReadOutbox("out_" + kind + ".txt");
      string old = kind == "pos" ? ownPos : ownState;
      if (!string.IsNullOrEmpty(line) && line != old) {
        if (kind == "pos") ownPos = line; else ownState = line;
        string who = Remember(line, false);
        if (who != null) { ownId = who; changed.Add(CleanLine(line)); }
      }
    }
    return changed;
  }

  // this player's lobby line (changes when their game starts or stops)
  static string OwnLobby() {
    if (string.IsNullOrEmpty(Id)) return null;
    var o = new Dictionary<string, object>();
    o["t"] = "lobby"; o["id"] = Id; o["name"] = Name; o["game"] = Game; o["host"] = Mode == "host"; o["playing"] = gameAlive;
    return "lobby " + Id + " " + Json.Serialize(o);
  }

  // is this player's game running? (checked every 2 seconds)
  static void UpdateGame() {
    bool alive = false;
    if (!string.IsNullOrEmpty(GamePidFile)) {
      int gp;
      string t = Shared.ReadShared(GamePidFile);
      if (t != null && int.TryParse(t.Trim(), out gp)) alive = Shared.Alive(gp);
    }
    gameAlive = alive;
  }

  // what the window asks for (lobby_cmd.txt): "start" = start the game for everyone (host), "quit"
  static string ReadCommand() {
    string path = Path.Combine(runtime, "lobby_cmd.txt");
    if (!File.Exists(path)) return null;
    string c = ReadOutbox("lobby_cmd.txt");
    Delete("lobby_cmd.txt");
    if (c == "quit") { Delete("in.json"); Quit("Stopped from the Soul Link window"); }
    return c;
  }

  static void CloseRouterPort() {
    try {
      var t = Type.GetTypeFromProgID("HNetCfg.NATUPnP");
      if (t == null) return;
      dynamic nat = Activator.CreateInstance(t);
      dynamic maps = nat.StaticPortMappingCollection;
      if (maps != null) { maps.Remove(Port, "TCP"); Log("Closed router port " + Port); }
    } catch { }
  }

  // true every 2 seconds (after checking the game); quits once the window and the game are both gone
  static bool CheckParent() {
    if (DateTime.Now < nextParentCheck) return false;
    nextParentCheck = DateTime.Now.AddSeconds(2);
    UpdateGame();
    if (ParentPid > 0 && !gameAlive && !Shared.Alive(ParentPid)) Quit("The Soul Link window and the game are closed, stopping the link");
    return true;
  }

  static int PlayerCount() {
    var ids = new HashSet<string>();
    foreach (var k in order) ids.Add(k.Split(' ')[1]);
    if (ownId != null) ids.Add(ownId);
    return ids.Count;
  }

  static void SetStatus(string s) { if (s != status) { status = s; dirty = true; } }

  // ------------------------------------------------------------------ host
  static void Welcome(Peer p) {
    if (roomLine != null) SendRaw(p, roomLine);
    foreach (var k in order.ToArray()) SendRaw(p, k + " " + latest[k]);
  }

  // the game a player says they play (lobby line, or their game's state), from what was just remembered
  static string SaidGame(string type, string who) {
    string v;
    if ((type != "lobby" && type != "state") || !latest.TryGetValue(type + " " + who, out v)) return "";
    var o = ParseObject(v);
    if (type == "lobby") return Shared.Str(Field(o, "game"));
    return Shared.Str(Field(Field(o, "d") as Dictionary<string, object>, "game"));
  }

  // the player ids already taken (yours, and those of the other connections)
  static bool IdTaken(string who, Peer self) {
    if (who == Id || (ownId != null && who == ownId)) return true;
    foreach (var q in peers) if (q != self && q.Id == who) return true;
    return false;
  }

  static void SayBye(string who, Peer except) {
    Log("Player " + who + " left");
    string bye = "bye " + who + " {}";
    Remember(bye, false);
    Broadcast(bye, except);
  }

  static void RunHost() {
    var listener = new TcpListener(IPAddress.Any, Port);
    listener.Start();
    Log("Hosting on port " + Port + ". Friends join with your join code.");
    status = "hosting, waiting for players";
    while (true) {
      while (listener.Pending()) {
        var client = listener.AcceptTcpClient();
        var peer = NewPeer(client);
        DateTime until;
        if (peers.Count >= MaxPeers || (waitUntil.TryGetValue(peer.Addr, out until) && DateTime.Now < until)) {
          Close(peer);
          continue;
        }
        peers.Add(peer);
        Log("Connection from " + peer.Addr);
        if (peer.Ok) Welcome(peer);
      }
      foreach (var p in peers.ToArray()) {
        bool drop = false;
        try {
          var got = ReadLines(p);
          if (p.Gone != null) {
            // turned away: they were told why and hang up themselves (closed for them after 3 seconds)
            got.Clear();
            if ((DateTime.Now - p.Gone.Value).TotalSeconds > 3) drop = true;
          }
          if (TooFast(p, got.Count)) { drop = true; Log("Dropped " + p.Addr + ": sending too fast"); }
          foreach (var line in got) {
            if (drop) break;
            if (!p.Ok) {
              if (line == "hello " + Key) { p.Ok = true; Welcome(p); }
              else {
                drop = true;
                waitUntil[p.Addr] = DateTime.Now.AddSeconds(10);
                Log("Rejected " + p.Addr + ": wrong room key");
              }
              continue;
            }
            var parts = line.Split(new[] { ' ' }, 3);
            string type = parts[0];
            if (type != "pos" && type != "state" && type != "lobby") continue;   // (hello, bye, go, room...)
            if (parts.Length < 3) continue;
            string who = parts[1];
            if (p.Id != null && who != p.Id) continue;          // a connection speaks for one player only
            if (p.Id == null && IdTaken(who, p)) continue;
            who = Remember(line, true);
            if (who == null) continue;
            // a game from another region: not supported, so this player is turned away (and told why)
            string said = SaidGame(type, who);
            if (roomRegion != "" && Shared.Region(said) != "" && Shared.Region(said) != roomRegion) {
              string nm = null, lv;
              if (latest.TryGetValue("lobby " + who, out lv)) nm = Field(ParseObject(lv), "name") as string;
              foreach (var kind in new[] { "lobby", "pos", "state" }) Unset(kind + " " + who);
              var r = new Dictionary<string, object> { { "t", "refuse" }, { "game", Game }, { "yours", said } };
              SendRaw(p, "refuse host " + Json.Serialize(r));
              refusedName = string.IsNullOrEmpty(nm) ? "Someone" : nm; refusedGame = said;
              refusedUntil = DateTime.Now.AddSeconds(60);
              dirty = true;
              Log("Refused " + who + " from " + p.Addr + ": plays " + said + ", this room plays " + Game + " (mixed games aren't supported)");
              if (p.Id != null) { SayBye(p.Id, p); p.Id = null; }
              p.Gone = DateTime.Now;
              break;
            }
            if (p.Id == null) { p.Id = who; Log("Player " + who + " joined from " + p.Addr); }
            Broadcast(CleanLine(line), p);
          }
          if (!drop && !p.Ok && (DateTime.Now - p.Since).TotalSeconds > AuthSeconds) {
            drop = true; Log("Dropped " + p.Addr + ": no room key");
          }
          if (!drop) drop = IsClosed(p);
        } catch (Exception e) { drop = true; Log("Dropped " + p.Addr + ": " + e.Message); }
        if (drop) {
          peers.Remove(p);
          Close(p);
          if (p.Id != null) SayBye(p.Id, null);
        }
      }
      foreach (var line in CheckOwn()) Broadcast(line, null);
      if (CheckParent()) {
        string line = OwnLobby();
        if (line != null && line != ownLobby) { ownLobby = line; Remember(line, false); Broadcast(CleanLine(line), null); }
      }
      if (ReadCommand() == "start") {
        go++;
        dirty = true;
        Broadcast("go " + Id + " {}", null);
        Log("Started the game for everyone");
      }
      if (refusedName != null && DateTime.Now > refusedUntil) { refusedName = null; dirty = true; }
      int n = PlayerCount();
      SetStatus(n <= 1 ? "hosting, waiting for players" : "hosting, " + n + " players");
      if (dirty) WriteFiles();
      Thread.Sleep(15);
    }
  }

  // ------------------------------------------------------------------ join
  static void RunJoin() {
    Peer peer = null;
    DateTime nextTry = DateTime.MinValue;
    status = "connecting to " + Address + ":" + Port;
    while (true) {
      if (peer == null && DateTime.Now >= nextTry) {
        try {
          var c = new TcpClient();
          var ar = c.BeginConnect(Address, Port, null, null);
          if (!ar.AsyncWaitHandle.WaitOne(5000)) { c.Close(); throw new IOException("timed out"); }
          c.EndConnect(ar);
          peer = NewPeer(c);
          peer.Ok = true;
          SendRaw(peer, "hello " + Key);
          foreach (var own in new[] { ownLobby, ownPos, ownState }) if (!string.IsNullOrEmpty(own)) SendRaw(peer, CleanLine(own));
          Log("Connected to " + Address + ":" + Port);
        } catch {
          peer = null;
          nextTry = DateTime.Now.AddSeconds(3);
          string s = "can't reach " + Address + ":" + Port + ", retrying";
          if (s != status) { SetStatus(s); Log(s); }
        }
      }
      if (peer != null) {
        bool drop = false;
        try {
          foreach (var line in ReadLines(peer)) {
            if (line.StartsWith("go ")) { go++; dirty = true; Log("The host started the game"); continue; }
            if (line.StartsWith("refuse ")) {
              // the host plays the other pair of games: tell the window which, and stop (no retrying)
              var parts = line.Split(new[] { ' ' }, 3);
              string hg = parts.Length == 3 ? Shared.Str(Field(ParseObject(parts[2]), "game")) : "";
              if (!Shared.GameNames.ContainsKey(hg)) hg = "";
              Log("The host turned this game away: mixed games aren't supported (host plays " + hg + ", you play " + Game + ")");
              Close(peer);
              // (the lobby file goes first, so the window can't take the lobby for still running)
              Delete("lobby.json"); Delete("in.json"); Delete("link.pid");
              WriteAtomic("refused.txt", hg);
              Environment.Exit(0);
            }
            Remember(line, false);   // (anything that isn't a clean pos/state/lobby/bye line is ignored)
          }
          drop = IsClosed(peer);
        } catch { drop = true; }
        if (drop) {
          Log("Lost connection to host");
          Close(peer);
          peer = null;
          foreach (var k in order.ToArray()) if (!(ownId != null && k.EndsWith(" " + ownId)) && k != "lobby " + Id) Unset(k);
          dirty = true;
          nextTry = DateTime.Now.AddSeconds(2);
        }
      }
      foreach (var line in CheckOwn()) if (peer != null) SendRaw(peer, line);
      if (CheckParent()) {
        string line = OwnLobby();
        if (line != null && line != ownLobby) {
          ownLobby = line; Remember(line, false);
          if (peer != null) SendRaw(peer, CleanLine(line));
        }
      }
      ReadCommand();   // (only the host can start the game for everyone; "quit" stops this link)
      if (peer != null) SetStatus("connected, " + PlayerCount() + " players");
      if (dirty) WriteFiles();
      Thread.Sleep(15);
    }
  }
}
