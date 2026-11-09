#pragma once
#include <jni.h>
#include <memory>
#include <string>
#include <cstdint>
namespace ibex_producer {
std::string encode_report(JNIEnv* env,jobject report,std::int64_t now);
// Android framework/JCE/regex/collections are platform primitives, not original SDK calls.
// Privacy values are explicit authorized inputs. Debug/root/accessibility flags
// and module-name fields use fixed declarations; other probes observe this app.
class Producer {
 public:
  Producer();
  ~Producer();
  Producer(const Producer&)=delete;
  Producer& operator=(const Producer&)=delete;
  jobject collect_required(JNIEnv* env,jobject context,jobject authorized_inputs,jobject options);
  void mark_failed();
  std::string generate(JNIEnv* env,jobject context,jobject authorized_inputs,jobject options,std::int64_t now);
 private:
  struct State;
  std::unique_ptr<State> state_;
};
}
