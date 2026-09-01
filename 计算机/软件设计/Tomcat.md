---
tags: [类型/实践, 技术/Tomcat, 技术/Java, 技术/Maven]
aliases: [Apache Tomcat, catalina]
created: 2026-09-01
updated: 2026-09-01
---
> Tomcat 是跑 [[Servlet]] 的那个「壳」：它监听端口、把 [[HTTP]] 报文解析成 Java 对象、按路径找到你的 Servlet 调用它。开发期不用装独立 Tomcat，给 [[Maven]] 项目挂个插件，一条 `mvn tomcat7:run` 就能起服务。

## 典型场景

你按教程写好了第一个 Servlet，类写完了，`@WebServlet("/hello")` 也标上了。然后卡住了——**这个类没有 `main` 方法，IDEA 的绿色三角按钮是灰的。**

它确实不该有 `main`。Servlet 是一个「被调用者」，规范只规定了容器该怎么调用它，没规定它怎么自己启动。你缺的是那个调用者：一个常驻进程，占着 8080 端口，收到 `GET /hello` 时把请求转给你的类。

Tomcat 就是这个进程。这篇讲它是什么、目录里各是什么，以及怎么在 Maven 项目里用插件把它拉起来。

## Tomcat 是什么

Apache Tomcat 是 Jakarta Servlet、Jakarta Pages（JSP）、Expression Language、WebSocket 这几个规范的**开源实现**。

「实现」两个字是理解它的关键：`jakarta.servlet` 那套接口只是一份契约，规定了 `HttpServletRequest` 上有哪些方法、`init` 什么时候被调用，但没有任何可执行代码。Tomcat 提供的就是这份契约背后的真身——你调 `req.getParameter("name")` 时，真正跑起来的是 Tomcat 的类。

同一份契约有多个实现，Jetty、Undertow、WildFly 都能跑 Servlet。**换实现不用改业务代码**，这正是面向规范编程的回报。

它同时扮演两个角色：

| 角色 | 干什么 |
| --- | --- |
| Web 服务器 | 监听 TCP 端口，收发 HTTP 报文，直接吐 HTML/CSS/图片这类静态文件 |
| Servlet 容器 | 加载你的 Servlet 类、管它们的生命周期、把请求路由给对应的 Servlet |

规范里对容器职责的定义是：提供收发请求的网络服务、解析 MIME 格式的请求、格式化 MIME 格式的响应，并且**容纳和管理 Servlet 的整个生命周期**。

## 目录结构

装一个独立 Tomcat 解开之后是这些目录，官方文档里的说明：

| 目录 | 装什么 |
| --- | --- |
| `bin/` | 启动、关闭等脚本。`.sh`（Unix）和 `.bat`（Windows）是功能对等的两套 |
| `conf/` | 配置文件和相关 DTD，**最重要的是 `server.xml`，它是容器的主配置文件** |
| `lib/` | 要加进 classpath 的额外依赖 |
| `logs/` | 日志默认落在这里 |
| `webapps/` | **你的 web 应用放这里** |
| `work/` | 已部署应用的临时工作目录 |
| `temp/` | JVM 用的临时文件 |

启动脚本在 `bin/` 里：Unix 下是 `startup.sh` / `shutdown.sh`，Windows 下是同名的 `.bat`。

排错时先看 `logs/`。Tomcat 起不来或者应用部署失败，异常栈都在那里，光看控制台经常是截断的。

### 改端口

默认 HTTP 端口是 **8080**。被占了就改 `$CATALINA_HOME/conf/server.xml`，在里面找 `<Connector>` 节点改 `port` 属性。

官方文档提醒了一句实际会踩到的：**在 UNIX 系统上，非 root 用户只能绑定 1024 以上的端口。** 所以想让 Tomcat 直接监听 80 端口，要么用 root 跑（不推荐），要么前面架个 Nginx 转发。

`CATALINA_HOME` 和 `CATALINA_BASE` 这两个环境变量的分工：前者指向 Tomcat 的安装目录（程序本体），后者指向某个实例的配置和数据目录。一台机器上跑多个 Tomcat 实例时，它们共用一个 `CATALINA_HOME`，各自有独立的 `CATALINA_BASE`。单实例时两者相同，可以先不管。文档里写明 `CATALINA_BASE` 至少要包含 `conf/server.xml` 和 `conf/web.xml` 两个文件。

