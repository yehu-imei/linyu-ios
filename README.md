# 🚿 淋浴 · LinYu iOS

趣智校园第三方 iOS 客户端，使用 SwiftUI + CoreBluetooth 开发，功能、文案和交互尽量与 [Android 端](https://github.com/yehu-imei/linyu) 一致

**当前版本：3.1.1（构建 19）** · 主应用 iOS 16+ · 桌面小组件 iOS 17+

## 下载与安装

- [GitHub 下载 IPA](https://github.com/yehu-imei/linyu-ios/releases/tag/v3.1.1)
- [Gitee 镜像与发行](https://gitee.com/yehu-imei/linyu-ios/releases)
- [Android 原仓库：APK / IPA](https://github.com/yehu-imei/linyu/releases/tag/v3.1.1)
- [作者的 iOS 自签安装教程](https://github.com/yehu-imei/Guides/blob/main/Tutorial/.ipa%E7%9A%84%E5%AE%89%E8%A3%85.md)

两个 GitHub 仓库提供同一份 IPA，可用发行附件的 SHA-256 校验文件核对。IPA 不含可直接安装的开发者证书，需自行签名；更新时尽量沿用同一签名身份，提前备份重要数据

如需桌面小组件，请通过 SideStore 等工具将淋浴作为独立 App 安装，并保留 LinYuWidgets 扩展及 App Group 共享权限。导入 LiveContainer 是容器运行方式，不等同于独立安装，不保证相同的系统通知和小组件能力。教程包含两种方式的说明，请按实际需求选择

## 功能

- 短信 / 密码登录、登录态保存、个人信息与账户管理
- 附近设备扫描、扫码选设备、绑定寝室
- 云端热水器及兼容 BLE 水表的开关水、订单恢复、结算与补结算
- 钱包余额、账单明细、近七天 / 本月消费趋势、未支付账单处理
- 使用码领取与次数限制、卡片排序和跨页面移动
- 主页 / 使用页独立背景、主题配色、中文提示、日志导出
- 系统通知、版本检查、精简更新日志与安装教程入口
- 小型（2×2）设备卡片和中型（2×4）多页小组件，展示设备、上次消费、附近设备和账单

小组件开关会打开 App，由主应用核对账户、目标设备及订单后执行；附近设备和账单入口跳转对应页面。尺寸由 iOS 系统决定，无 Android 1×1 尺寸。切页与刷新由 WidgetKit 调度，不保证即时刷新

## 3.1.1 修复重点

- 蓝牙结算区分“服务器已记账”和“设备记录已清除”，清理未确认时保留消费金额，不上报订单作废
- 整理小组件前台操作交接、页面导航及共享数据更新，减少入口重复处理
- 对齐使用码、账户卡片、背景、通知和扫码权限反馈
- 更新日志独立读取文档，支持本地缓存与联网刷新

[用户精简日志](docs/APP_CHANGELOG.md) · [详细更新记录](CHANGELOG.md) · [发布与验收说明](docs/RELEASE_3.1.1.md)

两端应用内更新日志的远程来源统一为 Android 仓库 master 分支的 docs/APP_CHANGELOG.md，联网取得有效文档后替换本地缓存，失败时保留已有内容。版本检查读取 Android 原仓库的正式 Release，因此该仓库也附带 IPA

## 能力边界

| 项目 | 当前实现 |
| --- | --- |
| 后台监控 | 不提供 Android 式常驻服务，不保证退到后台或被系统终止后仍自动关水 |
| 使用中通知 | 静态状态提示，不提供实时计时或通知内关水按钮 |
| 消费金额 | 以结束后的结算和账单为准；MQTT 仅有订单结束事件，不是使用中实时扣费，连接不可用时走 HTTP 对账 |
| 蓝牙设备 | 需真机、蓝牙权限及足够近的距离；不同学校设备兼容性仍需分别验证 |
| 小组件 | 需要保留扩展和共享权限；缓存展示不代表设备当前状态，执行前会再次核对 |
| 安装更新 | IPA 需要自行签名、按签名工具要求续签，不是 App Store 自动安装 |

请确认关水结果后离开设备。构建、模拟器截图与自动化测试通过，不代表已完成所有学校设备的实测

## 构建

GitHub Actions 在推送 main 或手动触发时执行：Swift 回归检查 → XcodeGen → Archive → 模拟器小组件截图 → IPA 校验打包。Artifacts 中的 LinYu-unsigned-ipa 是临时构建产物，正式安装包请从 Releases 下载

构建不上传开发者证书。打包时仅附加 ad-hoc 签名以保留扩展共享权限声明，安装仍需重新签名。主应用与小组件版本必须一致

macOS 本地构建：

```bash
brew install xcodegen
xcodegen generate
open LinYu.xcodeproj
```

project.yml 是工程配置来源，LinYu.xcodeproj 和 Info.plist 由 XcodeGen 生成。Windows 可编辑代码，但 Swift / iOS 编译验证在 macOS 或 Actions 上完成

## 源码与文档

| 目录 | 内容 |
| --- | --- |
| LinYu/ | SwiftUI 页面、网络、云端与 BLE 水控、结算和持久化 |
| WidgetShared/ | 主应用与小组件共享快照、身份与操作模型 |
| WidgetExtension/ | WidgetKit 小组件 |
| Tests/ | 不连接真实账户或水表的回归测试 |
| docs/ | 用户日志、发布说明和按日期保留的开发记录 |
| .github/workflows/ios.yml | 回归、构建与打包工作流 |

早期对齐清单和按日期命名的修复记录是当时的开发快照，不代表当前能力；以本 README、当前源码及最新发行说明为准

Android：[GitHub](https://github.com/yehu-imei/linyu) · [Gitee](https://gitee.com/yehu-imei/linyu)

iOS：[GitHub](https://github.com/yehu-imei/linyu-ios) · [Gitee](https://gitee.com/yehu-imei/linyu-ios)

## 许可证

[MIT](https://github.com/yehu-imei/linyu/blob/master/LICENSE)，沿用原项目许可证；本项目与官方趣智校园无隶属关系
