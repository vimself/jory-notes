---
tags: [类型/实践, 技术/Maven]
aliases: [Maven 聚合与继承]
created: 2026-10-04
updated: 2026-10-04
---
> 项目拆成多个 Maven 模块以后，靠「聚合」用一条命令把所有模块按正确顺序一起构建，靠「继承」让它们共用一份版本号和配置；这两件事通常由同一个打包类型为 `pom` 的父工程来做。

## 典型场景

[[SSM 整合]] 里那个图书管理项目，`domain`、`dao`、`service`、`controller` 四个包都挤在一个 war 工程里。现在公司要再做一个后台定时任务，每晚统计借阅数据，它要用同一套 `Book` 实体类和 `BookDao`。

能走的路只有两条：把那几个类复制一份过去，或者让定时任务依赖整个 war 包。前一种的后果是 `Book` 加个字段要改两处，迟早有一处忘了改；后一种根本走不通，war 不是给别人当依赖用的，就算硬塞进去也会把 Spring MVC、Servlet API 全拖过来。

问题的根子在于「一个工程 = 一个构件」：想复用其中一层，就只能整个拿走。解法是把工程按层拆成几个独立的 Maven 模块，每个模块有自己的坐标，各自产出一个 jar，谁要用哪层就依赖哪层。

拆完会立刻冒出两个新麻烦：

1. 四个模块要按顺序挨个 `mvn install`，顺序错了就找不到依赖
2. 四份 `pom.xml` 里重复写着同样的 Spring 版本号，升级时要改四处

**聚合**解决第 1 个，**继承**解决第 2 个。

## 怎么拆

按 [[三层架构]] 拆是最常见的做法：

| 模块 | 放什么 | 打包类型 | 依赖谁 |
| --- | --- | --- | --- |
| `ssm-domain` | 实体类 `Book` | `jar` | 无 |
| `ssm-dao` | `BookDao` 接口、MyBatis 映射 | `jar` | `ssm-domain` |
| `ssm-service` | `BookService` 及实现 | `jar` | `ssm-dao` |
| `ssm-web` | 控制器、`webapp` 静态资源 | `war` | `ssm-service` |

模块之间的依赖和引用第三方库一模一样，写坐标就行。`ssm-dao` 依赖 `ssm-domain`：

```xml
<dependency>
  <groupId>com.example</groupId>
  <artifactId>ssm-domain</artifactId>
  <version>1.0-SNAPSHOT</version>
</dependency>
```

`ssm-web` 只需要声明 `ssm-service`。`ssm-dao` 和 `ssm-domain` 会顺着 [[Maven]] 的传递依赖一路带进来，不用重复写。

拆的时候有三条规矩：

- **依赖只能单向，不能成环。** `ssm-dao` 依赖 `ssm-domain`，`ssm-domain` 就不能反过来依赖 `ssm-dao`，否则 Maven 排不出构建顺序，构建直接失败。拆出环来，通常说明有个类放错了层
- **配置文件跟着用它的模块走。** MyBatis 映射文件放 `ssm-dao` 的 `src/main/resources`，Spring MVC 的配置放 `ssm-web`。别都堆在 `ssm-web` 里，不然 `ssm-dao` 单独拿给定时任务用时会缺配置
- **拆的目标是「能被单独复用」。** 一个模块要是永远只被另一个模块用，它就没必要单独存在

### 单独构建一个模块为什么找不到兄弟模块

拆完以后，进 `ssm-web` 目录直接打包：

```bash
cd ssm-web
mvn package
```

很可能失败，说解析不了 `ssm-service`。原因是 Maven 在这个目录里只看得见 `ssm-web` 自己，它要的 `ssm-service` 只能去**本地仓库**找，而你从来没 `install` 过它，哪怕它的源码就在隔壁目录。

两种解法：

```bash
mvn install                    # 在父工程根目录跑，所有模块装进本地仓库
mvn -pl ssm-web -am package    # 在父工程根目录跑，只构建 ssm-web 和它依赖的模块
```

`-pl`（`--projects`）指定要构建哪些模块，可以写模块的相对路径或 `[groupId]:artifactId`；`-am`（`--also-make`）表示把这些模块依赖的兄弟模块也一起构建。这两条命令能用，都是靠下面要讲的聚合。

## 聚合：一条命令构建所有模块

在四个模块外面套一个父工程 `ssm-parent`：

