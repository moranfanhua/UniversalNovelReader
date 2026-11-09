#pragma once
#include "qimei_provider.hpp"
namespace qimei {
// Wire boundary of the independent AndroidSnapshot collector, usable by either
// host. It does not fabricate Android fields on Windows or read device data.
DeviceSnapshot snapshot_from_android_json(const std::string& encoded);
}
