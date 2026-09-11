# 仓库迁移说明

FlowSwitch 现在使用独立仓库 `turnsolesama/proxy-switch`。源码、功能文档和后续开发在本仓库维护；[portfolio](https://github.com/turnsolesama/portfolio) 保留工具总入口与原有历史。

迁移来源是 `portfolio` 的 [`d3b47d7fc4320f627e6b5fc8f653fcbd35007670`](https://github.com/turnsolesama/portfolio/commit/d3b47d7fc4320f627e6b5fc8f653fcbd35007670) 提交中的 [`proxy-switch/` 目录](https://github.com/turnsolesama/portfolio/tree/d3b47d7fc4320f627e6b5fc8f653fcbd35007670/proxy-switch)。该目录内容提升为本仓库根目录；开发命令在根目录执行，无需再进入一层 `proxy-switch/`。

- 原仓库提交历史与既有下载档案保留。这次迁移不代表重新发布 3.7.1，也不把旧 ZIP 复制到新 Git 历史中。
- 3.7.1 程序包和源码包原本保存在 `portfolio/proxy-switch/releases/`。首页仍链接这些真实档案，并固定到来源提交；未创建或假定新仓库存在同名 Release 资产。大小与 SHA-256 见[原下载说明](https://github.com/turnsolesama/portfolio/blob/d3b47d7fc4320f627e6b5fc8f653fcbd35007670/proxy-switch/releases/README.md)。
- 首页品牌横幅也引用来源提交中的公开 SVG；不依赖仓库外的 `../docs/` 相对目录。
- 本机程序、`%USERPROFILE%\.proxyswitch` 数据、代理入口与托盘行为不因仓库迁移改变。运行包升级仍按[首页说明](README.md#退出与升级)操作。

[返回 FlowSwitch 首页](README.md) · [工具总入口](https://github.com/turnsolesama/portfolio)
