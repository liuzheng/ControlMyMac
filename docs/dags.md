# DAG 指南

ControlMyMac 只从以下目录加载用户 DAG：

```text
~/Library/Application Support/ControlMyMac/dags/
```

安装、更新、服务启动和卸载都会保留这个目录。将自己的 `.py` DAG 文件复制到此处；在设置页通过“DAG 目录”打开它。任务日志按日期写入：

```text
~/Library/Logs/ControlMyMac/Airflow/tasks/YYYY-MM-DD/
```

## 可选网卡示例

仓库的 `dags_demo/wired_ethernet_inserted.py` 只是示例源文件，`make bundle` 和 `make install` 都不会自动部署它。若要试用，请手动复制：

```bash
cp dags_demo/wired_ethernet_inserted.py \
  "$HOME/Library/Application Support/ControlMyMac/dags/"
```

该 DAG：

- 名为 `wired_ethernet_inserted`，使用 `@continuous` 调度；
- 从 2026-01-01 开始；
- 默认每 5 秒检查一次 `en12`；
- 使用 triggerer 等待状态变化，并将状态保存在 `AIRFLOW_HOME` 下；
- 需要由当前应用安装的 Airflow 3 runtime。

这不是恢复旧版 ControlMyMac 内置网卡 Rule 或监听服务：应用本身不会自动安装、启用或配置它。

示例源码提到 `CONTROLMYMAC_WIRED_INTERFACES`，但打包 supervisor 会创建受限的 Airflow 进程环境，当前不会传入此 shell 环境变量。因此，不要将导出该变量视为已支持的安装后配置方式。若需修改监视接口，请复制后直接调整 DAG 源码，并在 Airflow 中验证其解析和任务行为。

## 可选飞书消息示例

仓库的 `dags_demo/feishu_message_received.py` 会通过飞书长连接订阅接收消息事件，不需要把本机 Airflow 的回调地址暴露到公网。它同样不会自动部署，直接复制即可：

```bash
cp dags_demo/feishu_message_received.py \
  "$HOME/Library/Application Support/ControlMyMac/dags/"
```

DAG 在 `@task.virtualenv` 中声明并固定 `lark-oapi==1.6.4`，Airflow 仅在执行监听任务时为它建立隔离环境；不需要修改或重新执行 ControlMyMac 的 `make install`。因此该 macOS 账户需要能访问配置的 Python 包索引。打开飞书开放平台的应用配置，启用长连接事件订阅并订阅“接收消息”事件；同时为应用授予所需的消息读取权限。

在 Airflow UI 的 **Connections** 页面创建一个 Connection，按以下方式填写：

| 字段 | 值 |
| --- | --- |
| Connection ID | `feishu_message_listener` |
| Connection Type | Generic |
| Login | 飞书 App ID，例如 `cli_xxx` |
| Password | 飞书 App Secret |
| Extra | 可选 JSON 白名单，例如下方内容 |

```json
{
  "allowed_chat_ids": ["oc_your_chat_id"],
  "allowed_sender_ids": ["ou_your_sender_open_id"]
}
```

`allowed_chat_ids` 与 `allowed_sender_ids` 均为可选白名单；省略或传入空数组时不按该维度过滤。不要把 App Secret 放入 DAG 源码、Connection 的 Extra、shell 环境变量或任务日志。DAG 使用 Airflow 的 Connection API 读取 Login 和 Password，因此凭据不会通过任务参数或 XCom 传递。

该 DAG 使用 `@continuous` 调度，每次由一个 `@task.virtualenv` 监听任务等待一条符合白名单的消息。该任务等待期间会占用一个 LocalExecutor worker；这是不将 SDK 安装到 Triggerer 全局环境的代价。它在 `AIRFLOW_HOME/feishu-message-received-state.json` 保存最近 500 个已交付的消息 ID，用于忽略重复投递；此状态文件不含凭据，仍位于应用创建的私有目录。SDK 确认事件后发生进程或任务失败时，消息不保证重放，因此替换默认任务时应以 `message_id` 设计幂等操作。修改 Connection 后，重新执行或重启 Airflow 服务以让新的监听任务读取更新后的值。

## 运行与排查

确认 Airflow 就绪后，在浏览器打开 `http://127.0.0.1:50100`，使用设置页显示的 `controlmymac` 管理员凭据登录。密码随服务启动轮换；不要把它写入 DAG 或任务日志。

DAG 不解析或任务失败时，先检查当天的任务日志和服务日志：

```bash
open "$HOME/Library/Logs/ControlMyMac/Airflow/tasks"
open "$HOME/Library/Logs/ControlMyMac/Airflow/service"
```

如需调整 DAG 依赖或执行行为，请把它们作为用户 DAG 的一部分维护；ControlMyMac 不提供额外的全局 DAG 配置层。
