---
tags: [类型/概念, 技术/GitHub, 技术/CI-CD]
aliases: [GitHub Action, Actions, workflow, 工作流, CI/CD, 持续集成, 持续部署, runner, 运行器, job, step, matrix, 矩阵构建, GITHUB_TOKEN, actions/checkout]
created: 2026-08-28
updated: 2026-08-28
---
> GitHub Actions 是内置在仓库里的自动化系统：你在 `.github/workflows/` 下写一个 YAML 文件，声明「什么事件发生时，在什么机器上，按顺序跑哪些步骤」，GitHub 就会替你跑。

## 它能干什么

最常见的用途是 **CI/CD**：

- **CI（持续集成）**：每次有人推代码或提 PR，自动跑测试、跑 lint、编译一遍。坏了立刻知道，而不是等到发版前
- **CD（持续部署）**：测试通过后自动构建产物、推镜像、部署到服务器

但它本质是个通用的事件驱动执行器，不只能做 CI/CD。定时清理陈旧 issue、有人提 issue 自动打标签、笔记仓库更新了去通知博客重建——只要能表达成「某事发生 → 跑一段脚本」，都能用它。

关键优势是**不用自己搭一台服务器**。GitHub 提供跑任务的机器（runner），公开仓库免费额度相当宽松。

## 四个核心概念

这四个词是理解 Actions 的全部地基，搞清楚层级关系就不会晕。

**Event（事件）** —— 触发条件。「有人推代码到 main」「有人开了 PR」「每天凌晨三点」都是事件。

**Workflow（工作流）** —— 一个 YAML 文件，就是一整套自动化流程。放在仓库的 `.github/workflows/` 目录下，一个仓库可以有多个，互相独立。

**Job（作业）** —— 工作流里的一个任务单元。**每个 job 跑在一台全新的、干净的虚拟机上**。默认所有 job **并行**执行。

**Step（步骤）** —— job 里的一条条命令，**顺序**执行。同一个 job 里的 step 共享同一台机器和同一个工作目录。

包含关系：

```text
Event 触发 → Workflow
              └── Job A（一台机器，和 B 并行）
              │    ├── Step 1
              │    └── Step 2
              └── Job B（另一台机器）
                   └── Step 1
```

**「每个 job 一台全新机器」这条最容易踩坑。** job A 里安装的依赖、生成的文件，job B 完全看不到——它们是两台机器。要传东西得用 artifact 或 job outputs，不能指望文件还在。

## 读懂一个最小的工作流

```yaml
name: GitHub Actions Demo
run-name: ${{ github.actor }} is testing out GitHub Actions 🚀
on: [push]
jobs:
  Explore-GitHub-Actions:
    runs-on: ubuntu-latest
    steps:
      - run: echo "🎉 The job was automatically triggered by a ${{ github.event_name }} event."
      - name: Check out repository code
        uses: actions/checkout@v7
      - name: List files in the repository
        run: |
          ls ${{ github.workspace }}
```

逐行拆：

**`name:`** 工作流的名字，显示在 Actions 页面上。

**`on:`** 触发事件。`[push]` 表示任何分支有推送就跑。

**`jobs:`** 下面是所有 job，`Explore-GitHub-Actions` 是你自己起的 job ID。

**`runs-on:`** 用哪种机器。`ubuntu-latest` 最常用也最便宜，另有 `windows-latest`、`macos-latest`。

**`steps:`** 步骤列表。每个步骤是列表里的一项（前面那个 `-`）。

**步骤只有两种形态**，这是关键区分：

- **`run:`** —— 直接执行 shell 命令。`|` 表示后面跟多行
- **`uses:`** —— 使用一个**别人写好的 action**，`@v7` 是版本

**`${{ }}`** 是表达式语法，用来取上下文变量。`github.actor` 是触发者用户名，`github.workspace` 是代码所在目录。

### 那个几乎每次都要写的 checkout

```yaml
- uses: actions/checkout@v7
```

**runner 上默认是没有你的代码的。** 新开的虚拟机是空的，`actions/checkout` 这个官方 action 的作用就是把你的仓库克隆下来。忘了写它，后面所有操作都会找不到文件——这是新手第一个必踩的坑。