## Web 应用长什么样

Tomcat 认的不是随便一堆 `.class` 文件，而是一个**有固定结构的目录**（或者把这个目录打包成的 WAR 文件）。

结构的核心是一个叫 `WEB-INF` 的特殊目录。规范对它的定义是：这个目录装「所有不属于应用文档根的东西」，而且**它里面的文件不会被容器直接发给客户端**——客户端请求 `/WEB-INF/foo` 会拿到 404。

```text
应用根目录/
├── index.html              ← 文档根下的东西，浏览器能直接访问
├── images/banner.gif
└── WEB-INF/                ← 浏览器访问不到，但你的代码能读
    ├── web.xml             部署描述符
    ├── classes/            你编译出来的 .class
    └── lib/                依赖的第三方 jar
```

**「浏览器访问不到」是个安全特性，不是限制。** 数据库密码写在 `WEB-INF/` 下的配置文件里是安全的；同一个文件放到文档根下，全世界都能下载走。

类加载顺序也定死了：**先从 `WEB-INF/classes` 加载，再从 `WEB-INF/lib` 里的 jar 加载。** 所以同名类冲突时，你自己的类赢。

打包成一个文件就是 **WAR**（Web ARchive）。它本质上就是用标准 Java 归档工具打的 zip，只是扩展名换成了 `.war`。丢进 `webapps/`，Tomcat 会自动解开并部署。

## 用 Maven 插件把项目跑起来

上面那套结构不用你手工摆，Maven 会按约定生成。开发期也不用装独立 Tomcat——插件会拉起一个内嵌的。

### 第一步：把项目声明成 war

在 `pom.xml` 里把打包类型改掉，默认的 `jar` 是不行的：

```xml
<packaging>war</packaging>
```

这一行会让 `mvn package` 交给 `maven-war-plugin` 处理，产出 `target/xxx.war` 而不是 jar。war 目标默认绑定在 `package` 阶段上，关于阶段和插件目标的关系见 [[Maven]]。

对应的目录结构多了一个 `src/main/webapp`，它是 `maven-war-plugin` 的 `warSourceDirectory` 参数的默认值：

```text
my-webapp/
├── pom.xml
└── src/main/
    ├── java/                   ← Servlet 源码，编译后进 WEB-INF/classes
    ├── resources/
    └── webapp/                 ← 文档根
        ├── index.html
        └── WEB-INF/
            └── web.xml
```

**`src/main/webapp` 就是将来的应用根目录**，你在里面建的 `WEB-INF` 会原样进 war 包，而 `src/main/java` 编译出来的 class 由 Maven 塞进 `WEB-INF/classes`。

### 第二步：声明 Servlet API 依赖

编译 Servlet 需要 `jakarta.servlet` 那些接口，但**运行时不能把它打进 war 包**——容器自己带了一份，重复会冲突。这正是 `provided` 这个 scope 存在的理由：

```xml
<dependency>
  <groupId>jakarta.servlet</groupId>
  <artifactId>jakarta.servlet-api</artifactId>
  <version>在 Maven Central 上查到的版本号</version>
  <scope>provided</scope>
</dependency>
```

scope 的完整含义见 [[Maven]]，一句话是：`provided` 表示「编译时要，打包时别带」。

### 第三步：挂上 Tomcat 插件

```xml
<build>
  <plugins>
    <plugin>
      <groupId>org.apache.tomcat.maven</groupId>
      <artifactId>tomcat7-maven-plugin</artifactId>
      <version>2.2</version>
      <configuration>
        <port>8080</port>
        <path>/</path>
      </configuration>
    </plugin>
  </plugins>
</build>
```

然后：

```bash
mvn tomcat7:run
```

命令跑完控制台不会退出——它就该这样，进程占着端口在等请求。浏览器打开 `http://localhost:8080/hello` 就能看到你的 Servlet。停掉用 `Ctrl+C`。

