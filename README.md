# 星璃 · Codex 启动动画与动态壁纸

Windows 上的银白龙娘启动动画、循环雨景壁纸和可选桌面挂件。第三方个人项目，与 OpenAI、ChatGPT 或 Codex 官方无隶属关系。

## 包含什么

- 7.2 秒启动视频：半脸构图、轮廓显影、睁眼、虹膜代码与 ChatGPT / CODEX MODE 字样。
- 8 秒循环聊天背景：眨眼、轻微人物运动和雨滴。
- Q 版挂件：点击害羞、悬停招呼、拖动、滚轮缩放、右键菜单。
- 启动器：检测已有 Codex 窗口并复用；不会主动结束或强制重启 Codex。

视频交付规格为 3840×2160、60 fps。人物源图为 1672×941，使用图片纹理和深度曲面形变；不是原生 4K 人物素材，也不是完整可旋转的三维角色模型。

## 快速使用

1. 在 Releases 下载完整 Windows ZIP，解压到长期保留的目录。不要直接在 ZIP 内运行。
2. 电脑需安装 Codex Windows 桌面应用。本启动器识别 `OpenAI.Codex` 包；不保证兼容其他安装方式或独立 ChatGPT 应用。
3. 双击 `app/Start-Xingli.vbs`。首次运行会从附带 C# 源码编译辅助组件，可能稍慢；不需要 Blender、Python 或 API 密钥。
4. 可右键 `Install-Shortcut.ps1` → 使用 PowerShell 运行，创建“星璃 Codex（便携版）”桌面快捷方式。快捷方式指向解压目录，移动目录后需重新运行安装脚本。

依赖 Windows PowerShell 5.1、.NET Framework/WPF、Windows Script Host 和可播放 MP4 的系统媒体组件。学校或企业策略可能禁用脚本；Windows N 等缺少媒体组件的系统可能无法播放视频。

`app/Start-Companion.vbs` 可单独打开挂件。没有可用视频时启动器尝试实时绘制。按 Esc 可跳过开场显示，具体应用启动仍由后台启动流程完成。

## 聊天壁纸

壁纸需要另外安装第三方 [Codex Dynamic Skin](https://github.com/CCDawn/Codex-Dynamic-Skin)。本仓库不包含其程序、用户配置或登录数据。

在其管理器中使用本地视频/自定义主题功能，选择 `app/xingli-chat-rain-blink.mp4`。具体入口以所安装版本的说明为准。需要启用该软件的背景透明度/沉浸设置，才能得到对应的聊天背景效果。我们原电脑的主题配置没有打包，因此初次导入不保证完全复刻原透明度。

启动器会查找当前用户安装的 Dream Skin 启动脚本；存在且 Codex 尚未运行时尝试使用它。已有普通 Codex 窗口会直接复用，不会为了加皮肤关闭它。需要皮肤时请自行保存工作并正常退出后再启动。

## 从仓库源码运行

源码包有图片和脚本，不含两个大视频。从完整 Release 包取出 `preview-startup.mp4` 和 `xingli-chat-rain-blink.mp4`，放入 `app/`。无需复制 DLL，脚本可从源代码加载所需组件。

`tools/VerifyLauncher.ps1` 是模拟启动分支检查，不会启动或关闭 Codex。它不等同于在所有机器上验证过真实冷启动。

## 卸载与限制

删除“星璃 Codex（便携版）”快捷方式和解压目录即可移除本包。挂件可右键关闭；Dream Skin 的主题请在其管理器中切换或移除。不会卸载 Codex。

这是一份当前个人使用版本的分享准备包，尚未在其他电脑完成兼容性测试。窗口有响应不代表聊天正文已加载完成；媒体解码、系统缩放和显卡性能也会影响体验。

素材来源和发布许可状态见 [NOTICE.md](NOTICE.md)。
