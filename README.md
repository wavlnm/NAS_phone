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
- 可上传文件
- 可新建文件夹
- 可重命名文件或目录
- 可把文件或目录移动到指定远端目录
- 可下载单个文件，也可递归下载整个文件夹到本地同名目录
- 可删除文件或目录

## 当前最容易跑起来的方式

这台机器当前最容易直接看到效果的方式，不是安卓真机，而是 Windows 桌面预览。

原因：

- 当前项目已经补了 Windows 平台
- 当前机器已经能跑 Flutter Windows 桌面程序
- Android 真机运行仍然依赖 Android SDK

先启动 loal_NAS 宿主：

```powershell
Set-Location "C:\Users\Administrator\Documents\wfm\loal_NAS"
dotnet run --project src/LoalNas.Host
```

再启动 NAS_phone：

如果 `flutter` 已经在 PATH 里：

```powershell
Set-Location "C:\Users\Administrator\Documents\wfm\NAS_phone"
flutter run -d windows
```

如果 `flutter` 还没加到 PATH，直接用当前机器上的 SDK：

```powershell
Set-Location "C:\Users\Administrator\Documents\wfm\NAS_phone"
& "C:\Users\Administrator\Documents\wfm\flutter-sdk\bin\flutter.bat" run -d windows
```

程序启动后，在地址输入框里先填：

- http://127.0.0.1:5034

这样可以直接在本机预览“连接宿主、文件列表、上传、下载、移动、重命名、删除”的效果。

## 安卓真机怎么运行

如果要在真实手机上运行，目前还不能只靠仓库代码本身，前提是这台电脑已经装好 Android SDK。

必须满足：

- Android Studio / Android SDK 已安装
- `flutter doctor` 里 Android toolchain 通过
- 手机已开启开发者模式和 USB 调试
- `flutter devices` 能看到手机

准备好以后：

```powershell
Set-Location "C:\Users\Administrator\Documents\wfm\NAS_phone"
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

- 当前仓库已经验证通过的能力：文件列表、缩略图、图片预览、上传、新建文件夹、重命名、移动、下载、删除
- FileBrowser 登录接口使用纯文本 JWT，后续请求头使用 `X-Auth`
- 当前最稳的开发方式：先用 Windows 桌面预览迭代界面和接口，再在需要真机联调时补 Android SDK
