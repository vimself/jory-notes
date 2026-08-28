---
tags: [类型/实践, 技术/GitHub]
aliases: [GitHub API, REST API, webhook, 网络钩子, gh CLI, gh 命令行, X-Hub-Signature-256, personal access token, PAT, GitHub App, 自动化]
created: 2026-08-28
updated: 2026-08-28
---
> 想让程序操作 GitHub，有三条路：`gh` 命令行（人和脚本用，最省事）、REST API（自己发请求，最灵活）、webhook（GitHub 主动通知你，用于实时响应事件）。

## 三者怎么选

关键区别在**谁主动**：前两个是你去问 GitHub，webhook 是 GitHub 来告诉你。

| 方式 | 方向 | 什么时候用 |
| --- | --- | --- |
| `gh` CLI | 你 → GitHub | 手动操作、写脚本，绝大多数场景 |
| REST API | 你 → GitHub | `gh` 没封装到的接口，或者非 shell 环境 |
| Webhook | GitHub → 你 | 需要在事件发生时立刻做出反应 |

## gh：优先选它

`gh` 是 GitHub 官方命令行工具，把常用操作都包好了，不用自己拼 URL、不用手动处理认证。

```bash
gh auth login        # 一次性登录，凭据存进系统钥匙串
```

登录之后就不用再管 token 了。查看当前状态：

```bash
gh auth status
```

核心命令按对象组织：

```bash
gh repo      # 仓库：clone / create / fork / view / edit / sync / delete
gh pr        # PR：create / list / checkout / diff / review / merge / checks
gh issue     # issue：create / list / view / close / comment
gh release   # 发布：create / upload / download
gh run       # Actions 运行记录：list / view / watch / rerun
gh secret    # 密钥管理
gh org       # 组织
gh project   # 项目看板
gh gist      # 代码片段
```

几个特别好用的：

```bash
gh pr checkout 123      # 把 123 号 PR 拉到本地检出，能实际跑一跑再评审
gh pr checks            # 看当前 PR 的 CI 过没过，不用切浏览器
gh run watch            # 实时盯着 Actions 跑，跑完通知
gh repo clone owner/repo   # 不用复制粘贴 URL
```

### gh api：命令行里直接调 REST API

`gh` 没封装的接口，用 `gh api` 直接打，认证自动带上：

```bash
gh api repos/{owner}/{repo}/releases/latest --jq '.tag_name'
```

两个便利设计：

- **`{owner}`、`{repo}`、`{branch}` 是占位符**，会自动替换成当前目录所在仓库的值（也可以用 `GH_REPO` 环境变量指定）
- **默认方法是 `GET`，一旦带了参数就自动变成 `POST`**，可以用 `--method` 覆盖

传参数用 `-f`（原始字符串）或 `-F`（自动推断类型）：

```bash
gh api repos/{owner}/{repo}/issues --method POST -f title="标题" -f body="内容"
```

要调 GraphQL 就把路径写成 `graphql`。

## REST API：自己发请求

不在 shell 里（比如在 Python 服务里），或者要做的事 `gh` 覆盖不到，就直接调 REST API。

基地址是 `https://api.github.com`。一个真实的调用长这样（取自本仓库的 [[GitHub Actions]] workflow）：

```bash
curl -sS -f -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/vimself/vimself.github.io/dispatches \
  -d '{"event_type":"notes-updated"}'
```

三个请求头的作用：`Accept` 指定返回格式，`Authorization` 带认证，**`X-GitHub-Api-Version` 锁定 API 版本**——写上它，GitHub 之后改版也不会突然打破你的脚本。

**注意速率限制。** 认证请求的额度比匿名高得多，但仍然有限。频繁轮询很容易撞上限。

## Webhook：让 GitHub 来通知你

前两种都是你去问。如果你要做的是「仓库一有推送就立刻部署」，靠轮询 API 既慢又浪费——**这正是 webhook 存在的理由**。

工作方式：你在 GitHub 上配一个 URL 和一组关心的事件；事件发生时，GitHub 往那个 URL 发一个带事件数据的 HTTP 请求；你的服务器收到后做相应处理。

官方对二者的取舍说得很直接：**webhook 近乎实时、资源消耗小、在大量资源上也能扩展；REST 轮询消耗更多资源，监控对象一多就容易耗尽速率限制。** 持续监控用 webhook，偶尔查一次用 REST API。

**可以配置 webhook 的层级**：单个仓库、组织、GitHub Marketplace 账号、GitHub Sponsors 账号、GitHub App。每个 webhook 只能访问其安装范围内的资源。

### 验签：这一步不能省

你的 webhook 接收地址是公网可访问的，**任何人都能往它发伪造请求**。所以必须验证请求确实来自 GitHub。

做法是配置时设一个 **secret token**，之后 GitHub 每次发送都会用它对请求体算一个 HMAC 签名，放在请求头里：

- **请求头名称：`X-Hub-Signature-256`**
- **算法：HMAC-SHA256**
- **格式：`sha256=` 加上十六进制摘要**

你的服务器要做的是：用自己存的 secret 和收到的 payload 算一遍 HMAC-SHA256，和请求头里的值比对。

**比对必须用常数时间比较函数**（如 `secure_compare`、`crypto.timingSafeEqual`），不能用普通的 `==`。普通比较会因为「第几位开始不同」而耗时不同，攻击者可以据此逐位试出正确签名。

secret 本身要安全存储，**不要硬编码、不要提交进仓库**。

## 关于「把 token 交给 AI 助手代劳」

草稿里留了个问题：能不能直接把 GitHub token 给 Claude Code，让它全权代办；还是用 `gh` 更方便。

**答案是用 `gh`，而且不要把 token 贴进对话。**

理由有三条：

**一、`gh` 已经解决了认证。** 你本机跑过 `gh auth login` 之后，凭据存在系统钥匙串里，任何能执行命令的工具直接敲 `gh pr list` 就能用，全程不需要谁看到 token 原文。

**二、贴进对话的 token 会留下副本。** 对话记录、日志、临时文件都可能留存。而 token 一旦泄露，拿到它的人就获得了它全部 scope 的权限。

**三、粘贴的 token 权限通常过大。** 大家习惯建一个勾满权限的 classic token 一劳永逸，于是一个本来只需要读 issue 的任务，拿到的是能删仓库的钥匙。

**如果确实需要独立 token**（比如在 CI 里、或者跨仓库操作），正确做法是：

- 优先用 **fine-grained token**，只勾选必需的仓库和必需的权限
- 在 Actions 里优先用自动提供的 `GITHUB_TOKEN`，配合 `permissions` 收紧，见 [[GitHub Actions]]
- token 存进仓库或环境的 secrets，用 `${{ secrets.NAME }}` 引用，不要写进代码
- 设置过期时间，别建永不过期的

本仓库那个通知博客的 workflow 就是这个模式：跨仓库触发需要额外权限，于是用了一个专用 token 存在 secrets 里，同时把工作流自己的 `GITHUB_TOKEN` 用 `permissions: {}` 全部关掉。

## 参考
- REST API 文档：https://docs.github.com/en/rest
- Webhook 介绍：https://docs.github.com/en/webhooks/about-webhooks
- 验证 webhook 签名：https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries
- `gh` 手册：https://cli.github.com/manual/

## 待补充
- REST API 速率限制的具体数字（认证/未认证/GraphQL 各不相同，用前查当期文档）
- GitHub App 相对 PAT 的优势与安装流程
- fine-grained token 对 [[GitHub Packages]] 等功能的支持现状
