; Build with ISCC /DSourceDir="<release folder>" /DOutputDir="<output folder>".
; SourceDir must include build_meow.exe, data/, DLLs and app_icon.ico.
#ifndef SourceDir
  #error SourceDir must point to a complete Windows release bundle
#endif
#ifndef OutputDir
  #define OutputDir "..\build\installers"
#endif
#ifndef AppVersion
  #define AppVersion "1.0.0-beta.1"
#endif

[Setup]
AppId={{B5E4F136-E54A-4C44-B649-65CBB884A79D}
AppName=建喵！测试版
AppVersion={#AppVersion}
AppPublisher=BuildMeow
AppComments=离线图片转方块像素画与地图画工具
DefaultDirName={localappdata}\Programs\BuildMeowBeta
DefaultGroupName={param:GROUP|建喵！测试版}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=BuildMeow-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile={#SourceDir}\app_icon.ico
UninstallDisplayIcon={app}\build_meow.exe
UninstallDisplayName=建喵！测试版 {#AppVersion}
VersionInfoVersion={#GetVersionNumbersString(SourceDir + "\build_meow.exe")}
VersionInfoDescription=建喵！测试版安装程序
LicenseFile=..\..\LICENSE
InfoBeforeFile=beta_notes.txt
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "beta_notes.txt"; DestDir: "{app}"; DestName: "测试版说明.txt"; Flags: ignoreversion
Source: "INNO_LICENSE.txt"; DestDir: "{app}\licenses"; Flags: ignoreversion

[Icons]
Name: "{group}\建喵！测试版"; Filename: "{app}\build_meow.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\建喵！测试版"; Filename: "{app}\build_meow.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\build_meow.exe"; Description: "启动建喵！测试版"; Flags: nowait postinstall skipifsilent; WorkingDir: "{app}"
