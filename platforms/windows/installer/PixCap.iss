; Inno Setup script for PixCap.
;
; Produces a conventional setup.exe. Inno Setup is used rather than MSIX
; because MSIX requires a signed package and a certificate chain the machine
; already trusts; an Inno installer runs from a plain download.
;
; Built by build.ps1 -Installer. Requires Inno Setup 6:
;   winget install JRSoftware.InnoSetup

#ifndef AppVersion
  #define AppVersion "2.0.0"
#endif
#ifndef Arch
  #define Arch "arm64"
#endif
#ifndef SourceDir
  #define SourceDir "..\PixCapWin\bin\Release\net8.0-windows10.0.22621.0\win-arm64\publish"
#endif

#define AppName "PixCap"
#define AppPublisher "PixCap"
#define AppExeName "PixCapWin.exe"

; Prerequisites. The app is published framework-dependent, so both of these
; have to be present. They are fetched from Microsoft at install time rather
; than carried in the setup: it keeps this download at about 10 MB instead of
; 64 MB, and - the reason that matters - a shared runtime keeps receiving
; security patches, while a private copy bundled into the app never would.
#define AppRuntimeVersion "1.6"
#if Arch == "arm64"
  #define DotNetUrl "https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-arm64.exe"
  #define AppRuntimeUrl "https://aka.ms/windowsappsdk/1.6/latest/windowsappruntimeinstall-arm64.exe"
#else
  #define DotNetUrl "https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe"
  #define AppRuntimeUrl "https://aka.ms/windowsappsdk/1.6/latest/windowsappruntimeinstall-x64.exe"
#endif

