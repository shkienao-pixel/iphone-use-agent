# ESP32-S3 固件

项目仅支持 **ESP32-S3**，使用 **ESP-IDF 5.5.4** 和 NimBLE，提供组合鼠标／键盘 HID、自定义控制服务及 GPIO48 RGB 状态灯。默认配置按 4 MB Flash 开发板准备。

## 编译

先进入已启用 ESP-IDF 的终端，再从仓库根目录执行：

```sh
bash scripts/build-firmware.sh
```

构建目标固定为 `esp32s3`。配置集中在 `firmware/sdkconfig.defaults`，生成配置为 `firmware/sdkconfig.esp32s3`，产物位于 `firmware/build-esp32s3`。脚本仍接受可选参数 `esp32s3`；其他芯片目标会被拒绝。首次构建设置目标，之后可增量编译。

### XIAO ESP32-S3

真机测试使用 Seeed Studio XIAO ESP32-S3 的 8 MB Flash 配置，关闭 GPIO48 RGB 与 PSRAM，并启用原生 USB Serial/JTAG 控制台。仓库保留通用开发板默认值，另提供 `sdkconfig.defaults.xiao-esp32s3` 作为覆盖配置。已启用 ESP-IDF 的终端中，从仓库根目录执行：

```sh
cd firmware
idf.py -B build-xiao -D SDKCONFIG=sdkconfig.xiao-esp32s3 \
  -D 'SDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.defaults.xiao-esp32s3' \
  set-target esp32s3
idf.py -B build-xiao -D SDKCONFIG=sdkconfig.xiao-esp32s3 \
  -D 'SDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.defaults.xiao-esp32s3' \
  build
```

`set-target` 只需在首次构建时执行。XIAO 使用单独的 `build-xiao` 与生成配置文件，避免复用通用板的已有构建配置。这里提供的是可复现的板型参数，不含设备身份、配对资料或本机生成产物。

## 烧录

确认开发板为 ESP32-S3，替换实际串口：

```sh
cd firmware
idf.py -B build-esp32s3 -D SDKCONFIG=sdkconfig.esp32s3 \
  -D SDKCONFIG_DEFAULTS=sdkconfig.defaults \
  -p YOUR_PORT flash monitor
```

若使用上面的 XIAO 配置，在 `firmware` 目录中改用：

```sh
idf.py -B build-xiao -D SDKCONFIG=sdkconfig.xiao-esp32s3 \
  -D 'SDKCONFIG_DEFAULTS=sdkconfig.defaults;sdkconfig.defaults.xiao-esp32s3' \
  -p YOUR_PORT flash monitor
```

构建目录包含 bootloader、分区表和应用镜像。保持相同分区布局时，可使用 ESP-IDF 的 `app-flash` 更新应用分区。擦除 NVS 会清除配对资料，需重新配对。仓库不包含设备 NVS、配对备份或本机生成镜像。

## RGB 状态灯

默认驱动 GPIO48 的一个 WS2812（GRB），峰值亮度 48/255；可通过 `idf.py menuconfig` 的 AgentMouse 配置修改。

| 状态 | 灯效 |
| --- | --- |
| 未连接 BLE | 蓝色呼吸 |
| 已连接、空闲 | 白色呼吸 |
| 执行任务 | 彩虹循环 |
| 失败 | 红色呼吸 |
| 完成 | 绿色呼吸 |

App 发送任务状态和心跳；运行状态失去心跳后会进入失败提示。关闭 RGB 配置时，鼠标和键盘仍可使用。

## 控制协议

蓝牙名称固定为 `AgentMouse-S3`。协议定义位于 `Shared/MouseProtocol.swift` 与 `firmware/main/main.c`。鼠标报告支持相对移动、按钮和滚轮；键盘报告支持 ASCII 与修饰键快捷键。鼠标轨迹在设备侧按固定节奏输出，App 等待对应序列完成后再点击。

键盘的中文输入依赖手机输入法或 App 现有输入路径。指针校准属于 iPhone 设置与配件组合；更改速度、方向、设备或运动参数后需重新校准。
