---
tags: [类型/实践, 技术/Maven]
aliases: [Maven 多环境配置]
created: 2026-10-04
updated: 2026-10-04
---
> profile 是 POM 里一段「只在指定环境下才生效」的配置。最常见的用法是给开发、测试、生产各准备一套属性值，打包时用 `-P` 选一套，再配合资源过滤，把对应环境的数据库地址写进配置文件。

## 典型场景

开发时 `jdbc.properties` 连本机的 MySQL，提测时要连测试服务器的库，上线又要连生产库。三个地址写在同一个文件里，每次打包前手动改一遍。

手动改迟早出事：哪天赶时间忘了改回来，带着本机地址的包就发上了生产，服务一启动就连不上数据库；更糟的是把测试库地址带上了生产，服务跑得好好的，数据却全写错了地方。

profile 让同一份 POM 里同时存着三套配置，打包命令决定用哪套，配置文件本身一个字都不用动。

## 定义 profile

profile 依赖 [[Maven 属性]] 里讲的两样东西：自定义属性和资源过滤。先把 `jdbc.properties` 里的值换成占位符：

```properties
jdbc.url=${jdbc.url}
```

然后在 POM 里给每个环境写一个 profile，各自定义自己的 `jdbc.url`：

```xml
<profiles>
  <profile>
    <id>dev</id>
    <activation>
      <activeByDefault>true</activeByDefault>
    </activation>
    <properties>
      <jdbc.url>jdbc:mysql://localhost:3306/ssm_db</jdbc.url>
    </properties>
  </profile>
  <profile>
    <id>test</id>
    <properties>
      <jdbc.url>jdbc:mysql://测试库地址:3306/ssm_db</jdbc.url>
    </properties>
  </profile>
  <profile>
    <id>prod</id>
    <properties>
      <jdbc.url>jdbc:mysql://生产库地址:3306/ssm_db</jdbc.url>
    </properties>
  </profile>
</profiles>

<build>
  <resources>
    <resource>
      <directory>${project.basedir}/src/main/resources</directory>
      <filtering>true</filtering>
    </resource>
  </resources>
</build>
```

每个 `<profile>` 必须有一个 `<id>`，命令行就靠它来选。`dev` 上的 `<activeByDefault>true</activeByDefault>` 表示什么都不指定时默认用它。

构建时，被激活的那个 profile 里的 `<properties>` 会并进 POM，资源过滤再把 `${jdbc.url}` 换成这个值。打出来的包里，`jdbc.properties` 已经是对应环境的真实地址。

### profile 里不只能放属性

属性是最常用的，但 profile 能改的东西多得多：

| 元素 | 能做什么 |
| --- | --- |
| `properties` | 换一套属性值 |
| `dependencies`、`dependencyManagement` | 只在某个环境下引入或锁定某些依赖 |
| `build` | 换插件配置、资源目录 |
| `modules` | 只在某个环境下才构建某些模块 |
| `repositories`、`pluginRepositories` | 换仓库地址 |
| `distributionManagement` | 换发布目标 |
| `reporting` | 换报告配置 |

比如生产环境要多打一个监控探针的依赖，就写在 `prod` 的 `<dependencies>` 里，开发时不会带上它。

## 激活 profile

### 命令行指定：-P

```bash
mvn package -P prod              # 激活 prod
mvn package -P test,prod         # 同时激活多个，逗号分隔
mvn package -P '!dev'            # 停用 dev
```

停用用的 `!` 在 Bash 和 Zsh 里有特殊含义，要加引号或者写成 `\!dev`。

### 默认激活：activeByDefault 的陷阱

`activeByDefault` 的规则比字面意思窄：**只有同一个 POM 里没有任何别的 profile 被激活时，它才生效。** 只要有一个 profile 被显式激活了（命令行 `-P`、`settings.xml` 里的 `<activeProfiles>`、或者下面讲的条件触发），所有 `activeByDefault` 的 profile 全部失效。

这个规则会在下面这种情况里咬人：POM 里除了 `dev`、`test`、`prod`，你又加了一个和环境无关的 profile，比如 `coverage`，专门用来跑测试覆盖率。本地开发时敲：

```bash
mvn test -P coverage
```

你以为是「dev 环境 + 覆盖率」，实际上 `coverage` 一被激活，`dev` 就失效了。三套环境的 profile 一个都没生效，`jdbc.url` 这个属性根本没人定义，资源过滤找不到值来替换。

