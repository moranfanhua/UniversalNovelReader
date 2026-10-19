## 声明

UniversalNovelReader（UNR）是一个非官方第三方阅读工具，与任何小说平台及其关联方无隶属、代理、合作或授权关系。平台名称、图标、商标、作品、评论、插图、封面等归各自权利人所有，本项目仅作技术说明与平台标识之用。

### 1. 内容与权限

本工具仅用于访问公开内容及用户已合法取得阅读权限的内容。本工具不提供、不托管、不存储、不索引、不推荐、不传播任何未经授权的作品内容或内容源，不绕过付费、登录、DRM、地域限制、反爬或其他技术措施，不自动购买、订阅、解锁、打赏、投票或分享。

### 2. 账号与会话

账号登录与会话导入由用户主动发起，登录凭据、Cookie、会话仅用于对应平台的 App API 请求及会话校验。用户应自行确保有权使用该账号，并遵守对应平台条款。不得共享、出租、售卖账号或会话。本机会话通过 `flutter_secure_storage` 保存，用户可在账号页退出登录清除，不上传至开发者服务器。

### 3. 导入、下载、导出与缓存

导入、下载、导出、缓存仅限用户对合法有权处理的内容，并遵守作品授权及平台条款。默认仅限本地个人使用，不得复制、传播、售卖、公开分享或商业利用。是否允许导出、下载、缓存，以平台规则和作品授权为准。

### 4. 用户责任

用户应遵守著作权法、平台协议及所在地法律。不得将本工具用于批量抓取、绕过限制、盗取内容、侵犯隐私、传播盗版或其他违法用途。因用户行为产生的后果由用户自行承担。

### 5. 非官方与商标

本项目为非官方工具，不声称获得任何平台授权。平台图标、商标仅用于标识对应平台，归权利人所有。若权利人反对，我们将更名、替换或移除相关标识。

### 6. 侵权处理

如认为本项目涉及侵权，请联系 [moranfanhua@outlook.com](mailto:moranfanhua@outlook.com)，提供权属证明、具体定位、联系方式及真实性声明。我们将在核实后依法采取删除、断开链接、下架等措施。

### 7. 无担保与责任限制

本工具按“现状”提供，不保证不中断、无错误或满足特定目的。在法律允许范围内，开发者不对用户不当使用或第三方内容承担责任。该声明不排除依法不能排除的责任。

### 8. 其他

本项目采用 GNU Affero General Public License v3.0（AGPL-3.0），完整许可证见 [LICENSE](LICENSE)。第三方依赖保留各自的版权与许可证。

`archive` 的主体采用 MIT；其附带的 zlib/inflate 与 pointycastle 衍生代码采用 MIT，JZLib 衍生代码采用 BSD-3-Clause，bzip2 衍生代码采用 bzip2-1.0.6 许可。完整附带代码声明见 [LICENSE-other.md](LICENSE-other.md)，对应锁定版本 `archive 4.5.1` 发布包内的同名文件。

`sky_engine` 随 Flutter SDK 分发，包含多种第三方组件的版权与许可声明，完整文本见该包内的 `LICENSE`；其许可不统一标记为 Flutter 框架的 BSD-3-Clause。

云端可选字体均使用 SIL Open Font License 1.1，保留各自的原作者版权；由用户按需下载，原许可随字体保存在本机：

