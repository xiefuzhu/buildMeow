#ifndef RUNNER_DESKTOP_INTEGRATION_H_
#define RUNNER_DESKTOP_INTEGRATION_H_

#include <windows.h>
#include <shellapi.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>

// Owns notification-area and hotkey resources for exactly one runner window.
class DesktopIntegration {
 public:
  DesktopIntegration(HWND window, flutter::BinaryMessenger* messenger);
  ~DesktopIntegration();
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  static LRESULT CALLBACK EventProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam);
  bool AddTray();
  void Menu();
  void Emit(const char* action);
  void ClearHotkeys();
  HWND window_;
  HWND event_window_ = nullptr;
  NOTIFYICONDATAW icon_{};
  bool tray_ready_ = false;
  bool show_hotkey_ = false;
  bool float_hotkey_ = false;
  UINT taskbar_created_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
#ifndef NDEBUG
  HWND reservation_ = nullptr;
#endif
};

#endif