两个配置项的默认值（官方 mojo 文档）：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `port` | `8080` | 内嵌 Tomcat 监听的端口 |
| `path` | `/${project.artifactId}` | 应用的上下文路径，**必须以 `/` 开头** |

**`path` 的默认值是个高频困惑源。** 不配它的话，你的应用挂在 `/你的-artifactId` 底下，访问地址是 `http://localhost:8080/my-webapp/hello` 而不是 `http://localhost:8080/hello`。配成 `<path>/</path>` 才是挂在根上。

`tomcat7:run` 这个写法是「插件前缀:目标」的直接调用形式，它会先触发 `process-classes` 阶段，所以能拿到最新编译的类。

### 版本这个坑必须先说清楚

`tomcat7-maven-plugin` 跑的是 **Tomcat 7**，而 Tomcat 7 实现的是 **Servlet 3.0**，用的是 **`javax.servlet`** 命名空间。

它的最后一个正式版本是 **2.2，发布于 2013 年 11 月**，此后没有再更新过。

后果很直接：**如果你的代码 import 的是 `jakarta.servlet`，这个插件跑不起来。** 表现通常不是编译报错，而是启动看着正常、一访问就 404——容器扫描注解时不认识 `jakarta.servlet.annotation.WebServlet`。

所以要么两边对齐：

| 你用的包名 | 能配的方案 |
| --- | --- |
| `javax.servlet` | `tomcat7-maven-plugin`，教程里最常见的组合 |
| `jakarta.servlet` | 换维护中的插件，或者装独立 Tomcat 10+ 部署 war |

跑 `jakarta.servlet` 的项目，维护中的选择是 Codehaus Cargo。它用 `containerId` 选容器版本，Tomcat 侧支持到 `tomcat10x` 和 `tomcat11x`。官方入门文档给的命令行形式是：

```bash
mvn clean verify org.codehaus.cargo:cargo-maven3-plugin:run -Dcargo.maven.containerId=tomcat9x
```

把 `tomcat9x` 换成 `tomcat10x` 就是 `jakarta.servlet` 那一侧。写进 `pom.xml` 的配置项见它的 Maven 3 Plugin Reference Guide。

Tomcat 版本和规范版本的对应关系值得记一下，排「为什么我的注解不生效」时用得上：

| Tomcat | Servlet 规范 | 命名空间 | 最低 Java |
| --- | --- | --- | --- |
| 11.0.x | 6.1 | `jakarta.*` | 17+ |
| 10.1.x | 6.0 | `jakarta.*` | 11+ |
| 9.0.x | 4.0 | `javax.*` | 8+ |
| 7.0.x | 3.0 | `javax.*` | 6+ |

**分界线在 Tomcat 10：9 及以前是 `javax.*`，10 开始是 `jakarta.*`。**

## 插件跑 vs 装一个独立 Tomcat

| | 插件内嵌 | 独立安装 |
| --- | --- | --- |
| 起服务 | `mvn tomcat7:run` | 把 war 丢进 `webapps/`，跑 `startup.sh` |
| 改配置 | 写在 `pom.xml` 里 | 改 `conf/server.xml` |
| 版本 | 由插件决定，换不了 | 你想装哪版装哪版 |
| 适合 | 开发期，改完代码重跑一下 | 部署到服务器，多应用共存 |

开发期用插件，省掉安装和往 `webapps/` 拷 war 的来回。真上线时环境里跑的一般是独立 Tomcat 或者容器镜像，配置得会 `server.xml` 那一套。

## 参考
- [Apache Tomcat 10.1 Introduction](https://tomcat.apache.org/tomcat-10.1-doc/introduction.html) — 目录结构与 `CATALINA_HOME` / `CATALINA_BASE`
- [Which Version of Tomcat Do I Want?](https://tomcat.apache.org/whichversion.html) — 版本与规范对照表
- [Apache Tomcat Maven Plugin](https://tomcat.apache.org/maven-plugin-2.2/) — `tomcat7-maven-plugin` 的目标与参数
- [Codehaus Cargo Maven 3 Plugin](https://codehaus-cargo.github.io/cargo/Maven+3+Plugin.html) — 维护中的替代方案
