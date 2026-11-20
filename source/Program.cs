// Soul Link: linked Nuzlockes for Pokemon Black/White and Black 2/White 2 in BizHawk.
//
// "Soul Link.exe" is a plain Windows program (no scripts): the window where you host, join or try it
// alone (Window.cs, Launcher.cs), and, started again by that window with "-Mode host|join", the
// network link between the players (Link.cs), which keeps running while your game does.
//
// Build with the C# compiler that comes with Windows' .NET Framework 4 (nothing to install), in the
// Soul Link folder (source\build.cmd does the same):
//   %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /optimize+ /target:winexe
//     "/out:Soul Link.exe" /win32icon:source\soullink.ico /reference:System.Web.Extensions.dll
//     /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll
//     /reference:Microsoft.CSharp.dll /reference:System.Core.dll source\*.cs
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Web.Script.Serialization;

[assembly: AssemblyTitle("Soul Link")]
[assembly: AssemblyDescription("Soul Link: linked Nuzlockes for Pokemon Black/White and Black 2/White 2 in BizHawk")]
[assembly: AssemblyCompany("Soul Link")]
[assembly: AssemblyProduct("Soul Link")]
[assembly: AssemblyVersion("2.0.0.0")]
[assembly: AssemblyFileVersion("2.0.0.0")]

static class Program {
  [STAThread]
  static int Main(string[] args) {
    string mode = null;
    for (int i = 0; i + 1 < args.Length; i++) if (args[i].TrimStart('-').Equals("Mode", StringComparison.OrdinalIgnoreCase)) mode = args[i + 1].ToLowerInvariant();
    if (mode == "host" || mode == "join") return Link.Run(args);
    return Launcher.Run(args);
  }
}

// things the window and the link both use
static class Shared {
  public static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
  public static readonly Dictionary<string, string> GameNames = new Dictionary<string, string> {
    { "B", "Black" }, { "W", "White" }, { "B2", "Black 2" }, { "W2", "White 2" },
    { "D", "Diamond" }, { "P", "Pearl" }, { "Pt", "Platinum" }, { "HG", "HeartGold" }, { "SS", "SoulSilver" } };

  // the folder Soul Link is in (where "Soul Link.exe" is)
  public static string Root { get { return Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location); } }

  // Only games whose areas line up can be linked, so one run can't mix regions (same as the game
  // script's game.region): "" = unknown
  static readonly Dictionary<string, string> Regions = new Dictionary<string, string> {
    { "B", "unova1" }, { "W", "unova1" }, { "B2", "unova2" }, { "W2", "unova2" },
    { "D", "sinnoh" }, { "P", "sinnoh" }, { "Pt", "sinnoh" }, { "HG", "johto" }, { "SS", "johto" } };
  public static string Region(string g) { string r; return g != null && Regions.TryGetValue(g, out r) ? r : ""; }
  // the games of a region, for messages ("Black 2 / White 2")
  public static string RegionGames(string region) {
    switch (region) {
      case "unova1": return "Black / White";
      case "unova2": return "Black 2 / White 2";
      case "sinnoh": return "Diamond / Pearl / Platinum";
      case "johto": return "HeartGold / SoulSilver";
      default: return "";
    }
  }

  public static JavaScriptSerializer Json(int maxLength) {
    return new JavaScriptSerializer { MaxJsonLength = maxLength, RecursionLimit = 14 };
  }
  public static Dictionary<string, object> ParseObject(JavaScriptSerializer j, string json) {
    try { return j.DeserializeObject(json) as Dictionary<string, object>; } catch { return null; }
  }
  public static object Field(Dictionary<string, object> o, string k) {
    object v;
    return o != null && o.TryGetValue(k, out v) ? v : null;
  }
  public static string Str(object v) { return v as string ?? ""; }
  public static bool Bool(object v) { return v is bool && (bool)v; }
  public static int Int(object v) {
    try { return v == null ? 0 : Convert.ToInt32(v, System.Globalization.CultureInfo.InvariantCulture); } catch { return 0; }
  }

  // a file another program may be swapping in place: read it without getting in its way
  public static string ReadShared(string path) {
    try {
      using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
      using (var r = new StreamReader(fs, Encoding.UTF8)) return r.ReadToEnd();
    } catch { return null; }
  }
  // write a whole file at once (readers never see half of it)
  public static bool WriteAtomic(string path, string text) {
    string tmp = path + ".tmp";
    try {
      File.WriteAllText(tmp, text, Utf8);
      if (File.Exists(path)) File.Replace(tmp, path, null); else File.Move(tmp, path);
      return true;
    } catch { return false; }
  }
  public static void Delete(string path) { try { File.Delete(path); } catch { } }

  // is this process running? (one we can't look at counts as running)
  public static bool Alive(int pid) {
    if (pid <= 0) return false;
    try { using (var p = Process.GetProcessById(pid)) return !p.HasExited; }
    catch (ArgumentException) { return false; }
    catch { return true; }
  }
}
