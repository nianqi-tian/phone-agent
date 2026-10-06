# ESP32 固件

使用 **ESP-IDF 5.5.4**，通过 NimBLE 提供组合鼠标／键盘 HID 和自定义控制服务。ESP32-C3 与 ESP32-S3 均使用 BLE。项目默认配置按 4 MB Flash 开发板准备。

## 编译

先进入已启用 ESP-IDF 的终端，再从仓库根目录执行：

```sh
bash scripts/build-firmware.sh esp32s3
bash scripts/build-firmware.sh esp32c3
```

每种芯片使用独立的 `firmware/build-esp32s3` / `firmware/build-esp32c3` 构建目录和生成配置；共享配置来自 `sdkconfig.defaults`，目标配置来自 `sdkconfig.defaults.<芯片>`。首次构建设置芯片目标，之后可增量编译。

## 烧录

先确认实际开发板芯片和串口。S3 示例：

```sh
cd firmware
idf.py -B build-esp32s3 -D SDKCONFIG=sdkconfig.esp32s3 \
  '-D' 'SDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.defaults.esp32s3' \
  -p YOUR_PORT flash monitor
```

C3 将命令里的 `esp32s3` 替换为 `esp32c3`。生成的固件目录内包含分区表、bootloader 和应用镜像；两个芯片的镜像不能混用。

已有设备更新前核对分区表；保持相同布局时，可使用 ESP-IDF 的 `app-flash` 只更新应用分区。擦除 NVS 会清除设备配对资料，需重新配对。仓库不包含设备 NVS、配对备份或本机生成镜像。

## RGB 状态灯

ESP32-S3 配置默认驱动 GPIO48 的一个 WS2812（GRB），峰值亮度 48/255；可通过 `idf.py menuconfig` 的 AgentMouse 配置修改。

| 状态 | 灯效 |
| --- | --- |
| 未连接 BLE | 蓝色呼吸 |
| 已连接、空闲 | 白色呼吸 |
| 执行任务 | 彩虹循环 |
| 失败 | 红色呼吸 |
| 完成 | 绿色呼吸 |

App 发送任务状态和心跳；运行状态失去心跳后会进入失败提示。C3 默认不启用此 S3 GPIO48 灯效。

## 控制协议

协议定义分别位于 `Shared/MouseProtocol.swift` 与 `firmware/main/main.c`。鼠标报告支持相对移动、按钮和滚轮；键盘报告支持 ASCII 与修饰键快捷键。固件的鼠标轨迹在设备侧按固定节奏输出，App 等待对应序列的完成状态后再点击。

键盘不等同于任意 Unicode 文本注入，中文输入依赖手机输入法或 App 现有输入路径。指针校准属于 iPhone 设置与配件组合；更改速度、方向、设备或运动参数后需重新校准。