正确的做法是把环境写全：`mvn test -P dev,coverage`。

### 按条件自动激活

`<activation>` 里除了 `activeByDefault`，还能写触发条件。最常用的是按属性触发：

```xml
<profile>
  <id>test</id>
  <activation>
    <property>
      <name>env</name>
      <value>test</value>
    </property>
  </activation>
  ...
</profile>
```

```bash
mvn package -Denv=test
```

`-D` 定义的属性 `env` 值为 `test`，这个 profile 就被激活。只写 `<name>` 不写 `<value>` 时，只要这个属性存在、值是什么都行；`<name>` 写成 `!env` 则表示「这个属性**不存在**时激活」。

除了属性，还可以按 JDK 版本、操作系统、某个文件是否存在来触发，写法见参考里的官方文档。

### 写在 settings.xml 里

profile 不只能写在 `pom.xml`，也能写在用户级的 `~/.m2/settings.xml` 和 Maven 安装目录下的全局 `conf/settings.xml` 里。`settings.xml` 还能用 `<activeProfiles>` 让某些 profile 始终激活：

```xml
<settings>
  <activeProfiles>
    <activeProfile>dev</activeProfile>
  </activeProfiles>
</settings>
```

**环境相关的值别写进 `settings.xml` 的 profile。** `settings.xml` 只在你自己的机器上，不进版本库。POM 里引用了一个只在你 `settings.xml` 里定义的属性，同事 clone 下来就构建不了。项目需要的 profile 都应该写在 POM 里。[[Maven 私服]] 的地址这类「跟人走、不跟项目走」的配置才适合放 `settings.xml`。

## 确认到底激活了哪些

profile 的激活规则绕，凭感觉判断很容易错。两条命令可以直接看结果：

```bash
mvn help:active-profiles                  # 列出当前激活的 profile
mvn help:active-profiles -Denv=test       # 带上条件再看
mvn help:effective-pom -P prod            # 看激活 prod 后最终生效的完整 POM
```

`effective-pom` 输出的是合并了父 POM、激活的 profile 之后的最终 POM。`jdbc.url` 到底是哪个值，在里面搜一下就知道了。

## 常见的坑

- **环境没写全。** 只写了 `dev` 和 `test`，没写 `prod`，打生产包时 `-P prod` 指向一个不存在的 profile，`jdbc.url` 同样没人定义。目标环境有几个，profile 就要写几个
- **父 POM 的 profile 不会原样继承。** 子模块继承不到父 POM 里 `<profiles>` 的定义，只能继承到父 POM 里已经激活的 profile 产生的效果，见 [[Maven 多模块项目#哪些东西会被继承]]
- **同一条命令，在你和同事机器上激活的 profile 可能不一样。** 你的 `settings.xml` 里用 `<activeProfiles>` 常开了某个 profile，同事没有，同样敲 `mvn package`，两边生效的配置就不同。结果对不上时，两边各跑一次 `help:active-profiles` 对比

## 顺带：跳过测试

`mvn package` 会先跑测试（原因见 [[Maven#阶段会带着前面的一起跑]]）。临时打个包、测试又很慢的时候，可以跳过：

| 写法 | 跳过运行测试 | 跳过编译测试代码 |
| --- | --- | --- |
| `mvn package -DskipTests` | ✅ | ❌ |
| `mvn package -Dmaven.test.skip=true` | ✅ | ✅ |

区别在于测试代码还编不编译：`-DskipTests` 只是不运行，测试代码照样编译，测试代码写错了照样会让构建失败；`maven.test.skip` 连编译都跳过，`maven-compiler-plugin`、`maven-surefire-plugin`、`maven-failsafe-plugin` 都认这个属性。

也可以在 POM 里给 `maven-surefire-plugin` 配置 `<skipTests>true</skipTests>`，让项目默认不跑测试。

跳过测试只适合临时用。给测试或生产环境打的包，测试一定要跑。

## 参考
- [Introduction to Build Profiles](https://maven.apache.org/guides/introduction/introduction-to-profiles.html)
- [POM Reference](https://maven.apache.org/pom.html) — Profiles 一节
- [Settings Reference](https://maven.apache.org/settings.html) — Active Profiles 一节
- [Maven Surefire Plugin: Skipping Tests](https://maven.apache.org/surefire/maven-surefire-plugin/examples/skipping-tests.html)
