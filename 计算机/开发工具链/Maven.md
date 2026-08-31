---
tags: [类型/概念, 技术/Maven, 技术/Java]
aliases: [Apache Maven, mvn, pom.xml, POM, Maven 坐标, GAV, Maven 依赖管理, Maven 生命周期, Maven scope, 依赖冲突, dependencyManagement, 构建工具]
created: 2026-08-31
updated: 2026-08-31
---
> Maven 把「项目长什么样、怎么构建、jar 包从哪来」这三件本来每个 Java 项目各搞一套的事，统一成了一套全世界通用的约定——你只写一个 `pom.xml`，剩下的它按规矩办。

## 没有 Maven 的时候有多疼

假设你要写一个读 Excel 的小程序，决定用 Apache POI 这个库。手动来的话，流程是这样的：

1. 去官网找下载页，挑一个版本，下一个 `poi-x.y.z.jar`
2. 放进项目的 `lib/` 目录，在 IDE 里手动加进 classpath
3. 跑一下，抛 `NoClassDefFoundError`，说某个类找不到
4. 才发现 POI 自己还依赖别的库，回去再下一个 jar
5. 重复第 3、4 步五六次，直到不报错为止
6. 同事 clone 你的项目，`lib/` 因为太大被 `.gitignore` 了，他从第 1 步重来一遍

最后你的项目里躺着十几个来路不明的 jar，没人说得清哪个是哪个的依赖、能不能升级、升了会不会炸。

Maven 让上面整件事变成往 `pom.xml` 里加五行：

```xml
<dependency>
  <groupId>org.apache.poi</groupId>
  <artifactId>poi</artifactId>
  <version>在 Maven Central 上查到的版本号</version>
</dependency>
```

POI 自己依赖的那些库会跟着一起下来，因为 POI 的作者在**它的** `pom.xml` 里声明过。这个「依赖会传染」的性质叫**传递依赖**，是 Maven 最省事的地方，后面细讲。

## Maven 替你做的三件事

| 它统一了什么 | 具体是什么 | 你因此不用做什么 |
| --- | --- | --- |
| 项目结构 | 源码放 `src/main/java`，测试放 `src/test/java`，全世界一个样 | 不用跟每个项目重新约定「代码放哪」 |
| 构建流程 | 编译、测试、打包、安装是一条固定顺序的流水线 | 不用手写编译和打包脚本 |
| 依赖管理 | 写下坐标，自动从远程仓库下载，连同它的依赖 | 不用手动下 jar、手动解决依赖的依赖 |

这三件事背后是同一个设计思想：**约定优于配置**。Maven 假定你会把源码放在 `src/main/java`，所以你什么都不用配；只有当你偏离约定时，才需要写配置去说明。代价是自由度低，回报是任何一个 Java 程序员 clone 下你的项目，`mvn package` 一敲就能构建。

## 坐标：一个库的身份证

Maven 用三个值唯一定位一个 jar 包，合称 **GAV**：

```xml
<groupId>com.mycompany.app</groupId>   <!-- 谁做的：组织，通常是倒写的域名 -->
<artifactId>my-app</artifactId>        <!-- 是什么：这个组织下的具体项目 -->
<version>1</version>                   <!-- 哪一版 -->
```

**`groupId` 用倒写域名是为了防重名**：全世界都可能有人写一个叫 `core` 的库，但 `org.apache.poi:core` 和 `com.mycompany:core` 不会撞车。这跟 Java 包名倒写域名是同一个理由。

坐标既用来**找别人的**库，也是**你自己**项目的身份。你的 `pom.xml` 顶上那三行 GAV，就是别人将来引用你时要写的坐标。

带 `-SNAPSHOT` 后缀的版本（比如 `1.0-SNAPSHOT`）表示**开发中的不稳定版**。Maven 对它的处理和正式版不同：正式版下载一次就永久缓存，SNAPSHOT 会定期重新拉取，因为它随时会变。

### jar 包实际存在哪

第一次构建时 Maven 从**远程仓库**下载，默认是 Maven Central。下完之后存进**本地仓库**，默认位置是 `${user.home}/.m2/repository`，也就是你主目录下的 `.m2/repository`。

之后所有项目共用这一份本地仓库。所以第二个项目再用同一个版本的 POI 就不会重新下载了——这也解释了为什么你第一次 `mvn` 会刷屏下载几分钟，之后就快了。

本地仓库位置能在 `settings.xml` 里改，路径必须是绝对路径：

```xml
<settings>
  <localRepository>${user.home}/.m2/repository</localRepository>
</settings>
```

## 标准目录结构

```text
my-app
├── pom.xml
└── src
    ├── main
    │   ├── java          业务代码
    │   └── resources     配置文件，会被打进 jar 的根目录
    └── test
        ├── java          测试代码，不会打进 jar
        └── resources     只在测试时可见的配置
```

两个容易忽略的点：

