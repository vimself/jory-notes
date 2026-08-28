---
tags: [类型/实践, 技术/GitHub]
aliases: [Dependabot, code scanning, 代码扫描, CodeQL, secret scanning, 密钥扫描, 依赖更新, 供应链安全, SARIF, 安全告警]
created: 2026-08-28
updated: 2026-08-28
---
> GitHub 内置了三道自动安全检查：Dependabot 盯依赖有没有已知漏洞、code scanning 用 CodeQL 扫你自己写的代码、secret scanning 找误提交的密钥。

## 三者分工

新手容易把它们混成一团，其实各管一块，界线很清楚：

| 功能 | 检查对象 | 典型发现 |
| --- | --- | --- |
| Dependabot | **你用的第三方依赖** | 用的某个库版本有已知 CVE |
| Code scanning | **你自己写的代码** | SQL 注入、路径穿越这类漏洞模式 |
| Secret scanning | **仓库里的字符串** | 误提交的 API key、token |

这三者查的是完全不同的东西，配置和处理方式也不一样，别混着看。

## Dependabot：盯住依赖

现代项目的依赖动辄几百个，每个依赖还有自己的依赖。某个深层依赖爆出漏洞时，你通常根本不知道自己用了它。

Dependabot 做两件事：

**安全更新** —— 你的某个依赖被披露漏洞时，自动提一个 PR 把它升到修复版本。这个功能开启后基本不用管。

**版本更新** —— 按你设定的节奏，把依赖升到最新版，不管有没有漏洞。这个需要配置文件。

### 配置文件

文件路径固定是 **`.github/dependabot.yml`**，顶层 `version` 必须是 **`2`**：

```yaml
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "daily"

  - package-ecosystem: "docker"
    directory: "/"
    schedule:
      interval: "weekly"
```

三个必填项：

- **`package-ecosystem`** —— 包管理器类型（`npm`、`pip`、`docker`、`gomod`、`maven`……）
- **`directory`** —— 依赖清单文件所在目录（也可以用 `directories` 配多个）
- **`schedule.interval`** —— 检查频率

常用的可选项：

- **`open-pull-requests-limit`** —— 最多同时开几个更新 PR。**不设的话很容易被 PR 淹没**，这是最该先配的一项
- **`groups`** —— 把多个更新合并成一个 PR，大幅减少噪音
- **`ignore`** —— 排除某些依赖不更新
- **`allow`** —— 反过来，只更新指定的依赖
- **`assignees`** / `labels` / `milestone` —— 给自动生成的 PR 打标记
- **`commit-message`** —— 自定义提交信息格式
- **`cooldown`** —— 新版本发布后先晾一段时间再考虑，避开刚发布就撤回的版本

顶层还有个 `registries`，用来配置私有源的访问凭据。

### 实践

**`groups` 和 `open-pull-requests-limit` 几乎是必配的。** 一个中等规模的前端项目，不加限制的话每周能收到二三十个 Dependabot PR，最后的结果是所有人都开始无视它——包括真正重要的安全更新。

**自动合并要谨慎。** 有人会配 CI 通过就自动合 Dependabot PR。补丁版本这样做还行，主版本升级往往有破坏性改动，自动合进去可能直接搞挂生产。

## Code scanning：扫自己的代码

Dependabot 管不到你自己写的逻辑。code scanning 就是干这个的——**分析仓库里的代码，找出安全漏洞和代码错误**，可以定时跑，也可以由推送等仓库事件触发。发现问题后会在仓库里生成一条告警（alert），修好之后可以关闭。

**CodeQL 是 GitHub 自研的代码分析引擎**，用来自动执行这些安全检查，是 code scanning 的默认引擎。它的思路是把代码当成数据库来查询，用查询语句描述漏洞模式（比如「用户输入未经过滤就流进了 SQL 拼接」），因此能发现跨函数、跨文件的问题，比单纯的正则匹配强很多。

启用方式有两种：

**默认设置（default setup）** —— 界面上点几下就开，GitHub 自动帮你配好。绝大多数项目用这个就够。

**高级设置（advanced setup）** —— 自己写 workflow 文件，能精细控制扫描范围、语言、查询集。它还能接入**第三方工具**——只要那个工具能输出 **SARIF** 格式（一种静态分析结果的通用交换格式），结果就能汇总到 GitHub 的告警界面里。

**先用默认设置。** 需要接第三方扫描器或者要定制查询时再转高级设置。

## Secret scanning：找误提交的密钥

密钥进了 Git 历史是个很麻烦的事：[[Git 三个区]] 里说过，`.gitignore` 对已跟踪文件无效；而 Git 历史不可变，光在新提交里删掉文件，旧提交里那份还在，任何人都能翻出来。

Secret scanning 会扫描仓库内容，识别出符合已知密钥格式的字符串（各家云服务的 token 都有特征模式），发现后告警。GitHub 还和不少服务商有合作，能直接通知服务商吊销泄露的凭据。

**发现密钥泄露的正确处理顺序是：先吊销，再清理。**

很多人第一反应是赶紧改提交、清历史。但**清理历史需要时间，而泄露的密钥在这段时间里一直是有效的**——尤其是已经推到公开仓库的，几分钟内就可能被自动化程序扫走。所以第一件事永远是去服务商后台把那个 key 作废，让它立刻失效。之后再从容处理历史。

## 从哪开始

对个人项目，性价比顺序大致是：

1. **开 Dependabot 安全更新** —— 零配置，收益最直接
2. **开 secret scanning** —— 零配置，防的是最严重的事故
3. **开 code scanning 默认设置** —— 点几下，之后基本不用管
4. **配 `dependabot.yml` 做版本更新** —— 记得同时配 `groups` 和数量上限

这些功能在公开仓库上一般是免费的，私有仓库的可用范围取决于套餐。

## 参考
- Dependabot 配置项完整参考：https://docs.github.com/en/code-security/dependabot/working-with-dependabot/dependabot-options-reference
- 代码扫描介绍：https://docs.github.com/en/code-security/code-scanning/introduction-to-code-scanning/about-code-scanning

## 待补充
- 各套餐下三项功能在私有仓库的可用性差异（随政策变动，用前查当期文档）
- 用 `git filter-repo` 从历史中彻底清除已泄露密钥的完整流程
- CodeQL 自定义查询的编写入门
