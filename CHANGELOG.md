# 更新日志

## v1.0.2

### 新增 | New

* 新增下载管理页，集中查看已下载书籍与正在执行的任务；支持选择章节加入顺序下载队列、关闭窗口后继续下载，并查看失败章节及重新下载。[#59](https://github.com/moranfanhua/UniversalNovelReader/pull/59)
* 支持菠萝包、起点和刺猬猫从当前章节起批量订阅后续章节；先获取费用并由用户确认后提交，跳过免费及已订阅章节。[#55](https://github.com/moranfanhua/UniversalNovelReader/pull/55)

### 修复 | Fix

* 修复 Android 自动更新下载包始终使用 universal 版本的问题，改为按设备 ABI 下载对应安装包。[#48](https://github.com/moranfanhua/UniversalNovelReader/pull/48)
* 修复番茄段评中的图片与表情显示问题。[#54](https://github.com/moranfanhua/UniversalNovelReader/pull/54)
* 修复番茄正文中缺少图片说明的空图片导致整章无法读取的问题。[#56](https://github.com/moranfanhua/UniversalNovelReader/pull/56)
* 番茄分享短链解析不再调用 H5 页面；无法从短链取得作品 ID 时，提示改用作品 ID、完整作品链接或搜索书名。[#60](https://github.com/moranfanhua/UniversalNovelReader/pull/60)
* 修复菠萝包数字书名被误判为作品 ID、导致书名搜索失效的问题。[#61](https://github.com/moranfanhua/UniversalNovelReader/pull/61)
* 修复服务端错误说明未完整保留的问题，并在日志中对相关内容脱敏。[#62](https://github.com/moranfanhua/UniversalNovelReader/pull/62)
* 修复导出 EPUB 时遇到不兼容图片格式导致失败的问题，导出时转换图片格式。[#63](https://github.com/moranfanhua/UniversalNovelReader/pull/63)

## v1.0.1

### 新增 | New

* 新增菠萝包、番茄、起点与刺猬猫的 App 会话检测，进入账号页时自动检查，也可手动重试；启动后检测到会话明确失效时提示重新登录。检测保留已有登录存储，不阻断书架与缓存阅读，网络异常或平台安全限制不会直接判为会话失效。[#43](https://github.com/moranfanhua/UniversalNovelReader/pull/43)
* 新增菠萝包安全验证入口，已登录账号可在账号设置或阅读加载失败时处理平台要求的人机验证；验证通过后可手动重试本章或滚动阅读的下一章。仅支持平台允许通过人机验证解除的限制，其他账号限制提示前往官方 App 处理。[#45](https://github.com/moranfanhua/UniversalNovelReader/pull/45)

### 改进 | Improved

* 优化菠萝包、番茄、起点与刺猬猫的书架更新检查，优先获取作品基本信息，仅在已有目录的作品发生更新时重新加载目录；新导入作品继续在首次打开时加载目录，保留已有缓存与阅读位置。[#41](https://github.com/moranfanhua/UniversalNovelReader/pull/41)
* 合并书架更新过程中的保存操作，并将书库索引编码移到后台、复用未变化的作品数据，减少大书库保存时的界面卡顿。[#41](https://github.com/moranfanhua/UniversalNovelReader/pull/41)
* 起点搜索结果与作品详情补充用于收藏人数排序的热度数据，以平台返回的推荐总数作为排序依据；补充查询失败时仍保留搜索结果。[#42](https://github.com/moranfanhua/UniversalNovelReader/pull/42)
* 书架切换、书架排序、阅读字体、显示模式和日志筛选等下拉选项统一从列表顶部展开，便于从头查找选项。[#40](https://github.com/moranfanhua/UniversalNovelReader/pull/40)

### 修复 | Fix

* 改善阅读字体加载与切换时的卡顿，复用已加载字体、合并重复加载，并在后台完成字体解压与校验；字体文件变化后重新校验，加载失败后可重试。[#40](https://github.com/moranfanhua/UniversalNovelReader/pull/40)
* 修复登录会话异常影响作品详情与目录获取的问题：菠萝包、番茄和起点使用不携带账号会话的 App 请求，刺猬猫使用独立游客会话，避免目录请求覆盖已有登录状态。[#41](https://github.com/moranfanhua/UniversalNovelReader/pull/41)

## v1.0.0

### 亮点

* 新增起点读书与刺猬猫阅读书源，并加快多个平台的章节缓存下载。

### 新增 | New

* 新增起点读书书源，支持搜索、通过作品 ID 或链接打开作品、查看目录及阅读免费章节；登录后可读取账号已有权限的 VIP 章节，支持手机号验证码登录。[#10](https://github.com/moranfanhua/UniversalNovelReader/pull/10)
* 新增刺猬猫阅读书源，支持搜索、在线阅读、章节缓存与导出；可使用账号密码、手机验证码或导入 App 会话登录，并导入平台书架中的作品。[#22](https://github.com/moranfanhua/UniversalNovelReader/pull/22)
* 新增刺猬猫段评，支持查看热门或最新评论、发表与回复评论，以及为评论和回复点赞。[#22](https://github.com/moranfanhua/UniversalNovelReader/pull/22)

### 改进 | Improved

* 章节缓存改用书源批量接口和受限并发，支持番茄、起点、刺猬猫与菠萝包；下载时显示进度，可停止任务并查看失败章节。[#19](https://github.com/moranfanhua/UniversalNovelReader/pull/19)、[#22](https://github.com/moranfanhua/UniversalNovelReader/pull/22)
* 刺猬猫作品导出为 EPUB 或 TXT 时加入作品来源链接。[#22](https://github.com/moranfanhua/UniversalNovelReader/pull/22)

### 修复 | Fix

* 修复手机书架宫格布局右侧留白，铺满可用宽度并保持每行三本。[#20](https://github.com/moranfanhua/UniversalNovelReader/pull/20)
* 修复段评输入时键盘弹出导致阅读正文重新分页的问题。[#21](https://github.com/moranfanhua/UniversalNovelReader/pull/21)

## v0.3.2

### 新增 | New

* 显示模式新增“跟随系统”，也可固定为日间或夜间模式；软件设置新增“外观”入口，与阅读设置及阅读器快捷切换共用同一偏好。新书库默认跟随系统，升级时保留原有日夜选择。[#17](https://github.com/moranfanhua/UniversalNovelReader/pull/17)
* 阅读设置支持将段评入口设为“固定右侧”或“跟随段尾”，适用于滚动、翻页和宽屏双页阅读；段尾空间不足时气泡另起一行，跨页长段仅在段尾显示跟随入口。[#16](https://github.com/moranfanhua/UniversalNovelReader/pull/16)

### 改进 | Improved

* 段评入口改为紧凑气泡，评论数显示在气泡内，超过 999 条显示为“999+”；固定右侧时对齐段落末行，计数更新不再挤动正文。[#16](https://github.com/moranfanhua/UniversalNovelReader/pull/16)
* 统一正文排版与分页测量，适配系统粗体、文字缩放及文字间距变化，改善页末文字与段评气泡的显示；插图段评保持完整入口并可点击。[#16](https://github.com/moranfanhua/UniversalNovelReader/pull/16)
* Android 状态栏与底部导航栏随当前日夜模式调整颜色和图标明暗，阅读器隐藏操作栏时也保持一致。[#17](https://github.com/moranfanhua/UniversalNovelReader/pull/17)

### 修复 | Fix

* 修复从番茄书架导入连载作品后，首次打开时报“番茄 App 未返回完整章节目录”的问题；按 App 返回的章节列表顺序加载普通连载目录，兼容可选目录字段缺失或为空的情况。[#15](https://github.com/moranfanhua/UniversalNovelReader/pull/15)
* 修复在 Windows 上构建 Android 包时，项目与 Pub 缓存位于不同盘符导致的 Kotlin 增量编译失败。[#17](https://github.com/moranfanhua/UniversalNovelReader/pull/17)

## v0.3.1

### 改进 | Improved

* 加快番茄与菠萝包书架导入：番茄批量获取作品信息，菠萝包优先复用收藏夹中的作品资料；先导入基本信息，首次打开作品时再加载目录。已有书库与最近阅读中的作品保留目录、缓存和阅读进度。[#12](https://github.com/moranfanhua/UniversalNovelReader/pull/12)
* 番茄作品详情与目录改用 App 接口获取，保留章节顺序、分卷、字数和权限标记。[#12](https://github.com/moranfanhua/UniversalNovelReader/pull/12)
* 更新 Windows 与 Android 应用图标，Android 支持自适应图标。

### 修复 | Fix

* 修复番茄作品存在多个书名时，搜索命中的作品因显示书名不同或收藏数较少而排序靠后的问题；保留番茄返回的结果顺序，并提示搜索结果可能显示同一作品的其他书名。[#11](https://github.com/moranfanhua/UniversalNovelReader/pull/11)
* 修复书架导入失败重试后作品顺序变化的问题，保持平台书架中的原有顺序。[#12](https://github.com/moranfanhua/UniversalNovelReader/pull/12)

### 其他 | Other

* 发布附件补充 archive 附带第三方代码的许可声明，Windows 压缩包同步包含 `LICENSE-other.md`。

## v0.3.0

### 亮点

* 新增番茄小说书源，支持搜索、正文阅读、离线缓存与段评互动。
* 支持导入平台书架、手动加入书架与最近阅读，提供列表 / 宫格切换及作品置顶。
* 新增本机运行日志，可筛选、复制和导出，便于反馈与排查问题。

### 新增 | New

* 接入番茄小说，支持通过作品 ID、作品链接或分享链接打开作品，查看详情与分卷目录，使用 App 接口读取正文，并可下载章节、离线阅读和导出 EPUB / TXT。
* 番茄段评支持段落评论数、热门 / 最新排序、分页查看及回复；登录后可发表评论、回复指定评论，并为主段评或回复点赞。
* 支持番茄手机号验证码登录、导入 App 会话及重新验证会话；认证使用官方 App 接口，验证后保存到本机安全存储。[#3](https://github.com/moranfanhua/UniversalNovelReader/pull/3)
* Android 新增菠萝包与番茄的本地 VPN 会话辅助，可在用户主动操作官方 App 后获取、验证并保存 App 会话。此功能需要官方 App 信任本机 CA，普通设备安装用户 CA 后仍可能不可用。
* 支持菠萝包与番茄聚合搜索，按书名或作者匹配相关性、收藏人数排序；可在搜索设置中选择参与搜索的平台，部分平台失败时保留其余平台的结果。
* 支持从已登录的菠萝包收藏夹或番茄书架导入作品，为导入的书架命名并切换查看；已有作品保留缓存与阅读进度。
* 作品详情和阅读页新增“加入书架”入口，浏览或阅读在线作品不再自动加入书架；“最近阅读”记录最近读过的 50 本作品。[#4](https://github.com/moranfanhua/UniversalNovelReader/pull/4)
* 新增运行日志页面，支持按认证日志、业务错误、日志级别与模块组合筛选，查看代码位置、复制单条 / 全部日志、导出及清空。日志仅保存在本机并自动轮换，不记录账号密码、会话或小说正文。[#5](https://github.com/moranfanhua/UniversalNovelReader/pull/5)

### 改进 | Improved

* 书架支持列表 / 宫格切换并保存选择，手机宫格每行显示 3 本；中文书名按无声调拼音排序，忽略英文大小写。
* 点击书架作品直接恢复上次阅读位置；长按可查看作品详情、置顶 / 取消置顶或从当前书架移除作品，移除时保留缓存与阅读进度。[#4](https://github.com/moranfanhua/UniversalNovelReader/pull/4)
* 作品详情与阅读页目录默认按分卷折叠，支持独立展开，保留全书章节序号，并显示当前阅读与已缓存标记。
* 阅读页默认收起操作栏，点击正文中央可展开或收起；显示全书累计页码，未缓存完整时以“约”标记估算总页数，不为统计页码自动下载全书。
* 新增默认开启的“显示段评”设置，可关闭阅读页段评入口与计数。
* 软件设置按书架、搜索、阅读、导入与日志分类进入独立页面；账号设置先选择平台，再选择对应的登录方式。
* 菠萝包免费与付费正文统一使用 App 接口，登录与会话验证移除网页登录入口及网页认证回退。旧网页会话保留原数据并提示重新登录，不清空本地书库。[#2](https://github.com/moranfanhua/UniversalNovelReader/pull/2)、[#3](https://github.com/moranfanhua/UniversalNovelReader/pull/3)

### 修复 | Fix

* 更新菠萝包 App 请求的版本与设备配置，修复请求配置不兼容导致的正文读取问题，并明确提示正文接口拒绝请求配置的情况。[#2](https://github.com/moranfanhua/UniversalNovelReader/pull/2)
* 修复从搜索结果、作品 ID 或链接重新打开已有作品后，书架与最近阅读仍保留旧目录的问题，保留既有缓存和阅读进度。
* 修复阅读栏“上一章”按钮跳到前一章末尾的问题，改为进入该章首页。
* 作品详情根据当前作品的实际阅读记录显示“开始阅读”或“继续阅读”，避免未读作品被误标为继续阅读。

[发布页面](https://github.com/moranfanhua/UniversalNovelReader/releases/tag/v0.3.0) · [完整变更](https://github.com/moranfanhua/UniversalNovelReader/compare/v0.2.0...v0.3.0)

## v0.2.0

首个发布版本，基于 Flutter 提供 Windows 与 Android 小说阅读器。

### 亮点

* 支持本地 EPUB / TXT 与菠萝包轻小说阅读，并可下载章节、离线阅读和导出。
* 提供滚动与翻页两种阅读方式，支持跨章节连续阅读和宽屏双页排版。
* 可查看菠萝包段评，登录后支持发表评论、回复和主段评点赞。

### 新增 | New

* 本地导入 EPUB / TXT，保留 EPUB 的封面、目录顺序与插图；TXT 支持 UTF-8 / UTF-16，以及手动选择 GBK 编码，并按章节标题拆分正文。
* 菠萝包作品支持按书名搜索、作品 ID 或链接添加、查看作品详情和刷新目录。免费章节无需登录；付费章节使用账号已有阅读权限。
* 支持菠萝包账号密码登录及 App 会话导入，验证后的会话保存在本机安全存储中，并可退出登录。
* 支持按章节范围下载正文、插图与封面，显示下载进度和失败章节，并可停止下载或重试。
* 已缓存章节可按原目录顺序导出 EPUB / TXT；缓存不完整时先确认导出范围，并将文件标记为“节选”。
* 保存阅读章节、段落及翻页模式下的页内位置，重新打开作品时继续阅读。
* 支持点击阅读区域两侧和键盘方向键翻页；Android 可启用音量键翻页。
* 支持夜间模式、字号、行间距及上下左右页边距调整，提供效果预览与恢复默认设置；可下载 Google Fonts 字体并离线使用。
* 书架支持按作品更新时间、名称或上次活跃时间排序，并保存排序选择。

### 改进 | Improved

* 滚动阅读在章末自动接续下一章正文；翻页阅读可跨章节继续，宽屏双页模式在章末衔接下一章首页。
* 宽屏阅读限制正文宽度并居中排版，翻页模式根据窗口宽度切换单页与双页布局。
* 段评展示真实头像、表情、点赞数与回复数，回复按时间从旧到新排列；支持点击主段评或已有回复进行回复，零赞段评也保留点赞入口。
* 在“我的”页面集中提供账号设置与软件设置入口，阅读页与软件设置共用阅读偏好。

### 修复 | Fix

* 修复正文空白及部分菠萝包正文解析问题，完善登录会话与章节权限提示。
* 修复 EPUB 封面丢失、SVG 插图及其相对图片资源的兼容问题；包含字体混淆资源的 EPUB 可正常导入正文，正文加密文件给出明确错误提示。
* 下载时一并缓存封面，避免离线导出 EPUB 时因封面未缓存而失败。
* 登录会话恢复失败时保留本地书库和缓存阅读能力，并提示重新登录。
* 规避 Windows 页面导航及阅读设置交互中的崩溃，修复阅读或下载返回后作品详情的缓存章节数未及时刷新。

[发布页面](https://github.com/moranfanhua/UniversalNovelReader/releases/tag/v0.2.0) · [完整提交记录](https://github.com/moranfanhua/UniversalNovelReader/commits/v0.2.0)
