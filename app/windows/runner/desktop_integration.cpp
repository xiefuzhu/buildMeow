#include "desktop_integration.h"

#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cstdio>
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 51;
constexpr int kShowHotkey = 0x4D01;
constexpr int kFloatHotkey = 0x4D02;
constexpr const wchar_t kEventClass[] = L"BuildMeowDesktopEvents";
}

DesktopIntegration::DesktopIntegration(HWND window,
                                       flutter::BinaryMessenger* messenger)
    : window_(window), taskbar_created_(RegisterWindowMessageW(L"TaskbarCreated")) {
  // Keep desktop event dispatch independent of Flutter view keyboard dispatch.
  // A top-level (rather than HWND_MESSAGE) window also receives TaskbarCreated.
  WNDCLASSW event_class{};
  event_class.lpfnWndProc = EventProc;
  event_class.hInstance = GetModuleHandle(nullptr);
  event_class.lpszClassName = kEventClass;
  RegisterClassW(&event_class);
  event_window_ = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      kEventClass, L"", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr,
      GetModuleHandle(nullptr), this);
  icon_.cbSize = sizeof(icon_);
  icon_.hWnd = event_window_;
  icon_.uID = 1;
  icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  icon_.uCallbackMessage = kTrayMessage;
  icon_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(icon_.szTip, L"建喵! · 地图画与方块像素画");
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "build_meow/desktop", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "configure") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (!args) {
        result->Error("arguments", "Expected desktop settings");
        return;
      }
      const auto enabled = args->find(flutter::EncodableValue("enabled"));
      const auto shift = args->find(flutter::EncodableValue("shift"));
      ClearHotkeys();
      DWORD show_error = 0;
      DWORD float_error = 0;
      if (enabled != args->end() && std::get_if<bool>(&enabled->second) &&
          std::get<bool>(enabled->second)) {
        UINT modifiers = MOD_CONTROL | MOD_ALT | MOD_NOREPEAT;
        if (shift != args->end() && std::get_if<bool>(&shift->second) &&
            std::get<bool>(shift->second)) modifiers |= MOD_SHIFT;
        show_hotkey_ = event_window_ && RegisterHotKey(event_window_, kShowHotkey, modifiers, 'M') != 0;
        if (!show_hotkey_) show_error = GetLastError();
        float_hotkey_ = event_window_ && RegisterHotKey(event_window_, kFloatHotkey, modifiers, 'F') != 0;
        if (!float_hotkey_) float_error = GetLastError();
      }
      if (!tray_ready_) AddTray();
#ifndef NDEBUG
      fprintf(stderr, "DESKTOP configure thread=%lu owner=%lu show=%d/%lu float=%d/%lu shift=%d\n",
              GetCurrentThreadId(), GetWindowThreadProcessId(window_, nullptr),
              show_hotkey_, show_error, float_hotkey_, float_error,
              shift != args->end() && std::get<bool>(shift->second));
#endif
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("tray"), flutter::EncodableValue(tray_ready_)},
          {flutter::EncodableValue("showHotkey"), flutter::EncodableValue(show_hotkey_)},
          {flutter::EncodableValue("showError"), flutter::EncodableValue(static_cast<int>(show_error))},
          {flutter::EncodableValue("floatError"), flutter::EncodableValue(static_cast<int>(float_error))},
          {flutter::EncodableValue("floatHotkey"), flutter::EncodableValue(float_hotkey_)}}));
    } else if (call.method_name() == "fitWorkArea") {
      RECT rect{};
      MONITORINFO monitor{};
      monitor.cbSize = sizeof(monitor);
      if (GetWindowRect(window_, &rect) && !IsZoomed(window_) &&
          GetMonitorInfo(MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &monitor)) {
        const RECT work = monitor.rcWork;
        const LONG width = std::min(rect.right - rect.left, work.right - work.left);
        const LONG height = std::min(rect.bottom - rect.top, work.bottom - work.top);
        const LONG x = std::clamp(rect.left, work.left, work.right - width);
        const LONG y = std::clamp(rect.top, work.top, work.bottom - height);
        SetWindowPos(window_, nullptr, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
      }
      result->Success();
#ifndef NDEBUG
    } else if (call.method_name() == "probeReserve") {
      const auto* args = std::get_if<flutter::EncodableList>(call.arguments());
      const bool reserve = args && args->size() == 2 && std::get<bool>((*args)[0]);
      const bool shift = args && args->size() == 2 && std::get<bool>((*args)[1]);
      if (reservation_) {
        UnregisterHotKey(reservation_, 1);
        UnregisterHotKey(reservation_, 2);
        DestroyWindow(reservation_);
        reservation_ = nullptr;
      }
      bool ok = true;
      if (reserve) {
        reservation_ = CreateWindowExW(0, L"STATIC", L"Hotkey QA", 0, 0, 0, 0, 0,
                                       HWND_MESSAGE, nullptr, nullptr, nullptr);
        const UINT modifiers = MOD_CONTROL | MOD_ALT | (shift ? MOD_SHIFT : 0);
        ok = reservation_ && RegisterHotKey(reservation_, 1, modifiers, 'M') &&
             RegisterHotKey(reservation_, 2, modifiers, 'F');
      }
      result->Success(flutter::EncodableValue(ok));
    } else if (call.method_name() == "probeKey") {
      const auto* args = std::get_if<flutter::EncodableList>(call.arguments());
      if (!args || args->size() != 3) { result->Error("arguments", "key, shift, down"); return; }
      const WORD key = static_cast<WORD>(std::get<int32_t>((*args)[0]));
      const bool shift = std::get<bool>((*args)[1]);
      const bool down = std::get<bool>((*args)[2]);
      INPUT inputs[4]{};
      const WORD keys[] = {VK_CONTROL, VK_MENU, VK_SHIFT, key};
      UINT count = 0;
      for (int i = 0; i < 4; ++i) {
        const int index = down ? i : 3 - i;
        if (index == 2 && !shift) continue;
        inputs[count].type = INPUT_KEYBOARD;
        inputs[count].ki.wVk = keys[index];
        inputs[count].ki.wScan = static_cast<WORD>(MapVirtualKeyW(keys[index], MAPVK_VK_TO_VSC));
        inputs[count++].ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
      }
      fprintf(stderr, "DESKTOP input key=%u shift=%d down=%d\n", key, shift, down);
      result->Success(flutter::EncodableValue(SendInput(count, inputs, sizeof(INPUT)) == count));
    } else if (call.method_name() == "probeTraySelect") {
      PostMessage(event_window_, kTrayMessage, 0, MAKELPARAM(NIN_KEYSELECT, icon_.uID));
      result->Success();
    } else if (call.method_name() == "probeHotkeyMessage") {
      const auto* key = std::get_if<int32_t>(call.arguments());
      if (!key || (*key != 'M' && *key != 'F')) {
        result->Error("arguments", "Expected M or F");
        return;
      }
      PostMessage(event_window_, WM_HOTKEY, *key == 'M' ? kShowHotkey : kFloatHotkey, 0);
      result->Success();
    } else if (call.method_name() == "probeTrayRestart") {
      Shell_NotifyIconW(NIM_DELETE, &icon_);
      PostMessage(event_window_, taskbar_created_, 0, 0);
      result->Success();
#endif
    } else {
      result->NotImplemented();
    }
  });
}

