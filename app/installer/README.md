# Windows 测试版安装包

图标采用用户提供的“图片转方块＋建喵！”标识，源文件为 `doc/design/user_logo.png`。用 `python tool/create_icon.py ../doc/design/user_logo.png` 生成 PNG 和包含七种尺寸的 Windows ICO，保留原图文字与白色背景。
安装包采用 Inno Setup：简体中文向导、当前用户安装、开始菜单快捷方式、可选桌面快捷方式和卸载入口。卸载不删除 AppData 配置及外部导出文件。

先将最终 ICO 写入 `windows/runner/resources/app_icon.ico`，重新生成 Windows release，再从 `app/` 执行：

```powershell
powershell -File tool/build_installer.ps1 `
  -ReleaseDirectory build/releases/beta_1 `
  -IconPath windows/runner/resources/app_icon.ico
```

编译器默认位于仓库的 `build/tools/inno/ISCC.exe`，也可通过 `-Compiler` 指定。脚本会自动寻找 Visual Studio 的 x64 release CRT；可用 `-CrtDirectory` 指定匹配构建工具链的目录。输出位于 `app/build/installers/`，并记录 SHA-256。

`ChineseSimplified.isl` 来自 Inno Setup 官方翻译仓库，保留维护者说明：
<https://raw.githubusercontent.com/jrsoftware/issrc/refs/heads/main/Files/Languages/ChineseSimplified.isl>。
编译器及翻译许可见 `INNO_LICENSE.txt`。字体许可与其他素材声明随程序资产、`LICENSE` 和 `THIRD_PARTY_NOTICES.md` 安装。

发布前应在隔离目录检查安装、重复安装、快捷方式目标、文件完整性与卸载，并核对配置及导出文件保留。
