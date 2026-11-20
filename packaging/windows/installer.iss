#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#ifndef MyAppArch
  #define MyAppArch "x64"
#endif
#ifndef MySourceDir
  #define MySourceDir "..\..\build\windows_packaging\" + MyAppArch + "\SyncCanvas_Notebook"
#endif
#ifndef MyOutputDir
  #define MyOutputDir "..\..\dist\windows"
#endif
#ifndef MyIconFile
  #define MyIconFile "..\..\windows\runner\resources\app_icon.ico"
#endif

[Setup]
AppId={{8F9E4C32-5A1B-4D7E-9B3C-2E6F1A8D4C90}
AppName=SyncCanvas Notebook
AppVersion={#MyAppVersion}
AppVerName=SyncCanvas Notebook {#MyAppVersion}
AppPublisher=SyncCanvas
AppPublisherURL=https://github.com/moyx782/notebook-gemini
AppSupportURL=https://github.com/moyx782/notebook-gemini
AppUpdatesURL=https://github.com/moyx782/notebook-gemini/releases
DefaultDirName={autopf}\SyncCanvas Notebook
DefaultGroupName=SyncCanvas Notebook
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#MyOutputDir}
OutputBaseFilename=SyncCanvas_Notebook_Setup_{#MyAppVersion}_windows_{#MyAppArch}
SetupIconFile={#MyIconFile}
UninstallDisplayIcon={app}\sync_canvas_notebook.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

#if MyAppArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
  #if VER >= EncodeVer(6,3,0,0)
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
  #else
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
  #endif
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\SyncCanvas Notebook"; Filename: "{app}\sync_canvas_notebook.exe"
Name: "{group}\{cm:UninstallProgram,SyncCanvas Notebook}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\SyncCanvas Notebook"; Filename: "{app}\sync_canvas_notebook.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\sync_canvas_notebook.exe"; Description: "{cm:LaunchProgram,SyncCanvas Notebook}"; Flags: nowait postinstall skipifsilent
