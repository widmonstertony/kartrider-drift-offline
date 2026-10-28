# KartDrift Offline

从零编写的原生离线卡丁车游戏。独立创建的仓库，不是 fork，也不包含其他卡丁车项目的实现代码。游戏运行部分只依赖 C++ 标准库和平台 SDK。

**当前是可运行的早期原型，不是已经恢复的《跑跑卡丁车：漂移》。** 车辆、人物、赛道和音效暂用我们编写的程序化内容；原版美术、音效和赛道尚未导入，物理手感也没有验证到与原版一致。

## 已实现

- 固定 120 Hz 车辆模拟：加速、刹车、转向、侧滑、漂移集气、氮气、护栏和车辆碰撞。
- 竞速赛：玩家与 7 名 AI，三圈、名次、独立完赛时间。
- 道具赛：加速、火箭、香蕉、护盾、闪电、水弹；AI 会拾取和使用，道具有实际效果。
- 单人练习、救援、暂停、重开、模式选择、最佳成绩的本地保存。
- 自研共享场景生成与追尾摄像机，Apple Metal 和 Android OpenGL ES 3 渲染。
- 原生键盘/触屏界面，临时引擎、漂移和事件合成音效。

## 验证状态

| 项目 | 状态 |
| --- | --- |
| 核心测试 | 三个随机种子的竞速/道具赛均 8/8 完赛；AI 漂移集气、氮气、道具命中和护盾检查通过 |
| Apple Silicon Mac | 已打开原生 3D 应用，观察到三圈道具赛完成 |
| iOS | 已在授权 iPadOS 16.1 设备安装、启动并渲染行驶场景；完整比赛与触控检查继续进行 |
| iPhone | 已构建 iPhone/iPad arm64 包，尚未在 iPhone 真机验证 |
| Android | 原生 arm64 APK 已编译并通过 v2/v3 签名校验，尚无 Android 真机运行证据 |
| 原版内容/手感 | 尚未完成，原版保留文件不进入公开仓库 |

`自动测试` 会让玩家车辆也交给 AI，用于验证比赛流程，不能替代手动驾驶验收。

## 构建

Mac 需要 Xcode、CMake、Ninja：

```sh
sh scripts/build_apple.sh mac
open build/mac/KartDriftOffline.app
```

左右方向键或 A/D 转向，空格漂移，Shift 或 K 使用氮气/道具，下方向键或 S 刹车，R 救援，P 暂停，1/2/3 切换模式，T 切换自动测试。自动加速已开启。

iOS：

```sh
sh scripts/build_apple.sh ios
```

输出 `build/KartDriftOffline-ios.ipa`。脚本中的 ad-hoc 签名仅用于允许这种安装方式的授权开发设备。普通 iPhone 需要 Apple 开发签名和 provisioning；可以生成 Xcode 项目后选择自己的开发团队和设备：

```sh
cmake -S . -B build/xcode-ios -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
open build/xcode-ios/KartDriftOffline.xcodeproj
```

触屏横屏操作：左侧转向/刹车，右侧漂移和氮气/道具，上方切换模式。

Android 需要官方 NDK、SDK build-tools、平台 `android.jar` 和 JDK 17。脚本直接调用官方编译工具：

```sh
python3 scripts/build_android.py \
  --ndk /path/to/android-ndk \
  --java-home /path/to/jdk/Contents/Home \
  --build-tools /path/to/android-sdk/build-tools/35.0.1 \
  --android-jar /path/to/android-sdk/platforms/android-35/android.jar
```

输出 `build/android/KartDriftOffline-android.apk`，开发密钥仅保存在本机构建目录。使用系统 Activity、GLSurfaceView、控件和共享 C++ 模拟；清单没有申请网络权限。

## 代码

| 路径 | 内容 |
| --- | --- |
| `core/Game.*` | 车辆物理、赛道中心线、AI、圈数、排名、碰撞和道具 |
| `core/Scene.*` | 自建场景几何和摄像机数学 |
| `core/Audio.*` | 临时音频合成，不含原版录音 |
| `platform/apple/` | AppKit/UIKit、Metal、AudioQueue、输入和保存 |
| `platform/android/` | Android 界面、JNI、GLES、AAudio |
| `scripts/` | 构建与打包 |
| `tests/race_test.cpp` | 完整比赛与交互机制集成检查 |
| `tools/` | 早期客户端保存/分析实验，不参与游戏编译或运行 |

Apple 开发版在本机 Documents 下写入 `kartdrift-last-race.json`，便于核实实际运行，不上传服务器。开发深链 `kartdriftoffline://race?mode=speed&autopilot=1` 开始自动比赛，`mode=item` 或 `practice` 选择其他模式。`kartdriftoffline://input?steer=0.5&drift=1` 可测试输入通路。

## 后续验收

以 iOS 真机手动驾驶、漂移、完整竞速赛和道具赛为首要验收，再核实 Mac 和 Android。继续接入单独保留的原版内容并校准手感；完成当前目标后，再研究 2004 年原版《跑跑卡丁车》的移植。训练场或启动画面不能代替这些目标。见 [requirements.json](requirements.json)。

## 保存研究与许可

`tools/` 是此前对 2.71.1 客户端的资源检查和独立诊断副本实验，不是本游戏的运行依赖。原客户端诊断副本仍受停服启动流程阻挡。可选 Python 分析依赖见 `requirements.txt`；版本资料来自[公开客户端保存资料](https://clientlover.tistory.com/13)，第三方解压工具没有包含或链接进游戏。

我们编写的代码使用 MIT 许可。原版客户端、模型、贴图、音乐、PAK、着色器、SDK、执行页和反汇编输出不随仓库发布，不适用本仓库的 MIT 许可。临时程序化内容由本项目源码生成。游戏名称与原版内容的权利属于各自权利人。
