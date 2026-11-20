// The Soul Link window: pick your game and BizHawk, then host a lobby, join one or try it alone.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows.Forms;

class Window : Form {
  static Color Rgb(int r, int g, int b) { return Color.FromArgb(r, g, b); }
  // colours and fonts: the same look as the in-game panel
  static readonly Color cBg = Rgb(19, 22, 32), cCard = Rgb(30, 35, 51), cEdge = Rgb(53, 61, 85), cText = Rgb(244, 245, 248),
    cDim = Rgb(184, 190, 208), cFaint = Rgb(127, 135, 158), cRed = Rgb(227, 38, 46), cRedDark = Rgb(156, 20, 27),
    cGood = Rgb(80, 210, 120), cWarn = Rgb(245, 158, 46), cBox = Rgb(13, 16, 24), cBtn = Rgb(43, 50, 72), cGold = Rgb(255, 207, 106);
  readonly Font font = new Font("Segoe UI", 10), small = new Font("Segoe UI", 9), bold = new Font("Segoe UI", 10, FontStyle.Bold),
    head = new Font("Segoe UI", 9, FontStyle.Bold), big = new Font("Consolas", 18, FontStyle.Bold);
  const string OK = "✓", NO = "✗", DOT = "●";

  Panel header, lobby;
  Label romCheck, emuCheck, randLabel, joinHint, lobbyTitle, codeTitle, codeShow, otherCodes, playersLabel, status, linkLabel;
  TextBox romBox, emuBox, nameBox, keyBox, codeBox;
  Button romBtn, emuBtn, getBtn, randSetBtn, randNewBtn, hostBtn, testBtn, joinBtn, copyBtn, startBtn, shareBtn, stopBtn;
  CheckBox randCheck;
  readonly ToolTip tips = new ToolTip();
  readonly Timer timer = new Timer();
  Control[] playControls;
  string lobbyMode = "";   // "", "host" or "join"
  int enteredTick, tick, lastGo;
  bool linkRunning;