- Google Fonts：[Noto Sans SC](https://github.com/google/fonts/tree/main/ofl/notosanssc)、[Noto Serif SC](https://github.com/google/fonts/tree/main/ofl/notoserifsc)。
- 落霞孤鹜：[霞鹜文楷 GB 屏幕版](https://github.com/lxgw/LxgwWenKai-Screen)、[悠哉字体](https://github.com/lxgw/yozai-font)、[霞鹜臻楷 GB](https://github.com/lxgw/LxgwZhenKai)、[小赖字体](https://github.com/lxgw/kose-font)。
- 寒蝉字型：[寒蝉半圆体](https://github.com/Warren2060/ChillRound)。
- 璇玑造字：[朱雀仿宋](https://github.com/TrionesType/zhuque)。
- IBM：[IBM Plex Sans SC](https://github.com/IBM/plex/tree/master/packages/plex-sans-sc)。

### 9. 更新

本声明可能更新，更新后公布即生效。继续使用视为接受更新版本。

最后更新日期：2026.10.19

## 开源库

- [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) 及其 Android、Windows、iOS、macOS、Linux、Web、平台接口和内部注解包 — Apache-2.0；菠萝包与起点安全验证使用 Android WebView 与 Windows WebView2。锁定 6.2.0-beta.3，以兼容项目使用的 AGP 9。
- [Microsoft WebView2](https://www.nuget.org/packages/Microsoft.Web.WebView2) — Microsoft 软件许可条款；Windows 验证页面运行时与 SDK。[Windows Implementation Library](https://github.com/microsoft/wil) — MIT；[nlohmann/json](https://github.com/nlohmann/json) — MIT，均为 Windows WebView 插件的原生依赖。
- [C++/WinRT](https://github.com/microsoft/cppwinrt) — MIT；Windows WebView 插件的原生依赖。
- [Flutter](https://github.com/flutter/flutter)、[flutter_localizations](https://github.com/flutter/flutter)、[flutter_test](https://github.com/flutter/flutter)、[flutter_web_plugins](https://github.com/flutter/flutter) — BSD-3-Clause
- [http](https://pub.dev/packages/http)、[crypto](https://pub.dev/packages/crypto) — BSD-3-Clause
- [html](https://pub.dev/packages/html)、[xml](https://pub.dev/packages/xml) — MIT
- [archive](https://pub.dev/packages/archive) — MIT；附带代码另有许可，见声明
- [flutter_svg](https://pub.dev/packages/flutter_svg) — MIT
- [uuid](https://pub.dev/packages/uuid)、[file_picker](https://pub.dev/packages/file_picker) — MIT
- [path_provider](https://pub.dev/packages/path_provider) — BSD-3-Clause
- [package_info_plus](https://pub.dev/packages/package_info_plus)、[package_info_plus_platform_interface](https://pub.dev/packages/package_info_plus_platform_interface) — BSD-3-Clause；读取已安装应用的版本与构建号。
- [url_launcher](https://pub.dev/packages/url_launcher) 及其 Android、iOS、Linux、macOS、Web、Windows 和平台接口包 — BSD-3-Clause；使用系统浏览器下载更新包。
- [pub_semver](https://pub.dev/packages/pub_semver) — BSD-3-Clause；检查更新时解析、比较正式版本号。
- [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) — BSD-3-Clause
- [enough_convert](https://pub.dev/packages/enough_convert) — MPL-2.0
- [flutter_lints](https://pub.dev/packages/flutter_lints)、[lints](https://pub.dev/packages/lints) — BSD-3-Clause
- [android_file_picker](https://pub.dev/packages/android_file_picker)、[file_picker_darwin](https://pub.dev/packages/file_picker_darwin)、[file_picker_linux](https://pub.dev/packages/file_picker_linux)、[file_picker_platform_interface](https://pub.dev/packages/file_picker_platform_interface) — MIT
- [file_picker_web](https://pub.dev/packages/file_picker_web)、[path_parsing](https://pub.dev/packages/path_parsing)、[petitparser](https://pub.dev/packages/petitparser)、[posix](https://pub.dev/packages/posix) — MIT
- [windows_file_picker](https://pub.dev/packages/windows_file_picker)、[yaml](https://pub.dev/packages/yaml) — MIT
- [args](https://pub.dev/packages/args)、[async](https://pub.dev/packages/async)、[boolean_selector](https://pub.dev/packages/boolean_selector)、[characters](https://pub.dev/packages/characters) — BSD-3-Clause
- [code_assets](https://pub.dev/packages/code_assets)、[collection](https://pub.dev/packages/collection)、[cross_file](https://pub.dev/packages/cross_file)、[csslib](https://pub.dev/packages/csslib) — BSD-3-Clause
- [ffi](https://pub.dev/packages/ffi)、[ffi_leak_tracker](https://pub.dev/packages/ffi_leak_tracker)、[fixnum](https://pub.dev/packages/fixnum)、[flutter_secure_storage_darwin](https://pub.dev/packages/flutter_secure_storage_darwin) — BSD-3-Clause
- [flutter_secure_storage_linux](https://pub.dev/packages/flutter_secure_storage_linux)、[flutter_secure_storage_platform_interface](https://pub.dev/packages/flutter_secure_storage_platform_interface)、[flutter_secure_storage_web](https://pub.dev/packages/flutter_secure_storage_web)、[flutter_secure_storage_windows](https://pub.dev/packages/flutter_secure_storage_windows) — BSD-3-Clause
- [hooks](https://pub.dev/packages/hooks)、[http_parser](https://pub.dev/packages/http_parser)、[intl](https://pub.dev/packages/intl)、[jni](https://pub.dev/packages/jni) — BSD-3-Clause
- [jni_flutter](https://pub.dev/packages/jni_flutter)、[jni_util](https://pub.dev/packages/jni_util)、[leak_tracker](https://pub.dev/packages/leak_tracker)、[leak_tracker_flutter_testing](https://pub.dev/packages/leak_tracker_flutter_testing) — BSD-3-Clause
- [leak_tracker_testing](https://pub.dev/packages/leak_tracker_testing)、[logging](https://pub.dev/packages/logging)、[matcher](https://pub.dev/packages/matcher)、[meta](https://pub.dev/packages/meta) — BSD-3-Clause
- [objective_c](https://pub.dev/packages/objective_c)、[package_config](https://pub.dev/packages/package_config)、[path](https://pub.dev/packages/path)、[path_provider_android](https://pub.dev/packages/path_provider_android) — BSD-3-Clause
- [path_provider_foundation](https://pub.dev/packages/path_provider_foundation)、[path_provider_linux](https://pub.dev/packages/path_provider_linux)、[path_provider_platform_interface](https://pub.dev/packages/path_provider_platform_interface)、[path_provider_windows](https://pub.dev/packages/path_provider_windows) — BSD-3-Clause
- [platform](https://pub.dev/packages/platform)、[plugin_platform_interface](https://pub.dev/packages/plugin_platform_interface)、[record_use](https://pub.dev/packages/record_use) — BSD-3-Clause
- [source_span](https://pub.dev/packages/source_span)、[stack_trace](https://pub.dev/packages/stack_trace)、[stream_channel](https://pub.dev/packages/stream_channel)、[string_scanner](https://pub.dev/packages/string_scanner) — BSD-3-Clause
- [term_glyph](https://pub.dev/packages/term_glyph)、[test_api](https://pub.dev/packages/test_api)、[typed_data](https://pub.dev/packages/typed_data)、[vector_graphics](https://pub.dev/packages/vector_graphics) — BSD-3-Clause
- [vector_graphics_codec](https://pub.dev/packages/vector_graphics_codec)、[vector_graphics_compiler](https://pub.dev/packages/vector_graphics_compiler)、[vector_math](https://pub.dev/packages/vector_math)、[vm_service](https://pub.dev/packages/vm_service) — BSD-3-Clause
- [web](https://pub.dev/packages/web)、[win32](https://pub.dev/packages/win32)、[xdg_directories](https://pub.dev/packages/xdg_directories) — BSD-3-Clause
- [clock](https://pub.dev/packages/clock)、[fake_async](https://pub.dev/packages/fake_async)、[material_color_utilities](https://pub.dev/packages/material_color_utilities) — Apache-2.0
- [dbus](https://pub.dev/packages/dbus) — MPL-2.0
- [sky_engine](https://github.com/flutter/flutter) — 第三方组件分别授权，见声明
- [actions/checkout](https://github.com/actions/checkout)、[actions/setup-java](https://github.com/actions/setup-java)、[actions/upload-artifact](https://github.com/actions/upload-artifact)、[actions/download-artifact](https://github.com/actions/download-artifact)、[subosito/flutter-action](https://github.com/subosito/flutter-action) — MIT；构建与发布 CI 使用的工具。
- [actions/github-script](https://github.com/actions/github-script) — MIT；分支校验与 PR 检查反馈使用的工具。
- [peter-evans/create-pull-request](https://github.com/peter-evans/create-pull-request) — MIT；自动格式化变更的 PR 创建与更新工具。
- [SFacgExporter](https://github.com/moranfanhua/SFacgExporter) — AGPL-3.0；菠萝包签名、正文字符表与导出逻辑参考来源，原作者 moranfanhua。
- [fanqienovel-downloader](https://github.com/ying-ck/fanqienovel-downloader) — AGPL-3.0；番茄官网正文字体字符表参考来源，原作者 ying-ck（qxqycb）。
- [Pointy Castle](https://pub.dev/packages/pointycastle) — MIT；番茄接口签名与阅读密钥注册使用的 AES、SM3 实现，起点 App 协议使用的 AES、DES 与 3DES 实现，以及刺猬猫 App 协议使用的 AES 与 RSA 实现。
- [pinyin](https://pub.dev/packages/pinyin) — BSD-2-Clause；书名排序使用的汉字转拼音实现。
- [convert](https://pub.dev/packages/convert) — BSD-3-Clause；Pointy Castle 的传递依赖。
- [fqapp](https://github.com/ch6vip/fqapp) — GPL-3.0；番茄签名、密钥注册与接口参数参考来源，原作者 ch6vip。
- [Guava](https://github.com/google/guava) — Apache-2.0；AndroidX 仍使用其 listenablefuture 接口包。
- [AndroidX Core](https://android.googlesource.com/platform/frameworks/support/)、[AndroidX Annotation](https://android.googlesource.com/platform/frameworks/support/) — Apache-2.0；Flutter Android 插件的平台适配。WebView 插件还使用 Apache-2.0 的 AndroidX WebKit、Browser、AppCompat 与 SwipeRefreshLayout。
- [Error Prone annotations](https://github.com/google/error-prone)、[JSpecify](https://github.com/jspecify/jspecify) — Apache-2.0；Flutter Android 插件的传递依赖。
