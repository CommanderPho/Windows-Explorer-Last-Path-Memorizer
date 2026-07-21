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
  //
  System.NetEncoding,
  Winapi.ActiveX,
  SHDocVw,
  System.Variants,
  Vcl.OleCtrls;

const
  LOOP_SLEEP_TIME = 50;

  EXPLORER_MAX_RETRY = 5; // retry to fetch interface
  EXPLORER_POLL_INTERVAL = 500; // ms

var
  // Compare
  ExpectedModuleName: string;

  // COM
  ShellWindows: IShellWindows;

  // System
  var AppData, LastKnowPath, InclusionPath: string;

  // Settings
  InclusionSettings: TStringList;

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

procedure DoLoop;
begin
  // Process Known Explorer Windows (delete OLD/EXPIRED)
  for var W in KnownExplorerWindowsPaths.Keys.ToArray do
    if not IsWindow(W) then begin
      // Fetch last path
      var CurrentPath := KnownExplorerWindowsPaths[W];
      if (CurrentPath <> '') and (CurrentPath <> LastExpectedExplorerPath) and TDirectory.Exists(CurrentPath) then begin
        LastExpectedExplorerPath := CurrentPath;
        {$IFDEF OUTPUT}Log('Set EXPECT PATH "%s".', [LastExpectedExplorerPath]);{$ENDIF}

        // Save settings
        TFile.WriteAllText(LastKnowPath, LastExpectedExplorerPath, TEncoding.UTF8);

        {$IFDEF OUTPUT}Log('Saved to filesystem!', [LastExpectedExplorerPath]);{$ENDIF}
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

    // Get module
    try
      ModuleName := ProcessHandle.GetModuleFilePath.ToLower;
    except
      {$IFDEF OUTPUT}Log('Failed to fetch ProcessHandle');{$ENDIF}
      exit;
    end;
  //  {$IFDEF OUTPUT}Log('MODULE: "%s"', [ModuleName]);{$ENDIF}
    if ModuleName <> ExpectedModuleName then
      Exit;
  //  {$IFDEF OUTPUT}Log('Matches explorer!!');{$ENDIF}
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

procedure MainLoop;
begin
  {$IFDEF OUTPUT}Log('Starting main loop...');{$ENDIF}
  repeat
    DoLoop;

    Sleep(LOOP_SLEEP_TIME);
  until false;
end;

begin
  {$IFDEF OUTPUT}Log('Starting...');{$ENDIF}

  // Param
  if HasParameter('help', 'h') then begin
    winapi.Windows.MessageBox(0,
      'Explorer Last Path Memorizer'#13+
      '================================'#13+
      'Copyright (c) 2026 Codrut Software.'#13+
      'Developed by Petculescu Codrut'#13+
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
  LastKnowPath := AppData + 'last-know.dat';
  InclusionPath := APpData + 'inclusion-rules.txt';
  try
    if TFile.Exists(LastKnowPath) then begin
      LastExpectedExplorerPath := TFile.ReadAllText(LastKnowPath, TEncoding.UTF8);
      if not TDirectory.Exists(LastExpectedExplorerPath) then
        LastExpectedExplorerPath := '';
    end;
  except
    LastExpectedExplorerPath := '';
  end;

  // Create
  {$IFDEF OUTPUT}Log('Creating items');{$ENDIF}
  KnownExplorerWindowsPaths := TDictionary<HWND, string>.Create;
  InclusionSettings := TStringList.Create;

  // Read inclusion
  if TFile.Exists(InclusionPath) then
    InclusionSettings.LoadFromFile(InclusionPath)
  else begin
    InclusionSettings.Add('this pc');
    InclusionSettings.Add('home');
    InclusionSettings.Add('one drive');

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
    // Free
    KnownExplorerWindowsPaths.Free;
    InclusionSettings.Free;
  end;
end.
