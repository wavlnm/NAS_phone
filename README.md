# NAS_phone

loal_NAS 的 Flutter 手机端仓库。

当前已完成的最小骨架：

- Android / iOS / Windows Flutter 工程已初始化
- 保留宿主地址输入框
- 可连接宿主并自动登录 FileBrowser
- 可展示文件列表
- 可在列表中显示图片缩略图
- 可进入目录、返回上级目录
- 可点击图片文件进行在线预览
- 可点击音频文件在线播放，支持播放、暂停和拖动进度
- 可点击视频文件，向宿主申请短时中转链接后在浏览器中播放
- 可上传文件
- 可新建文件夹
- 可重命名文件或目录
- 可把文件或目录移动到指定远端目录
- 可下载单个文件，也可递归下载整个文件夹到本地同名目录
- 可删除文件或目录（删除进入回收站，可从回收站恢复）

## 当前最容易跑起来的方式

这台机器当前最容易直接看到效果的方式，不是安卓真机，而是 Windows 桌面预览。

原因：

- 当前项目已经补了 Windows 平台
- 当前机器已经能跑 Flutter Windows 桌面程序
- Android 真机运行仍然依赖 Android SDK

先启动 loal_NAS 宿主：

```powershell
Set-Location "<你的 loal_NAS 仓库目录>"
dotnet run --project src/LoalNas.Host
```

这台机器当前仓库路径示例：

```powershell
Set-Location "C:\Users\windy\Desktop\github_project\loal_NAS"
dotnet run --project src/LoalNas.Host
```

再启动 NAS_phone：

如果 `flutter` 已经在 PATH 里：

```powershell
Set-Location "<你的 NAS_phone 仓库目录>"
flutter run -d windows
```

这台机器当前仓库路径示例：

```powershell
Set-Location "C:\Users\windy\Desktop\github_project\NAS_phone"
flutter run -d windows
```

如果运行时出现下面这个报错：

```text
Error: Building with plugins requires symlink support.
```

说明这台 Windows 机器还没有开启开发者模式。先执行：

```powershell
start ms-settings:developers
```

然后在系统设置里打开 **Developer Mode**，再重新运行 `flutter run -d windows`。

如果 `flutter` 还没加到 PATH，直接把命令里的 `flutter` 换成你本机 Flutter SDK 里的 `flutter.bat` 绝对路径，例如：

```powershell
Set-Location "<你的 NAS_phone 仓库目录>"
& "<你的 Flutter SDK 目录>\bin\flutter.bat" run -d windows
```

这台机器当前 Flutter SDK 路径示例：

```powershell
Set-Location "C:\Users\windy\Desktop\github_project\NAS_phone"
& "C:\Users\windy\flutter\bin\flutter.bat" run -d windows
```

程序启动后，在地址输入框里先填：

- http://127.0.0.1:5034

这样可以直接在本机预览“连接宿主、文件列表、上传、下载、移动、重命名、删除”的效果。
## 构建 Android APK

**环境要求：**

- Flutter SDK（已加到 PATH，或使用绝对路径调用）
- JDK 17（设置 `JAVA_HOME`）
- Android SDK（设置 `ANDROID_HOME`，包含 `build-tools` 和 `platform-tools`）

**构建 release APK：**

```powershell
$env:JAVA_HOME = "C:\Users\windy\jdk-17"
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
cd "C:\Users\windy\Desktop\github_project\NAS_phone"
flutter build apk --release
```

输出文件：`build\app\outputs\flutter-apk\app-release.apk`

**构建 debug APK（不混淆，便于排查问题）：**

```powershell
flutter build apk --debug
```

输出文件：`build\app\outputs\flutter-apk\app-debug.apk`

构建完成后，将 APK 文件传到手机直接安装即可（需在手机设置中允许安装未知来源应用）。
## 安卓真机怎么运行

如果要在真实手机上运行，目前还不能只靠仓库代码本身，前提是这台电脑已经装好 Android SDK。

必须满足：

- Android Studio / Android SDK 已安装
- `flutter doctor` 里 Android toolchain 通过
- 手机已开启开发者模式和 USB 调试
- `flutter devices` 能看到手机

准备好以后：

```powershell
Set-Location "<你的 NAS_phone 仓库目录>"
flutter devices
flutter run -d <device-id>
```

或者在 VS Code 里：

1. 打开 NAS_phone 仓库根目录
2. 左下角选中你的手机设备
3. 按 F5

只有在 Android SDK 和手机识别都已经正常时，VS Code 的 F5 才会像“一键运行”那样工作。

## 当前地址填写方式

常见填写示例：

- Windows 桌面预览连本机宿主：`http://127.0.0.1:5034`
- 安卓手机连同一局域网里的电脑宿主：`http://192.168.x.x:5034`
- 安卓手机连可达的 IPv6 宿主：`http://[fc00::xxxx]:5034`

注意：IPv6 地址必须带中括号。

## 说明

- 当前仓库已经验证通过的能力：文件列表、缩略图、图片预览、音频播放、视频外部打开、上传、新建文件夹、重命名、移动、下载、删除
- FileBrowser 登录接口使用纯文本 JWT，后续请求头使用 `X-Auth`
- 当前最稳的开发方式：先用 Windows 桌面预览迭代界面和接口，再在需要真机联调时补 Android SDK
