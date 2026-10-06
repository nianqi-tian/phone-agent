# 验证说明

## 离线检查

```sh
bash scripts/check.sh
```

入口运行现有协议／动作／键盘／校准检查，以及生产引擎的产品状态检查。临时可执行文件和 Swift 模块缓存位于自动清理的临时目录；不使用真实模型、设备或 BLE。

有编译后的 App 时：

```sh
bash scripts/check.sh build/ios/Build/Products/Debug-iphonesimulator/PhoneAgent.app
```

额外检查内置手机操控 Skill 和 Apple 帮助资源能否从 App 包读取。`Tests/ProductState/README.md` 说明状态检查的详细范围与限制。

## App 编译

```sh
xcodebuild -project PhoneAgent.xcodeproj -scheme PhoneAgent \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO build
```

编译成功只确认源码与资源打包，不代表真机权限、Siri、BLE/HID、跨 App 执行或后台行为已通过验证。Build 67 的侧栏文案曾在模拟器的两种模式确认，底部均显示“新建”。

## 初次仓库整理（结构重构前）

生产 Swift/C 源码取自 Build 67；导出的 Xcode 工程清除开发者 Team，生成文件和私人配置被排除。主项目包中的历史说明与旧固件镜像保留在原工作目录，未加入源码仓库。

2026-10-06 在整理后的目录执行：

| 检查 | 结果 |
| --- | --- |
| Xcode 27 Debug / 通用 iOS 模拟器编译，无签名 | 通过 |
| 协议、动作、键盘和校准 | 39 项通过 |
| 生产引擎产品状态 | 74 项通过 |
| 编译后 App 的 Skill 资源 | 14 项通过 |
| ESP-IDF 5.5.4 / ESP32-S3，GPIO48 RGB | 编译通过 |
| 文档本地链接、工程 plist 和 shell 语法 | 通过 |
| 常见密钥格式和本机绝对路径检查 | 未发现匹配 |

以上共 127 项已有离线检查；本次整理不涉及真机安装、固件烧录或真实模型调用。

## GestaltEdit 结构参考

2026-10-06：App 源码目录改为 `PhoneAgent/`，拆出页面、服务、Store、外观和 Debug 预览，工程改为 Xcode 同步文件夹。已有离线检查入口已同步源码路径；本次未重新运行测试。上表的 127 项结果属于结构重构前。Xcode 27 的 Debug 与 Release 通用 iOS 模拟器无签名编译均通过，构建日志未出现警告或错误；打包目录保留两套内置 Skill 及引用资源。此结果仅确认编译和打包。

## 仅 ESP32-S3

2026-10-06：固件目标固定为 ESP32-S3，配置合并为 `firmware/sdkconfig.defaults`，构建脚本使用固定目标。清理旧芯片配置、镜像、构建目录和混合源码压缩包。ESP-IDF 5.5.4 编译通过；应用镜像大小 `0x7e5b0`，可放入默认的 `0x100000` 应用分区。此更改未新增或运行测试，也未烧录设备。
