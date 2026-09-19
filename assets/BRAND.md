# 双入口 · FlowSwitch

Windows 3.8.4 / macOS 0.1.0-preview.3 使用用户选定的双入口原图。`FlowSwitch.png` 是内置图像生成工具制作的批准稿，保留透明度与原始画面，不依赖在线生成即可构建。

Windows：`Build-BrandAssets.ps1` 从 PNG 生成 16、24、32、48、64、128、256 像素 ICO；macOS 构建脚本用系统 sips / iconutil 生成 ICNS，菜单栏使用同主题的单色双入口轮廓。

界面色板：背景 `#121C2B`、面板 `#1B2A3D`、控件 `#263A51`、边框 `#40566F`、正文 `#EBF3FC`、次要文字 `#AFBED0`、强调色 `#9EDBFA`。警告与错误保留独立语义色。

生成提示词：

Design one polished app icon concept for FlowSwitch, a desktop network proxy routing utility. Square 1024px image. Center a large rounded-square application tile with generous outer margin against a neutral charcoal #14171C background. Straight-on view, precision balanced geometry, exceptionally clean silhouette recognizable at 24px, no text, no letters outside the tile, no watermarks, no tiny decorations, no mock device. Premium desktop app identity, tasteful subtle dimensionality, cool graphite/navy and ice-blue palette, restrained light and shadows. Two staggered upright open portal frames connected by a single flowing route passing through them, suggesting switching between two gateways. Strong geometric composition with two rounded rectangular frame silhouettes, one slate-silver and one ice blue, and a simple blue-white joining path. Elegant frosted-glass material, deep blue-gray rounded-square tile. Avoid tiny circuit patterns and lock/shield imagery.
