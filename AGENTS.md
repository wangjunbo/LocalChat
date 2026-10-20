# LocalChat 鸿蒙邻聊

- 修改范围是此 ArkTS / ArkUI Stage 工程；Mac 协议参考 `/Users/sunshine/SwiftProjects/local-chat`，不要随意修改 Mac 项目。
- 保留包名和用户签名配置。当前最低 SDK 为 6.1.1（API 24），更改兼容范围需有明确需求。
- 应用名称使用“邻聊”，图标与 Mac 版本同源。界面装饰圆角克制，返回使用系统图标并处理系统返回。
- 交付更新版本，AppScope/app.json5 与 Models.ets 的 APP_VERSION 保持一致；版本不得包含数字 4。版本号在首页底部设置图标左侧同行显示，不另起一行。
- 构建 `./scripts/build.sh`；核心及原始 Mac TCP 互通测试 `node scripts/test-core.cjs`（推荐 DevEco 自带 Node）。
- 区分 ArkTS 编译、Node 平台适配器验证和鸿蒙真机测试。未连接设备时不得声称系统 mDNS、粘贴、UI 或设备安装已验证。
- 未经明确要求，不安装设备、不提交 Git、不上传或发布；测试不要接入正常客户端会话。