[Setup]
AppId={{9F2C4A18-6D3B-4E71-9A4F-2C7E5B8D1A63}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
LicenseFile=
OutputDir=..\..\..\dist
OutputBaseFilename=PixCap-{#AppVersion}-{#Arch}-setup
SetupIconFile=PixCap.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Per-user install by default, so no UAC prompt is needed.
PrivilegesRequiredOverridesAllowed=dialog
PrivilegesRequired=lowest

#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked
; On by default, and worth it: the shortcut below only works while PixCap is
; running, so without this the feature quietly does nothing until the user
; happens to open the app.
Name: "startupicon"; Description: "Start PixCap when I sign in, in the notification area"; GroupDescription: "Startup:"

[InstallDelete]
; Clear the application folder before copying into it.
;
; Upgrading from a self-contained build otherwise leaves its private copy of
; .NET sitting beside the app - coreclr.dll, hostfxr.dll, hostpolicy.dll. An
; app-local hostfxr takes precedence over the shared runtime, so the new
; framework-dependent build loads the old host, goes looking for a .NET 8 that
; is not there, and refuses to start with "You must install or update .NET".
; Nothing the user owns lives here: settings are in LocalAppData and captures
; in Pictures.
Type: filesandordirs; Name: "{app}"

[Files]
; The published output, including pixcap_ffi.dll. The .NET and Windows App SDK
; runtimes are not here; see the prerequisite handling below.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon
; --background starts straight into the notification area, so signing in does
; not throw the editor at you.
Name: "{userstartup}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Parameters: "--background"; Tasks: startupicon

[Run]
; Prerequisites first, and only the missing ones. Both are run visibly rather
; than silently: each may raise a UAC prompt of its own, and a prompt the user
; cannot see is a prompt that looks like a hang.
Filename: "{tmp}\windowsdesktop-runtime.exe"; Parameters: "/install /passive /norestart"; \
  StatusMsg: "Installing the .NET Desktop Runtime..."; Check: NeedsDotNet; Flags: waituntilterminated
Filename: "{tmp}\windowsappruntime.exe"; Parameters: "--quiet"; \
  StatusMsg: "Installing the Windows App Runtime..."; Check: NeedsAppRuntime; Flags: waituntilterminated
Filename: "{app}\{#AppExeName}"; Description: "Launch PixCap"; Flags: nowait postinstall skipifsilent

[Code]
var
  MissingDotNet: Boolean;
  MissingAppRuntime: Boolean;

// Exposed to [Run] as Check functions.
function NeedsDotNet: Boolean;
begin
  Result := MissingDotNet;
end;

function NeedsAppRuntime: Boolean;
begin
  Result := MissingAppRuntime;
end;

// True when a .NET Desktop Runtime of at least MinMajor is installed.
//
// Found by looking at the shared framework folder rather than the registry:
// on a current machine HKLM\SOFTWARE\dotnet\Setup\InstalledVersions does not
// exist at all, while the folder is always there. The app rolls forward, so
// anything from 8 up will do.
function HasDotNetDesktop(MinMajor: Integer): Boolean;
var
  Roots: array[0..1] of String;
  FindRec: TFindRec;
  Index, Dot, Major: Integer;
begin
  Result := False;

  Roots[0] := ExpandConstant('{commonpf}') + '\dotnet\shared\Microsoft.WindowsDesktop.App';
  // An x64 .NET on an ARM64 machine lives one level deeper.
  Roots[1] := ExpandConstant('{commonpf}') + '\dotnet\x64\shared\Microsoft.WindowsDesktop.App';

  for Index := 0 to 1 do
  begin
    if FindFirst(Roots[Index] + '\*', FindRec) then
    begin
      try
        repeat
          if (FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
          begin
            Dot := Pos('.', FindRec.Name);
            if Dot > 1 then
            begin
              Major := StrToIntDef(Copy(FindRec.Name, 1, Dot - 1), 0);
              if Major >= MinMajor then
                Result := True;
            end;
          end;
        until not FindNext(FindRec);
      finally
        FindClose(FindRec);
      end;
    end;

    if Result then
      Exit;
  end;
end;

// True when the Windows App Runtime of this version is registered.
//
// It ships as an MSIX framework package, which leaves nothing in the registry
// and nothing readable under Program Files, so PowerShell is the only way to
// ask. Deliberately without -AllUsers: this installer runs unelevated, and a
// per-user registration is what the app actually needs.
function HasWindowsAppRuntime(const Version: String): Boolean;
var
  Code: Integer;
begin
  Result :=
    Exec('powershell.exe',
         '-NoProfile -NonInteractive -Command "if (Get-AppxPackage -Name Microsoft.WindowsAppRuntime.' +
           Version + ') { exit 0 } else { exit 1 }"',
         '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

function InitializeSetup(): Boolean;
var
  Version: TWindowsVersion;
begin
  GetWindowsVersionEx(Version);
  if (Version.Major < 10) or ((Version.Major = 10) and (Version.Build < 18362)) then
  begin
    MsgBox('PixCap needs Windows 10 version 1903 (build 18362) or newer.' + #13#10 +
           'Screen capture relies on APIs that are not present on this version.',
           mbCriticalError, MB_OK);
    Result := False;
    Exit;
  end;

  MissingDotNet := not HasDotNetDesktop(8);
  MissingAppRuntime := not HasWindowsAppRuntime('{#AppRuntimeVersion}');
  Result := True;
end;

// Fetches whichever runtimes are missing.
//
// Done here rather than from a wizard page so that a silent install works too:
// /SILENT never reaches the Ready page, and a prerequisite step hung off a
// button the user never presses is a prerequisite step that never runs.
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';

  try
    if MissingDotNet then
      DownloadTemporaryFile('{#DotNetUrl}', 'windowsdesktop-runtime.exe', '', nil);
    if MissingAppRuntime then
      DownloadTemporaryFile('{#AppRuntimeUrl}', 'windowsappruntime.exe', '', nil);
  except
    // Offline, or Microsoft moved a link. Install anyway and say so: the app's
    // own first-run prompts cover the same ground, and a PixCap that needs one
    // download is easier to rescue than no PixCap at all.
    MissingDotNet := False;
    MissingAppRuntime := False;

    if not WizardSilent then
      MsgBox('The required Microsoft runtimes could not be downloaded:' + #13#10#13#10 +
             GetExceptionMessage + #13#10#13#10 +
             'PixCap will still be installed. It will offer to install them the ' +
             'first time you run it, or you can get them yourself from ' +
             'dotnet.microsoft.com and from the Windows App SDK downloads page.',
             mbInformation, MB_OK);
  end;
end;
