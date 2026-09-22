program ExplorerLastPathMemorizer;

{$IFDEF RELEASE}
  {$APPTYPE GUI}
{$ELSE}
  {$APPTYPE CONSOLE}
  {$DEFINE OUTPUT}
{$ENDIF}


{$R *.res}

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  Cod.SysUtils,
  Cod.ArrayHelpers,
  Cod.Files,
  Cod.Windows,
  Cod.Instances,
  System.IOUtils,
  System.DateUtils,
  IniFiles,
  Vcl.Menus,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.ImgList,
  Vcl.Graphics,
  Winapi.ShellAPI,
  //
  System.NetEncoding,
  Winapi.ActiveX,
  SHDocVw,
  System.Variants,
  Vcl.OleCtrls;

var
  ENABLE_MODULE_REOPENER: boolean = true;
  ENABLE_MODULE_HISTORY: boolean = true;
  //
  LOOP_SLEEP_TIME: integer = 50;

  EXPLORER_MAX_RETRY: integer = 5; // retry to fetch interface
  EXPLORER_POLL_INTERVAL: integer = 300; // ms

  CLOSED_EXPLORER_WINDOWS_CAPACITY: integer = 16;

var
  // Compare
  ExpectedModuleName: string;

  // COM
  ShellWindows: IShellWindows;

  // System
  var AppData,
    FileLogPath, LastKnowPath, InclusionPath: string;
  StopProgram: boolean=false;

  // Settings
  InclusionSettings: TStringList;
  Settings: TIniFile;

  // Expect
  LastExpectedExplorerPath: string='';

  // Runtime fetch
  ActiveWindow: HWND;
  ActivePID: TProcessID;
  ProcessHandle: TProcessHandle;
  ModuleName: string;

    ExplorerRetryCounter: integer;
    LastExplorerPoll: UInt64 = 0;
    LastActiveWindow: HWND=0;
    LastWasAWindowChange: boolean; // the last time the windows were changed
    LastWasExplorerWindow: boolean;
    KnownExplorerWindowsPaths: TDictionary<HWND, string>;

    ClosedExplorerWindowsStack: TArray<string> = [];

{$IFDEF OUTPUT}
procedure Log(S: string); overload;
begin
  WriteLn(Format('%s: %s', [DateTimeToStr(Now), S]));
end;
procedure Log(S: string; Fmt: array of const); overload;
begin
  Log(Format(S, Fmt));
end;
{$ENDIF}
procedure LogFile(S: string); overload;
begin
  TFile.AppendAllText(FileLogPath, Format('%s: %s', [DateTimeToStr(Now), S])+sLineBreak, TEncoding.UTF8);
end;
procedure LogFile(S: string; Fmt: array of const); overload;
begin
  LogFile(Format(S, Fmt));
end;

procedure OpenExplorer(const Path: string);
begin
  if (Path <> '') and TDirectory.Exists(Path) then
    ShellRun(Path, true);
end;

function GetExplorerBrowserInterface(Handle: HWND): IWebBrowser2;
var
  Browser: IWebBrowser2;
  Disp: IDispatch;
  I: Integer;
  Root: HWND;
begin
  Result := nil;

  Handle := GetAncestor(Handle, GA_ROOT);

  for I := 0 to ShellWindows.Count - 1 do
  begin
    Disp := ShellWindows.Item(I);

    if Supports(Disp, IWebBrowser2, Browser) then
    begin
      Root := GetAncestor(HWND(Browser.HWND), GA_ROOT);

      if (Root = Handle) or
         (IsChild(Handle, HWND(Browser.HWND))) or
         (IsChild(Root, Handle)) then
      begin
        Exit(Browser);
      end;
    end;
  end;
end;