DesktopIntegration::~DesktopIntegration() {
#ifndef NDEBUG
  if (reservation_) {
    UnregisterHotKey(reservation_, 1);
    UnregisterHotKey(reservation_, 2);
    DestroyWindow(reservation_);
  }
#endif
  ClearHotkeys();
  Shell_NotifyIconW(NIM_DELETE, &icon_);
  channel_->SetMethodCallHandler(nullptr);
  if (event_window_) DestroyWindow(event_window_);
  UnregisterClassW(kEventClass, GetModuleHandle(nullptr));
}

void DesktopIntegration::ClearHotkeys() {
  if (show_hotkey_) {
    const BOOL ok = UnregisterHotKey(event_window_, kShowHotkey);
#ifndef NDEBUG
    fprintf(stderr, "DESKTOP unregister M=%d error=%lu\n", ok, ok ? 0 : GetLastError());
#else
    (void)ok;
#endif
  }
  if (float_hotkey_) {
    const BOOL ok = UnregisterHotKey(event_window_, kFloatHotkey);
#ifndef NDEBUG
    fprintf(stderr, "DESKTOP unregister F=%d error=%lu\n", ok, ok ? 0 : GetLastError());
#else
    (void)ok;
#endif
  }
  show_hotkey_ = float_hotkey_ = false;
}

bool DesktopIntegration::AddTray() {
  tray_ready_ = event_window_ && Shell_NotifyIconW(NIM_ADD, &icon_) != 0;
  if (tray_ready_) {
    icon_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &icon_);
  }
  return tray_ready_;
}

void DesktopIntegration::Emit(const char* action) {
#ifndef NDEBUG
  fprintf(stderr, "DESKTOP action=%s\n", action);
#endif
  channel_->InvokeMethod("action", std::make_unique<flutter::EncodableValue>(action));
}

void DesktopIntegration::Menu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, 1, L"显示建喵!");
  AppendMenuW(menu, MF_STRING, 2, L"隐藏到托盘");
  AppendMenuW(menu, MF_STRING, 3, L"切换悬浮图纸");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, 4, L"退出");
  POINT cursor{};
  GetCursorPos(&cursor);
  SetForegroundWindow(window_);
  const UINT action = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                                    cursor.x, cursor.y, 0, window_, nullptr);
  PostMessage(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  switch (action) {
    case 1: Emit("show"); break;
    case 2: Emit("hide"); break;
    case 3: Emit("float"); break;
    case 4: Emit("exit"); break;
    default: Shell_NotifyIconW(NIM_SETFOCUS, &icon_); break;
  }
}

bool DesktopIntegration::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == taskbar_created_ && taskbar_created_ != 0) {
    tray_ready_ = false;
    AddTray();
    // The UI refreshes status; a failed recovery makes a hidden app visible.
    Emit("trayChanged");
    return true;
  }
  if (message == WM_HOTKEY) {
#ifndef NDEBUG
    fprintf(stderr, "DESKTOP WM_HOTKEY id=%llu\n", static_cast<unsigned long long>(wparam));
#endif
    if (wparam == kShowHotkey) { Emit("toggleVisibility"); return true; }
    if (wparam == kFloatHotkey) { Emit("float"); return true; }
  }
  if (message == kTrayMessage) {
    switch (LOWORD(lparam)) {
      case NIN_SELECT:
      case NIN_KEYSELECT: Emit("show"); break;
      case WM_CONTEXTMENU: Menu(); break;
    }
    return true;
  }
  return false;
}

LRESULT CALLBACK DesktopIntegration::EventProc(HWND window, UINT message,
                                              WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self = reinterpret_cast<DesktopIntegration*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (self && self->HandleMessage(message, wparam, lparam)) return 0;
  return DefWindowProcW(window, message, wparam, lparam);
}
