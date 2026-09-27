; ITGMania Content Browser - Windows GUI installer
;
; Builds a normal Windows setup wizard: artwork, an auto-detected install
; folder the user can change with Browse, a progress page and a finish page.
;
; The wizard does not reimplement any install logic. It bundles the tested
; console installer and calls it with -install-dir/-y, so the GUI and the CLI
; always behave identically.
;
; Build:  ISCC.exe /DAppVersion=1.0.0 packaging\windows\setup.iss
; (expects the payload binary at dist\itgmania-content-browser-installer-windows-amd64.exe)

#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif

#define AppName    "ITGMania Content Browser"
#define AppPublisher "GregTech"
#define AppSlug    "itgmania-content-browser"
#define CoreExe    "itgmania-content-browser-installer-windows-amd64.exe"
; Support files live outside the game folder, so the only thing this setup
; adds to ITGmania is the module itself.
#define SupportDir "{localappdata}\ITGMania Content Browser"

[Setup]
AppId={{8E4A2F6C-3B71-4D2E-9C55-7A1E0B9D4F32}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
VersionInfoCompany={#AppPublisher}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup
VersionInfoVersion=0.0.0
UninstallDisplayName={#AppName}
UninstallDisplayIcon={#SupportDir}\{#CoreExe}
UninstallFilesDir={#SupportDir}

; This installs *into an existing ITGmania folder*, so the directory page is
; a picker for that folder rather than a normal Program Files destination.
DefaultDirName={code:DetectInstallDir}
DirExistsWarning=no
AppendDefaultDirName=no
UsePreviousAppDir=no
DisableProgramGroupPage=yes
DisableReadyPage=no
DisableWelcomePage=no
CreateAppDir=yes
Uninstallable=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
ArchitecturesInstallIn64BitMode=x64compatible

OutputDir=..\..\dist
OutputBaseFilename={#AppSlug}-setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
WizardImageFile=wizard-large.bmp
WizardSmallImageFile=wizard-small.bmp
WizardImageStretch=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
WelcomeLabel1=Welcome to the [name] Setup Wizard
WelcomeLabel2=This will install [name] into your ITGmania installation.%n%nIt adds a "Find Content" entry to the ITGmania title menu: an in-game browser for stepmaniaonline.net that downloads and installs song packs without leaving the game.%n%nPlease close ITGmania before continuing.
WizardSelectDir=Select your ITGmania folder
SelectDirDesc=Where is ITGmania installed?
SelectDirLabel3=Setup will install [name] into the ITGmania folder below. If this is not your ITGmania installation, click Browse and choose the correct folder.
SelectDirBrowseLabel=To continue, click Next. If you would like to select a different folder, click Browse.
FinishedHeadingLabel=Finished installing [name]
FinishedLabelNoIcons=Start ITGmania and look for "Find Content" on the title menu, below Exit.

[Files]
; The console installer does the real work; it lives in LocalAppData.
Source: "..\..\dist\{#CoreExe}"; DestDir: "{#SupportDir}"; Flags: ignoreversion

[UninstallRun]
Filename: "{#SupportDir}\{#CoreExe}"; \
  Parameters: "-install-dir ""{app}"" -uninstall -y -no-banner"; \
  RunOnceId: "RemoveContentBrowser"; \
  Flags: runhidden waituntilterminated

[UninstallDelete]
; the console installer's log from the last install
Type: files; Name: "{#SupportDir}\install-log.txt"

[Code]
var
  DetectedDir: String;
  DetectRan: Boolean;

// ---------------------------------------------------------------------
// Maintenance: what to do when it is already installed.
//
// Windows puts an uninstall entry in Apps & Features, and that has always
// worked -- but nobody looks there. People run the setup they downloaded and
// expect it to offer removal, and this one only ever offered to install again.
// So a previous install now gets a page with the choice on it.
var
  MaintPage: TInputOptionWizardPage;
  PrevUninstaller: String;
  Removing: Boolean;

// FindPreviousUninstaller returns the uninstall program of an existing install,
// or an empty string. Both hives are asked because PrivilegesRequired can be
// overridden on the command line, so an install may have been made either way.
function FindPreviousUninstaller(): String;
var
  Key, Cmd: String;
  Roots: array[0..2] of Integer;
  I: Integer;
begin
  Result := '';
  Key := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8E4A2F6C-3B71-4D2E-9C55-7A1E0B9D4F32}_is1';
  Roots[0] := HKEY_CURRENT_USER;
  Roots[1] := HKEY_LOCAL_MACHINE;
  Roots[2] := HKEY_LOCAL_MACHINE_32;
  for I := 0 to 2 do
  begin
    if RegQueryStringValue(Roots[I], Key, 'UninstallString', Cmd) then
    begin
      Cmd := RemoveQuotes(Trim(Cmd));
      // A registry entry left by a half-removed install names a program that
      // is no longer there; offering to run it would be offering nothing.
      if (Cmd <> '') and FileExists(Cmd) then
      begin
        Result := Cmd;
        Exit;
      end;
    end;
  end;
end;

procedure InitializeWizard();
begin
  PrevUninstaller := FindPreviousUninstaller();
  if PrevUninstaller = '' then
    Exit;

  MaintPage := CreateInputOptionPage(wpWelcome,
    'ITGMania Content Browser is already installed',
    'What would you like to do?',
    'Choose an option, then click Next.',
    True, False);
  MaintPage.Add('Update or repair the installation');
  MaintPage.Add('Remove ITGMania Content Browser from this computer');
  MaintPage.SelectedValueIndex := 0;
end;

// RunPreviousUninstaller removes the existing install and reports whether it
// went. Silent, because the choice was already made a page ago and a second
// wizard asking the same question is not a confirmation, it is a nuisance.
function RunPreviousUninstaller(): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec(PrevUninstaller, '/SILENT /SUPPRESSMSGBOXES /NORESTART',
                 '', SW_SHOW, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

// The wizard is closed from script after a removal, and the usual "Exit Setup?"
// confirmation would be asking whether the user meant the thing they just did.
procedure CancelButtonClick(CurPageID: Integer; var Cancel, Confirm: Boolean);
begin
  if Removing then
    Confirm := False;
end;

// HasGameExe: an executable in Program\, which is what the console installer
// insists on. The profile folder of a non-portable install (%APPDATA%\ITGmania)
// mirrors Themes\, NoteSkins\ and Save\ but holds no game, and accepting it
// here only moved the refusal to the end of the wizard, behind a message that
// blamed Preferences.ini.
function HasGameExe(Path: String): Boolean;
var
  FindRec: TFindRec;
begin
  Result := FindFirst(AddBackslash(Path) + 'Program\*.exe', FindRec);
  if Result then
    FindClose(FindRec);
end;

// LooksLikeITGmania mirrors the console installer's check: a Themes folder
// beside the game's own executable.
function LooksLikeITGmania(Path: String): Boolean;
begin
  Result := DirExists(AddBackslash(Path) + 'Themes') and HasGameExe(Path);
end;

// The folder a non-portable install keeps its settings, songs and themes in:
// Save\ beside Themes\, and no game.
function IsProfileFolder(Path: String): Boolean;
begin
  Result := DirExists(AddBackslash(Path) + 'Save') and
            DirExists(AddBackslash(Path) + 'Themes') and not HasGameExe(Path);
end;

function HasSimplyLove(Path: String): Boolean;
begin
  Result := DirExists(AddBackslash(Path) + 'Themes\Simply Love');
end;

// RunDetect extracts the console installer to a temporary folder and asks it
// where ITGmania is, so detection logic lives in exactly one place.
function RunDetect(): String;
var
  TmpExe, OutFile: String;
  ResultCode: Integer;
  Lines: TArrayOfString;
begin
  Result := '';
  TmpExe := ExpandConstant('{tmp}\{#CoreExe}');
  if not FileExists(TmpExe) then
    ExtractTemporaryFile('{#CoreExe}');

  OutFile := ExpandConstant('{tmp}\detected.txt');
  // cmd /c is needed to redirect the child's stdout to a file.
  if Exec(ExpandConstant('{cmd}'),
          '/c ""' + TmpExe + '" -detect > "' + OutFile + '""',
          '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if (ResultCode = 0) and LoadStringsFromFile(OutFile, Lines) and (GetArrayLength(Lines) > 0) then
      Result := Trim(Lines[0]);
  end;
end;

function DetectInstallDir(Param: String): String;
var
  Candidates: array[0..5] of String;
  I: Integer;
begin
  if not DetectRan then
  begin
    DetectRan := True;
    DetectedDir := RunDetect();

    if (DetectedDir = '') or (not LooksLikeITGmania(DetectedDir)) then
    begin
      // Fall back to the usual spots if the helper could not be run.
      Candidates[0] := 'C:\Games\ITGmania';
      Candidates[1] := ExpandConstant('{autopf}\ITGmania');
      Candidates[2] := ExpandConstant('{localappdata}\Programs\ITGmania');
      // ITGmania's own setup puts a non-admin install in Documents
      Candidates[3] := ExpandConstant('{userdocs}\ITGmania');
      Candidates[4] := 'C:\ITGmania';
      Candidates[5] := ExpandConstant('{sd}\Games\ITGmania');
      DetectedDir := '';
      for I := 0 to 5 do
        if (DetectedDir = '') and LooksLikeITGmania(Candidates[I]) then
          DetectedDir := Candidates[I];
    end;

    if DetectedDir = '' then
      DetectedDir := 'C:\Games\ITGmania';
  end;
  Result := DetectedDir;
end;

// Validate the chosen folder before letting the wizard continue.
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;

  if (MaintPage <> nil) and (CurPageID = MaintPage.ID) and
     (MaintPage.SelectedValueIndex = 1) then
  begin
    if RunPreviousUninstaller() then
      MsgBox('ITGMania Content Browser has been removed.' + #13#10 + #13#10 +
             'The "Find Content" entry is gone from the ITGmania title menu. ' +
             'Your songs and packs were not touched.', mbInformation, MB_OK)
    else
      MsgBox('The uninstaller did not finish.' + #13#10 + #13#10 +
             'You can remove it from Settings > Apps instead.', mbError, MB_OK);

    // Nothing left for this wizard to do either way.
    Removing := True;
    Result := False;
    PostMessage(WizardForm.Handle, $0010 { WM_CLOSE }, 0, 0);
    Exit;
  end;

  if CurPageID = wpSelectDir then
  begin
    if IsProfileFolder(WizardDirValue) then
    begin
      MsgBox('That is ITGmania''s data folder, where your settings and songs are kept, ' +
             'not the game itself.' + #13#10 + #13#10 +
             'Choose the folder ITGmania is installed in: the one that contains the ' +
             'Program folder (for example C:\Games\ITGmania).', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if not LooksLikeITGmania(WizardDirValue) then
    begin
      MsgBox('That folder does not look like an ITGmania installation.' + #13#10 + #13#10 +
             'Choose the folder that contains the Themes and Program folders ' +
             '(for example C:\Games\ITGmania).', mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if not HasSimplyLove(WizardDirValue) then
    begin
      MsgBox('The Simply Love theme was not found in that ITGmania folder.' + #13#10 + #13#10 +
             'ITGMania Content Browser is a Simply Love add-on, so Simply Love ' +
             'must be installed first.', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;
end;

// ITGmania rewrites Preferences.ini from memory when it exits, so an edit made
// while it is running would be discarded.
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Result := True;
  if Exec(ExpandConstant('{cmd}'),
          '/c tasklist /FI "IMAGENAME eq ITGmania.exe" /NH | find /I "ITGmania.exe" > nul',
          '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if ResultCode = 0 then
    begin
      MsgBox('ITGmania is running.' + #13#10 + #13#10 +
             'Please close it completely and run this installer again.',
             mbError, MB_OK);
      Result := False;
    end;
  end;
end;

// ---------------------------------------------------------------------
// Post-install: run the console installer and report what it said.
//
// Its exit code is the whole answer. Before it exits 0 it reads back the
// Preferences.ini it wrote and checks every host in the allowlist, and when
// something is wrong it prints an ERROR or WARNING that names it. This used
// to be checked a second time here, and that copy drifted: it still wanted
// the 127.0.0.1 of the old local helper, which no install writes any more,
// so every fresh machine was told network access was not enabled.
//
// The output goes to a log beside it, because the useful part of a failure
// is the reason, and a generic message about Preferences.ini sent players
// looking in the wrong place: a wrong folder, a running game and a missing
// theme all read the same.

// InstallFailed lets the finish page tell the truth instead of showing the
// normal success text after a failed install.
var
  InstallFailed: Boolean;
  FailureText: String;

procedure Fail(Msg: String);
begin
  InstallFailed := True;
  FailureText := Msg;
  SuppressibleMsgBox(Msg, mbCriticalError, MB_OK, IDOK);
end;

// What the console installer printed about its failure: the ERROR or WARNING
// line and the lines that go with it, up to the blank line that ends them.
// Empty if the log has none, which means it never got as far as saying.
function InstallerSaid(LogFile: String): String;
var
  Lines: TArrayOfString;
  I: Integer;
  Line: String;
  Capturing: Boolean;
begin
  Result := '';
  Capturing := False;
  if not LoadStringsFromFile(LogFile, Lines) then
    Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    Line := Trim(Lines[I]);
    if (Pos('ERROR:', Line) = 1) or (Pos('WARNING:', Line) = 1) then
    begin
      Capturing := True;
      Line := Trim(Copy(Line, Pos(':', Line) + 1, Length(Line)));
      if Line <> '' then
        Line := Uppercase(Copy(Line, 1, 1)) + Copy(Line, 2, Length(Line));
    end
    else if Capturing and (Line = '') then
      Break;
    if Capturing and (Line <> '') then
    begin
      if Result <> '' then
        Result := Result + #13#10;
      Result := Result + Line;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Helper, LogFile, Said: String;
  ResultCode: Integer;
begin
  if CurStep <> ssPostInstall then
    Exit;

  Helper := ExpandConstant('{#SupportDir}\{#CoreExe}');
  if not FileExists(Helper) then
  begin
    Fail('Setup could not find its helper program, so nothing was installed.' + #13#10 + 'Please run the installer again.');
    Exit;
  end;

  // cmd /c is needed to redirect the child's output to a file.
  LogFile := ExpandConstant('{#SupportDir}\install-log.txt');
  if not Exec(ExpandConstant('{cmd}'),
              '/c ""' + Helper + '" -install-dir "' + ExpandConstant('{app}') + '" -y -no-banner > "' + LogFile + '" 2>&1"',
              '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    Fail('Setup could not run its helper program, so nothing was installed.');
    Exit;
  end;

  if ResultCode <> 0 then
  begin
    Said := InstallerSaid(LogFile);
    if Said = '' then
      Said := 'Close ITGmania, make sure Preferences.ini is writable, then run Setup again.';
    // what a game under Program Files looks like to a setup running as the player
    if Pos('Access is denied', Said) > 0 then
      Said := Said + #13#10 + #13#10 +
              'If ITGmania is installed under Program Files, right-click Setup and ' +
              'choose Run as administrator.';
    Fail('The module could not be installed.' + #13#10 + #13#10 + Said + #13#10 + #13#10 +
         'The full log is in:' + #13#10 + LogFile);
  end;
end;

// Reflect a failed install on the final page rather than saying it finished.
procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and InstallFailed then
  begin
    WizardForm.FinishedHeadingLabel.Caption := 'Setup did not finish successfully';
    WizardForm.FinishedLabel.Caption := FailureText;
  end;
end;
