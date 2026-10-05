---
tags: [类型/实践, 技术/Maven]
aliases: []
created: 2026-10-04
updated: 2026-10-04
---
> 在 `<properties>` 里定义一次值，POM 里到处用 `${名字}` 引用，改版本号只改一处；再给资源目录打开过滤，`jdbc.properties` 这类配置文件里的 `${}` 也会在构建时被换成真实的值。

## 典型场景

[[SSM 整合]] 的 POM 里，`spring-webmvc`、`spring-jdbc`、`spring-test` 三个依赖用的是同一个 Spring 版本。要是版本号直接写死在每个 `<version>` 里，升级时就得改三处。漏改一处，项目里就混着两个版本的 Spring，报出来的往往是 `NoSuchMethodError` 这类错，很难联想到是版本混用。

属性就是 POM 里的变量。版本号定义一次，三处都引用它，升级只改一行。

## 自定义属性

在 `<properties>` 里定义，标签名就是属性名，标签内容就是值：

```xml
<properties>
  <spring.version>在 Maven Central 上查到的版本号</spring.version>
  <mybatis.version>在 Maven Central 上查到的版本号</mybatis.version>
</properties>

<dependencies>
  <dependency>
    <groupId>org.springframework</groupId>
    <artifactId>spring-webmvc</artifactId>
    <version>${spring.version}</version>
  </dependency>
  <dependency>
    <groupId>org.springframework</groupId>
    <artifactId>spring-jdbc</artifactId>
    <version>${spring.version}</version>
  </dependency>
</dependencies>
```

`spring.version` 里的点只是名字的一部分，不表示层级，写成 `spring-version` 也一样能用。约定俗成用 `xxx.version` 命名版本号，读 POM 的人一眼就知道它是干什么的。

`${}` 能出现在 POM 里几乎任何位置，不只是 `<version>`。

## 能引用的五类属性

除了自己定义的，Maven 还提供了一批现成的属性，按前缀分五类：

| 写法 | 来源 | 例子 |
| --- | --- | --- |
| `${project.x}` | 当前 POM 里的元素，按层级用点连接 | `${project.version}`、`${project.build.sourceDirectory}` |
| `${env.X}` | 操作系统的环境变量 | `${env.PATH}` |
| `${settings.x}` | `settings.xml` 里的元素 | `${settings.offline}` |
| `${java.home}` 这类 | Java 系统属性，即 `System.getProperties()` 能拿到的那些 | `${java.home}` |
| `${x}` | `<properties>` 里自定义的 | `${spring.version}` |

几个常用的值得单独记：

- **`${project.version}`**：当前项目的版本号。多模块项目里兄弟模块互相依赖时，版本号写它，全项目升版本只改父 POM，见 [[Maven 多模块项目]]
- **`${project.basedir}`**：当前项目所在的目录
- **`${maven.build.timestamp}`**：构建开始的时间（UTC）。格式可以通过定义 `maven.build.timestamp.format` 属性来改，写法遵循 Java `SimpleDateFormat`

`env.` 后面的环境变量名会被统一成大写，所以写 `${env.PATH}`，别写 `${env.path}`。

### 有些属性是写给插件看的

你会在很多 POM 里看到这几行：

```xml
<properties>
  <maven.compiler.source>17</maven.compiler.source>
  <maven.compiler.target>17</maven.compiler.target>
  <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
</properties>
```

POM 里没有任何地方用 `${}` 引用它们，可它们照样生效。原因是插件的参数可以绑定一个「用户属性」，插件运行时会去读同名属性：`maven-compiler-plugin` 的 `source` 参数读 `maven.compiler.source`，`target` 读 `maven.compiler.target`，`encoding` 参数的默认值则是 `${project.build.sourceEncoding}`。

所以这几行实际上是在用属性给编译插件传参，省掉了写一整段 `<plugin><configuration>` 的麻烦。插件的哪个参数对应哪个属性名，在插件文档每个参数的「User Property」一栏里能查到。

### 父子 POM 里同名属性听谁的

属性随继承一起传给子模块（见 [[Maven 多模块项目#继承：子模块共用一份配置]]）。替换 `${}` 发生在继承**之后**，所以父 POM 里用了某个属性，而子 POM 重新定义了它，最终生效的是**子 POM 的值**。

这个顺序可以利用：父 POM 定一个默认值，个别模块需要不同的值时，在自己的 POM 里覆盖即可。

## 资源过滤：让配置文件也能用属性

POM 里的 `${}` 会被替换，但 `src/main/resources` 下的配置文件默认是原样复制到 `target/classes` 的。想让配置文件也用上 POM 里的属性，要给资源目录打开**过滤**（filtering）。

还是以 `jdbc.properties` 为例。先把写死的值换成占位符：

```properties
jdbc.url=${jdbc.url}
jdbc.username=${jdbc.username}
```

在 POM 里定义属性，并打开过滤：

```xml
<properties>
  <jdbc.url>jdbc:mysql://localhost:3306/ssm_db</jdbc.url>
  <jdbc.username>root</jdbc.username>
</properties>

<build>
  <resources>
    <resource>
      <directory>${project.basedir}/src/main/resources</directory>
      <filtering>true</filtering>
    </resource>
  </resources>
</build>
```

构建时，复制资源的那一步会把 `${jdbc.url}` 换成 `jdbc:mysql://localhost:3306/ssm_db`。源文件不变，变的是 `target/classes/jdbc.properties`，也就是最终打进包里的那份。

过滤时能用的值不止 `<properties>` 里的：`${project.version}` 这类 POM 自带的属性，以及命令行用 `-D名字=值` 传进来的属性也都可以。除了 `${...}`，`@...@` 也是默认认的占位符写法。

单看这个例子，绕一圈好像只是把值从配置文件挪进了 POM。它真正的用处在多环境：开发、测试、生产各定义一套 `jdbc.url`，打包时选一套，配置文件一个字都不用改。这就是 [[Maven Profile]] 的典型用法。

### 资源过滤的坑

**不要过滤二进制文件。** 图片、字体、证书这类文件被当成文本做替换，基本都会损坏。资源目录里两类文件混放时，分成两个目录，只给放文本配置的那个打开过滤：

```xml
<resources>
  <resource>
    <directory>${project.basedir}/src/main/resources</directory>
    <filtering>false</filtering>
  </resource>
  <resource>
    <directory>${project.basedir}/src/main/resources-filtered</directory>
    <filtering>true</filtering>
  </resource>
</resources>
```

**Spring 配置里的占位符可能被 Maven 抢先替换。** Spring 的 XML 配置也用 `${jdbc.url}` 这种写法，本意是运行时由 Spring 从 `jdbc.properties` 里读。如果这份 XML 在被过滤的目录里，而 Maven 恰好也有个同名属性，它在构建时就被换掉了，运行时 Spring 拿到的已经是写死的值。Spring 那边的配置照样能跑，所以这个问题很难察觉。要么别过滤 Spring 的配置文件，要么让 Maven 属性和 Spring 占位符别重名。

## 参考
- [Introduction to the POM](https://maven.apache.org/guides/introduction/introduction-to-the-pom.html) — Project Interpolation and Variables 一节
- [POM Reference](https://maven.apache.org/pom.html) — Properties、Resources 两节
- [Maven Resources Plugin: Filtering](https://maven.apache.org/plugins/maven-resources-plugin/examples/filter.html)
- [maven-compiler-plugin: compiler:compile](https://maven.apache.org/plugins/maven-compiler-plugin/compile-mojo.html)
