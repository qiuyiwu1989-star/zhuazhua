<p align="center"><img src="assets/brand/app-icon.png" width="128" alt="爪爪图标"></p>
<h1 align="center">爪爪 · ZhuaZhua</h1>
<p align="center">把看到的资料抓住，把图片里的文字找回来。</p>

原生 macOS 截图收集与本地 OCR 检索工具。Swift、SwiftUI、AppKit 和 Apple Vision，无第三方 Swift 包依赖。

## 已实现

- 屏幕顶部截图收纳栏，点击或下拉打开整理抽屉。
- 顶部「＋ 拖入图片」支持图片文件和图片数据拖入；点击可粘贴剪贴板图片或选择文件。浏览器若仅提供 URL，请先使用“复制图片”。
- 本地保存独立图片副本，后台识别简体中文、繁体中文和英文。
- 搜索图片文字、文件名、备注与标签；显示命中文字片段。
- 顶部图片单击复制、双击或右上角放大镜打开苹果原生 Quick Look；左右键翻图，空格/Esc 关闭。
- 大图连续预览、备注编辑、批量标签、标签去重与一次撤销。
- 自定义截图、收纳栏、搜索及设置快捷键。

## 开发运行

需要 macOS 14+、Swift 工具链与 Command Line Tools。

```sh
swift test
SIGN_IDENTITY=- scripts/build-app.sh debug
open build/ZhuaZhua.app
```

构建脚本产出 Apple silicon / Intel 通用应用。当前没有经 Developer ID 签名、公证的发行包；当前为 0.2.0 (7) 预览版；[下载](https://qiuyiwu.com/downloads/zhuazhua/) · [更新记录](CHANGELOG.md) · [版本发布规范](docs/RELEASING.md)。

## 数据与联网

图片和 OCR 在本机处理，默认不上传。历史兼容目录为 `~/Library/Application Support/QiuyiwuCapture/`，截图收件目录为 `~/Library/Application Support/Tendedero/Screenshots/`。保留现有 Bundle ID `com.qiuyiwu.capture`，以延续用户设置。

目前保留一个面向 `qiuyiwu.com` 的实验性网站适配：需主动登录、选择工作区并上传，自动上传默认关闭。它不是通用云服务，不附带网站后台、账号或云密钥。图片 COS 与数据库同步已接入兼容服务。不要把任何凭据提交到仓库。

## 边界与后续

OCR 可能有错字；大量图库性能和跨屏快捷键仍需更多验证。后续计划包括来源网址、缩略图缓存、可配置的云端同步。

## 来源与许可

本项目基于 [Alejandro Buján 的 Tendedero](https://github.com/alejandrobujan/tendedero)，上游源码快照见 `SOURCE-SNAPSHOT.json`。保留上游 MIT 版权与许可；本项目与上游作者不存在背书关系。

爪爪采用独立名称与新图标，不分发上游受保留的图标作品。新增代码及 `assets/brand/` 中的爪爪图形同样以 MIT 许可提供。内部 Swift target 名称暂保留 Tendedero 以兼容现有测试和构建。

### 时间与顶部排列

顶部保留图片原始比例、顶边对齐，采用连续排列，添加入口收进下方工具栏，保留横向滚动，展示当前屏幕容纳的最近图片；完整记录从“搜索与整理”查看。抽屉支持按本机日历日期筛选收集或整理记录。收集时间沿用首次入库时间；整理时间从本版本开始，在实际修改备注或标签时追加，OCR 不算人工整理，历史缺失时间不推断。

顶部历史滑动：启用最近 100 张收纳，按收集时间排列；触控板横向滑动、鼠标滚轮或“更早 / 更新”按钮查看。下方导入入口固定，超过收纳上限的完整记录仍可在整理抽屉搜索。

### 知行档案收件箱

已连接设备可在“网站与工作区”中开启自动同步，或在图片整理面板勾选图片后点“同步到知行档案”。原图存入私有 COS，OCR、备注、标签和采集时间进入知行档案；卡片显示“已入档”。本地原件保留，失败可重试；字节完全相同的图片不会重复入库。

这一连接需要自行部署的兼容服务和设备凭据，并非安装公开应用后自动获得作者的私人资料库访问权限。客户端仅持有采集接口的设备令牌，COS 密钥只放在服务端。当前支持 PNG/JPEG/GIF/WebP/TIFF 图片，单张上限 64 MB。

`swift test` 默认不访问线上资料库。`ZHUA_LIVE_SYNC=1 swift test --filter VaultLiveTests` 是显式生产联调，会将当前用户本地采集库同步到已配置的收件箱，只能在确认目标和范围后使用，运行时应退出桌面应用以免并发写本地账本。
