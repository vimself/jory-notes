---
tags: [类型/实践, 技术/GitHub]
aliases: [GitHub Packages, ghcr.io, Container registry, 容器镜像仓库, 私有制品库, npm registry, 包管理, 制品仓库]
created: 2026-08-28
updated: 2026-08-28
---
> GitHub Packages 是挂在 GitHub 账号下的软件包仓库，让你把 Docker 镜像、npm 包、Maven 构件这些**构建产物**和代码放在同一个平台上，共用一套权限。

## 它解决什么问题

代码在 GitHub，构建产物却要另找地方放：Docker 镜像推 Docker Hub，npm 包发 npm 官方源，Java 构件传 Nexus。于是你要维护好几套账号、好几套权限、好几个密钥。

GitHub Packages 把这些收拢到一起：**产物跟着仓库走，权限跟着仓库的权限走**。谁能读这个仓库，谁就能拉这个包。

对私有项目尤其省事——不用为了发一个内部 npm 包去搭私有 registry。

## 支持哪些包类型

| registry | 用于 |
| --- | --- |
| Container registry | Docker / OCI 镜像 |
| npm | JavaScript |
| RubyGems | Ruby |
| Apache Maven | Java |
| Gradle | Java |
| NuGet | .NET |

其中最常用的是 **Container registry**，因为容器镜像几乎是所有部署方式的公共底座。

## 容器镜像：最常用的那个

Container registry 的域名是 **`ghcr.io`**。

**登录：**

```bash
echo $CR_PAT | docker login ghcr.io -u USERNAME --password-stdin
```

`$CR_PAT` 是你的 personal access token（classic）。用 `--password-stdin` 而不是把 token 直接写在命令里，避免它进入 shell 历史记录。

**推送：**

```bash
docker push ghcr.io/NAMESPACE/IMAGE_NAME:latest
```

`NAMESPACE` 是你的账号名或组织名。所以完整镜像名类似 `ghcr.io/vimself/my-app:latest`。

**需要的 token 权限**（classic token 的 scope）：

- `read:packages` —— 下载镜像、读取元数据
- `write:packages` —— 上传（同时隐含下载权限）
- `delete:packages` —— 删除镜像

## 认证方式

这里有个容易卡住的地方：**GitHub Packages 只支持用 personal access token (classic) 认证**，用你的 GitHub 登录密码是不行的。

但在 [[GitHub Actions]] 里是例外，也是推荐做法：**直接用自动提供的 `GITHUB_TOKEN`**，配上相应的 `permissions` 即可，不需要你手动创建和保管任何 token。官方对自动化场景明确推荐这种方式而不是 PAT。

大致形态：

```yaml
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v7
      # 登录 ghcr.io，用 GITHUB_TOKEN
      # 构建并推送镜像
```

`packages: write` 这个权限是关键，不给的话推送会 403。

## 用之前想清楚的

**公开包和私有包的可见性跟仓库关联**，但可以单独调整。私有包会占用套餐的存储和流量配额，公开包通常不占。

**国内拉取 `ghcr.io` 的速度**和拉 Docker Hub 一样受网络环境影响。CI 在 GitHub 的 runner 上跑没问题（同一个网络内），但部署到国内服务器时可能很慢，需要走镜像加速或者转存到国内仓库——[[GitHub Actions]] 参考里那个把国外镜像转存到阿里云的方案就是干这个的。

**删包要谨慎。** 已经被生产环境引用的镜像标签删掉，会导致重新拉取时直接失败。

**它不是万能替代品。** 面向公众分发的开源 npm 包，用户还是习惯从 npm 官方源装；发到 GitHub Packages 需要用户额外配置 registry 地址，会劝退一部分人。**GitHub Packages 最适合的是内部包和容器镜像**，公开分发的库还是发到各语言的官方源。

## 参考
- GitHub Packages 介绍：https://docs.github.com/en/packages/learn-github-packages/introduction-to-github-packages
- 容器仓库用法：https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry

## 待补充
- 各套餐下 Packages 的存储与流量配额数字（随政策变动，用前查当期文档）
- 用 fine-grained token（而非 classic）访问 Packages 的当前支持情况
- npm / Maven registry 的具体域名与配置文件写法（本篇未实测）