```text
ssm-parent
├── pom.xml
├── ssm-domain
│   └── pom.xml
├── ssm-dao
│   └── pom.xml
├── ssm-service
│   └── pom.xml
└── ssm-web
    └── pom.xml
```

父工程的 `pom.xml`：

```xml
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>

  <groupId>com.example</groupId>
  <artifactId>ssm-parent</artifactId>
  <version>1.0-SNAPSHOT</version>
  <packaging>pom</packaging>

  <modules>
    <module>ssm-web</module>
    <module>ssm-service</module>
    <module>ssm-dao</module>
    <module>ssm-domain</module>
  </modules>
</project>
```

两处关键：

- **`<packaging>pom</packaging>`**：父工程自己不产出 jar 或 war，它的产物只有这份 POM。做聚合的工程打包类型必须是 `pom`，它下面也不需要 `src` 目录
- **`<module>` 写的是目录的相对路径**，不是 artifactId。模块不在子目录里时写 `../ssm-domain` 这种路径也行，还可以直接指向某个 POM 文件

这种带 `<modules>` 的工程叫**聚合工程**。在它的根目录跑任何 Maven 命令，命令会对每个模块各执行一遍。

### 模块的顺序不用你操心

上面故意把 `<modules>` 写成了倒序，`ssm-web` 排第一。构建时 Maven 照样会先构建 `ssm-domain`，最后构建 `ssm-web`。

负责这件事的叫 **Reactor**（反应堆），它是 Maven 处理多模块构建的机制，做三步：

1. 收集所有要构建的模块
2. 按模块之间的关系排出构建顺序，被依赖的排前面
3. 按这个顺序依次构建

排序依据的是**实际生效的引用关系**：模块 A 在 `<dependencies>` 里依赖了模块 B，或者把 B 当插件、插件的依赖、构建扩展来用，B 就排在 A 前面。各种关系都没有的模块之间，才按 `<modules>` 里的书写顺序来。

**`<dependencyManagement>` 和 `<pluginManagement>` 不影响排序。** 它们只声明版本，不真正引入依赖，Reactor 不把它们算作引用关系。

Reactor 构建时，模块之间直接用本次构建的产物，不经过本地仓库。这就是为什么在父工程根目录跑 `mvn package` 不需要先 `install`。

### 聚合构建常用的命令行选项

| 选项 | 作用 |
| --- | --- |
| `-pl ssm-web` | 只构建列出的模块，多个用逗号分隔 |
| `-am` | 配合 `-pl`，连同它依赖的模块一起构建 |
| `-amd` | 配合 `-pl`，连同依赖它的模块一起构建 |
| `-rf ssm-service` | 从指定模块开始继续构建，用在中途失败修好之后 |
| `-N` | 不递归进子模块，只构建当前这个工程 |

`-am` 和 `-amd` 方向相反，容易记混：改了 `ssm-dao`，想确认上层没被改坏，用 `-pl ssm-dao -amd`，会把 `ssm-service`、`ssm-web` 也带上；想单独打 `ssm-web` 的包，用 `-pl ssm-web -am`，会把它底下的三个模块先构建好。

## 继承：子模块共用一份配置

聚合只管「一起构建」，四份 POM 里重复的配置还在。继承要解决的就是这个：把公共配置写进父 POM，子模块声明「我的父亲是谁」，自动获得这些配置。

子模块 `ssm-dao` 的 POM：

```xml
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>com.example</groupId>
    <artifactId>ssm-parent</artifactId>
    <version>1.0-SNAPSHOT</version>
  </parent>

  <artifactId>ssm-dao</artifactId>

  <dependencies>
    <dependency>
      <groupId>com.example</groupId>
      <artifactId>ssm-domain</artifactId>
      <version>${project.version}</version>
    </dependency>
  </dependencies>
</project>
```

几个细节：

- **子模块只写 `artifactId`。** `groupId` 和 `version` 从父 POM 继承，省略不写。兄弟模块之间互相依赖时，版本号写 `${project.version}`，整个项目升版本只改父 POM 一处（`${}` 的用法见 [[Maven 属性]]）
- **`<parent>` 里的坐标必须和父 POM 完全对上。** Maven 靠这三个值认父亲
- **`<relativePath>` 默认指向上一级目录。** 父 POM 恰好在上一级时可以不写；不在时用它指路，比如 `<relativePath>../parent/pom.xml</relativePath>`。Maven 先按这个路径找父 POM，找不到再去本地仓库、远程仓库