  public Window() {
    Text = "Soul Link";
    ClientSize = new Size(540, 742);
    FormBorderStyle = FormBorderStyle.FixedDialog;
    MaximizeBox = false;
    StartPosition = FormStartPosition.CenterScreen;
    Font = font; BackColor = cBg; ForeColor = cText;
    try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

    // header: a Poke Ball and the title on Pokedex red
    header = new Panel { Location = new Point(0, 0), Size = new Size(540, 66), BackColor = cRed };
    Controls.Add(header);
    AddArt("ballring_48.png", 18, 9, 48, 48);
    AddArt("logo_40.png", 76, 13, 250, 40);
    Controls.Add(new Panel { Location = new Point(0, 66), Size = new Size(540, 5), BackColor = cRedDark });

    romCheck = AddStep("1", "YOUR GAME", 86);
    romBox = AddBox(Launcher.OriginalGame(), 20, 116, 396);
    romBtn = AddButton("Browse...", 422, 114, 98, 28, false);

    emuCheck = AddStep("2", "BIZHAWK EMULATOR", 158);
    emuBox = AddBox(Settings.Str("bizhawk"), 20, 188, 290);
    emuBtn = AddButton("Browse...", 316, 186, 98, 28, false);
    getBtn = AddButton("Get BizHawk", 420, 186, 100, 28, false);

    AddStep("3", "OPTIONS", 230);
    randCheck = new CheckBox { Text = "Randomized run", Location = new Point(20, 262), Size = new Size(150, 26), ForeColor = cText };
    Controls.Add(randCheck);
    randCheck.Checked = Settings.Bool("randomized");
    randSetBtn = AddButton("Settings...", 176, 260, 120, 28, false);
    randNewBtn = AddButton("New randomized run", 302, 260, 218, 28, false);
    randLabel = AddLabel("", 20, 292, 500, 36, small, cFaint);
    AddLabel("Your name", 20, 338, 70, 20, small, cDim);
    nameBox = AddBox(Launcher.LobbyName(), 100, 334, 156);
    AddLabel("Room password", 272, 338, 98, 20, small, cDim);
    keyBox = AddBox(Settings.Str("key"), 374, 334, 146);
    tips.SetToolTip(nameBox, "The name the others see in the lobby. In the game they see your trainer name.");
    tips.SetToolTip(keyBox, "Optional extra. Join codes already carry a private room key, so only people you send the code to can get in.");

    AddStep("4", "PLAY", 384);
    hostBtn = AddButton("Host a game", 20, 416, 246, 44, true);
    testBtn = AddButton("Try it alone (Test Buddy)", 274, 416, 246, 44, false);
    joinHint = AddLabel("Join a friend: paste the join code they sent you", 20, 472, 500, 20, small, cDim);
    codeBox = AddBox(Settings.Str("lastCode"), 20, 496, 340);
    codeBox.Font = bold;
    joinBtn = AddButton("Join", 366, 493, 154, 32, true);
    tips.SetToolTip(hostBtn, "Opens a lobby and gives you a join code for your friends. Start the game when everyone is in.");
    tips.SetToolTip(joinBtn, "Joins your friend's lobby. Your game starts when the host starts it (or press Start my game).");
    tips.SetToolTip(testBtn, "Plays on your own, with a Test Buddy that copies your steps.");

    // the lobby: the join code (host), who is in the room, and the start button
    lobby = new Panel { Location = new Point(20, 416), Size = new Size(500, 228), BackColor = cCard, Visible = false };
    Controls.Add(lobby);
    lobbyTitle = LobbyLabel(14, 10, 472, 22, bold, cText);
    codeTitle = LobbyLabel(14, 38, 310, 18, small, cDim);
    codeShow = LobbyLabel(14, 56, 310, 34, big, cGold);
    copyBtn = new Button { Text = "Copy code", Location = new Point(330, 56), Size = new Size(156, 32) };
    StyleButton(copyBtn, false);
    lobby.Controls.Add(copyBtn);
    otherCodes = LobbyLabel(14, 92, 472, 18, small, cFaint);
    playersLabel = LobbyLabel(14, 114, 472, 70, font, cText);
    startBtn = new Button { Location = new Point(14, 188), Size = new Size(472, 32) };
    StyleButton(startBtn, true);
    lobby.Controls.Add(startBtn);

    status = AddLabel("Ready.", 20, 646, 500, 56, font, cDim);
    linkLabel = AddLabel("", 20, 684, 500, 20, bold, cGood);
    shareBtn = AddButton("Share Soul Link with a friend", 20, 732, 246, 32, false);
    stopBtn = AddButton("Leave the lobby", 274, 732, 246, 32, false);
    stopBtn.Enabled = false;
    ClientSize = new Size(540, 776);

    playControls = new Control[] { hostBtn, testBtn, joinHint, codeBox, joinBtn };
    PlaceStatus();
    Shown += (s, e) => { ActiveControl = hostBtn; };

    UpdateChecks();
    romBox.TextChanged += (s, e) => UpdateChecks();
    emuBox.TextChanged += (s, e) => UpdateChecks();
    ShowRandState();

    romBtn.Click += (s, e) => {
      using (var d = new OpenFileDialog { Filter = "Pokemon DS games (*.nds;*.zip)|*.nds;*.zip|All files|*.*" })
        if (d.ShowDialog(this) == DialogResult.OK) { romBox.Text = d.FileName; SavePaths(); ShowRandState(); }
    };
    emuBtn.Click += (s, e) => {
      using (var d = new OpenFileDialog { Filter = "EmuHawk.exe|EmuHawk.exe" })
        if (d.ShowDialog(this) == DialogResult.OK) { emuBox.Text = d.FileName; SavePaths(); }
    };
    getBtn.Click += (s, e) => GetBizHawk();
    randCheck.CheckedChanged += (s, e) => { Settings.Save("randomized", randCheck.Checked); ShowRandState(); };
    randSetBtn.Click += (s, e) => PickRandomizerSettings();
    randNewBtn.Click += (s, e) => {
      if (MessageBox.Show(this, "Start a new randomized run?\nNext time you host, everyone gets a newly randomized game and a fresh save, and the Nuzlocke progress (encounters, links, deaths) starts over.",
          "Soul Link", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
      Settings.Save("randRun", "");
      Say("New run: press Host (or Try it alone) to randomize and start.");
    };
    nameBox.TextChanged += (s, e) => Settings.Save("lobbyName", nameBox.Text.Replace("\"", "").Trim());
    hostBtn.Click += (s, e) => Host();
    copyBtn.Click += (s, e) => { try { Clipboard.SetText(codeShow.Text); Say("Join code copied - paste it to your friends."); } catch { } };
    joinBtn.Click += (s, e) => Join();
    startBtn.Click += (s, e) => StartPressed();
    testBtn.Click += (s, e) => {
      try {
        SavePaths();
        Launcher.PrepareRun(GetJarGui, Say);
        Launcher.StartGame("test");
        Say("Started in test mode: walk around and the Test Buddy follows you.");
      } catch (Exception ex) { SayBad(ex.Message); }
    };
    shareBtn.Click += (s, e) => {
      try {
        string zip = Launcher.MakeShareZip();
        Process.Start("explorer.exe", "/select,\"" + zip + "\"");
        Say("Made 'Soul Link.zip' on your Desktop. Send it to your friends: they unzip it, double-click Soul Link and pick their own game.");
      } catch (Exception ex) { SayBad("Couldn't make the zip: " + ex.Message); }
    };
    stopBtn.Click += (s, e) => {
      bool wasHost = lobbyMode == "host";
      int n = Launcher.StopLink();
      LeaveLobby();
      if (n > 0) Say(wasHost ? "Lobby closed. The router port is closed again; a running game keeps running on its own."
                             : "You left the lobby. A running game keeps running on its own.");
      else Say("Nothing was running.");
    };

    // live status from the link: the connection, who is in the lobby, and the host's start
    timer.Interval = 1000;
    timer.Tick += (s, e) => OnTick();
    timer.Start();
  }

  // ------------------------------------------------------------------ building the window
  void AddArt(string file, int x, int y, int w, int h) {
    string path = Path.Combine(Launcher.Root, "lib", "art", file);
    if (!File.Exists(path)) return;
    var p = new PictureBox { SizeMode = PictureBoxSizeMode.Zoom, Location = new Point(x, y), Size = new Size(w, h), BackColor = Color.Transparent };
    try { p.Image = Image.FromFile(path); } catch { return; }
    header.Controls.Add(p);
  }
  Label AddLabel(string text, int x, int y, int w, int h, Font f, Color color) {
    var l = new Label { Text = text, Location = new Point(x, y), Size = new Size(w, h), Font = f, ForeColor = color, BackColor = Color.Transparent };
    Controls.Add(l);
    return l;
  }
  void StyleButton(Button b, bool primary) {
    b.FlatStyle = FlatStyle.Flat; b.Cursor = Cursors.Hand;
    b.FlatAppearance.BorderSize = 1;
    if (primary) {
      b.BackColor = cRed; b.ForeColor = Color.White; b.Font = bold;
      b.FlatAppearance.BorderColor = cRedDark; b.FlatAppearance.MouseOverBackColor = Rgb(240, 70, 76);
    } else {
      b.BackColor = cBtn; b.ForeColor = cText;
      b.FlatAppearance.BorderColor = cEdge; b.FlatAppearance.MouseOverBackColor = Rgb(58, 67, 95);
    }
  }
  Button AddButton(string text, int x, int y, int w, int h, bool primary) {
    var b = new Button { Text = text, Location = new Point(x, y), Size = new Size(w, h) };
    StyleButton(b, primary);
    Controls.Add(b);
    return b;
  }
  TextBox AddBox(string text, int x, int y, int w) {
    var t = new TextBox { Text = text, Location = new Point(x, y), Size = new Size(w, 26), BackColor = cBox, ForeColor = cText, BorderStyle = BorderStyle.FixedSingle };
    Controls.Add(t);
    t.BringToFront();
    return t;
  }
  // a numbered step title with a thin line under it; returns the label on its right (for a check mark)
  Label AddStep(string num, string title, int y) {
    AddLabel(num + "   " + title, 20, y, 260, 20, head, cDim);
    Controls.Add(new Panel { Location = new Point(20, y + 22), Size = new Size(500, 1), BackColor = cEdge });
    var r = AddLabel("", 260, y, 260, 20, head, cFaint);
    r.TextAlign = ContentAlignment.TopRight;
    return r;
  }
  Label LobbyLabel(int x, int y, int w, int h, Font f, Color color) {
    var l = new Label { Location = new Point(x, y), Size = new Size(w, h), Font = f, ForeColor = color, BackColor = Color.Transparent };
    lobby.Controls.Add(l);
    return l;
  }

  // ------------------------------------------------------------------ status and checks
  void Say(string m) { status.ForeColor = cDim; status.Text = m; Application.DoEvents(); }
  void SayBad(string m) { status.ForeColor = cWarn; status.Text = m; Application.DoEvents(); }

  // the status line sits right under the play buttons, or under the lobby while you're in one
  void PlaceStatus() {
    int top = lobby.Visible ? 652 : 544;
    status.Top = top; linkLabel.Top = top + 56;
  }

  void UpdateChecks() {
    string n = Launcher.GameName(romBox.Text.Trim('"', ' '));
    if (!string.IsNullOrEmpty(n)) { romCheck.Text = OK + "  " + n; romCheck.ForeColor = cGood; }
    else if (n == "") { romCheck.Text = NO + "  not a Pok\u00e9mon game Soul Link knows"; romCheck.ForeColor = cWarn; }
    else { romCheck.Text = "pick your .nds or .zip"; romCheck.ForeColor = cWarn; }
    string e = emuBox.Text.Trim('"', ' ');
    bool found = false;
    try { found = e != "" && File.Exists(e); } catch { }
    if (found) {
      string v = "";
      try { var vi = FileVersionInfo.GetVersionInfo(e); v = vi.FileMajorPart + "." + vi.FileMinorPart + "." + vi.FileBuildPart; } catch { }
      if (Launcher.HasVCRuntime()) { emuCheck.Text = (OK + "  BizHawk " + v).TrimEnd(); emuCheck.ForeColor = cGood; }
      else { emuCheck.Text = NO + "  needs the Visual C++ runtime"; emuCheck.ForeColor = cWarn; }
    } else { emuCheck.Text = "not found: Browse or Get BizHawk"; emuCheck.ForeColor = cWarn; }
  }

  void SavePaths() {
    string g = romBox.Text.Trim('"', ' ');
    // picking a different game file means playing that one (not a randomized copy)
    if (g != Launcher.OriginalGame()) Settings.Save("rom", g, "romOriginal", g);
    Settings.Save("bizhawk", emuBox.Text.Trim('"', ' '));
  }

  void ShowRandState() {
    randSetBtn.Enabled = randCheck.Checked;
    randNewBtn.Enabled = randCheck.Checked;
    if (!randCheck.Checked) {
      randLabel.Text = "Off. (Joining a randomized host? Nothing to do - you get their settings automatically.)";
      return;
    }
    string set = Launcher.FindRandomizerSettings();
    randLabel.Text = set != "" ? "Settings: " + Path.GetFileName(set) + ". Friends who join get the same settings automatically."
                               : "No randomizer settings yet - press Settings...";
  }

  // ------------------------------------------------------------------ buttons
  // the randomizer, downloaded (after asking) if it isn't here yet
  string GetJarGui() {
    string jar = Launcher.FindRandomizer();
    if (jar != "") return jar;
    if (MessageBox.Show(this, "Randomized runs use the Universal Pokemon Randomizer ZX.\nDownload it now from its official GitHub page?",
        "Soul Link", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return null;
    Say("Downloading the randomizer...");
    jar = Launcher.GetRandomizerDownload(Say);
    Settings.Save("upr", jar);
    return jar;
  }

  void GetBizHawk() {
    // (the buttons that start something stay off meanwhile: the window keeps working during the download)
    var busy = new[] { getBtn, emuBtn, hostBtn, testBtn, joinBtn };
    foreach (var b in busy) b.Enabled = false;
    try {
      string tag;
      string exe = Launcher.GetBizHawkDownload(Say, out tag);
      emuBox.Text = exe; SavePaths();
      Say("BizHawk " + tag + " is ready.");
      if (!Launcher.HasVCRuntime()) {
        SayBad("BizHawk " + tag + " is ready, but it needs Microsoft's Visual C++ runtime, which this PC doesn't have yet.");
        if (MessageBox.Show(this, "BizHawk needs Microsoft's Visual C++ runtime (x64), which this PC doesn't have yet.\n\nDownload it from Microsoft now? Run the file once it's downloaded.",
            "Soul Link", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes) Process.Start(Launcher.VCRuntimeUrl);
      }
    } catch (Exception ex) { SayBad("Couldn't get BizHawk: " + ex.Message); }
    finally { foreach (var b in busy) b.Enabled = true; UpdateChecks(); }
  }

  void PickRandomizerSettings() {
    try {
      string jar = GetJarGui();
      if (string.IsNullOrEmpty(jar)) return;
      using (var d = new OpenFileDialog()) {
        d.Title = "Pick randomizer settings (.rnqs) - Cancel to make new ones in the randomizer";
        d.Filter = "Randomizer settings (*.rnqs)|*.rnqs";
        string cur = Launcher.FindRandomizerSettings();
        d.InitialDirectory = cur != "" ? Path.GetDirectoryName(cur) : Path.GetDirectoryName(jar);
        if (d.ShowDialog(this) == DialogResult.OK) {
          Settings.Save("rnqs", d.FileName, "randRun", "");
          ShowRandState();
          Say("Randomizer settings saved. Host (or Try it alone) to play with them.");
        } else {
          string java = Launcher.FindJava(true) ?? Launcher.FindJava(false);
          if (java == null) throw new Exception("The randomizer needs Java. Install it from adoptium.net (Temurin), then try again.");
          Process.Start(new ProcessStartInfo(java, "-jar \"" + jar + "\"") { WorkingDirectory = Path.GetDirectoryName(jar), UseShellExecute = false }).Dispose();
          Say("The randomizer opened: load your game, choose your options and use 'Save Settings'. Then press Settings... here and pick that file.");
        }
      }
    } catch (Exception ex) { SayBad(ex.Message); }
  }

  void Host() {
    try {
      SavePaths();
      var r = Launcher.DoHost(keyBox.Text, Say, GetJarGui);
      EnterLobby("host");
      var first = r.Codes[0];
      codeTitle.Text = "Give your friends this join code (" + first.Key + "):";
      codeShow.Text = first.Value;
      otherCodes.Text = string.Join("     ", r.Codes.Skip(1).Select(c => c.Key + " : " + c.Value));
      Say("Lobby open. " + r.Note + " Allow Soul Link if Windows asks about the firewall.");
    } catch (Exception ex) { SayBad(ex.Message); }
  }

  void Join() {
    try {
      SavePaths();
      var t = Launcher.DoJoin(codeBox.Text, keyBox.Text, Say, GetJarGui);
      EnterLobby("join");
      codeTitle.Text = "Joined with the code:";
      codeShow.Text = codeBox.Text.Trim();
      otherCodes.Text = "Host: " + t.Address + " port " + t.Port;
      Say("In the lobby. Your game starts when the host starts it, or press Start my game.");
    } catch (Exception ex) { SayBad(ex.Message); }
  }

  void StartPressed() {
    try {
      if (lobbyMode == "host") {
        File.WriteAllText(Path.Combine(Launcher.Runtime, "lobby_cmd.txt"), "start", Encoding.ASCII);
        Say("Starting the game for everyone...");
      } else if (Launcher.GameRunning()) {
        Say("Your game is already running.");
      } else {
        Launcher.StartGame("join");
        Say("Your game is starting.");
      }
    } catch (Exception ex) { SayBad(ex.Message); }
  }

  // ------------------------------------------------------------------ the lobby
  void EnterLobby(string mode) {
    lobbyMode = mode;
    lastGo = 0;
    linkRunning = true;   // (the link takes a moment to start)
    enteredTick = tick;
    foreach (var c in playControls) c.Visible = false;
    lobby.Visible = true;
    bool isHost = mode == "host";
    lobbyTitle.Text = isHost ? "Your lobby" : "In the lobby";
    copyBtn.Visible = isHost;
    startBtn.Text = isHost ? "Start the game for everyone" : "Start my game";
    stopBtn.Text = isHost ? "Close the lobby" : "Leave the lobby";
    stopBtn.Enabled = true;
    romBox.ReadOnly = true; romBtn.Enabled = false;   // (your game can't change while you're in a lobby)
    playersLabel.Text = "Waiting for the room...";
    PlaceStatus();
  }
  void LeaveLobby() {
    lobbyMode = "";
    lobby.Visible = false;
    foreach (var c in playControls) c.Visible = true;
    stopBtn.Text = "Leave the lobby"; stopBtn.Enabled = false;
    romBox.ReadOnly = false; romBtn.Enabled = true;
    linkLabel.Text = "";
    PlaceStatus();
  }

  static Dictionary<string, object> ReadJson(string path) {
    string t = Shared.ReadShared(path);
    return t == null ? null : Shared.ParseObject(Shared.Json(int.MaxValue), t);
  }

  // the people in the room, from the link (lobby.json); starts your game when the host says so
  void UpdateLobby() {
    var j = ReadJson(Path.Combine(Launcher.Runtime, "lobby.json"));
    if (j == null) return;
    var lines = new List<string>();
    var players = (Shared.Field(j, "players") as object[] ?? new object[0]).OfType<Dictionary<string, object>>().ToList();
    foreach (var p in players) {
      string who = Shared.Str(Shared.Field(p, "name"));
      if (Shared.Bool(Shared.Field(p, "host"))) who += " (host)";
      if (Shared.Bool(Shared.Field(p, "me"))) who += " (you)";
      string g = Shared.Str(Shared.Field(p, "game"));
      g = Shared.GameNames.ContainsKey(g) ? Launcher.Poke + " " + Shared.GameNames[g] : "";
      string trainer = Shared.Str(Shared.Field(p, "trainer"));
      string state = Shared.Bool(Shared.Field(p, "playing")) ? (trainer != "" ? "playing as " + trainer : "playing") : "in the lobby";
      lines.Add(DOT + "  " + who + "    " + string.Join("  -  ", new[] { g, state }.Where(x => x != "")));
    }
    if (!players.Any(p => !Shared.Bool(Shared.Field(p, "me")))) lines.Add("Nobody else is here yet.");
    // someone with a game from another region was turned away (mixed games aren't supported)
    var refused = Shared.Field(j, "refused") as Dictionary<string, object>;
    string rg = Shared.Str(Shared.Field(refused, "game"));
    if (refused != null && Shared.GameNames.ContainsKey(rg))
      lines.Add(Shared.Str(Shared.Field(refused, "name")) + " couldn't join with " + Launcher.Poke + " " + Shared.GameNames[rg] + ": mixed games aren't supported.");
    playersLabel.Text = string.Join("\n", lines);
    int go = Shared.Int(Shared.Field(j, "go"));
    if (go > lastGo) {
      lastGo = go;
      if (!Launcher.GameRunning()) {
        try { Launcher.StartGame(lobbyMode); Say("The game is starting for everyone. Have fun!"); }
        catch (Exception ex) { SayBad(ex.Message); }
      }
    }
  }

  void OnTick() {
    tick++;
    // the host turned you away (a game from another region): out of the lobby, and say why
    string rf = Path.Combine(Launcher.Runtime, "refused.txt");
    if (lobbyMode != "" && File.Exists(rf)) {
      string hg = (Shared.ReadShared(rf) ?? "").Trim();
      Shared.Delete(rf);
      LeaveLobby();
      SayBad(Launcher.MixedMessage(hg, Launcher.GameVersion(Settings.Str("rom"))));
      return;
    }
    if (tick % 3 == 1) linkRunning = Launcher.LinkRunning();
    string lf = Path.Combine(Launcher.Runtime, "lobby.json");
    if (linkRunning) {
      // (a lobby still running from before this window opened)
      if (lobbyMode == "" && File.Exists(lf)) {
        var j = ReadJson(lf);
        if (j != null) {
          string m = Shared.Str(Shared.Field(j, "mode"));
          EnterLobby(m);
          lastGo = Shared.Int(Shared.Field(j, "go"));
          if (m == "host") {
            codeTitle.Text = "Give your friends this join code (" + Settings.Str("hostCodeKind") + "):";
            codeShow.Text = Settings.Str("hostCode");
          } else { codeTitle.Text = "Joined with the code:"; codeShow.Text = Settings.Str("lastCode"); }
        }
      }
      if (lobbyMode != "") UpdateLobby();
      var inbox = ReadJson(Path.Combine(Launcher.Runtime, "in.json"));
      string st = Shared.Str(Shared.Field(inbox, "status"));
      if (st != "") linkLabel.Text = "Link: " + st;
    } else if (lobbyMode != "" && tick % 3 == 1 && tick - enteredTick > 5) {
      LeaveLobby();
      Say("The lobby has closed.");
    }
  }
}
