# UNR 证据与代码入口

以下是编写 skill 时核对的实现入口，不是日志能力的永久契约。分析前按用户版本读取实际文件；找不到字段或事件时先检查历史，不编造报告内容。

## 运行日志

* 入口文案与导出流程：`lib/ui/my.dart`、`lib/ui/settings.dart`、`lib/ui/logs.dart`。引导用户按“我的 → 软件设置 → 日志”进入“运行日志”，复现后选择“导出日志”。取消保存不等于导出成功。
* 导出名为 `UNR-日志-时间.txt`；包含说明头和逐行 JSON，不是整份 JSON 文档。头部有版本、平台和 debug / profile / release 模式；未传入 `APP_VERSION` 时显示“开发版”，不等于确定的发布版本。
* `lib/data/app_log.dart`：日志位于应用支持目录的 `logs/unr.0.jsonl` 等轮换文件。默认每份 512 KiB、最多三份；快照从较旧文件读到最新文件。日志界面最新在上，分析时按时间和原始记录顺序还原，不照搬显示顺序。
* 事件字段包括 `time`、`level`、`event`，按事件可有 `errorType`、`code`、`errorCode`、`httpStatus`、`elapsedMs`、`stack`。`time` 是 UTC；只有异常类型与有限 Dart 代码位置，没有完整异常消息。
* 写入繁忙会丢记录；存储不可用时使用内存最近记录，导出头会提示。日志轮换或损坏可能让前文缺失，解析时逐行保留可读记录，不因一行损坏放弃整份文件。
* 日志不记录账号、会话、请求 URL / 请求头 / 正文或小说正文。不要从不存在的字段推断接口参数，也不要为了补日志破坏这些隐私约束。
* `lib/ui/log_entry.dart`：字段解析、事件与模块的中文映射。认证日志等筛选只影响显示，“复制全部”和导出包含全部保留记录。

## 事件与调用链

| 线索 | 优先核对 | 常见误判 |
| --- | --- | --- |
| `app.starting`、`app.started`、`app.start_failed` | `lib/main.dart`、`lib/data/error_logging.dart` | 没有后续日志就直接认定崩溃；记录可能缺失或启动未走到该处 |
| `app.flutter_error`、`app.unhandled_error` | `lib/data/error_logging.dart` 及堆栈对应文件 | 所有 Flutter 异常都归为进程闪退 |
| `http.sfacg`、`sfacg.response_invalid`、`sfacg.request_rejected` | `lib/sources/logged_request.dart`、`lib/sources/sfacg/sfacg_api.dart` | HTTP 200 就认定平台业务成功 |
| `http.fanqie.app`、`fanqie.response_invalid`、`fanqie.request_rejected` | `lib/sources/fanqie/fanqie_app_api.dart`、`fanqie_crypto.dart` | 将权限、密钥或解析问题统一归为网络失败 |
| `http.fanqie.auth`、`fanqie.auth_rejected`、`fanqie.auth_response_invalid` | `lib/sources/fanqie/fanqie_auth.dart` | 认证请求完成就认定登录态可用 |
| `http.fanqie` 或旧版网页会话提示 | 按用户版本检查 `lib/sources/fanqie/fanqie_api.dart` 与实际调用方 | 看到旧路径仍存在就建议网页认证回退 |
| `session.*.restore_failed`、`session.*.save_failed`、`session.fanqie.device_restore_failed` | 各书源 `*_session.dart` 与 `lib/data/library.dart` | 会话恢复失败就清空整个本地书库 |
| `session_helper.*` | `lib/sources/session_helper.dart`、`lib/ui/session_helper_page.dart`、Android `SessionCapture.kt` / `SessionVpnService.kt` / `SessionCookies.kt` / `MainActivity.kt` | 辅助状态为运行中就认定真实认证或会话校验成功 |
| `storage.write_failed`、`reader.chapter_failed`、`reader.image_failed` | `lib/data/library.dart`、实际书源和格式适配 | 只看顶层事件，忽略平台、缓存命中、文件与图片来源 |
| `search.*`、`book.*`、`import.failed`、`export.failed` | `lib/sources/novel_search.dart`、相关 UI、`lib/formats/ebook.dart` | 所有失败都归到同一个平台接口 |

Android 原生入口位于 `android/app/src/main/kotlin/io/github/moranfanhua/unr/`。这些文件存在不代表每一步原生行为都已写入 Dart 日志；需要时只索取与本次故障有关的脱敏报错。

## 阅读器、持久化与格式问题

* 阅读与进度：`lib/ui/reader.dart`、`paged_chapter.dart`、`reading_layout.dart`、`chapter_page_layout.dart`、`text_pagination.dart`、`lib/data/library.dart`。核对滚动 / 翻页、宽屏双页、跨章及恢复模式，不能把一种模式的结果套到所有模式。
* 导入导出：`lib/formats/ebook.dart`、`image_format.dart`、`lib/data/library.dart`。核对 EPUB / TXT、章节顺序、封面插图、已缓存范围与资源失败；请求最小可复现样本，不要求上传完整受版权保护的作品。
* 书架与作品身份：`lib/domain/`、`lib/data/library.dart`、`lib/sources/*_source.dart` 和 UI 入口。来源与作品 ID 必须同时匹配，不能只按书名或数字 ID 关联。
* 评论：`lib/sources/comment_source.dart`、各平台评论适配和 `lib/ui/comments_sheet.dart`，按 `CommentCapabilities` 核验入口和实现。发送结果不确定时不得用自动重试作为默认排查方式。

## 相关现有验证入口

* 日志：`test/app_log_test.dart`、`test/logged_request_test.dart`、`test/logs_page_test.dart`。
* 书源 / 认证：`test/sfacg_test.dart`、`test/fanqie_test.dart`、`test/fanqie_auth_test.dart`、`test/session_test.dart`、`test/session_helper_test.dart`。
* 阅读器 / 数据：`test/reader_test.dart`、`test/chapter_transition_test.dart`、`test/continuous_scroll_test.dart`、`test/wide_reading_test.dart`、`test/library_test.dart`。
* 格式：`test/ebook_test.dart`；Android 会话处理：`android/app/src/test/kotlin/io/github/moranfanhua/unr/SessionCookiesTest.kt`。

这些仅用于定位相关检查，实际阅读测试内容后再选择；不替代根目录 `AGENTS.md` 的验证要求，不因测试文件存在就声称问题已覆盖。
