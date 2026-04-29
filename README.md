# NAS_phone

loal_NAS 的 Flutter 手机端仓库。

当前已完成的最小骨架：

- Android / iOS Flutter 工程已初始化
- 首页已替换为宿主探测页
- 可输入宿主地址并请求 /api/system/status
- 可展示宿主名称、FileBrowser 运行状态和内部地址

本地开发：

1. 进入仓库根目录
2. 运行 flutter pub get
3. 运行 flutter run

当前首页建议输入示例：

- http://192.168.x.x:5034
- http://[fc00::xxxx]:5034

注意：IPv6 地址必须带中括号。
