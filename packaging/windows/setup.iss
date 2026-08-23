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

[Code]
var
  DetectedDir: String;
  DetectRan: Boolean;

// LooksLikeITGmania mirrors the console installer's check: a Themes folder
// next to another ITGmania marker.
function LooksLikeITGmania(Path: String): Boolean;
begin
  Result := DirExists(AddBackslash(Path) + 'Themes') and
            (DirExists(AddBackslash(Path) + 'Data') or
             DirExists(AddBackslash(Path) + 'Program') or
             DirExists(AddBackslash(Path) + 'NoteSkins'));
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
      Candidates[3] := ExpandConstant('{userdocs}\..\ITGmania');
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
  if CurPageID = wpSelectDir then
  begin
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
// Post-install: run the helper, check that it succeeded, and confirm the
// allowlist really is in Preferences.ini. A silent failure here would
// leave the module unable to reach stepmaniaonline.net.

// PrefsPath returns the Preferences.ini this install actually uses:
// portable installs keep Save/ beside the game, others use %APPDATA%.
function PrefsPath(AppDir: String): String;
var
  Local: String;
begin
  Local := AddBackslash(AppDir) + 'Save\Preferences.ini';
  if FileExists(Local) then
    Result := Local
  else
    Result := ExpandConstant('{userappdata}') + '\ITGmania\Save\Preferences.ini';
end;

// AllowlistOK mirrors the console installer's own check.
function AllowlistOK(AppDir: String): Boolean;
var
  Lines: TArrayOfString;
  I: Integer;
  Line, Lower: String;
  Enabled, Allowed: Boolean;
begin
  Enabled := False;
  Allowed := False;
  if LoadStringsFromFile(PrefsPath(AppDir), Lines) then
  begin
    for I := 0 to GetArrayLength(Lines) - 1 do
    begin
      Line := Trim(Lines[I]);
      Lower := Lowercase(Line);
      if Pos('httpenabled=', Lower) = 1 then
        Enabled := (Trim(Copy(Line, Length('HttpEnabled=') + 1, Length(Line))) = '1');
      if Pos('httpallowhosts=', Lower) = 1 then
        Allowed := (Pos('stepmaniaonline.net', Lower) > 0) and (Pos('127.0.0.1', Lower) > 0);
    end;
  end;
  Result := Enabled and Allowed;
end;

// InstallFailed lets the finish page tell the truth instead of showing the
// normal success text after a failed allowlist write.
var
  InstallFailed: Boolean;
  FailureText: String;

procedure Fail(Msg: String);
begin
  InstallFailed := True;
  FailureText := Msg;
  SuppressibleMsgBox(Msg, mbCriticalError, MB_OK, IDOK);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Helper: String;
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

  if not Exec(Helper, '-install-dir "' + ExpandConstant('{app}') + '" -y -no-banner',
              '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    Fail('Setup could not run its helper program, so nothing was installed.');
    Exit;
  end;

  if ResultCode <> 0 then
  begin
    Fail('The module could not be installed.' + #13#10 + '' + #13#10 + 'Close ITGmania, make sure Preferences.ini is writable, then run Setup again.');
    Exit;
  end;

  // The point of this installer: without the allowlist entry the module
  // cannot reach stepmaniaonline.net, so never report success without
  // reading the file back.
  if not AllowlistOK(ExpandConstant('{app}')) then
    Fail('The module was installed, but network access was NOT enabled.' + #13#10 + '' + #13#10 + 'stepmaniaonline.net is missing from HttpAllowHosts in:' + #13#10 + PrefsPath(ExpandConstant('{app}')) + #13#10 + '' + #13#10 + 'With ITGmania closed, run "Enable Network Access.bat" from the' + #13#10 + 'Themes\Simply Love\Modules folder, or run Setup again.');
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
