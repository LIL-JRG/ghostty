; Inno Setup script for the Ghostty Windows port.
;
; Compile (after running dist/windows/package.sh or a release build):
;   ISCC.exe dist\windows\ghostty.iss
;
; The installer expects the staged layout produced by package.sh at
; zig-out\dist\ghostty-<version>-windows-x86_64\ (bin\ghostty.exe and
; share\ghostty\...). Override the version with /DAppVersion=x.y.z.

#ifndef AppVersion
  #define AppVersion "1.3.2"
#endif
#define StageDir "..\..\zig-out\dist\ghostty-" + AppVersion + "-windows-x86_64"

[Setup]
AppId={{8A7D3E5B-1F2C-4D8E-9A6B-C5D4E3F2A1B0}
AppName=Ghostty
AppVersion={#AppVersion}
AppPublisher=Ghostty Windows Port
AppPublisherURL=https://ghostty.org
DefaultDirName={autopf}\Ghostty
DefaultGroupName=Ghostty
DisableProgramGroupPage=yes
LicenseFile=..\..\LICENSE
OutputDir=..\..\zig-out\dist
OutputBaseFilename=ghostty-{#AppVersion}-windows-x86_64-setup
SetupIconFile=ghostty.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\bin\ghostty.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
    GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "addtopath"; Description: "Add Ghostty to PATH"; \
    GroupDescription: "Other:"; Flags: unchecked

[Files]
Source: "{#StageDir}\bin\ghostty.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "{#StageDir}\share\*"; DestDir: "{app}\share"; \
    Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#StageDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#StageDir}\README-WINDOWS.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Ghostty"; Filename: "{app}\bin\ghostty.exe"
Name: "{autodesktop}\Ghostty"; Filename: "{app}\bin\ghostty.exe"; Tasks: desktopicon

[Registry]
Root: HKA; Subkey: "Environment"; ValueType: expandsz; ValueName: "Path"; \
    ValueData: "{olddata};{app}\bin"; Tasks: addtopath; \
    Check: NeedsAddPath(ExpandConstant('{app}\bin'))

[Run]
Filename: "{app}\bin\ghostty.exe"; Description: "{cm:LaunchProgram,Ghostty}"; \
    Flags: nowait postinstall skipifsilent

[Code]
function NeedsAddPath(Param: string): boolean;
var
  OrigPath: string;
begin
  if not RegQueryStringValue(HKA, 'Environment', 'Path', OrigPath) then
  begin
    Result := True;
    exit;
  end;
  Result := Pos(';' + Uppercase(Param) + ';', ';' + Uppercase(OrigPath) + ';') = 0;
end;
