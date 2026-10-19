# 建喵! Flutter 应用

离线 Minecraft 方块像素画与地图画工具。功能、限制、数据来源和使用说明见[仓库 README](../README.md)。

## 本地开发

需要 Dart `>=3.13.0 <4.0.0` 及匹配的 Flutter SDK。Windows 还需 Visual Studio 的 C++ 桌面工作负载。

从本目录执行：

```powershell
flutter pub get
flutter analyze --no-pub
powershell -File tool/run_tests.ps1
powershell -File tool/run_desktop_check.ps1
powershell -File tool/run_close_check.ps1
flutter run -d windows
flutter build windows --release
```

`run_tests.ps1` 分文件运行，原生测试进程异常才允许重试，断言失败不重试。日志位于 `build/test_logs/`。本机已有 Flutter 原生测试进程崩溃记录，重试通过不表示其根因已经消失。

`run_desktop_check.ps1` 使用测试入口启动真实窗口，检查两种作品、语义、最大化/还原、拖动、图纸与 Windows 桌面功能。它会发送已注册的测试组合键，短暂显示、隐藏及调整自己的窗口；不移动鼠标、不重新启动 Explorer，不写入用户实际配置。全局键被占用会在报告中记录，并尝试备用组合键。检查报告和截图位于 `build/qa/`；之前的原生输出会自动归档。不要同时启动多个原生检查进程。

若当前桌面执行环境接受 `SendInput` 却不投递键盘事件，检查会回退为向自己的原生事件窗口投递 `WM_HOTKEY`。报告中的 `realGlobalKeys: false` 表示只完成了系统注册、冲突处理和消息到动作的验证；物理按键、游戏内触发仍须人工验收，不能把 `passed: true` 单独解读为真实按键已实测。

`run_close_check.ps1` 单独构建 **Release** 验证入口，通过真实标题栏的指针命中测试关闭普通、悬浮和最大化窗口，检查未完成的设置写入，以及关闭到托盘后恢复并退出。每个场景使用独立进程和隔离配置，必须在时限内以退出码 0 结束；写出报告不算关闭成功。证据保存在 `build/qa/close_*/`。此脚本会替换默认 Release 构建产物，验收后发布前须重新运行 `flutter build windows --release --no-pub`，恢复正式入口。

## Windows 桌面实现

- `lib/src/window/desktop_integration.dart`：串行窗口操作、悬浮状态、托盘和热键状态、关闭行为。
- `windows/runner/desktop_integration.cpp`：Win32 托盘、全局快捷键、任务栏重建处理和资源释放。
- 默认 `Ctrl+Alt+M` 显示/隐藏，`Ctrl+Alt+F` 切换悬浮；备用组合键增加 `Shift`。冲突可在设置页查看并重试。
- 默认关闭退出；可开启关闭隐藏到托盘，从托盘菜单显式退出。退出前等待偏好设置保存。
- 原生消息循环结束后，必须先显式销毁 Flutter 窗口，再释放 COM；派生析构也必须在成员销毁前清理窗口。不要把窗口清理留给基类析构，否则销毁期间的窗口回调可能访问已失效的 Flutter 控制器。
- 悬浮默认 480×620，最小 360×360；退出恢复普通窗口状态。图纸支持方向键与 `Home` 读取格子。

桌面功能只在 Windows 初始化，其他平台仍可使用图纸、自适应布局和外观选项。`AccessibleSlider` 为 Flutter 3.47 的语义浮层问题保留局部 Overlay；不要通过排除整个页面语义来规避原生可访问性错误。

Windows 安装包脚本及完整载荷检查见 [installer/README.md](installer/README.md)。
