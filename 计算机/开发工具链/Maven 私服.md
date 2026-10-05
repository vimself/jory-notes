---
tags: [类型/实践, 技术/Maven]
aliases: [Nexus]
created: 2026-10-04
updated: 2026-10-04
---
> 私服是架在团队内网里的 Maven 仓库：它替所有人缓存中央仓库的构件，也存放团队自己发布的 jar，开发者只需要连它一个地址。最常用的实现是 Sonatype 的 Nexus Repository。

## 典型场景

团队把项目拆成了多个模块（见 [[Maven 多模块项目]]），A 组维护的 `common-utils` 要给 B 组的项目用。

A 组在自己机器上 `mvn install`，这个 jar 只进了 A 组那台机器的本地仓库，B 组的机器上没有。发到 Maven Central 也不行，那是公开仓库，公司内部代码不能放上去。剩下的办法只有把 jar 拷给 B 组，又退回到了 Maven 出现之前手动管 jar 的日子（见 [[Maven]] 开头）。

缺的是一个**只对团队开放的远程仓库**：A 组 `deploy` 上去，B 组像引用任何第三方库一样写坐标就能用。这就是私服。

它顺带还解决了另一件事：二十个人各自从中央仓库下同一批 jar，每个新人第一次构建都要等很久。有了私服，第一个人下载过的构件会缓存在私服上，后面的人直接从内网拿。

## 私服站在哪

```text
开发者 A ─┐
开发者 B ─┼──→  私服（内网）  ──→  Maven Central
CI 服务器 ─┘        │
                    └─ 团队自己发布的构件
```

所有 Maven 请求都先到私服。私服有就直接返回，没有的话，如果是中央仓库的东西就去中央仓库拉一份回来，存下再返回。

## 私服里的三种仓库

Nexus 里的仓库分三种类型：

| 类型 | 是什么 | 用来 |
| --- | --- | --- |
| **proxy**（代理仓库） | 远程仓库的缓存。请求进来先查本地缓存，没有再去远程拉 | 代理 Maven Central 等外部仓库 |
| **hosted**（宿主仓库） | 构件的正式存放地，内容由你上传 | 存放团队自己发布的构件 |
| **group**（仓库组） | 把多个仓库合并成一个，对外只暴露一个地址 | 给开发者统一的下载入口 |

Nexus 装好后自带四个 Maven 仓库，正好是这三种类型的组合：

| 仓库名 | 类型 | 存什么 |
| --- | --- | --- |
| `maven-central` | proxy | 代理 Maven Central |
| `maven-releases` | hosted | 团队发布的正式版 |
| `maven-snapshots` | hosted | 团队发布的 SNAPSHOT 版 |
| `maven-public` | group | 把上面三个合成一个 |

