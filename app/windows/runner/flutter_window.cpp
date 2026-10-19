#include "flutter_window.h"

#include <optional>
#include <cstdint>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // The base destructor cannot dispatch to this class's OnDestroy override.
  // Clear the controller before its native view emits destruction messages.
  Destroy();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  desktop_ = std::make_unique<DesktopIntegration>(
      GetHandle(), flutter_controller_->engine()->messenger());

  // Flutter pointer positions are relative to the moving client area. Sample
  // the cursor and window in the same physical screen coordinates instead.
  // This avoids both the feedback jitter and a blocking native move loop.
  drag_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "build_meow/window_drag",
      &flutter::StandardMethodCodec::GetInstance());
  drag_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "begin") {
          POINT cursor{};
          dragging_ = false;
          if (GetCursorPos(&cursor)) BeginDrag(cursor);
          result->Success(flutter::EncodableValue(dragging_));
        } else if (call.method_name() == "update") {
          POINT cursor{};
          if (GetCursorPos(&cursor)) ApplyDragCursor(cursor);
          result->Success();
        } else if (call.method_name() == "end") {
          dragging_ = false;
          result->Success();
#ifndef NDEBUG
        } else if (call.method_name() == "verify") {
          // Exercise real window placement with deterministic screen points.
          // QA must not warp the user's cursor or depend on their mouse input.
          RECT original{};
          GetWindowRect(GetHandle(), &original);
          POINT anchor{original.left + 500, original.top + 20};
          BeginDrag(anchor);
          bool passed = dragging_;
          flutter::EncodableList samples;
          const POINT deltas[] = {{30, 15}, {60, 30}, {90, 45}, {60, 30}, {0, 0}};
          for (const auto& delta : deltas) {
            const POINT cursor{anchor.x + delta.x, anchor.y + delta.y};
            for (int feedback = 0; feedback < 4; ++feedback) {
              ApplyDragCursor(cursor);
              RECT actual{};
              GetWindowRect(GetHandle(), &actual);
              passed = passed && actual.left == original.left + delta.x &&
                       actual.top == original.top + delta.y;
              samples.emplace_back(flutter::EncodableList{
                  flutter::EncodableValue(static_cast<int>(actual.left)),
                  flutter::EncodableValue(static_cast<int>(actual.top))});
            }
          }
          dragging_ = false;
          ApplyDragCursor(POINT{anchor.x + 120, anchor.y + 60});
          RECT released{};
          GetWindowRect(GetHandle(), &released);
          passed = passed && released.left == original.left &&
                   released.top == original.top;
          ShowWindow(GetHandle(), SW_MAXIMIZE);
          RECT maximized{};
          GetWindowRect(GetHandle(), &maximized);
          BeginDrag(POINT{maximized.left + 500, maximized.top + 20});
          const bool restored = dragging_ && !IsZoomed(GetHandle());
          dragging_ = false;
          SetWindowPos(GetHandle(), nullptr, original.left, original.top,
                       original.right - original.left, original.bottom - original.top,
                       SWP_NOZORDER | SWP_NOACTIVATE);
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("passed"), flutter::EncodableValue(passed && restored)},
              {flutter::EncodableValue("samples"), flutter::EncodableValue(samples)},
              {flutter::EncodableValue("restoredMaximized"), flutter::EncodableValue(restored)}}));
#endif
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::BeginDrag(const POINT& cursor) {
  dragging_ = false;
  const HWND window = GetHandle();
  RECT rect{};
  if (!window || !GetWindowRect(window, &rect)) return;
  if (IsZoomed(window)) {
    const RECT maximized = rect;
    ShowWindow(window, SW_RESTORE);
    if (!GetWindowRect(window, &rect)) return;
    // Keep the horizontal grip point when restoring a maximized window.
    const LONG width = maximized.right - maximized.left;
    const LONG grip = width > 0 ? static_cast<LONG>(
        static_cast<int64_t>(cursor.x - maximized.left) *
        (rect.right - rect.left) / width) : 0;
    SetWindowPos(window, nullptr, cursor.x - grip, maximized.top, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    if (!GetWindowRect(window, &rect)) return;
  }
  drag_cursor_ = cursor;
  drag_window_ = {rect.left, rect.top};
  dragging_ = true;
}

void FlutterWindow::ApplyDragCursor(const POINT& cursor) {
  const HWND window = GetHandle();
  RECT rect{};
  if (!dragging_ || !window || !GetWindowRect(window, &rect)) return;
  const LONG x = drag_window_.x + cursor.x - drag_cursor_.x;
  const LONG y = drag_window_.y + cursor.y - drag_cursor_.y;
  if (rect.left != x || rect.top != y) {
    SetWindowPos(window, nullptr, x, y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  }
}

void FlutterWindow::OnDestroy() {
  desktop_ = nullptr;
  drag_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
