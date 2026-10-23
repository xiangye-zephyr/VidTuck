# VidTuck Windows

Windows 10 22H2 / Windows 11，Intel / AMD 64 位（x64）。当前为 0.3.0-beta.1 测试版。

## 普通用户

下载 `VidTuck-0.3.0-beta.1-Windows-x64.zip`，右键选择“全部解压”，打开解压后的文件夹，双击 `VidTuck.exe`。保留整个文件夹；不要只复制 exe，也不要在压缩包预览中直接运行。

已内置下载引擎、Deno、FFmpeg 和桌面运行环境；不需要安装 Python、Node、Chrome 或开发工具，不需要管理员权限。默认保存到系统“下载”目录内的 `VidTuck` 文件夹；设置中可更改。

粘贴链接或分享文案（Ctrl+V），也可拖入链接。支持队列、暂停、继续、失败重试、画质上限、M4A 音频、历史记录、文件定位、独立网页辅助和本人 cookies.txt 导入。抖音网页直接解析沿用 Mac 版 ID 校验；平台接口、网络与本人账号权限影响可用性。YouTube 仍需要网络可访问。

本版本尚无 Windows 代码签名，Windows 可能显示发布者未知或 SmartScreen 提示。请只从本仓库的发布页获取并核对 SHA256SUMS.txt；不要关闭 Defender 或 SmartScreen。若系统或组织策略不允许运行，请停止并反馈。

仅支持 x64；尚未验证 Windows on ARM。辅助网页与系统浏览器登录状态独立；不会自动读取 Chrome / Edge 账号。本机数据位于 `%APPDATA%/VidTuck/data`，浏览器独立状态位于应用数据目录。不要分享 Cookie、任务数据库或带签名参数的私密链接。

## 开发与构建

```sh
cd windows
npm ci
npm test
npm run prepare-tools
npm run build
```

构建过程需下载公开依赖；最终用户运行时不需要 npm。依赖版本和 SHA-256 固定在 `scripts/prepare-tools.cjs`，FFmpeg 对应源码与构建脚本位于发行包的 `resources/licenses`。桌面壳使用 Electron；Mac 原生源码与已有 Mac 发布包保持独立。

`.github/workflows/windows.yml` 在 Windows runner 上构建实际 Windows 包，再启动打包后的 exe，运行本地视频下载、M4A 导出、ffprobe 媒体验证、历史恢复和界面/IPC 验收；报告、截图与包均保留为 Actions 产物。自动验收使用自制媒体，不代表所有平台链接均已通过实测。
