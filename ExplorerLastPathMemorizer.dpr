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

  EXPLORER_POLL_INTERVAL = 500; // ms

var
  // Compare
  ExpectedModuleName: string;

  // COM
  ShellWindows: IShellWindows;

  // System
  var AppData, LastKnowPath: string;

  // Expect
  LastExpectedExplorerPath: string='';

  // Runtime fetch
  ActiveWindow: HWND;
  ActivePID: TProcessID;
  ProcessHandle: TProcessHandle;
  ModuleName: string;

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

function GetPathOfExplorerWindow(Handle: HWND): string;
  function ExplorerLocationToPath(const URL: string): string;
  begin
    Result := URL;

    if Result.StartsWith('file:///') then
      Delete(Result, 1, 8);

    Result := StringReplace(Result, '/', '\', [rfReplaceAll]);
    Result := TNetEncoding.URL.Decode(Result);
  end;
var
  Browser: IWebBrowser2;
  Disp: IDispatch;
  I: Integer;
begin
  Result := '';

  Handle := GetAncestor(Handle, GA_ROOT);

  for I := 0 to ShellWindows.Count - 1 do
  begin
    Disp := ShellWindows.Item(I);

    if Supports(Disp, IWebBrowser2, Browser) then
    begin
      if GetAncestor(HWND(Browser.HWND), GA_ROOT) = Handle then
      begin
        const S = Browser.LocationURL;
        {$IFDEF OUTPUT}Log('Location of window: "%s", "%s"', [S, Browser.LocationName]);{$ENDIF}

        Result := ExplorerLocationToPath(S);
        Exit;
      end;
    end;
  end;
end;

function SetPathOfExplorerWindow(Handle: HWND; const Path: string): boolean;
var
  Browser: IWebBrowser2;
  Disp: IDispatch;
  I: Integer;
  Root: HWND;
begin
  Result := false;

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
        Browser.Navigate(
          WideString(Path),
          EmptyParam,
          EmptyParam,
          EmptyParam,
          EmptyParam);
        Exit(true);
      end;
    end;
  end;
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
    if not LastWasExplorerWindow then
      Exit;

    if not LastWasAWindowChange and (GetTickCount64 - LastExplorerPoll < EXPLORER_POLL_INTERVAL) then
      Exit;

    LastWasAWindowChange := false;
  end else
    LastWasAWindowChange := true;


  if ActiveWindow <> LastActiveWindow then begin
    LastActiveWindow := ActiveWindow;
    LastWasExplorerWindow := false;

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
    LastWasExplorerWindow := true;
    LastExplorerPoll := GetTickCount64;
  //  {$IFDEF OUTPUT}Log('Matches explorer!!');{$ENDIF}
  end;

  // Check new window

  if KnownExplorerWindowsPaths.ContainsKey(ActiveWindow) then begin
    // MODE EXISTING
//    {$IFDEF OUTPUT}Log('Existing explorer windows detected! Processing');{$ENDIF}

    // Store last path
    LastExplorerPoll := GetTickCount64;
    var CurrentPath := GetPathOfExplorerWindow(ActiveWindow);
    if (CurrentPath <> '') and TDirectory.Exists(CurrentPath) then begin
      KnownExplorerWindowsPaths.AddOrSetValue(ActiveWindow, CurrentPath);
      {$IFDEF OUTPUT}Log('Changed PATH for window "%d" to "%s".', [ActiveWindow, CurrentPath]);{$ENDIF}
    end;

  end else begin
    // MODE NEW WINDOW
    {$IFDEF OUTPUT}Log('New EXPLORER WINDOW detected! Processing');{$ENDIF}

  end;


                   
  // Set path
  if (LastExpectedExplorerPath = '') or (not TDirectory.Exists(LastExpectedExplorerPath)) or (GetPathOfExplorerWindow(ActiveWindow) <> '') or SetPathOfExplorerWindow(ActiveWindow, LastExpectedExplorerPath) then begin
    KnownExplorerWindowsPaths.Add(ActiveWindow, LastExpectedExplorerPath)
  end
  else begin
    {$IFDEF OUTPUT}Log('Processing failed!');{$ENDIF}
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

  {$IFDEF OUTPUT}Log('Processing instances...');{$ENDIF}
  SetSemaphore('com.codrutsoft.explorerlastpathmemorizer');
  InstanceAuto(TAutoInstanceMode.TerminateIfOtherExist);
  
  ExpectedModuleName := IncludeTrailingPathDelimiter(ReplaceWinPath('%windir%')).ToLower+'explorer.exe';
  {$IFDEF OUTPUT}Log('Fetched expected module "%s"', [ExpectedModuleName]);{$ENDIF}

  // Filesytem
  {$IFDEF OUTPUT}Log('Init settings...');{$ENDIF}
  AppData := GetPathInAppData('Explorer Last Path Memorizer', 'Codrut Software', TAppDataType.Roaming, true);
  LastKnowPath := AppData + 'last-know.dat';
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
  end;
end.
