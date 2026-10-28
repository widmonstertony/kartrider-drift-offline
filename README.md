# KartDrift Offline

《跑跑卡丁车：漂移》原版客户端的离线保存与运行研究。这是独立建立的项目，目标是让保留下来的客户端在本地运行。

**目前仍在研究阶段，没有可玩的离线版本，也没有可下载的游戏安装包。** 已完成的工作是客户端与资源检查、独立 iOS 测试副本制作和真机启动诊断。测试副本目前仍会显示服务器主机名错误（80099）。成功安装、显示启动画面或找到地图文件，都不代表离线玩法已经完成。

## 目标

- 优先实现 iOS，并推进 Apple Silicon macOS 和 Android，共三个平台。
- 原版客户端中能够本地驾驶、漂移和单人练习。
- 离线竞速赛：玩家与多名能正常行驶的 AI 一起完成比赛。
- 离线道具赛：玩家与多名 AI 比赛，道具能够正常使用。
- 保留原安装与缓存，以独立副本进行实验。

训练场和教程只是中间步骤，不能代替竞速赛和道具赛的验收。机器可读要求见 [requirements.json](requirements.json)。

## 已确认的结果

- 研究客户端版本为 2.71.1。
- 保留的 iOS 缓存内有训练场、教程、其他赛道以及配套 Metal 着色器。
- 已验证这批客户端 PAK 的索引解密和 SHA-1 校验；目录清单中的流式子关卡不能按独立赛道计数。
- 驾照任务数据中包含车辆配置、AI 生成配置及 AI 行驶数据。
- 发行版的 `Dev_OpenLicense` 实现为空，不能把它当作可用入口。
- 原版逻辑中存在 `?License=L00` 等任务选项；当前还没有通过这些选项验证可玩的离线比赛。

## 代码

| 文件 | 用途 |
| --- | --- |
| `tools/pak_archive.py` | 只读 PAK 索引校验、文件读取与命令行检查 |
| `tools/list_ios_pak_maps.c` | 在 iOS 上只读列出 PAK 内的地图包 |
| `tools/inspect_client.py` | Android 包身份、证书、原生符号和资源检查 |
| `tools/disasm_android.py` | 解析本地 Android 原生函数及调用目标 |
| `tools/disasm_ios.py`、`tools/ios_xrefs.py` | 解析本地 iOS 函数边界和字符串引用 |
| `tools/read_kartdrift_task.c` | 从正在运行的自有客户端读取保留所需的执行页 |
| `tools/rebuild_ios_binary.py` | 用读取的执行页重建本地分析副本 |
| `tools/offline_probe.m` | 测试副本启动诊断库 |
| `tools/prepare_ios_probe.py` | 准备独立标识的本地诊断补丁 |
| `tools/build_device_ipa.py` | 在自有设备缓存中组合测试安装包 |
| `tools/ios_mcp.py` | 调用用户自己的 iOS MCP 服务，连接信息仅保存在本地 |

## 本地使用

Python 3.11 或更新版本：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python tools/pak_archive.py /path/to/pakchunk0-ios.pak
.venv/bin/python tools/pak_archive.py /path/to/pakchunk0-ios.pak --list
```

PAK 读取器目前支持未压缩和 Zlib 数据。Oodle 数据还需要自行准备兼容的 `tools/ooz-decode` 命令行解码器，其接口是：第一个参数为预期输出字节数，从标准输入读压缩数据，向标准输出写解压数据。可参考 [ooz 上游](https://github.com/rarten/ooz)；上游代码没有包含在本仓库中。

iOS 诊断需要 Xcode 的 iPhoneOS SDK、`ldid`，以及允许运行这些调试工具的自有设备环境。**尚未提供普通未越狱 iPhone 的安装方案。** 示例编译命令：

```sh
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -O2 \
  -o tools/read_kartdrift_task tools/read_kartdrift_task.c
ldid -Stools/read_task.entitlements.plist tools/read_kartdrift_task
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 -O2 \
  -fobjc-arc -dynamiclib -framework Foundation -framework UIKit \
  -install_name @rpath/OfflineProbe.dylib \
  -o tools/OfflineProbe.dylib tools/offline_probe.m
ldid -S tools/OfflineProbe.dylib
```

MCP 连接地址由本地环境变量配置；会话信息、设备路径和输出报告不会提交：

```sh
export IOS_MCP_URL=http://YOUR_DEVICE:PORT
python3 tools/ios_mcp.py describe_screen '{}'
python3 tools/build_device_ipa.py --help
```

`prepare_ios_probe.py` 的输入均来自本地保存的客户端：

```text
runtime/ios-original/KartDrift.app/
analysis/ios-Info.plist
analysis/KartDrift-ios-decrypted
tools/OfflineProbe.dylib
```

补丁输出到 `runtime/ios-probe-patch.zip`。它是实验性的诊断补丁，不是已经完成的离线游戏补丁。当前版本的固定函数地址与布局仅适用于正在研究的版本，不能直接用于其他版本。

## 内容与许可

本仓库只发布我们编写的研究、构建和诊断代码，采用 MIT 许可。游戏客户端、可执行文件、PAK、着色器、音乐、模型、贴图、SDK 二进制和原始反汇编输出均不随代码发布，也不受本仓库的 MIT 许可覆盖。游戏名称和原版内容的权利属于其各自权利人。

PAK 索引读取中使用的版本密钥来自已有的[公开客户端保存资料](https://clientlover.tistory.com/13)。第三方工具和依赖分别遵循其自身许可。
