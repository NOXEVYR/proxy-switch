# 仓库迁移与同步说明

FlowSwitch 使用独立仓库 `turnsolesama/proxy-switch` 维护公开源码与文档；[portfolio](https://github.com/turnsolesama/portfolio) 保留工具总入口、原有源码历史与下载档案。

最初迁入的 3.7.1 来源为 `portfolio` 的 [`d3b47d7fc4320f627e6b5fc8f653fcbd35007670`](https://github.com/turnsolesama/portfolio/commit/d3b47d7fc4320f627e6b5fc8f653fcbd35007670)。本次在已有独立仓库历史上追加同步 **3.8.0 核心重构候选**，来源为 [`35ecc7e17cb9053279ecc422c3a577f5dafa5104`](https://github.com/turnsolesama/portfolio/commit/35ecc7e17cb9053279ecc422c3a577f5dafa5104) 提交中的 [`proxy-switch/` 目录](https://github.com/turnsolesama/portfolio/tree/35ecc7e17cb9053279ecc422c3a577f5dafa5104/proxy-switch)。此前提交保留，不重写迁移历史。

- 原 `proxy-switch/` 目录内容对应本仓库根目录，开发与构建命令直接在根目录执行。候选版的功能范围和待验收项见[核心重构说明](CORE_REBUILD.md)。
- 此次同步保留 3.8.0 的候选状态，不代表真实 IDE 登录与长期使用已经验收。使用前继续保留旧版和本机数据备份。
- Windows 候选包与源码包仍使用原 `portfolio/proxy-switch/releases/` 中的真实档案，首页下载、校验说明和品牌图片固定到 `35ecc7e…` 来源提交；未创建或假定新仓库已有同名 Release 资产。文件大小与 SHA-256 见[原下载说明](https://github.com/turnsolesama/portfolio/blob/35ecc7e17cb9053279ecc422c3a577f5dafa5104/proxy-switch/releases/README.md)。
- 原有 3.7.1 与更早下载档案保留，不把这些 ZIP 加入新仓库的 Git 历史。源码同步本身不会升级本机安装、迁移个人数据或切换系统代理；升级按[首页说明](README.md#退出与升级)操作。

[返回 FlowSwitch 首页](README.md) · [工具总入口](https://github.com/turnsolesama/portfolio)