**版本号会变。** 上面写的 `@v7` 是 2026-08-28 查到的当期主版本（`actions/checkout` 当时最新发布为 v7.0.1）。这类官方 action 每年都在升大版本，用之前去 [github.com/actions/checkout](https://github.com/actions/checkout) 确认一眼。**固定到主版本（`@v7`）**是通行做法，能自动拿到该主版本内的修复；对安全敏感的场景可以固定到完整 commit SHA。

## 常用触发方式

```yaml
on:
  push:
    branches: [main]              # 只有推到 main 才跑
    paths:                        # 且只有这些路径变了才跑
      - 'src/**'
  pull_request:
    branches: [main]              # 针对 main 的 PR
  schedule:
    - cron: '0 3 * * *'           # 定时，UTC 时间
  workflow_dispatch:              # 在网页上手动点按钮触发
```

`paths` 过滤器很实用，能避免改个 README 也跑一遍完整测试。

`workflow_dispatch` 建议给大多数工作流都加上，调试时能手动触发，不用为了测试一直造假提交。

**`schedule` 用的是 UTC 时间**，写定时任务时记得换算，北京时间要减 8 小时。

## 变量与密钥

**环境变量**可以定义在三个层级，就近覆盖：

```yaml
env:
  DAY_OF_WEEK: Monday           # 整个工作流可见

jobs:
  greeting_job:
    runs-on: ubuntu-latest
    env:
      Greeting: Hello           # 这个 job 可见
    steps:
      - name: "Say Hello Mona it's Monday"
        run: echo "$Greeting $First_Name. Today is $DAY_OF_WEEK!"
        env:
          First_Name: Mona      # 只有这一步可见
```

**密钥（Secrets）** 用来放 token、密码这类不能写进代码的东西。在仓库设置里添加，用 `${{ secrets.NAME }}` 取用：

```yaml
- run: curl -H "Authorization: Bearer ${{ secrets.MY_TOKEN }}" ...
```

**Secrets 在日志里会被自动打码**，但这不是万无一失的——如果你把它做了 base64 编码再打印，GitHub 就认不出来了。别主动往日志里输出密钥。

**`GITHUB_TOKEN` 是自动提供的。** 每次运行 GitHub 都会生成一个临时 token，能操作当前仓库，用完即失效。给仓库自己提交、发 Release、推包，用它就够了，不需要自己建 token。

配套的是 `permissions`，用来收紧这个 token 的权限：

```yaml
jobs:
  stale:
    runs-on: ubuntu-latest
    permissions:
      issues: write
      pull-requests: write
    steps:
      - uses: actions/stale@v10
```

**写了 `permissions` 之后，没列出来的权限一律变成 `none`。** 这是好事——最小权限原则。完全不需要 token 的工作流可以直接写 `permissions: {}` 全部关掉。

## job 之间的关系

**默认全部并行。** 想串起来用 `needs`：

```yaml
jobs:
  job1:
    runs-on: ubuntu-latest
    outputs:
      output_1: ${{ steps.gen_output.outputs.output_1 }}
    steps:
      - name: Generate output
        id: gen_output
        run: |
          echo "output_1=hello" >> "$GITHUB_OUTPUT"
  job2:
    runs-on: ubuntu-latest
    needs: [job1]
    steps:
      - run: echo '${{ needs.job1.outputs.output_1 }}'
```

`needs: [job1]` 表示等 job1 成功了再跑。job 之间传值靠 `outputs`，而在 step 里设置输出的方式是**往 `$GITHUB_OUTPUT` 这个文件追加 `键=值`**，不是设置环境变量。

## 矩阵：一次跑多种组合

同一套测试要在多个版本、多个操作系统上跑，用 `matrix` 自动展开：

```yaml
jobs:
  example_matrix:
    strategy:
      max-parallel: 2
      matrix:
        version: [10, 12, 14]
        os: [ubuntu-latest, windows-latest]
```

这会生成 3 × 2 = 6 个 job。`max-parallel` 限制同时跑几个，不写就是能跑多少跑多少。

矩阵是 Actions 性价比最高的功能之一——测多版本兼容性，不用复制粘贴六份配置。

## 并发控制

同一个分支被连续推了三次，默认会跑三遍，浪费额度还可能互相干扰。`concurrency` 可以让新的顶掉旧的：

```yaml
jobs:
  job-1:
    runs-on: ubuntu-latest
    concurrency:
      group: example-group
      cancel-in-progress: true
```

同一个 `group` 里只允许一个在跑，`cancel-in-progress: true` 表示新任务来了就取消正在跑的那个。CI 类工作流建议加上；**部署类的要谨慎**，中途取消部署可能留下半吊子状态。

## 一个真实例子

本仓库自己就有一个，`.github/workflows/notify-blog.yml`，作用是笔记更新后通知博客仓库重建：

```yaml
name: 通知博客重建

on:
  push:
    branches: [main]
    paths:
      - '计算机/**'
      - '附件/**'

permissions: {}

jobs:
  notify:
    runs-on: ubuntu-latest
    steps:
      - name: 触发 vimself.github.io 重建
        run: |
          curl -sS -f -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${{ secrets.BLOG_DISPATCH_TOKEN }}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            https://api.github.com/repos/vimself/vimself.github.io/dispatches \
            -d '{"event_type":"notes-updated","client_payload":{"sha":"${{ github.sha }}"}}'
```

这个例子里：它用 `paths` 过滤，只有正式笔记和附件变了才触发，改草稿不会白跑一次；它没有 `uses: actions/checkout`，因为这个任务根本不需要代码，只是发个 HTTP 请求；`permissions: {}` 把 `GITHUB_TOKEN` 权限全关了，因为它用的是另一个仓库的专用 token；调用的是跨仓库触发接口（`dispatches`），这属于 [[GitHub 自动化接口]] 的范畴。

## 常见坑

**忘了 checkout。** 前面说过，最高频的错误。

**以为 job 之间共享文件。** 每个 job 一台新机器。传文件用 `actions/upload-artifact` / `download-artifact`，传小数据用 job outputs。

**在 fork 的 PR 上拿不到 secrets。** 出于安全考虑，来自 fork 的 PR 默认无法访问仓库密钥——否则任何人提个 PR 就能把你的密钥打印出来。需要密钥的部署流程不能挂在 `pull_request` 事件上。

**YAML 缩进错误。** Actions 的报错有时候很不直观，一个缩进错了可能提示得很远。改完先在编辑器里过一下 YAML 校验。

**忘了这是要花钱的。** 私有仓库有免费分钟数额度，超了按量计费。矩阵一开就是六倍消耗，`macos` runner 的单价比 `ubuntu` 高不少。

## 参考
- 工作流语法完整参考：https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
- 官方起步文档：https://docs.github.com/en/actions/get-started/quickstart
- 用 Actions 把国外 Docker 镜像转存到国内仓库的现成方案：https://github.com/tech-shrimp/docker_image_pusher
