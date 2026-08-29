---
tags: [类型/实践, 技术/GitHub, 技术/CI-CD]
aliases: [GitHub Environments, deployment environment, 部署环境, 环境保护规则, required reviewers, 环境密钥, environment secrets, 审批部署, 灰度发布]
created: 2026-08-28
updated: 2026-08-28
---
> GitHub 的 Environment 是给部署目标（测试环境、预发、生产）加的一道门禁：把密钥绑在环境上，并要求满足保护规则（比如指定的人点了批准）之后，job 才能开始跑、才能拿到那些密钥。

先读 [[GitHub Actions]]，本篇假设你已经知道 workflow / job / step 和 secrets 是什么。

## 为什么需要环境这个东西

一套代码通常要部署到好几个地方：开发环境随便推、测试环境给 QA、生产环境面向真实用户。它们的差别在两处：

**用的密钥不一样。** 测试环境连测试数据库，生产环境连生产数据库。把两套密钥都放在仓库级 secrets 里，任何一个 workflow 都能读到全部——一个本该只发测试环境的任务，代码写错了就可能把生产库刷掉。

**风险等级不一样。** 部署到测试环境错了就重来，部署到生产环境错了就是事故。生产部署应该有人看一眼再放行，而不是谁推个代码就自动上线。

Environment 同时解决这两点：**密钥按环境隔离**，**部署前可以卡审批**。

## 最小用法

在仓库设置里创建环境（比如 `production`），然后在 job 上声明：

```yaml
jobs:
  JOB-ID:
    environment: ENVIRONMENT-NAME
```

就这一行。声明之后这个 job 才能读到该环境的密钥，也才会受该环境保护规则的约束。

一个具体些的样子：

```yaml
jobs:
  deploy-staging:
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - uses: actions/checkout@v7
      - run: ./deploy.sh
        env:
          DB_URL: ${{ secrets.DB_URL }}

  deploy-production:
    runs-on: ubuntu-latest
    needs: [deploy-staging]
    environment: production
    steps:
      - uses: actions/checkout@v7
      - run: ./deploy.sh
        env:
          DB_URL: ${{ secrets.DB_URL }}
```

两个 job 里 `secrets.DB_URL` 的写法完全一样，**取到的值却不同**——各自读的是自己那个环境下配置的值。这是环境机制最舒服的地方：部署脚本不用关心自己在往哪个环境发。

`needs: [deploy-staging]` 保证了顺序：测试环境部署成功，才轮到生产。

## 环境密钥和仓库密钥的区别

**仓库密钥**：所有 workflow 的所有 job 都能读。

**环境密钥**：**只有声明了 `environment: 该环境` 的 job 能读**，而且要等这个环境的保护规则全部满足之后才能拿到。

官方措辞很明确：环境密钥对没有引用该环境的 job 不可见，并且在所有环境保护规则（例如指定审批人）满足之前，job 拿不到它们。

所以生产密钥应该放在 `production` 环境下，而不是仓库级。这样即使有人在别的 workflow 里写了 `${{ secrets.PROD_KEY }}`，也读不出东西来。

用命令行管理环境密钥：

```bash
gh secret set --env ENV_NAME SECRET_NAME
gh secret list --env ENV_NAME
```

## 保护规则

环境上可以挂保护规则，job 必须先满足才能执行。最常用的是**必需审批人（required reviewers）**。

配上之后，工作流跑到这个 job 会**暂停**，在 GitHub 界面上等人点批准。指定的审批人可以批准或拒绝：

- **批准** → job 继续跑，并获得环境密钥的访问权
- **拒绝** → 整个工作流失败

**环境可以配置成禁止自我批准。** 开启后，你不能批准由你自己触发的那次部署。这是为了避免「自己写自己批」让审批流于形式，团队里建议打开。

除审批外，环境通常还能配等待时间（部署前强制等 N 分钟，留出反悔窗口）和允许部署的分支限制（比如只有 `main` 能部到 `production`）。

## 怎么组织一条部署链

一个常见的形态：

```text
push 到 main
  → 跑测试（无环境）
  → 部署 staging（环境: staging，无需审批）
  → 自动化验收
  → 部署 production（环境: production，需要审批）
```

前面几步全自动，只在最后一道卡人工。这样既保住了速度，又在真正有风险的那一步留了闸。

配合分支保护还能反过来约束合并：[[Pull Request]] 里提到，分支保护支持「必须成功部署到指定环境之后才能合并」。

## 几个坑

**并发取消要小心。** [[GitHub Actions]] 里提到的 `concurrency` + `cancel-in-progress`，用在部署 job 上要谨慎。部署跑到一半被取消，可能留下升级了一半的状态，比不部署更糟。CI 可以随便取消，CD 通常不该取消。

**审批不等于安全。** 审批人看到的只是「要不要放行这次部署」，他很难逐行核对将要上线的代码。审批是流程闸门，代码质量还得靠 [[Pull Request]] 的评审和 CI。

**fork 的 PR 拿不到环境密钥。** 和仓库密钥同理，来自 fork 的 PR 默认无法访问，别把需要密钥的部署挂在 `pull_request` 事件上。

**环境名要和实际一致。** `environment: production` 里的名字必须和设置里创建的环境同名，写错了不会报「环境不存在」，而是会自动创建一个同名的新环境——没有任何保护规则的那种。这个坑很隐蔽，配好后跑一次确认审批确实被触发了。

## 参考
- 部署到环境：https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/deploy-to-environment
- 管理环境：https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments
- 审批部署：https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/review-deployments
