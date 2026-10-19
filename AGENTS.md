# UNR 项目协作约定

本文件适用于整个仓库。更深目录的 `AGENTS.md` 可补充该目录规则；用户在当前会话中的明确要求优先。

## 项目与沟通

* UniversalNovelReader（UNR）是基于 Flutter 的小说阅读器，当前提供 Windows、Android 工程，支持本地 EPUB / TXT，以及起点读书、番茄小说、刺猬猫阅读、菠萝包轻小说四个在线书源。
* 默认使用简体中文沟通，界面文案保持中文。说明最终行为、验证结果与实际限制，避免将单个平台或模拟器的验证表述为全部平台通过。
* 修改前检查 `git status`、当前分支和相关代码。保留用户及其他任务的未提交修改，只改动本任务涉及的内容。
* 以当前代码、测试和工作流为准。历史聊天、参考仓库和提交标题用于定位线索，不能代替对最终实现的检查。

## 代码结构

| 位置 | 职责 |
| --- | --- |
| `lib/main.dart` | 应用初始化、书源注册、主题与入口 |
| `lib/domain/` | 作品、章节、段落、书架等领域模型 |
| `lib/data/` | 书库及快照、缓存、阅读进度、偏好、字体、日志与应用更新 |
| `lib/formats/` | EPUB / TXT 导入导出及图像格式处理 |
| `lib/sources/` | 书源、搜索、书架预览、批量下载、更新检查、段评、会话与安全验证接口 |
| `lib/sources/sfacg/`、`lib/sources/fanqie/`、`lib/sources/qidian/`、`lib/sources/ciweimao/` | 各平台协议、认证、正文与评论适配 |
| `lib/ui/` | 书架、作品详情、阅读器、设置、账号、安全验证、日志与关于页面 |
| `assets/` | 字符表、平台图标等应用资源 |
| `android/` | Android 工程、原生音量键翻页与平台集成 |
| `windows/` | Windows 工程及平台集成 |
| `test/` | Dart 单元测试、Flutter 组件与交互回归测试 |
| `.github/` | 分支策略、发布准备、构建发布脚本及其测试 |
| `.agents/skills/` | 随项目复用的 agent skill |

## 实现要求

* 所有书源业务请求仅使用 App API，不能使用网页端 API 作为替代。
* 所有登录、验证码发送、认证及会话校验统一依据已解包的官方 APK 实现，使用 App API、签名与设备参数；不得提供网页登录选项或回退网页端认证接口。旧会话迁移不得清空用户书库或登录存储。
* 安全验证沿用官方 App 的挑战流程，通过 `SourceVerificationChallenge` 与公共验证页衔接；可主动验证的书源实现 `VerifiableNovelSource`。内嵌 WebView 仅承载安全验证，处理取消、过期、重试、旧回调及平台差异；不得注入 App 会话或将验证票据写入日志。
* 沿用现有 Dart 风格与 `flutter_lints`；格式化改动文件，避免顺手重排整个项目。
* 平台请求、签名、认证、分页和数据解析放在对应书源目录，通过公共接口向上层提供功能；不要把平台协议写进通用页面。
* 新增能力按实际实现扩展 `NovelSource`、`SearchableNovelSource`、`BookshelfSource` 或 `CommentSource`。段评操作依据 `CommentCapabilities` 显示，不为未实现的能力提供可点击入口。
* 书架导入使用 `BookshelfSource` 的作品预览，按需加载完整目录；自动更新通过 `BookUpdateSource` 获取新数据，保留每本书十分钟的检查间隔、重启后的限流与页面离开后的取消行为。目录请求遵循各平台 App 的会话规则，不污染已登录会话。
* 离线下载使用 `ChapterBatchSource`，遵循各书源的批大小与并发限制，逐章保留成功与失败结果。实现 `PlatformRankedSearchSource` 的书源保留其平台搜索顺序与提示，通用搜索合并不得打乱该平台结果的相对顺序。
* 保持书源与作品标识一致，避免不同平台的同名作品或相同数字 ID 混用缓存、阅读进度和书架成员。
* 网络和文件操作应有明确的加载、失败与重试行为；处理页面销毁、异步结果过期、取消以及重复请求。发表评论、回复、点赞等写操作结果不确定时，不盲目自动重发。
* 持久化变更兼容已有书库与阅读偏好。会话恢复异常不得阻断本地缓存阅读；不要为修复问题清空用户书库或登录状态。
* 仅在 App 明确拒绝认证或返回匿名账号时判定 `SessionExpiredException`；网络故障、安全挑战和解析异常只表示暂时无法确认。启动、账号页及手动会话检查应忽略已被新登录或退出取代的结果，不自动清除会话。
* 导入导出保留章节顺序、封面和插图。仅导出已缓存章节时明确提示节选，资源获取失败不得伪装成完整导出成功。
* 阅读器改动同时考虑滚动、翻页、宽屏双页、跨章节衔接及进度恢复。UI 改动检查手机与宽屏布局、文字缩放及长书名。
* 保留现有书架列表 / 宫格切换、手机宫格每行三本、书名拼音排序及目录按分卷收纳的行为，除非用户要求调整。平台展示顺序统一使用 `lib/sources/source_order.dart`。
* 云端字体按需下载并在本机保留原许可。GitHub 字体与安装包下载沿用 `DownloadMirror` 配置，书源与认证请求不套用下载镜像。版本检查直连 GitHub Releases API，仅接受本仓库已发布正式版与约定附件，安装包下载交由系统浏览器。
* 新依赖应有实际用途，同时核对 `pubspec.yaml`、`pubspec.lock`、资源声明和第三方许可记录，不为无关任务升级依赖或 SDK。

