#pragma once
#include "client.hpp"
#include <memory>

namespace qimei::client {
struct HttpDiagnostics {
  bool send_started=false,send_completed=false,headers_received=false;
  unsigned http_status=0,native_error=0;
  std::size_t decoded_response_bytes=0;
};
// Native Windows TLS transport. Production endpoint is fixed to the App API.
// No automatic redirects, HTTP authentication, cookie jar or request retries.
class WindowsHttp {
 public:
  WindowsHttp();
  ~WindowsHttp();
  WindowsHttp(const WindowsHttp&)=delete;
  WindowsHttp& operator=(const WindowsHttp&)=delete;
  static std::shared_ptr<WindowsHttp> loopback_for_test(std::uint16_t port);
  AppReply send(const SignedRequest& request);
  void close();
  unsigned last_native_error()const;
  HttpDiagnostics diagnostics()const;
 private:
  struct Runtime;
  explicit WindowsHttp(std::uint16_t loopback_port);
  std::shared_ptr<Runtime> runtime_;
};
}
