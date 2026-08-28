---
tags: [类型/实践, 技术/GitHub]
aliases: [GitHub Pages, 静态网站托管, 个人站点, 项目站点, user site, project site, gh-pages, 免费建站, Jekyll]
created: 2026-08-28
updated: 2026-08-28
---
> GitHub Pages 把仓库里的静态文件直接托管成一个公开网站，免费、带 HTTPS，适合放个人博客、项目文档和作品集。

## 它是什么

给一个仓库开启 Pages 之后，GitHub 会把里面的 HTML/CSS/JS 发布到一个公网地址上。**只能放静态内容**——没有后端、没有数据库、不能跑 PHP 或 Node 服务。

这个限制没有听上去那么大。博客、文档站、简历、前端 demo，本来就都是静态的。需要动态数据的话，前端调用别人的 API 也行。

## 两种站点，先分清

这是配置前必须搞清楚的第一件事，因为**仓库名的要求完全不同**。

**用户/组织站点** —— 代表你这个账号的主站。

- 仓库名**必须**是 `<你的用户名>.github.io`，一个字都不能差
- 网址是 `https://<你的用户名>.github.io`
- **每个账号只能有一个**

**项目站点** —— 挂在某个具体项目下的站。

- 仓库名随便起
- 网址是 `https://<你的用户名>.github.io/<仓库名>`
- 每个仓库可以有一个

举例：账号 `vimself` 建一个叫 `vimself.github.io` 的仓库，访问 `https://vimself.github.io`；同一个账号下的 `jory-notes` 仓库开 Pages，访问 `https://vimself.github.io/jory-notes`。

**项目站点最常见的坑是路径。** 它的网站根目录是 `/<仓库名>/` 而不是 `/`。页面里写 `/style.css` 这种绝对路径会 404，因为实际地址是 `/仓库名/style.css`。用相对路径，或者在构建工具里配好 base path（Vite 的 `base`、Next.js 的 `basePath` 之类）。

## 两种发布方式

**方式一：从分支发布。**

在仓库设置里指定一个分支，以及该分支上的哪个文件夹。文件夹只有两个选项：**仓库根目录（`/`）或者 `/docs` 文件夹**。

选定之后，每次往这个分支推东西，选中文件夹里的内容就会自动发布。

这种方式最省事，适合：手写的纯 HTML；或者用 Jekyll（GitHub Pages 原生支持它，会自动构建）；或者你在本地构建好、把产物提交进仓库。

历史上大家习惯用一个叫 `gh-pages` 的分支专门存构建产物，现在源分支可以是任意分支，不再有这个硬性要求。

**方式二：用 GitHub Actions 自定义构建。**

适合用了 Jekyll 以外的工具（Hugo、VitePress、Astro、Next.js 静态导出……），或者不想让编译产物污染仓库。

官方推荐的流程是：

1. 在推送到默认分支或手动触发时运行
2. 用 `actions/checkout` 检出代码
3. 跑你的构建命令生成静态文件
4. 用 `actions/upload-pages-artifact` 上传构建产物
5. 用 `actions/deploy-pages` 部署（PR 场景下跳过这步）

GitHub 明确建议：**当你想用 Jekyll 之外的构建流程、或者不想专门留一个分支存编译产物时，就用 Actions 这种方式。**

这个流程会用到一个叫 **`github-pages` 的部署环境**，不存在的话会自动创建。也就是说它天然接入了 [[GitHub Actions 多环境部署]] 讲的那套环境机制，你可以给它加保护规则。

## 一些实践

**自定义域名**：仓库设置里填域名，同时在你的 DNS 服务商那边加解析记录。GitHub 会在仓库根目录生成一个 `CNAME` 文件记录这个域名——**别手动删它**，删了域名就失效。

**HTTPS 默认开启**，包括自定义域名，证书由 GitHub 自动签发和续期，不用管。

**`.nojekyll` 文件**：GitHub Pages 默认用 Jekyll 处理文件，而 Jekyll 会**跳过以 `_`、`.`、`#` 开头的文件和目录**（还有 `/node_modules`、`/vendor`、以 `~` 结尾的文件）。用现代前端框架构建的站点产物里经常有 `_next`、`_assets` 这类目录，于是资源整批丢失，线上白屏或样式全无——而本地预览一切正常，现象非常迷惑。

解决办法是在**发布源的根目录**放一个空的 `.nojekyll` 文件，它会完全绕过 Jekyll 构建，源文件原样发布。只有站点用到下划线开头的文件或目录时才需要它。

**部署有延迟**，推完之后通常等几十秒到几分钟才生效，看到旧内容先别急着改，也记得强制刷新绕开浏览器缓存。

**别放敏感信息。** 公开仓库的 Pages 是完全公开的，而且历史提交里的东西也能被翻出来。任何密钥都不要进仓库。

## 参考
- Pages 是什么：https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages
- 配置发布源：https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site
- 绕过 Jekyll：https://github.blog/news-insights/bypassing-jekyll-on-github-pages/
- Pages 与 Jekyll：https://docs.github.com/en/pages/setting-up-a-github-pages-site-with-jekyll/about-github-pages-and-jekyll

## 待补充
- 免费套餐下 Pages 的站点大小与月流量软限制（数字随政策变动，用前查当期文档）
- 私有仓库使用 Pages 的套餐要求
