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

[Run]
; -y skips the interactive picker; the folder was already chosen in the wizard.
Filename: "{#SupportDir}\{#CoreExe}"; \
  Parameters: "-install-dir ""{app}"" -y -no-banner"; \
  StatusMsg: "Installing the module and enabling network access..."; \
  Flags: runhidden waituntilterminated

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
