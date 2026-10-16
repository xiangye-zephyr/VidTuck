<p align="center"><img src="Resources/AppIcon.png" width="104" alt="VidTuck 图标"></p>

# VidTuck

把视频链接收进口袋。面向 Apple Silicon Mac 的轻量视频下载工具，支持 YouTube、B站、抖音和小红书。

**0.2.6 · macOS 15+ · M 系列芯片 · 中文界面**

[下载 Mac 版](https://github.com/xiangye-zephyr/VidTuck/releases/latest) · [开发说明](docs/DEVELOPMENT.md) · [第三方组件](ThirdParty/NOTICE.md)

## 安装与使用

1. 从 [Releases](https://github.com/xiangye-zephyr/VidTuck/releases) 下载 `VidTuck-0.2.6-macOS-arm64.zip`，解压后把 `VidTuck.app` 拖进「应用程序」。GitHub 自动生成的「Source code」压缩包是源码，不含可直接运行的应用。
2. 在主窗口按 **⌘V** 粘贴视频链接或分享文案，也可拖入链接。默认自动解析、依次下载，一次最多添加 50 条。
3. 默认选择**最高可用画质**并保存视频和音频。「设置」可调整清晰度、仅音频、自动下载和保存目录。
4. 完成后点击播放或显示文件。全新安装默认保存到 `~/Downloads/VidTuck`。

已内置 yt-dlp、Deno 和 FFmpeg。使用时无需安装 Codex、Python、Node、Homebrew，也无需运行服务器。

**首次打开：**当前版本只有临时签名，未做 Developer ID 签名和苹果公证，macOS 可能阻止首次启动。确认来源与校验值后，请按[苹果官方说明](https://support.apple.com/zh-cn/102445)到「系统设置 → 隐私与安全」检查是否提供「仍要打开」。不要关闭系统安全保护。不支持 Intel Mac 或 Windows。

## 功能与平台

- 视频封面背景、进度、速度、大小和下载状态。
- 队列、暂停、继续、失败重试和重启后保留任务。
- 最高可用画质，或限制为最高 4K、1080p、720p、480p；支持导出 M4A。
- 视频与音频合并，通常保存为 MP4，部分编码可能保存为 MKV。
- 网页辅助登录、本地 Cookie 导入和解析器更新。

| 平台 | 支持与限制 |
| --- | --- |
| YouTube | 音视频分轨下载后合并；网络需要能访问 YouTube，部分内容需要本人登录。 |
| B站 | 单条视频；清晰度受视频源、账号与权限影响。 |
| 抖音 | 后台解析，优先直连；连接 5 秒无数据且有同画质备用地址时，自动切换一次。 |
| 小红书 | 已验证有效的完整视频分享链接；保留分享参数，失效链接、部分短链接或登录受限内容可能失败。 |

「最高可用」是平台当前返回且账号可访问的最佳格式，不保证获取原始上传文件。相同清晰度与帧率下优先 H.264/AAC。网站变化、网络、验证和账号权限都会影响可用性、画质与速度。

抖音 0.2.6 在本机 4 次小样本中，粘贴到首次报告已收到数据约 2.5～3.8 秒，这不是其他网络或设备上的速度承诺。连接切换保持同一编码流、分辨率、码率、编码与大小；5 秒从下载连接阶段计时，并非从粘贴开始计时。

## 数据与隐私

- 不需要 VidTuck 账号，无遥测、无云端上传服务；在本机解析下载，网络直接访问目标网站与媒体服务。网页自身的网络行为由目标网站决定。
- 登录由本人完成；软件不自动读取 Safari、Chrome 的账号。网页辅助使用独立网站数据，支持导入本人的 `cookies.txt`。
- 任务、封面、Cookie 与引擎更新保存在 `~/Library/Application Support/StreamNest/`；沿用内部标识以兼容旧版数据。
- 不要上传应用数据目录：Cookie 和签名视频链接可能包含敏感信息。仓库与发行包不包含开发者的账号、任务记录或下载视频。
- 移除任务或清除已完成记录会保留文件；清除登录信息仅影响本软件。

## 从源码构建

需要 Apple Silicon Mac、macOS 15+、Xcode Command Line Tools，以及构建 FFmpeg 所需的 `make`、`nasm`、`pkg-config` 等工具。普通使用者只需下载 Releases 中的应用。

```sh
git clone https://github.com/xiangye-zephyr/VidTuck.git
cd VidTuck
zsh scripts/prepare-tools.sh
zsh scripts/build.sh
```

依赖放在 `.build-tools/` 并校验 SHA-256；应用默认输出到仓库上一级目录。当前只构建 arm64。实现与测试程序说明见 [开发说明](docs/DEVELOPMENT.md)。

## 许可与反馈

原创源码使用 [MIT License](LICENSE)。第三方组件保留各自许可，来源、许可证和 FFmpeg 对应源码见 [ThirdParty](ThirdParty/NOTICE.md)。VidTuck 是独立项目，与 Downie 无关联。

请仅下载你有权下载和使用的内容。[反馈问题](https://github.com/xiangye-zephyr/VidTuck/issues)时，说明系统版本、平台及错误现象；提交前删除 Cookie、令牌、个人信息和敏感链接参数。