## 开发与验证

Flutter 版本以 `.github/actions/setup-flutter/action.yml` 为准，Dart 约束以 `pubspec.yaml` 为准。使用本机已有 SDK；需要恢复依赖且不更改依赖时，使用锁文件：

```powershell
flutter pub get --enforce-lockfile
```

修改 Dart 代码后格式化对应文件，并运行静态分析及相关测试：

```powershell
dart format <改动的 Dart 文件>
flutter analyze --no-pub --fatal-infos
flutter test --no-pub <相关测试文件>
```

* 优先运行与行为相关的现有回归测试。修复故障或新增重要行为时，补能重现问题、验证结果的测试；纯文档、格式及低影响布局调整不必机械添加测试。
* 会话改动优先检查 `test/session_validation_test.dart`、`test/startup_session_check_test.dart`、`test/account_session_test.dart` 及对应书源认证测试；安全验证改动检查 `test/sfacg_verification_test.dart`、`test/qidian_captcha_test.dart`、`test/reader_verification_test.dart` 中相关用例。Android WebView 与 Windows WebView2 的实际交互需分别核实，mock 测试不能替代。
* 影响书库持久化、阅读器公共逻辑或多个书源的改动，交付前运行 `flutter test --no-pub`。检查通过且没有新改动或未解决问题时，不重复执行同一批检查。
* Android 原生集成改动需运行相关现有原生测试（如有），并按需构建 `flutter build apk --debug --no-pub`。
* Windows 平台集成改动按需运行 `flutter build windows --debug --no-pub`。使用平台构建验证改动，但不要把构建成功等同于真实账号或设备交互已验证。
* `.github/` 发布脚本或分支策略改动运行以下测试；分支策略测试需要 Node.js，未在 PATH 中时可通过 `UNR_TEST_NODE` 指定可执行文件。

```powershell
python -m unittest discover -s .github/scripts/tests -v
```

* 修改工作流时使用可用的 `actionlint` 检查。发布日志改动运行 `python .github/scripts/release.py changelog`。
* 工作流、复合 Action 和可复用工作流中的所有远程 `uses:`（包括 GitHub 官方 `actions/*`）必须固定到上游官方仓库经核实的完整 40 位 commit SHA，行尾用注释保留对应版本（如 `# v1.2.3`）；不得使用分支、可移动标签或短 SHA。新增或升级时核对发布标签对应的实际 commit 并审阅变更，同步更新 SHA 与版本注释；本仓库 `./...` 本地引用沿用相对路径。
* 引入或升级第三方复合 Action 时检查其内部远程引用；固定外层 SHA 不代表间接依赖也已固定，发现浮动引用时须明确说明其限制。
* 提交前运行 `git diff --check`，并检查将提交的差异。若其他任务存在错误或空白问题，说明其归属，不擅自修正。
* 只有用户要求或当前任务确需设备验证时才安装调试包；先确认设备与应用标识，保留现有数据，避免卸载重装。真实登录结果必须实际核实，不能用 mock 测试代替。

