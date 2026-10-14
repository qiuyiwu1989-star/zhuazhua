# 版本与发布

`VERSION` 是应用版本及构建号的唯一来源。采用 SemVer；预览阶段使用 0.x.y，构建号每次发布递增。标签为 v版本号，已发布标签和同名安装包不可覆盖。

1. 更新 VERSION、CHANGELOG.md，运行 swift test；确认没有凭据或个人数据入库。
2. 提交源码后运行 `APP_OUTPUT=build/distribution/ZhuaZhua.app SIGN_IDENTITY=- scripts/build-app.sh release`。
3. 使用 ditto 打包应用为 ZhuaZhua-版本号-macOS.zip，生成 SHA256SUMS.txt；检查 Info.plist、通用架构与签名。
4. 推送提交与对应标签，创建 GitHub 预发布并上传 ZIP 和校验文件。
5. 官网链接同一版本文件，保留旧版；核对公网下载 SHA-256。

应用 Info.plist 记录版本、构建号和源码修订。发布说明必须区分自动化检查与真实业务验收。回退时下载历史 Release，不覆盖版本号。安装不携带用户数据和设备令牌，升级保留原 Bundle ID。
