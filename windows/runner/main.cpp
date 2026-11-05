#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <memory>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Each engine keeps a full in-memory library snapshot. Only one process may
  // write it; a second instance could otherwise overwrite newer reading data.
  const HANDLE mutex =
      ::CreateMutexW(nullptr, FALSE, L"Local\\io.github.moranfanhua.unr");
  const DWORD mutex_error = ::GetLastError();
  const std::unique_ptr<void, decltype(&::CloseHandle)> instance_mutex(
      mutex, ::CloseHandle);
  if (!instance_mutex) {
    ::MessageBoxW(nullptr, L"无法保护本地书库，请稍后重试。", L"UNR 阅读器",
                  MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
  if (mutex_error == ERROR_ALREADY_EXISTS) {
    const HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"unr");
    if (existing) {
      ::ShowWindow(existing, ::IsIconic(existing) ? SW_RESTORE : SW_SHOW);
      ::SetForegroundWindow(existing);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"unr", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