## Issue 分析与 PR 审查

* 用户要求分析本项目 Issue、故障反馈、日志或功能诉求时，读取并使用 `.agents/skills/issue-analysis/SKILL.md`，可通过 `$issue-analysis` 调用。区分已证实事实、待验证假设与缺失证据，结合用户版本和当前实现判断，不把分析请求视为修复或对外回复授权。
* 用户要求审查本项目 PR 时，必须读取并使用 `.agents/skills/pr-review/SKILL.md`，可通过 `$pr-review` 调用。启动两个独立子智能体，先分别审查同一提交，再交换候选问题交叉核验，等待双方结果后由主智能体依据证据裁定分歧并汇总。普通开发后的自查不自动触发该流程。

## 文件、隐私与许可

* `README.md` 只维护开源库、参考来源、版权与许可声明。版本说明写入根目录 `CHANGELOG.md`，agent 约定写在本文件，skill 写入 `.agents/skills/`。
* 不额外提交开发报告、调试记录、发布操作文档等材料；临时脚本、探测结果、截图、日志与草稿统一放在已忽略的 `.local/`。
* 不提交构建产物、缓存、账号密码、Cookie、Token、抓包文件、签名密钥或私有证书；日志和交付说明不要包含这些值。
* 运行日志沿用 `AppLog` 与请求脱敏逻辑；新增日志字段、异常或诊断输出时检查账号、会话、验证码、验证票据和阅读密钥，导出日志也不得泄露这些值。
* `.gitignore` 默认忽略 Markdown；确需随项目提交的文档添加精确例外，不广泛放开临时文档。
* 保留项目 AGPL-3.0 及第三方版权、许可证和来源声明。引入或更新依赖、参考实现与字体时同步核对 README 中的声明。
* 内容访问使用公开接口或用户已有阅读权限，不自动购买章节。认证和会话辅助沿用用户主动操作的流程。

## Git 与发布

* 开发分支为 `dev`，稳定分支为 `master`。`master` 的 PR 仅接受本仓库 `dev`，不要绕过 `.github/workflows/branch-policy.yml`。
* 提交信息使用中文约定式格式，如 `feat(bookshelf): 支持书架列表显示`、`fix(reader): 修复跨章节进度恢复`、`docs(changelog): 整理 v版本号 更新日志`。
* 只暂存本任务文件，避免 `git add .` 混入其他修改。用户要求“先不要 commit”时，保持文件未提交；未经要求不推送、创建版本标签或发布 Release。
* 生成、补写版本日志或准备发版时，读取并使用 `.agents/skills/changelog/SKILL.md`，通过 `$changelog` 调用。
* 新版本在 `dev` 准备 `pubspec.yaml` 的版本与构建号以及 `CHANGELOG.md`。日志标题采用 `## vX.Y.Z`，不含 `+构建号`，最新版本置顶；内容按提交边界与最终 diff 整理。
* 保留提交 changelog commit 的阶段：运行日志校验，将版本号与审阅过的日志提交到 `dev`，然后通过 `dev → master` PR 的 `release-changelog` 和分支来源检查。失败时补提交修复原 PR。
* 合并后，版本标签 `vX.Y.Z` 必须与 `pubspec.yaml` 一致，并指向已包含版本号与日志的 `master` 提交。
* 标签触发 Release 工作流，构建 Windows x64 与 Android 通用 / 分 ABI 包并创建草稿；检查说明及附件后由维护者发布。手动构建选择 `master`，该入口只构建，不创建 Release。
* 补写已发布版本日志时只收录该版本已有变化，不混入之后的 `dev` 改动，不自动递增版本或移动既有标签。已发布 Release 与维护者编辑过的草稿不得被自动覆盖。

## 交付

简要说明改了什么、验证了什么及仍需确认的实际问题，给出相关文件或提交信息。没有运行、失败或受环境限制的验证如实说明；用户要求保持未提交时明确说明文件尚未提交。
