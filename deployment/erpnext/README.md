# Frappe 增量覆盖部署（本地手动流程）

此流程以当前生产镜像为基础，只叠加本次改动，生成一个新的不可变派生镜像。它只适用于**不含迁移、Schema 变更或业务数据写入**的 Frappe 代码改动。

> 本项目不使用 GitHub CI/CD：发布由本地操作者通过 Netcatty 连接生产服务器执行。

## 文件与运行位置

| 位置 | 内容 | 是否常驻 |
| --- | --- | --- |
| 本地仓库 | 本目录的脚本、Dockerfile 和发布源码。 | 是，受 Git 管理。 |
| 生产服务器 `/home/ubuntu/gitops` | 生产与预发 Compose 文件、镜像、常驻预发服务及其站点。 | 是。 |
| 生产服务器 `/home/ubuntu/gitops/releases/<tag>/` | 每次手动上传的 overlay、Dockerfile、`deploy.sh`、回滚 Compose 副本和部署记录。 | 按发布保留，可审计与回滚。 |

因此，`deployment/erpnext/` 下的脚本和文档**不常驻部署在生产服务器**；每次发布时才将所需文件上传到对应的 release 目录并执行。

## 优化内容

- **不复制完整源码：** `prepare-patch.sh` 只将 `frappe/` 下新增或修改的文件放入 Docker 构建上下文。删除、重命名或复制文件会直接失败，必须改走完整发布流程。
- **Desk Doctype JS 不构建资源：** Frappe 通过 Desk 元数据加载 Doctype JavaScript。`frappe/**/doctype/**/*.js` 这类改动使用 `BUILD_ASSETS=0`，镜像仅叠加源码。
- **依赖与镜像层复用：** 不可变基础镜像已经包含依赖，部署主机复用持久 Docker/BuildKit 层缓存。仅 `frappe/public/**` 或 `esbuild/**` 的改动会设置 `BUILD_ASSETS=1` 并运行 `bench build --app frappe`。
- **常驻预发：** 部署主机必须持续运行预发 Compose 项目及其 `erp.amoze.net` 站点。每次发布只检查并复用它，绝不新建站点。
- **轻量冒烟测试：** 在预发和生产阶段分别验证 Compose 配置、`--wait` 服务启动、Frappe 元数据缓存清理、`/api/method/ping` 与 `/desk` HTTP 响应。
- **自动回滚：** 预发失败仅恢复预发 Compose；生产失败则恢复发布前复制的生产 Compose 文件并重新启动旧镜像。每次发布在 `deployment-record.txt` 中记录旧/新镜像 ID。

## 手动发布步骤

1. 确认本地改动已经过最小相关验证，且 `base_ref` 与当前生产应用代码基线一致。
2. 在本地执行：

   ```bash
   cd apps/frappe
   bash deployment/erpnext/prepare-patch.sh <base_ref> HEAD release
   cp deployment/erpnext/Dockerfile.patch deployment/erpnext/deploy.sh release/
   chmod +x release/deploy.sh
   ```

3. 通过 Netcatty SFTP 将 `release/` 上传到生产服务器：

   ```text
   /home/ubuntu/gitops/releases/<唯一标签>/
   ```

4. 通过 Netcatty 终端在生产服务器执行：

   ```bash
   RELEASE_DIR=/home/ubuntu/gitops/releases/<唯一标签> \
   RELEASE_TAG=<唯一镜像标签> \
   BUILD_ASSETS=$(cat /home/ubuntu/gitops/releases/<唯一标签>/build-assets) \
   SOURCE_REF=<本地提交SHA> \
   bash /home/ubuntu/gitops/releases/<唯一标签>/deploy.sh
   ```

5. 观察预发与生产日志；脚本在预发失败时不会更新生产，在生产检查失败时会恢复已保存的 Compose 文件和旧镜像。

`prepare-patch.sh` 会拒绝删除、重命名或复制文件；遇到这些变更时不要绕过检查，应使用完整镜像发布流程。

## 当前平台限制

目前生产 Compose 项目中每项服务仅有一个副本，因此 Compose 执行的是受保护的**重建**，不是零停机滚动更新。预发门禁、`--wait`、冒烟测试和自动 Compose 回滚会降低风险，但不能实现真正的滚动发布。若需要滚动更新，应配置负载均衡后的多副本服务，或迁移到 Swarm/Kubernetes 等编排平台。

Desk Doctype JS 虽可跳过 `bench build`，但仍包含在应用镜像中，发布时需要重建相关服务。当前架构尚未提供独立静态资源仓库/CDN 与 asset-only 前端镜像，因此不能单独发布静态资源。