function ExplorerLocationToPath(const URL: string): string;
begin
  Result := URL;

  if Result.StartsWith('file:///') then
    Delete(Result, 1, 8);

  Result := StringReplace(Result, '/', '\', [rfReplaceAll]);
  Result := TNetEncoding.URL.Decode(Result);
end;

procedure DoProcessWindows;
begin
  // Process Known Explorer Windows (delete OLD/EXPIRED)
  for var W in KnownExplorerWindowsPaths.Keys.ToArray do
    if not IsWindow(W) then begin
      // Fetch last path
      var CurrentPath := KnownExplorerWindowsPaths[W];
      if (CurrentPath <> '') and TDirectory.Exists(CurrentPath) then begin
        if ENABLE_MODULE_HISTORY then begin
          TArrayUtils<string>.AddValue(CurrentPath, ClosedExplorerWindowsStack);
          if Length(ClosedExplorerWindowsStack) > CLOSED_EXPLORER_WINDOWS_CAPACITY then
            TArrayUtils<string>.Shift(ClosedExplorerWindowsStack);
          {$IFDEF OUTPUT}Log('Pushed closed window "%s".', [CurrentPath]);{$ENDIF}
        end;

        if CurrentPath <> LastExpectedExplorerPath then begin
          LastExpectedExplorerPath := CurrentPath;
          {$IFDEF OUTPUT}Log('Set EXPECT PATH "%s".', [LastExpectedExplorerPath]);{$ENDIF}

          // Save settings
          TFile.WriteAllText(LastKnowPath, LastExpectedExplorerPath, TEncoding.UTF8);

          {$IFDEF OUTPUT}Log('Saved to filesystem!', [LastExpectedExplorerPath]);{$ENDIF}
        end;
      end;

      // Delete
      KnownExplorerWindowsPaths.Remove(W);
      {$IFDEF OUTPUT}Log('Deleted expired window "%d".', [W]);{$ENDIF}
    end;

  // Active window
  try
    ActiveWindow := GetForegroundWindow;
  except
    {$IFDEF OUTPUT}Log('Failed to fetch ActiveWindow');{$ENDIF}
    exit;
  end;
  if not IsWindow(ActiveWindow) then
    exit;

  if ActiveWindow = LastActiveWindow then begin
    if not LastWasExplorerWindow and ((ExplorerRetryCounter = 0) or (ExplorerRetryCounter >= EXPLORER_MAX_RETRY)) then
      Exit;

    if not LastWasAWindowChange and (GetTickCount64 - LastExplorerPoll < EXPLORER_POLL_INTERVAL) then
      Exit;

    LastWasAWindowChange := false;
  end else
    LastWasAWindowChange := true;

  if ActiveWindow <> LastActiveWindow then begin
    LastActiveWindow := ActiveWindow;
    LastWasExplorerWindow := false;
    ExplorerRetryCounter := 0;

  //  {$IFDEF OUTPUT}Log('WINDOW:"%s"', [ActiveWindow.GetTitle]);{$ENDIF}

    // Active PID
    try
      ActivePID := ActiveWindow.GetProcessID;
    except
      {$IFDEF OUTPUT}Log('Failed to fetch PID');{$ENDIF}
      exit;
    end;

    // Get handle
    try
      ProcessHandle := ActivePID.ProcessHandleReadOnly;
    except
      {$IFDEF OUTPUT}Log('Failed to fetch ProcessHandle');{$ENDIF}
      exit;
    end;
    if ProcessHandle = 0 then
      Exit;

    try
      // Get module
      try
        ModuleName := ProcessHandle.GetModuleFilePath.ToLower;
      except
        {$IFDEF OUTPUT}Log('Failed to fetch ModuleName');{$ENDIF}
        exit;
      end;
    //  {$IFDEF OUTPUT}Log('MODULE: "%s"', [ModuleName]);{$ENDIF}
      if ModuleName <> ExpectedModuleName then
        Exit;
    //  {$IFDEF OUTPUT}Log('Matches explorer!!');{$ENDIF}
    finally
      ProcessHandle.CloseHandle;
    end;
  end;

  // Fetch browser
  const Browser = GetExplorerBrowserInterface(ActiveWindow);
  if Browser = nil then begin
    Inc(ExplorerRetryCounter);
    {$IFDEF OUTPUT}Log('Explore window has NO browser interface! (attempt %d/%d)', [ExplorerRetryCounter, EXPLORER_MAX_RETRY]);{$ENDIF}
    Exit; // if  LastWasExplorerWindow is true at this point.... um app is cooked (eats CPU cycles)
  end;
  // Is explorer
  LastWasExplorerWindow := true;
  LastExplorerPoll := GetTickCount64;

  // Fetch path
  const ExploreURL: string = Browser.LocationURL;
  const ExploreName: string = Browser.LocationName;
  var CurrentPath := ExplorerLocationToPath(ExploreURL);

  if KnownExplorerWindowsPaths.ContainsKey(ActiveWindow) then begin
    // MODE EXISTING
//    {$IFDEF OUTPUT}Log('Existing explorer windows detected! Processing');{$ENDIF}

    // Store last path
    if (CurrentPath <> '') and TDirectory.Exists(CurrentPath) then begin
      KnownExplorerWindowsPaths.AddOrSetValue(ActiveWindow, CurrentPath);
      {$IFDEF OUTPUT}Log('Changed PATH for window "%d" to "%s".', [ActiveWindow, CurrentPath]);{$ENDIF}
    end;

  end else begin
    // MODE NEW WINDOW
    {$IFDEF OUTPUT}Log('New EXPLORER WINDOW detected! U:(%s) N:(%s) Processing', [ExploreURL, ExploreName]);{$ENDIF}

    if ENABLE_MODULE_REOPENER then
      if not ExploreURL.StartsWith('file:///', True) and (LastExpectedExplorerPath <> '') and TDirectory.Exists(LastExpectedExplorerPath)
        and ((InclusionSettings.Count = 0) or InclusionSettings.Contains(ExploreName.ToLower)) then begin
        CurrentPath := LastExpectedExplorerPath;
        Browser.Navigate(
          WideString(CurrentPath),
          EmptyParam,
          EmptyParam,
          EmptyParam,
          EmptyParam);
      end;

    //
    KnownExplorerWindowsPaths.Add(ActiveWindow, CurrentPath)
  end;
end;

var
  Reopener_LastReopenCommandMenu: TPopupMenu;
  Reopener_MenuShown: boolean;
  Reopener_ComboWasDown: boolean;
  Reopener_MenuImages: TImageList;

type
  TMasterClass = class
    class procedure OnFileClick(Sender: TObject);
    //
    class procedure OnClearClick(Sender: TObject);
    class procedure OnReopenAllClick(Sender: TObject);
    class procedure OnExitClick(Sender: TObject);

    //
    class procedure AppMessage(var Msg: TMsg; var Handled: Boolean);
  end;

class procedure TMasterClass.OnFileClick(Sender: TObject);
begin
  const Index = TMenuItem(Sender).Tag;

  // Reopen selected item
  OpenExplorer(ClosedExplorerWindowsStack[Index]);

  TArrayUtils<string>.Delete(Index, ClosedExplorerWindowsStack);
end;

class procedure TMasterClass.OnClearClick(Sender: TObject);
begin
  ClosedExplorerWindowsStack := [];
end;

class procedure TMasterClass.OnReopenAllClick(Sender: TObject);
begin
  var I := ClosedExplorerWindowsStack.Count;
  var S: string;
  while I > 0 do begin
    OpenExplorer( TArrayUtils<string>.Pop(ClosedExplorerWindowsStack) );
    //
    Dec(I);
  end;
end;

class procedure TMasterClass.OnExitClick(Sender: TObject);
begin
  StopProgram := true;
end;

class procedure TMasterClass.AppMessage(var Msg: TMsg; var Handled: Boolean);
begin
  if Reopener_MenuShown then
    case Msg.message of
      WM_KEYDOWN, WM_KEYUP,
      WM_SYSKEYDOWN, WM_SYSKEYUP:
        if Msg.wParam in [
          VK_CONTROL, VK_LCONTROL, VK_RCONTROL,
          VK_SHIFT, VK_LSHIFT, VK_RSHIFT,
          Ord('T')
        ] then
          Handled := True;
    end;
end;

procedure DoProcessReopen;
  procedure ReopenLastWindow;
  begin
    if ClosedExplorerWindowsStack.Count = 0 then
      Exit;

    {$IFDEF OUTPUT}Log('Attempting to reopen window...');{$ENDIF}
    const Path = TArrayUtils<string>.Pop(ClosedExplorerWindowsStack);
    {$IFDEF OUTPUT}Log('Opened: %s', [Path]);{$ENDIF}
    OpenExplorer(Path);
  end;
  procedure ShowPopupMenu;
  begin
    // Clear existing
    for var I := Reopener_LastReopenCommandMenu.Items.Count-1 downto 0 do begin
      Reopener_LastReopenCommandMenu.Items[I].Free;
    end;
    Reopener_LastReopenCommandMenu.Items.Clear;

    // Settings
    Reopener_LastReopenCommandMenu.Images := Reopener_MenuImages;

    // Clear
    Reopener_MenuImages.Clear;

    // Add new
    var Item, Sub: TMenuItem;
    Item := TMenuItem.Create(nil);
      Item.Caption := 'Cancel';
      Reopener_LastReopenCommandMenu.Items.Add(Item);
    Item := TMenuItem.Create(nil);
      Item.Caption := '-';
      Reopener_LastReopenCommandMenu.Items.Add(Item);
    for var I := 0 to High(ClosedExplorerWindowsStack) do begin
      Item := TMenuItem.Create(nil);
        Item.Caption := ClosedExplorerWindowsStack[I];
        Item.Tag := I;
        Item.OnClick := TMasterClass.OnFileClick;

      var SFI: SHFILEINFO;
      if SHGetFileInfo(
           PChar(ClosedExplorerWindowsStack[I]),
           FILE_ATTRIBUTE_DIRECTORY,
           SFI,
           SizeOf(SFI),
           SHGFI_ICON or SHGFI_SMALLICON) <> 0 then
      begin
        const Icn = TIcon.Create;
        try
          Icn.Handle := SFI.hIcon;
          Item.ImageIndex := Reopener_MenuImages.AddIcon(Icn);
        finally
          DestroyIcon(SFI.hIcon);
          Icn.Free;
        end;
      end;

      Reopener_LastReopenCommandMenu.Items.Add(Item);
    end;
    Item := TMenuItem.Create(nil);
      Item.Caption := '-';
      Reopener_LastReopenCommandMenu.Items.Add(Item);
    Sub := TMenuItem.Create(nil);
      Sub.Caption := 'Other';
      Reopener_LastReopenCommandMenu.Items.Add(Sub);
      Item := TMenuItem.Create(nil);
        Item.Caption := 'Re-open all';
        Item.Enabled := ClosedExplorerWindowsStack.Count > 0;
        Item.OnClick := TMasterClass.OnReopenAllClick;
        Sub.Add(Item);
      Item := TMenuItem.Create(nil);
        Item.Caption := 'Clear';
        Item.Enabled := ClosedExplorerWindowsStack.Count > 0;
        Item.OnClick := TMasterClass.OnClearClick;
        Sub.Add(Item);
//      Item := TMenuItem.Create(nil);
//        Item.Caption := '-';
//        Sub.Add(Item);
//      Item := TMenuItem.Create(nil);
//        Item.Caption := 'Exit';
//        Item.OnClick := TMasterClass.OnExitClick;
//        Sub.Add(Item);


    // Popup
    var P: TPoint; GetCursorPos(P);
    SetForegroundWindow(Application.Handle);
    Application.ProcessMessages;
    Sleep(1);

    Reopener_LastReopenCommandMenu.Popup(P.X, P.Y);
  end;
function IsKeyComboDown(Key: Word): Boolean;
begin
  Result :=
    ((GetAsyncKeyState(VK_CONTROL) and $8000) <> 0) and
    ((GetAsyncKeyState(VK_SHIFT) and $8000) <> 0) and
    ((GetAsyncKeyState(Key) and $8000) <> 0);
end;
var
  ReopenDown: Boolean;
  MenuDown: Boolean;
begin
  if not ENABLE_MODULE_HISTORY then
    Exit;

  ReopenDown := IsKeyComboDown(Ord('T'));
  MenuDown := IsKeyComboDown(Ord('R'));

  // Not applicable
  const Progman = FindWindow('Progman', nil);
  if not LastWasExplorerWindow and
     (ActiveWindow <> GetDesktopWindow) and
     (ActiveWindow <> Progman) then
    Exit;

  // Ctrl+Shift+T
  if ReopenDown then
  begin
    if not Reopener_ComboWasDown then
    begin
      Reopener_ComboWasDown := True;
      ReopenLastWindow;
    end;
  end
  // Ctrl+Shift+R
  else if MenuDown then
  begin
    if not Reopener_MenuShown then
    begin
      Reopener_MenuShown := True;
      ShowPopupMenu;
    end;
  end
  else
  begin
    Reopener_ComboWasDown := False;
    Reopener_MenuShown := False;
  end;
end;

procedure DoLoop;
begin
  DoProcessWindows;
  DoProcessReopen;

  // procc
  Application.ProcessMessages;
end;

procedure MainLoop;
begin
  {$IFDEF OUTPUT}Log('Starting main loop...');{$ENDIF}
  repeat
    try
      DoLoop;
    except
      on E: Exception do
        LogFile('ERROR: Raised exception '+E.ClassName+': '+E.ToString);
    end;

    Sleep(LOOP_SLEEP_TIME);
  until StopProgram;
end;

begin
  {$IFDEF OUTPUT}Log('Starting...');{$ENDIF}

  Application.OnMessage := TMasterClass.AppMessage;

  // Param
  if HasParameter('help') then begin
    winapi.Windows.MessageBox(0,
      'Explorer Last Path Memorizer'#13+
      '================================'#13+
      'Copyright (c) 2026 Codrut Software.'#13+
      'Developed by Petculescu Codrut'#13+
      ''#13+
      'Keybinds:'#13+
      'Ctrl+Shift+T -> Re-open last window'#13+
      'Ctrl+Shift+R -> Open menu with opened windows history'#13+
      'These work when a Explorer/Desktop window is focused'#13+
      ''#13+
      '-help -> show help info'#13+
      '-settings -> open settings file'#13+
      '-rules -> open inclusion rules file'#13+
      ''#13+
      ''#13+
      'https://www.codrutsoft.com/'#13+
      ''#13+
      'Version 1.0'#13+
      '', 'About', 0
      );
      Exit;
  end;

  {$IFDEF OUTPUT}Log('Processing instances...');{$ENDIF}
  SetSemaphore('com.codrutsoft.explorerlastpathmemorizer');
  InstanceAuto(TAutoInstanceMode.TerminateIfOtherExist);
  
  ExpectedModuleName := IncludeTrailingPathDelimiter(ReplaceWinPath('%windir%')).ToLower+'explorer.exe';
  {$IFDEF OUTPUT}Log('Fetched expected module "%s"', [ExpectedModuleName]);{$ENDIF}

  // Filesytem
  {$IFDEF OUTPUT}Log('Init settings...');{$ENDIF}
  AppData := GetPathInAppData('Explorer Last Path Memorizer', 'Codrut Software', TAppDataType.Roaming, true);
  FileLogPath := AppData + 'app.log';
  LastKnowPath := AppData + 'last-know.dat';
  InclusionPath := AppData + 'inclusion-rules.txt';
  try
    if TFile.Exists(LastKnowPath) then begin
      LastExpectedExplorerPath := TFile.ReadAllText(LastKnowPath, TEncoding.UTF8);
      if not TDirectory.Exists(LastExpectedExplorerPath) then
        LastExpectedExplorerPath := '';
    end;
  except
    LastExpectedExplorerPath := '';
  end;

  if HasParameter('settings') then begin
    ShellRun(AppData+'settings.ini', true);
    Exit;
  end;
  if HasParameter('rules') then begin
    ShellRun(InclusionPath, true);
    Exit;
  end;

  // Settings
  Settings := TIniFile.Create(AppData+'settings.ini');
  var SECT: string;
  var Name: string;

  SECT := 'Modules';
  begin
    Name := 'Re-opener';
    ENABLE_MODULE_REOPENER := Settings.ReadBool(SECT, Name, ENABLE_MODULE_REOPENER);
    if not Settings.ValueExists(SECT, Name) then Settings.WriteBool(SECT, Name, ENABLE_MODULE_REOPENER);

    Name := 'History';
    ENABLE_MODULE_HISTORY := Settings.ReadBool(SECT, Name, ENABLE_MODULE_HISTORY);
    if not Settings.ValueExists(SECT, Name) then Settings.WriteBool(SECT, Name, ENABLE_MODULE_HISTORY);
  end;

  SECT := 'General';
  begin
    Name := 'Loop sleep time';
    LOOP_SLEEP_TIME := Settings.ReadInteger(SECT, Name, LOOP_SLEEP_TIME);
    if not Settings.ValueExists(SECT, Name) then Settings.WriteInteger(SECT, Name, LOOP_SLEEP_TIME);
  end;

  SECT := 'Explorer';
  begin
    Name := 'Explorer max retry';
    EXPLORER_MAX_RETRY := Settings.ReadInteger(SECT, Name, EXPLORER_MAX_RETRY);
    if not Settings.ValueExists(SECT, Name) then Settings.WriteInteger(SECT, Name, EXPLORER_MAX_RETRY);

    Name := 'Explorer poll interval';
    EXPLORER_POLL_INTERVAL := Settings.ReadInteger(SECT, Name, EXPLORER_POLL_INTERVAL);
    if not Settings.ValueExists(SECT, Name) then Settings.WriteInteger(SECT, Name, EXPLORER_POLL_INTERVAL);

    Name := 'Window history capacity';
    CLOSED_EXPLORER_WINDOWS_CAPACITY := Settings.ReadInteger(SECT, Name, CLOSED_EXPLORER_WINDOWS_CAPACITY);
    if not Settings.ValueExists(SECT, Name) then Settings.WriteInteger(SECT, Name, CLOSED_EXPLORER_WINDOWS_CAPACITY);
  end;

  // Create
  {$IFDEF OUTPUT}Log('Creating items');{$ENDIF}
  KnownExplorerWindowsPaths := TDictionary<HWND, string>.Create;
  InclusionSettings := TStringList.Create;
  Reopener_LastReopenCommandMenu := TPopupMenu.Create(nil);
  Reopener_MenuImages := TImageList.Create(nil);

  // Read inclusion
  if TFile.Exists(InclusionPath) then
    InclusionSettings.LoadFromFile(InclusionPath)
  else begin
    InclusionSettings.Add('this pc');
    InclusionSettings.Add('home');
    InclusionSettings.Add('quick access');
    InclusionSettings.Add('one drive');
    InclusionSettings.Add('onedrive');

    InclusionSettings.SaveToFile(InclusionPath);
  end;
  {$IFDEF OUTPUT}Log('Read a total of %d inclusion settings!', [InclusionSettings.Count]);{$ENDIF}
  try
    // Init COM
    {$IFDEF OUTPUT}Log('Initializing COM');{$ENDIF}
    CoInitialize(nil);

    // Com items
    ShellWindows := CoShellWindows.Create;
    try
      try
        // Loop
        MainLoop;
      except
        on E: Exception do begin
          {$IFDEF OUTPUT}Log(E.ClassName+': '+E.Message);{$ENDIF}
        end;
      end;
    finally
      // Uninit COM
      CoUninitialize;
    end;
  finally
    Settings.Free;

    // Free
    KnownExplorerWindowsPaths.Free;
    InclusionSettings.Free;
    Reopener_LastReopenCommandMenu.Free;
    Reopener_MenuImages.Free;
  end;
end.