### 哪些东西会被继承

| 会继承 | 不会继承 |
| --- | --- |
| `groupId`、`version` | `artifactId` |
| `properties` | `name` |
| `dependencies` | `prerequisites` |
| `dependencyManagement` | `profiles`（但父 POM 里已激活的 profile 的效果会继承） |
| `build`：插件配置、插件执行等 | |
| `repositories`、`pluginRepositories` | |
| `description`、`url`、`licenses`、`developers` 等描述信息 | |

`artifactId` 不继承，因为每个模块的身份必须独一无二。`profiles` 那一条见 [[Maven Profile]]。

### 父 POM 里的 dependencies 和 dependencyManagement

这是继承里最容易用错的地方。

**写在父 POM 的 `<dependencies>` 里，每个子模块都会被强行塞一份。** 把 `spring-webmvc` 写进去，`ssm-domain` 这个只放实体类的模块也会依赖上 Spring MVC。这里只适合放真正人人都要的东西，比如测试库：

```xml
<!-- ssm-parent/pom.xml -->
<dependencies>
  <dependency>
    <groupId>org.junit.jupiter</groupId>
    <artifactId>junit-jupiter</artifactId>
    <version>${junit.version}</version>
    <scope>test</scope>
  </dependency>
</dependencies>
```

**其余的依赖放进 `<dependencyManagement>`，它只定版本，不引入依赖。** 子模块要用时自己在 `<dependencies>` 里声明，只写 `groupId` 和 `artifactId`，版本由父 POM 填上：

```xml
<!-- ssm-parent/pom.xml -->
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>org.springframework</groupId>
      <artifactId>spring-webmvc</artifactId>
      <version>${spring.version}</version>
    </dependency>
    <dependency>
      <groupId>org.mybatis</groupId>
      <artifactId>mybatis</artifactId>
      <version>${mybatis.version}</version>
    </dependency>
  </dependencies>
</dependencyManagement>
```

```xml
<!-- ssm-web/pom.xml：要用才声明，不写版本 -->
<dependencies>
  <dependency>
    <groupId>org.springframework</groupId>
    <artifactId>spring-webmvc</artifactId>
  </dependency>
</dependencies>
```

这样一来，每个模块只拿自己需要的依赖，而所有模块用到的版本都由父 POM 一处说了算。`dependencyManagement` 还会顺带锁住传递依赖的版本，这部分机制见 [[Maven#排除和锁版本]]。

插件也有对应的写法：`<build>` 下的 `<pluginManagement>` 只配置插件、不启用插件，子模块在自己的 `<plugins>` 里引用了才生效。

## 聚合和继承的区别

两者都有「父工程」，所以常被混为一谈，但关系的方向正好相反：

| | 聚合 | 继承 |
| --- | --- | --- |
| 解决什么 | 多个模块一起构建 | 多个模块共用配置 |
| 关系写在哪 | 父 POM 的 `<modules>` | 子 POM 的 `<parent>` |
| 谁知道谁 | 父知道有哪些子，子不知道父 | 子知道父是谁，父不知道有哪些子 |
| 父工程打包类型 | `pom` | `pom` |

它们完全可以分开用：

- **只继承不聚合**：用一个公司统一的父 POM 管所有项目的插件和版本，但每个项目各自构建。Spring Boot 项目继承 `spring-boot-starter-parent` 就是这种，那个父 POM 不会把你的工程列进它的 `<modules>`
- **只聚合不继承**：几个配置毫不相干的工程，只是想一条命令一起构建

日常的多模块项目两件事都要，于是同一个 `ssm-parent` 身兼二职：`<modules>` 列出四个子模块，四个子模块的 `<parent>` 又都指向它。这时要同时满足三条：

1. 每个子 POM 用 `<parent>` 声明父亲
2. 父 POM 的打包类型是 `pom`
3. 父 POM 用 `<modules>` 列出子模块的目录

## 参考
- [Introduction to the POM](https://maven.apache.org/guides/introduction/introduction-to-the-pom.html) — Project Inheritance、Project Aggregation 两节
- [POM Reference](https://maven.apache.org/pom.html) — Inheritance、Aggregation 两节
- [Guide to Working with Multiple Modules](https://maven.apache.org/guides/mini/guide-multiple-modules.html)
- [Maven CLI Options Reference](https://maven.apache.org/ref/current/maven-embedder/cli.html)
