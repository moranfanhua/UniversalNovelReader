#include "http_windows.hpp"
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <winhttp.h>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <stdexcept>

namespace qimei::client {
namespace {
[[noreturn]]void failed(){throw std::runtime_error("App HTTP transport failed");}
std::wstring ascii(const std::string& value){std::wstring out;for(unsigned char ch:value){if(ch<0x20||ch>=0x7f)throw std::invalid_argument("App HTTP header is not ASCII");out+=wchar_t(ch);}return out;}
struct Handle {
  HINTERNET value=nullptr;
  explicit Handle(HINTERNET handle=nullptr):value(handle){}
  ~Handle(){if(value)WinHttpCloseHandle(value);}
  Handle(const Handle&)=delete;Handle&operator=(const Handle&)=delete;
};
struct Operation:std::enable_shared_from_this<Operation> {
  Handle session,connection;
  HINTERNET request=nullptr;
  std::mutex api,state;std::condition_variable changed;
  std::shared_ptr<Operation> callback_lifetime;
  std::uint64_t sent=0,headers=0,read=0;DWORD bytes_read=0,error=0;
  bool cancelled=false,handle_closed=false;
  std::array<char,65536> buffer{};
  std::string body;
  const std::chrono::steady_clock::time_point deadline=std::chrono::steady_clock::now()+std::chrono::seconds(45);
  ~Operation(){if(request)WinHttpCloseHandle(request);}
  static void CALLBACK callback(HINTERNET,DWORD_PTR context,DWORD status,LPVOID data,DWORD length)noexcept{
    if(!context)return;
    auto* self=reinterpret_cast<Operation*>(context);std::shared_ptr<Operation> alive,release;
    {std::lock_guard<std::mutex> lock(self->state);alive=self->callback_lifetime;
      if(status==WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE)++self->sent;
      else if(status==WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE)++self->headers;
      else if(status==WINHTTP_CALLBACK_STATUS_READ_COMPLETE){++self->read;self->bytes_read=length;}
      else if(status==WINHTTP_CALLBACK_STATUS_REQUEST_ERROR)self->error=data&&length>=sizeof(WINHTTP_ASYNC_RESULT)?static_cast<WINHTTP_ASYNC_RESULT*>(data)->dwError:ERROR_WINHTTP_INTERNAL_ERROR;
      else if(status==WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING){self->handle_closed=true;release=std::move(self->callback_lifetime);}
    }self->changed.notify_all();
  }
  void close(bool cancel){
    {std::lock_guard<std::mutex> lock(state);if(cancel)cancelled=true;}changed.notify_all();
    std::lock_guard<std::mutex> call(api);if(request){const auto handle=request;request=nullptr;WinHttpCloseHandle(handle);}
  }
  template<class Call>void invoke(Call action){
    std::lock_guard<std::mutex> call(api);
    {std::lock_guard<std::mutex> lock(state);if(cancelled||handle_closed||!request)failed();}
    if(!action(request)){const auto code=GetLastError();if(code!=ERROR_IO_PENDING){std::lock_guard<std::mutex> lock(state);error=code;failed();}}
  }
  void await(std::uint64_t Operation::* counter,std::uint64_t previous){
    std::unique_lock<std::mutex> lock(state);
    if(!changed.wait_until(lock,deadline,[&]{return this->*counter>previous||error||cancelled||handle_closed;})){error=ERROR_WINHTTP_TIMEOUT;lock.unlock();close(true);failed();}
    if(error||cancelled||handle_closed)failed();
  }
  std::uint64_t value(std::uint64_t Operation::*counter){std::lock_guard<std::mutex> lock(state);return this->*counter;}
};
void option(HINTERNET request,DWORD key,DWORD value){if(!WinHttpSetOption(request,key,&value,sizeof(value)))failed();}
}
struct WindowsHttp::Runtime {
  mutable std::mutex mutex;std::weak_ptr<Operation> active;bool closed=false,inflight=false;std::uint16_t loopback=0;std::atomic<unsigned> last_error{0},status{0};std::atomic<bool> started{false},sent{false},headers{false};std::atomic<std::size_t> received{0};
};
WindowsHttp::WindowsHttp():runtime_(std::make_shared<Runtime>()){}
WindowsHttp::WindowsHttp(std::uint16_t port):WindowsHttp(){if(!port)throw std::invalid_argument("Loopback port missing");runtime_->loopback=port;}
WindowsHttp::~WindowsHttp(){close();}
std::shared_ptr<WindowsHttp> WindowsHttp::loopback_for_test(std::uint16_t port){return std::shared_ptr<WindowsHttp>(new WindowsHttp(port));}
unsigned WindowsHttp::last_native_error()const{return runtime_->last_error.load();}
HttpDiagnostics WindowsHttp::diagnostics()const{auto r=runtime_;return {r->started.load(),r->sent.load(),r->headers.load(),r->status.load(),r->last_error.load(),r->received.load()};}
void WindowsHttp::close(){auto r=runtime_;std::shared_ptr<Operation> active;{std::lock_guard<std::mutex> lock(r->mutex);r->closed=true;active=r->active.lock();}if(active)active->close(true);}
AppReply WindowsHttp::send(const SignedRequest& input){
  auto r=runtime_;
  if(input.path!="/argus/api/v1/client/ostar"||input.form_body.size()>4*1024*1024)throw std::invalid_argument("App API request boundary invalid");
  {std::lock_guard<std::mutex> lock(r->mutex);if(r->closed||r->inflight)failed();r->inflight=true;r->last_error=0;r->status=0;r->started=false;r->sent=false;r->headers=false;r->received=0;}
  struct Finish {std::shared_ptr<Runtime> r;~Finish(){std::lock_guard<std::mutex> lock(r->mutex);r->active.reset();r->inflight=false;}} finish{r};
  auto operation=std::make_shared<Operation>();
  operation->body=input.form_body;
  try{
    operation->session.value=WinHttpOpen(L"UNR QIMEI client",WINHTTP_ACCESS_TYPE_NO_PROXY,WINHTTP_NO_PROXY_NAME,WINHTTP_NO_PROXY_BYPASS,WINHTTP_FLAG_ASYNC);if(!operation->session.value)failed();
    if(!WinHttpSetTimeouts(operation->session.value,5000,10000,10000,30000))failed();
    operation->connection.value=WinHttpConnect(operation->session.value,r->loopback?L"127.0.0.1":L"druidv6.if.qidian.com",r->loopback?r->loopback:INTERNET_DEFAULT_HTTPS_PORT,0);if(!operation->connection.value)failed();
    const auto path=ascii(input.path);operation->request=WinHttpOpenRequest(operation->connection.value,L"POST",path.c_str(),nullptr,WINHTTP_NO_REFERER,WINHTTP_DEFAULT_ACCEPT_TYPES,r->loopback?0:WINHTTP_FLAG_SECURE);if(!operation->request)failed();
    option(operation->request,WINHTTP_OPTION_DISABLE_FEATURE,WINHTTP_DISABLE_REDIRECTS|WINHTTP_DISABLE_COOKIES|WINHTTP_DISABLE_AUTHENTICATION);
    option(operation->request,WINHTTP_OPTION_REDIRECT_POLICY,WINHTTP_OPTION_REDIRECT_POLICY_NEVER);
    option(operation->request,WINHTTP_OPTION_AUTOLOGON_POLICY,WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH);
    option(operation->request,WINHTTP_OPTION_CONNECT_RETRIES,0);
    option(operation->request,WINHTTP_OPTION_DECOMPRESSION,WINHTTP_DECOMPRESSION_FLAG_GZIP|WINHTTP_DECOMPRESSION_FLAG_DEFLATE);
#ifdef WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL
    DWORD protocol=WINHTTP_PROTOCOL_FLAG_HTTP2;WinHttpSetOption(operation->request,WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL,&protocol,sizeof(protocol));
#endif
    std::wstring headers=L"Content-Type: application/x-www-form-urlencoded\r\n";
    for(const auto& [name,value]:input.headers){if(name.empty()||name.find_first_of(": \r\n")!=std::string::npos||value.find_first_of("\r\n")!=std::string::npos)throw std::invalid_argument("App API header invalid");headers+=ascii(name)+L": "+ascii(value)+L"\r\n";}
    if(!WinHttpAddRequestHeaders(operation->request,headers.c_str(),DWORD(headers.size()),WINHTTP_ADDREQ_FLAG_ADD|WINHTTP_ADDREQ_FLAG_REPLACE))failed();
    DWORD_PTR context=reinterpret_cast<DWORD_PTR>(operation.get());if(!WinHttpSetOption(operation->request,WINHTTP_OPTION_CONTEXT_VALUE,&context,sizeof(context)))failed();
    {std::lock_guard<std::mutex> lock(operation->state);operation->callback_lifetime=operation;}
    if(WinHttpSetStatusCallback(operation->request,Operation::callback,WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS|WINHTTP_CALLBACK_FLAG_HANDLES,0)==WINHTTP_INVALID_STATUS_CALLBACK){std::lock_guard<std::mutex> lock(operation->state);operation->callback_lifetime.reset();failed();}
    {std::lock_guard<std::mutex> lock(r->mutex);if(r->closed){operation->close(true);failed();}r->active=operation;}
    r->started=true;const auto sent=operation->value(&Operation::sent);operation->invoke([&](HINTERNET handle){return WinHttpSendRequest(handle,WINHTTP_NO_ADDITIONAL_HEADERS,0,operation->body.empty()?WINHTTP_NO_REQUEST_DATA:operation->body.data(),DWORD(operation->body.size()),DWORD(operation->body.size()),context);});operation->await(&Operation::sent,sent);r->sent=true;
    const auto available=operation->value(&Operation::headers);operation->invoke([](HINTERNET handle){return WinHttpReceiveResponse(handle,nullptr);});operation->await(&Operation::headers,available);
    DWORD status=0,size=sizeof(status);operation->invoke([&](HINTERNET handle){return WinHttpQueryHeaders(handle,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,WINHTTP_HEADER_NAME_BY_INDEX,&status,&size,WINHTTP_NO_HEADER_INDEX);});
    r->headers=true;r->status=status;AppReply reply{int(status),{}};
    for(;;){const auto read=operation->value(&Operation::read);operation->invoke([&](HINTERNET handle){return WinHttpReadData(handle,operation->buffer.data(),DWORD(operation->buffer.size()),nullptr);});operation->await(&Operation::read,read);DWORD count;{std::lock_guard<std::mutex> lock(operation->state);count=operation->bytes_read;}if(!count)break;if(reply.body.size()+count>1024*1024)throw std::runtime_error("App API response too large");reply.body.append(operation->buffer.data(),count);}
    r->received=reply.body.size();operation->close(false);return reply;
  }catch(const std::exception&){DWORD native=0;{std::lock_guard<std::mutex> lock(operation->state);native=operation->error;if(operation->cancelled&&!native)native=ERROR_WINHTTP_OPERATION_CANCELLED;}r->last_error=native?native:GetLastError();operation->close(true);throw;}
}
}
