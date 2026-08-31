# Frappe 增量覆盖部署

此流程以当前生产镜像为基础，只叠加本次改动，生成一个新的不可变派生镜像。它只适用于**不含迁移、Schema 变更或业务数据写入**的 Frappe 代码改动。

## 文件与运行位置

| 位置 | 内容 | 是否常驻 |
| --- | --- | --- |
| 本地仓库 / GitHub | 本目录的脚本、Dockerfile 和 GitHub Actions 工作流源码。 | 是，受 Git 管理。 |
| GitHub `production` Environment | SSH 私钥、固定主机指纹、主机地址等环境级 Secrets。 | 是，由 GitHub 保管。 |
| 生产服务器 `/home/ubuntu/gitops` | 生产与预发 Compose 文件、镜像、常驻预发服务及其站点。 | 是。 |
| 生产服务器 `/home/ubuntu/gitops/releases/<tag>/` | 每次 CI 上传的本次 overlay、Dockerfile、`deploy.sh`、回滚 Compose 副本和部署记录。 | 按发布保留，可审计与回滚。 |

因此，`deployment/erpnext/` 下的文档与脚本**不常驻部署在生产服务器**；GitHub Actions 运行时才会将所需文件上传到对应的 release 目录并执行。

## 优化内容

- **不复制完整源码：** `prepare-patch.sh` 只将 `frappe/` 下新增或修改的文件放入 Docker 构建上下文。删除、重命名或复制文件会直接失败，必须改走完整发布流程。
- **Desk Doctype JS 不构建资源：** Frappe 通过 Desk 元数据加载 Doctype JavaScript。`frappe/**/doctype/**/*.js` 这类改动使用 `BUILD_ASSETS=0`，镜像仅叠加源码。
- **依赖与镜像层复用：** 不可变基础镜像已经包含依赖，部署主机复用持久 Docker/BuildKit 层缓存。仅 `frappe/public/**` 或 `esbuild/**` 的改动会设置 `BUILD_ASSETS=1` 并运行 `bench build --app frappe`。
- **常驻预发：** 部署主机必须持续运行预发 Compose 项目及其 `erp.amoze.net` 站点。每次发布只检查并复用它，绝不新建站点。
- **轻量冒烟测试：** 在预发和生产阶段分别验证 Compose 配置、`--wait` 服务启动、Frappe 元数据缓存清理、`/api/method/ping` 与 `/desk` HTTP 响应。
- **自动回滚：** 预发失败仅恢复预发 Compose；生产失败则恢复发布前复制的生产 Compose 文件并重新启动旧镜像。每次发布在 `deployment-record.txt` 中记录旧/新镜像 ID。

## GitHub Actions 配置

手动工作流位于 [`.github/workflows/erpnext-production-deploy.yml`](../../.github/workflows/erpnext-production-deploy.yml)。先将包含该文件的 PR 合并到默认分支，然后从 `release/erpnext-production` 分支触发部署。

GitHub `production` Environment 应启用审核，并配置以下 Environment Secrets：

| Secret | 用途 |
| --- | --- |
| `DEPLOY_HOST` | 部署服务器主机名或 IP。 |
| `DEPLOY_USER` | 受限的 SSH 部署用户。 |
| `DEPLOY_SSH_PORT` | SSH 端口；留空时为 `22`。 |
| `DEPLOY_SSH_PRIVATE_KEY` | 专用部署密钥，不能使用个人私钥。 |
| `DEPLOY_KNOWN_HOSTS` | 固定的服务器 `known_hosts` 条目；CI 中不得使用 `ssh-keyscan`。 |

部署用户需要 Docker Compose 权限且不得依赖交互式密码输入。工作流会将 release overlay 上传至 `/home/ubuntu/gitops/releases/<tag>/`，然后调用其中的 `deploy.sh`。

触发工作流时：

1. `base_ref` 填写当前生产应用代码所对应的 Frappe 提交；它必须是待部署提交的祖先。
2. 可选填写不可变 `release_tag`；不填写时由提交 SHA 与工作流运行编号生成。
3. 审核 GitHub Environment 部署请求，并查看预发、生产提升和回滚日志。

## 当前平台限制

目前生产 Compose 项目中每项服务仅有一个副本，因此 Compose 执行的是受保护的**重建**，不是零停机滚动更新。预发门禁、`--wait`、冒烟测试和自动 Compose 回滚会降低风险，但不能实现真正的滚动发布。若需要滚动更新，应配置负载均衡后的多副本服务，或迁移到 Swarm/Kubernetes 等编排平台。

Desk Doctype JS 虽可跳过 `bench build`，但仍包含在应用镜像中，发布时需要重建相关服务。当前架构尚未提供独立静态资源仓库/CDN 与 asset-only 前端镜像，因此不能单独发布静态资源。