**`src/main/resources` 里的文件会原样打进 jar 的根目录，目录层级保留。** 所以 `src/main/resources/db.properties` 在程序里就是用 `db.properties` 这个路径读，不带 `src/main/resources` 前缀。这是初学时最常踩的「配置文件读不到」的原因。

**`src/test/` 下的东西不会进最终产物。** 测试代码和测试用的配置只在构建期间存在，打出来的 jar 里没有它们。

## POM：最小可用的样子

POM 是 Project Object Model 的缩写，`pom.xml` 就是这个模型的落地文件——它描述「这个项目是什么、依赖谁、怎么构建」。

最小的一个 POM 只需要四个元素：

```xml
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>

  <groupId>com.mycompany.app</groupId>
  <artifactId>my-app</artifactId>
  <version>1</version>
</project>
```

`modelVersion` 固定写 `4.0.0`，它说的是「这个 POM 文件本身用的是哪个版本的格式」，跟你的项目版本无关。剩下三个就是这个项目自己的坐标。没写的东西 Maven 全用默认值，比如打包类型默认是 `jar`。

## 构建生命周期

这是 Maven 里最值得搞清楚的机制，也是命令行为看起来「不讲道理」的根源。

### 三套生命周期

Maven 内置三套互相独立的生命周期：

| 生命周期 | 干什么 | 主要阶段 |
| --- | --- | --- |
| `clean` | 清理上次构建的产物 | `clean` |
| `default` | 真正的构建 | `validate` → `compile` → `test` → `package` → `verify` → `install` → `deploy` |
| `site` | 生成项目文档站点 | `site`、`site-deploy` |

它们是**平行**的三套，不是一条长流水线。`mvn clean package` 是「先跑 clean 生命周期，再跑 default 生命周期」，这也是为什么这两个词天天一起出现。

### 阶段会带着前面的一起跑

**这是最关键的一条规则：执行某个阶段时，它之前的所有阶段会按顺序先执行一遍。**

所以 `mvn package` 实际发生的是 `validate` → `compile` → `test` → `package`。这解释了新手最常见的困惑：**「我只是想打个包，为什么它跑测试了，还因为测试失败构建失败了？」** 因为 `test` 排在 `package` 前面，跑不过就轮不到打包。

`default` 生命周期里几个阶段的实际含义：

| 阶段 | 做什么 | 产物在哪 |
| --- | --- | --- |
| `compile` | 编译主代码 | `target/` 下 |
| `test` | 跑单元测试 | 测试报告在 `target/` 下 |
| `package` | 打成 jar / war | `target/` 下 |
| `verify` | 跑集成测试等验证 | — |
| `install` | 装进**本地**仓库 `~/.m2/repository` | 供你自己其他项目引用 |
| `deploy` | 传到**远程**仓库 | 供别人引用 |

`install` 和 `deploy` 的区别值得记牢：**`install` 只影响你这台机器，`deploy` 是发布给全世界（或全公司）。** 想把构件发到 GitHub 上，走的就是 `deploy`，见 [[GitHub Packages]]。

### 阶段（phase）和目标（goal）

阶段本身**不干活**，它只是流水线上的一个工位。真正干活的是**插件目标**（goal）——插件里的一个具体功能。

「编译」这件事是 `maven-compiler-plugin` 这个插件的 `compile` 目标做的，它默认**绑定**在 `compile` 阶段上。你敲 `mvn compile`，Maven 走到 `compile` 这个工位，看见上面挂着 compiler 插件的 `compile` 目标，就执行它。

所以 Maven 的构建能力全部来自插件，生命周期只提供「什么时候执行」的时间表。

你也可以绕过阶段直接点名一个目标，格式是 `插件:目标`：

```bash
mvn dependency:tree      # 直接执行 dependency 插件的 tree 目标
```

这条命令不触发任何生命周期阶段，所以它不编译、不测试，跑得很快。

### 把自己的插件挂上去

用 `<executions>` 把一个目标绑定到指定阶段：

```xml
<build>
  <plugins>
    <plugin>
      <artifactId>maven-myquery-plugin</artifactId>
      <version>1.0</version>
      <executions>
        <execution>
          <id>execution1</id>
          <phase>install</phase>
          <goals>
            <goal>query</goal>
          </goals>
        </execution>
      </executions>
    </plugin>
  </plugins>
</build>
```

这段的意思是：跑到 `install` 阶段时，顺便执行一次这个插件的 `query` 目标。

## 依赖管理

### scope：这个依赖什么时候需要

`<scope>` 控制依赖出现在哪些 classpath 上，以及它会不会传递给下游。一共六个值：

| scope | 编译期 | 运行期 | 测试期 | 会传递给下游吗 | 典型用途 |
| --- | --- | --- | --- | --- | --- |
| `compile`（默认） | ✅ | ✅ | ✅ | ✅ | 绝大多数库 |
| `provided` | ✅ | ❌ | ✅ | ❌ | 容器或 JDK 会提供，比如 Servlet API |
| `runtime` | ❌ | ✅ | ✅ | ✅ | 只在运行时需要，比如 JDBC 驱动 |
| `test` | ❌ | ❌ | ✅ | ❌ | JUnit 这类测试库 |
| `system` | ✅ | ❌ | ✅ | ❌ | 指向本地文件的 jar，不推荐 |
| `import` | — | — | — | — | 只用在 `dependencyManagement` 里导入别的 POM |

