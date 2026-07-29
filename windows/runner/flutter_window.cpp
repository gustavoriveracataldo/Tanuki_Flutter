#include "flutter_window.h"

#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

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
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "tanuki/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setFullscreen") {
          const auto* enabled = std::get_if<bool>(call.arguments());
          SetFullscreen(enabled != nullptr && *enabled);
          result->Success();
          return;
        }
        result->NotImplemented();
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

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
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

void FlutterWindow::SetFullscreen(bool enabled) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || fullscreen_ == enabled) {
    return;
  }

  if (enabled) {
    restore_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
    GetWindowRect(hwnd, &restore_bounds_);

    MONITORINFO monitor_info = {};
    monitor_info.cbSize = sizeof(monitor_info);
    if (GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                       &monitor_info)) {
      SetWindowLongPtr(hwnd, GWL_STYLE,
                       restore_style_ &
                           ~static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW));
      SetWindowPos(hwnd, HWND_TOP, monitor_info.rcMonitor.left,
                   monitor_info.rcMonitor.top,
                   monitor_info.rcMonitor.right - monitor_info.rcMonitor.left,
                   monitor_info.rcMonitor.bottom - monitor_info.rcMonitor.top,
                   SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
      fullscreen_ = true;
    }
    return;
  }

  SetWindowLongPtr(hwnd, GWL_STYLE, restore_style_);
  SetWindowPos(hwnd, nullptr, restore_bounds_.left, restore_bounds_.top,
               restore_bounds_.right - restore_bounds_.left,
               restore_bounds_.bottom - restore_bounds_.top,
               SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  fullscreen_ = false;
}
