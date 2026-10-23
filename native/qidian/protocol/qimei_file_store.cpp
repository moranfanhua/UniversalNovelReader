#include "qimei_file_store.hpp"
#include "qimei_json.hpp"
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <utility>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>
#endif

namespace qimei {
namespace {
std::string encode_state(const StoredState& state){
  return Json::object({{"version",Json::number(1)},{"appKey",Json::string(base64(state.app_key))},{"qimei",Json::string(base64(state.identifiers.qimei))},{"qimei36",Json::string(base64(state.identifiers.qimei36))},{"riskUntilMs",Json::string(std::to_string(state.risk_until_ms))}}).encode();
}
std::string required(const Json& value,const char* name){const auto* field=value.find(name);if(!field||field->kind!=Json::Kind::string)throw std::runtime_error("QIMEI state is malformed");return field->text;}
StoredState decode_state(const std::string& text){
  const auto value=Json::parse(text);const auto* version=value.find("version");if(!version||version->integer()!=1)throw std::runtime_error("QIMEI state version unsupported");
  StoredState state;state.app_key=unbase64(required(value,"appKey"));state.identifiers.qimei=unbase64(required(value,"qimei"));state.identifiers.qimei36=unbase64(required(value,"qimei36"));
  const auto until=required(value,"riskUntilMs");if(until.empty()||until.find_first_not_of("0123456789")!=std::string::npos)throw std::runtime_error("QIMEI state timestamp invalid");
  try{std::size_t consumed=0;state.risk_until_ms=std::stoull(until,&consumed);if(consumed!=until.size())throw std::runtime_error("QIMEI state timestamp invalid");}catch(const std::exception&){throw std::runtime_error("QIMEI state timestamp invalid");}
  return state;
}
}
FileStateStore::FileStateStore(std::filesystem::path path):path_(std::move(path)){if(path_.empty())throw std::invalid_argument("QIMEI state path missing");}
StoredState FileStateStore::read(){
  std::lock_guard<std::mutex> lock(mutex_);std::error_code error;const bool exists=std::filesystem::exists(path_,error);
  if(error){throw std::runtime_error("QIMEI state unavailable");}
  if(!exists)return {};
  const auto size=std::filesystem::file_size(path_,error);if(error||size>65536)throw std::runtime_error("QIMEI state size invalid");
  std::ifstream stream(path_,std::ios::binary);if(!stream)throw std::runtime_error("QIMEI state cannot be opened");
  const std::string text(std::istreambuf_iterator<char>(stream),{});if(stream.bad())throw std::runtime_error("QIMEI state cannot be read");return decode_state(text);
}
bool FileStateStore::save(const StoredState& state){
  std::lock_guard<std::mutex> lock(mutex_);const auto text=encode_state(state);if(text.size()>65536)return false;
  auto parent=path_.parent_path();if(parent.empty())parent=".";std::error_code error;std::filesystem::create_directories(parent,error);if(error)return false;
  const auto temporary=parent/(path_.filename().u8string()+".tmp-"+random_nonce());bool committed=false;
#ifdef _WIN32
  const auto file=CreateFileW(temporary.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);if(file==INVALID_HANDLE_VALUE)return false;
  DWORD written=0;const bool persisted=WriteFile(file,text.data(),DWORD(text.size()),&written,nullptr)&&written==text.size()&&FlushFileBuffers(file);CloseHandle(file);
  if(persisted)committed=MoveFileExW(temporary.c_str(),path_.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=0;
#else
  const int file=::open(temporary.c_str(),O_CREAT|O_EXCL|O_WRONLY,0600);if(file<0)return false;
  std::size_t offset=0;while(offset<text.size()){const auto written=::write(file,text.data()+offset,text.size()-offset);if(written<0&&errno==EINTR)continue;if(written<=0)break;offset+=std::size_t(written);}
  const bool persisted=offset==text.size()&&::fsync(file)==0;const int closed=::close(file);
  if(persisted&&closed==0){std::filesystem::rename(temporary,path_,error);committed=!error;}
  if(committed){const int directory=::open(parent.c_str(),O_RDONLY|O_DIRECTORY);if(directory>=0){::fsync(directory);::close(directory);}}
#endif
  if(!committed)std::filesystem::remove(temporary,error);
  return committed;
}
}