**`provided` 和 `runtime` 的区别值得单独理解：**

- `provided`「编译时要，运行时别打进去」——Servlet API 就是这样，编译你的 Servlet 需要它，但 Tomcat 自己带了一份，你再打一份进 war 包会冲突
- `runtime`「编译时不要，运行时要」——JDBC 驱动就是这样，你的代码只写 `java.sql` 的接口，从不 import MySQL 驱动的类，但运行时没有驱动就连不上库

### 传递依赖和它的 scope

你依赖 A，A 依赖 B，那 B 也会进你的 classpath。但 **B 最终的 scope 由两段共同决定**：

- A 是 `compile`、B 是 `runtime` → B 在你这里是 `runtime`
- A 是 `compile`、B 是 `provided` → **B 直接被丢掉**，不会传给你

第二条是 `provided` 不传递的具体表现，它解释了为什么有些库你必须自己再声明一遍——上游用 `provided` 引的东西，Maven 认为「你的运行环境自己会提供」，不替你带。

### 冲突了听谁的

同一个库出现两个版本时，Maven 的仲裁规则是**最短路径优先**（nearest definition wins）：**在依赖树上离你的项目最近的那个版本胜出。**

```text
你的项目
├── A → C 1.0        深度 2
└── B → D → C 2.0    深度 3
```

这里 C **1.0** 胜出，因为它离根更近。注意胜出的是**距离近的**，不是**版本高的**——所以你完全可能被一个老版本悄悄降级，这是「明明依赖里写了新版却报 `NoSuchMethodError`」的常见成因。

两条路径深度相同时，**POM 里先声明的那个赢**。

**在自己的 `pom.xml` 里直接声明版本，一定会胜出**，因为直接声明的深度是 1，没有比这更近的了。这也是解决冲突最直接的手段。

### 排除和锁版本

**排除**某个传递依赖，用 `<exclusions>`：

```xml
<dependency>
  <groupId>sample.ProjectB</groupId>
  <artifactId>Project-B</artifactId>
  <version>1.0-SNAPSHOT</version>
  <exclusions>
    <exclusion>
      <groupId>sample.ProjectD</groupId>
      <artifactId>Project-D</artifactId>
    </exclusion>
  </exclusions>
</dependency>
```

`<exclusion>` 里只写 `groupId` 和 `artifactId`，**不写版本**——你排的是这个库本身，不是某个版本。

**统一锁版本**，用 `<dependencyManagement>`：

```xml
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>com.example</groupId>
      <artifactId>D</artifactId>
      <version>2.0</version>
    </dependency>
  </dependencies>
</dependencyManagement>
```

这一段**只声明版本，不引入依赖**。它的作用是：无论 D 从哪条路径被传递进来、原本是什么版本，一律用 2.0。真正要用 D 时，你仍然要在 `<dependencies>` 里写一条，但那里可以省略 `<version>`。

这是多模块项目的标准做法：父 POM 用 `dependencyManagement` 定死所有版本，子模块只写 GA 不写 V，全项目版本天然一致。

## 排查依赖问题

依赖出问题时，第一条命令永远是看依赖树：

```bash
mvn dependency:tree
```

输出长这样，缩进就是依赖深度：

```text
[INFO] test:relocation-test:jar:1.0-SNAPSHOT
[INFO] +- org.apache.ant:ant:jar:1.7.0:compile
[INFO] |  \- org.apache.ant:ant-launcher:jar:1.7.0:compile
[INFO] \- org.apache.poi:poi:jar:3.0-FINAL:compile
[INFO]    +- commons-logging:commons-logging:jar:1.1:compile
[INFO]    \- log4j:log4j:jar:1.2.13:compile
```

每一行是 `groupId:artifactId:类型:版本:scope`。想知道某个 jar 为什么会在你的项目里，在这棵树上往上找它的父节点就行。

依赖的安全性问题（已知漏洞、自动升级）见 [[GitHub 供应链安全]]。

## 常用命令

```bash
mvn clean                  # 删掉 target/
mvn compile                # 编译主代码
mvn test                   # 编译并跑测试
mvn package                # 打包，会先跑测试
mvn install                # 打包并装进本地仓库
mvn clean package          # 最常用：先清理再打包
mvn dependency:tree        # 看依赖树
```

## 参考
- [Introduction to the Build Lifecycle](https://maven.apache.org/guides/introduction/introduction-to-the-lifecycle.html)
- [Introduction to the Dependency Mechanism](https://maven.apache.org/guides/introduction/introduction-to-dependency-mechanism.html)
- [Introduction to the POM](https://maven.apache.org/guides/introduction/introduction-to-the-pom.html)
- [Maven Getting Started Guide](https://maven.apache.org/guides/getting-started/index.html)