正式版和 SNAPSHOT 分两个仓库放，是因为两者的规矩不同：SNAPSHOT 是开发中的版本，会反复覆盖更新；正式版发出去就不该再变（SNAPSHOT 的含义见 [[Maven#坐标：一个库的身份证]]）。

分工是：**下载走 group，上传走 hosted。** 下载时你不关心构件来自中央仓库还是同事，找 `maven-public` 一个地址就够了；上传时得说清楚放进哪个具体的仓库，group 只是一个合并视图，不能往里传。

Nexus 里每个仓库的地址形如 `http://私服地址:8081/repository/仓库名/`，下文用这个格式举例，实际地址以你们私服为准。

## 下载：让 Maven 从私服拉依赖

改的是 `~/.m2/settings.xml`，不是项目的 `pom.xml`。私服地址属于「跟人和网络环境走」的配置，换个不在内网的人来构建，这个地址就没意义了。

```xml
<settings>
  <mirrors>
    <mirror>
      <id>nexus</id>
      <mirrorOf>*</mirrorOf>
      <url>http://私服地址:8081/repository/maven-public/</url>
    </mirror>
  </mirrors>
</settings>
```

**镜像**（mirror）的意思是「本来要去 A 仓库的请求，改去 B 地址」。`<mirrorOf>` 写的是被替代仓库的 id：

| `<mirrorOf>` 写法 | 拦截哪些仓库 |
| --- | --- |
| `central` | 只拦中央仓库，它的 id 就叫 `central` |
| `*` | 所有仓库 |
| `external:*` | 除了 localhost 和本地文件仓库以外的所有仓库 |
| `repo1,repo2` | 列出的几个，逗号分隔，别加空格 |
| `*,!repo1` | 除了 `repo1` 以外的所有 |

写 `*` 就是让 Maven 不管要去哪个仓库，一律找私服。**一个仓库最多只会命中一个镜像**，Maven 按声明顺序取第一个匹配的，不会把多个镜像合起来用。想合并多个来源，靠的是私服上的 group，不是多写几个镜像。

### 拉不到 SNAPSHOT 版本

只配上面的镜像，下载正式版没问题，但 B 组想用 A 组刚发的 `common-utils:1.0-SNAPSHOT` 时会拉不到。

原因在 Maven 内置的 Super POM（所有 POM 的祖先）里：它声明的 `central` 仓库关掉了 SNAPSHOT（`<snapshots><enabled>false</enabled></snapshots>`）。镜像只替换地址，不改这个开关，所以 Maven 认为这个仓库不提供 SNAPSHOT，根本不会去问。

Sonatype 官方文档给的配置是在 `settings.xml` 里再加一个始终激活的 profile，重新声明一个打开了 SNAPSHOT 的 `central`：

```xml
<settings>
  <mirrors>
    <!-- 同上 -->
  </mirrors>
  <profiles>
    <profile>
      <id>nexus</id>
      <repositories>
        <repository>
          <id>central</id>
          <url>http://central</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </repository>
      </repositories>
      <pluginRepositories>
        <pluginRepository>
          <id>central</id>
          <url>http://central</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </pluginRepository>
      </pluginRepositories>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>nexus</activeProfile>
  </activeProfiles>
</settings>
```

`http://central` 这个地址是假的，看着像写错了，其实无所谓：这个仓库的请求会被 `*` 镜像拦下，转去私服，这个 URL 永远不会被真正访问。这段配置要的只是那两个 `<enabled>true</enabled>`。profile 和 `<activeProfiles>` 的机制见 [[Maven Profile]]。

## 上传：把自己的构件发到私服

上传要配两处，分别回答「传到哪」和「用什么身份传」。

**传到哪，写在项目的 `pom.xml` 里：**

```xml
<distributionManagement>
  <repository>
    <id>nexus</id>
    <url>http://私服地址:8081/repository/maven-releases/</url>
  </repository>
  <snapshotRepository>
    <id>nexus</id>
    <url>http://私服地址:8081/repository/maven-snapshots/</url>
  </snapshotRepository>
</distributionManagement>
```

`<repository>` 收正式版，`<snapshotRepository>` 收 SNAPSHOT 版，Maven 按项目版本号是否带 `-SNAPSHOT` 自动选。没配 `<snapshotRepository>` 时，SNAPSHOT 也会传到 `<repository>`。

多模块项目把这段写在父 POM 里，所有子模块继承同一份。

**用什么身份传，写在 `settings.xml` 里：**

```xml
<settings>
  <servers>
    <server>
      <id>nexus</id>
      <username>你的私服账号</username>
      <password>你的私服密码</password>
    </server>
  </servers>
</settings>
```

两处靠 **`<id>` 对上**：`<server>` 的 `id` 要和 `<distributionManagement>` 里仓库的 `id` 一致，Maven 才知道传这个仓库时该用哪组账号密码。`<server>` 的 `id` 填的是仓库的 id，不是登录用户名。id 对不上时，Maven 会不带凭据去上传，被私服拒绝。

账号密码放 `settings.xml` 而不放 `pom.xml`，是因为 `pom.xml` 要提交进 Git，写进去就等于公开了密码。

两处都配好之后：

```bash
mvn clean deploy
```

`deploy` 是 `default` 生命周期的最后一个阶段，前面的编译、测试、打包、`install` 都会先跑一遍，最后把构件传到私服。之后 B 组在 POM 里写上 `common-utils` 的坐标，就能从 `maven-public` 拉到它。

## HTTP 地址被拦截

上面的例子用的都是 `http://`。Maven 3.8.1 起，默认配置里内置了一个 id 为 `maven-default-http-blocker` 的镜像，`<mirrorOf>` 是 `external:http:*`，作用是拦下所有走 HTTP 的外部仓库。

**localhost 不受影响**，所以在本机装 Nexus 练习时一切正常。部署到内网服务器、用 IP 或内网域名配 `http://` 地址后，构建就可能失败，报错里会出现 `maven-default-http-blocker` 和 `Blocked mirror for repositories` 字样。

根本的解法是给私服配上 HTTPS。看到这个报错，先确认私服地址是不是 HTTP。

## 和 GitHub Packages 的关系

[[GitHub Packages]] 也能当 Maven 仓库用，`distributionManagement` 和 `settings.xml` 的配法和私服是同一套。区别在于它托管在 GitHub 上，不用自己搭服务器，权限跟着 GitHub 仓库走。

## 参考
- [Nexus Repository: Repository Types](https://help.sonatype.com/en/repository-types.html)
- [Nexus Repository: Maven Repositories](https://help.sonatype.com/en/maven-repositories.html) — settings.xml 与 distributionManagement 示例
- [Using Mirrors for Repositories](https://maven.apache.org/guides/mini/guide-mirror-settings.html)
- [Settings Reference](https://maven.apache.org/settings.html) — Servers、Mirrors 两节
- [POM Reference](https://maven.apache.org/pom.html) — Distribution Management 一节
- [Maven 3.8.1 Release Notes](https://maven.apache.org/docs/3.8.1/release-notes.html)
