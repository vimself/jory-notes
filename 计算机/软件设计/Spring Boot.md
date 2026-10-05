---
tags: [类型/概念, 技术/Spring Boot, 技术/Spring, 技术/Java, 技术/Maven]
aliases: [SpringBoot]
created: 2026-10-05
updated: 2026-10-05
---
> Spring Boot 是 [[Spring Framework]] 上面的一层默认配置。起步依赖替你挑好一组互相兼容的依赖版本；自动配置看 classpath 上有哪些 jar，替你把对应的 bean 注册好；内嵌的 Tomcat 让整个项目打成一个 jar，用 `java -jar` 就能启动。你只需要在 `application.yml` 里写和默认值不一样的那部分。

## 典型场景

[[SSM 整合]] 里做过一个图书管理接口。回头数一下那个工程里和业务无关的东西：

- **5 个配置类**：`JdbcConfig`、`MyBatisConfig`、`SpringConfig`、`SpringMvcConfig`、`ServletContainerInitConfig`，其中大部分代码是 `new` 一个对象、调几个 setter、返回
- **10 个依赖**：每个都要写版本号，还要自己核对 Spring 和 Tomcat、mybatis-spring 和 Spring、Jackson 2 和 Jackson 3 之间的兼容关系
- **部署**：打成 war 包，装一个版本对得上的 Tomcat，把 war 放进去再启动

业务代码只有实体、Dao、Service、Controller 加上统一响应和异常处理，脚手架代码的量和它差不多。而且换一个项目，这些脚手架几乎要原样再写一遍。

用 Spring Boot 重写同一个项目，结果是：5 个配置类全部删掉；依赖剩 4 个，其中只有一个要写版本号；打出来一个 jar，`java -jar` 直接运行。

## 第一个 Boot 项目

### 项目结构和 POM

Spring Boot 4 要求 Java 17 及以上。项目可以在 [start.spring.io](https://start.spring.io) 上勾选依赖后生成，也可以手写一个 POM：

```xml
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>4.1.1</version>
</parent>

<groupId>com.example</groupId>
<artifactId>book-demo</artifactId>
<version>0.0.1-SNAPSHOT</version>

<dependencies>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-webmvc</artifactId>
    </dependency>
</dependencies>

<build>
    <plugins>
        <plugin>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-maven-plugin</artifactId>
        </plugin>
    </plugins>
</build>
```

三处和 SSM 不同：多了一个 `<parent>`；依赖只有一个，而且**没写版本号**；没有 `<packaging>war</packaging>`，默认打 jar。

### 启动类

```java
package com.example;

@SpringBootApplication
public class BookApplication {

    public static void main(String[] args) {
        SpringApplication.run(BookApplication.class, args);
    }
}
```

再写一个 Controller，放在 `com.example.controller` 包下：

```java
@RestController
public class HelloController {

    @GetMapping("/hello")
    public String hello() {
        return "Hello Spring Boot";
    }
}
```

运行 `main` 方法，或者在项目根目录执行：

```bash
mvn spring-boot:run
```

控制台先打出一个 Spring 字样的 ASCII 图案，日志最后一行是 `Started BookApplication in … seconds`。浏览器访问 `http://localhost:8080/hello` 就能看到返回的字符串。

整个过程没有装 Tomcat，也没有写 `web.xml` 或初始化类。`SpringApplication.run` 创建 Spring 容器的同时，启动了一个内嵌在应用里的 Tomcat，默认端口 8080。

### @SpringBootApplication 做了三件事

它是一个组合注解，相当于同时写了三个：

| 注解 | 作用 |
| --- | --- |
| `@SpringBootConfiguration` | 标记这是一个配置类，可以在里面写 `@Bean` 方法 |
| `@EnableAutoConfiguration` | 开启自动配置，下面专门讲 |
| `@ComponentScan` | 从**启动类所在的包**开始扫描组件 |

第三条决定了启动类该放在哪里。`BookApplication` 在 `com.example`，扫描范围就是 `com.example` 及其所有子包，所以 `com.example.controller.HelloController` 能被扫到。

如果把 Controller 放在 `com.demo.controller`，它和 `com.example` 是平级的两个包，不在扫描范围内。启动不报错，访问时 404。**启动类要放在所有业务包的上一层**，这是 Boot 项目结构的第一条规矩。

### 打成可执行 jar

```bash
mvn package
java -jar target/book-demo-0.0.1-SNAPSHOT.jar
```

`target` 目录下会有两个文件：`book-demo-0.0.1-SNAPSHOT.jar` 和一个小得多的 `book-demo-0.0.1-SNAPSHOT.jar.original`。后者是 Maven 原本打出的普通 jar，只有你自己的类；前者是 `spring-boot-maven-plugin` 重新打包（repackage）后的结果，把所有依赖的 jar（包括 Tomcat）原样嵌套在里面。官方入门教程里这个最小项目打出来大约 18 MB。

Java 本身不支持加载「jar 里面的 jar」，Boot 在可执行 jar 里放了自己的启动器来处理这件事，所以只有经过 repackage 的那个 jar 能用 `java -jar` 运行。服务器上不用再装 Tomcat，有 JDK 就行。

## 起步依赖

### parent：版本号去哪了

`spring-boot-starter-parent` 继承自 `spring-boot-dependencies`，后者的 `<dependencyManagement>` 里登记了一份清单：Spring 全家的模块，以及大量常用第三方库（MySQL 驱动、Jackson、JUnit、Tomcat……），每个都配好了经过测试、互相兼容的版本。继承关系和 `<dependencyManagement>` 的原理见 [[Maven 多模块项目]]。

所以在自己的 POM 里引用清单上的库时可以省略 `<version>`，版本由 parent 决定。升级 Spring Boot 只需要改 parent 的一个版本号，清单上所有依赖跟着一起升级，Spring 和 Tomcat、Jackson 之间对不上版本的问题由 Boot 团队提前处理掉了。

几个要注意的地方：

- **不在清单上的库照样要写版本。** 比如后面整合用的 `mybatis-spring-boot-starter`，它是 MyBatis 团队发布的，Boot 的清单里没有它
- **能覆盖但要慎重。** 清单里的库大多有一个对应的 Maven 属性，在自己的 POM 里重新定义这个属性就能换版本（写法见 [[Maven 属性]]，属性名在官方文档的 Dependency Versions Properties 附录里查）。官方明确提醒：每个 Boot 版本都是对着一组特定版本测试的，覆盖可能引入兼容问题。Spring Framework 的版本更是强烈建议不要自己指定
- **parent 不只管版本。** 它还设好了：默认 Java 17（改 `<java.version>` 属性即可）、UTF-8 源码编码、编译时带 `-parameters`（[[Spring MVC]] 按参数名绑定需要它）、`repackage` 的执行配置，以及对 `application*.yml`、`application*.properties` 的资源过滤，这一项多环境那节会用到

### starter：一个依赖拉进来一组

parent 只管「用哪个版本」，不管「要哪些库」。后者由 **starter** 负责：starter 本身几乎没有代码，它就是一个 POM，把做某件事需要的依赖打包声明好。

`spring-boot-starter-webmvc` 在 Boot 4.1 源码里声明的依赖是：

```text
spring-boot-starter-webmvc
├── spring-boot-starter            核心：自动配置支持、日志、SnakeYAML
├── spring-boot-starter-jackson    JSON 转换
├── spring-boot-starter-tomcat     内嵌 Tomcat
├── spring-boot-http-converter
└── spring-boot-webmvc             Spring MVC 本身 + 它的自动配置
```

引一个 starter，Maven 的传递依赖（见 [[Maven]]）就把 Spring MVC、Tomcat、Jackson、日志全拉进来了。想看完整的依赖树，执行 `mvn dependency:tree`。

命名有固定规律：官方 starter 叫 `spring-boot-starter-*`，第三方 starter 叫 `*-spring-boot-starter`，`spring-boot` 开头的名字留给官方。看到 `mybatis-spring-boot-starter` 就知道它是 MyBatis 团队自己维护的。

常用的几个：

| starter | 用途 |
| --- | --- |
| `spring-boot-starter-webmvc` | Web 接口：Spring MVC、内嵌 Tomcat、Jackson |
| `spring-boot-starter-jdbc` | JDBC 和数据源，默认连接池 HikariCP |
| `spring-boot-starter-test` | 测试：JUnit Jupiter、Spring Test、AssertJ、Mockito 等 |

**Web starter 在 Boot 4 改了名。** 网上大量教程写的是 `spring-boot-starter-web`，在 Boot 4 里它被标记为弃用，替代者是 `spring-boot-starter-webmvc`。Boot 4 还把原来集中在一个大 jar 里的自动配置拆进了各个技术模块：Web 的自动配置在 `spring-boot-webmvc` 里，数据源的在 `spring-boot-jdbc` 里。引了哪个 starter，才会带上哪部分自动配置。

## 自动配置

### 它怎么知道该配什么

起步依赖解决了「jar 包从哪来」，但 jar 进了 classpath 不等于 bean 进了容器。SSM 里 `DataSource`、`SqlSessionFactory`、`DispatcherServlet` 都是在配置类里手写 `@Bean` 注册的。Boot 里这些配置类由各个 jar 自己带着，称为**自动配置类**。

启动时，`@EnableAutoConfiguration` 会到 classpath 上每个 jar 里找一个固定位置的清单文件：

```text
META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
```

里面一行一个自动配置类的全名。比如 `spring-boot-jdbc` 这个 jar 里的清单（节选）：

```text
org.springframework.boot.jdbc.autoconfigure.DataSourceAutoConfiguration
org.springframework.boot.jdbc.autoconfigure.DataSourceTransactionManagerAutoConfiguration
org.springframework.boot.jdbc.autoconfigure.JdbcTemplateAutoConfiguration
```

清单上的类不会无条件生效。每个自动配置类都是一个普通的 `@Configuration` 类，只是上面加了**条件注解**，条件全部满足才生效。`DataSourceTransactionManagerAutoConfiguration` 的源码（节选）：

```java
@ConditionalOnClass({ DataSource.class, JdbcTemplate.class, TransactionManager.class })
public final class DataSourceTransactionManagerAutoConfiguration {

    @ConditionalOnSingleCandidate(DataSource.class)
    static class JdbcTransactionManagerConfiguration {

        @Bean
        @ConditionalOnMissingBean(TransactionManager.class)
        DataSourceTransactionManager transactionManager(...) { ... }
    }
}
```

三个条件，翻译过来：

- `@ConditionalOnClass`：classpath 上**有** `DataSource`、`JdbcTemplate` 这些类，也就是你引了 JDBC 相关的 jar
- `@ConditionalOnSingleCandidate`：容器里**恰好有一个**（或者有一个主要的）`DataSource`
- `@ConditionalOnMissingBean`：容器里**还没有**事务管理器，也就是你自己没定义

三个都满足，才注册一个 `DataSourceTransactionManager`。这正是 SSM 里 `JdbcConfig` 手写的那个 bean。

把起步依赖和自动配置连起来，整条链路是：

```text
引入 spring-boot-starter-jdbc
  └─▶ classpath 上出现 HikariCP、spring-jdbc、spring-boot-jdbc
        └─▶ spring-boot-jdbc 里的清单列出 DataSourceAutoConfiguration 等
              └─▶ @ConditionalOnClass 满足，你又没自己定义 DataSource
                    └─▶ 按 spring.datasource.* 配置项创建一个 HikariDataSource
```

官方入门文档的说法是自动配置会根据你加的 jar「猜」你想怎么配置 Spring。引了 Tomcat 和 Spring MVC，它就认为这是一个 Web 应用，配好 `DispatcherServlet` 和内嵌服务器。

### 覆盖默认配置

自动配置的默认值不合适时，有三种办法，按侵入程度从小到大：

**一、改配置项。** 绝大多数默认值都对应一个配置项，在 `application.yml` 里改就行，比如端口、数据库地址、连接池大小。这是最常用的办法，配置文件下一节讲。

**二、自己定义 bean。** 自动配置类里的 bean 大多带着 `@ConditionalOnMissingBean`，你在自己的配置类里 `@Bean` 一个同类型的对象，自动配置就自动让位。官方文档的原话是自动配置「非侵入」，可以逐步用自己的配置替换其中任何一部分。

**三、整个排除。** 不想要某个自动配置类：

```java
@SpringBootApplication(exclude = DataSourceAutoConfiguration.class)
```

或者写在配置文件的 `spring.autoconfigure.exclude` 里。

有一个从 SSM 迁过来时很容易犯的错：**Boot 项目里不要加 `@EnableWebMvc`。** 在 SSM 里它是开启 MVC 的必需注解；在 Boot 里，加了它就等于声明「Spring MVC 由我完全接管」，Boot 对 MVC 的自动配置随之失效，静态资源映射、消息转换器等默认设置都没了。需要加拦截器（见 [[Spring MVC 拦截器]]）、格式化器这类自定义配置时，写一个实现 `WebMvcConfigurer` 的配置类，但**不加** `@EnableWebMvc`，这样 Boot 的默认配置保留，你的定制叠加在上面。

### 查看哪些自动配置生效了

自动配置是在后台完成的，出问题时最难查的是「某个 bean 到底有没有被配上、为什么没配上」。启动时加 `--debug` 参数：

```bash
java -jar target/book-demo-0.0.1-SNAPSHOT.jar --debug
```

控制台会输出一份 `CONDITIONS EVALUATION REPORT`，分为 `Positive matches`（生效的自动配置，以及满足了哪些条件）和 `Negative matches`（没生效的，以及卡在哪个条件上）。数据源没配上时，到 `Negative matches` 里找 `DataSourceAutoConfiguration`，就能看到是哪个条件没满足。

## 配置文件

### 两种格式，三种扩展名

Boot 启动时会自动加载 `src/main/resources` 下的 `application.properties`、`application.yml` 或 `application.yaml`。把端口改成 80，三种写法：

```properties
# application.properties
server.port=80
```

```yaml
# application.yml 或 application.yaml
server:
  port: 80
```

`.yml` 和 `.yaml` 是同一种格式的两个扩展名。YAML 的语法规则和常见的坑见 [[YAML]]，这里只讲 Boot 怎么用它。

同一个位置下 properties 和 YAML 文件同时存在、又配了同一个键时，**properties 优先**。官方建议整个项目只用一种格式，免得改了 YAML 却发现被 properties 盖住了。下文统一用 YAML。

YAML 读进来后会展平成 properties 的形式：嵌套的 `server` → `port` 变成 `server.port`，列表项变成 `servers[0]`、`servers[1]`。下面三种读取方式里写的都是展平后的名字。

### 三种读取方式

假设配置文件里有一组自己定义的配置：

```yaml
book:
  page-size: 20
  admin-email: admin@example.com
  categories:
    - 计算机
    - 文学
```

**方式一：`@Value`**，读单个值。这是 Spring Framework 自带的注解，SSM 里读 `jdbc.properties` 用的也是它：

```java
@Value("${book.page-size}")
private int pageSize;

@Value("${book.timeout:30}")   // 冒号后面是默认值，配置里没有这个键时取 30
private int timeout;
```

**方式二：`Environment`**，注入整个环境对象，按名字取：

```java
@RestController
public class ConfigController {

    private final Environment env;

    public ConfigController(Environment env) {
        this.env = env;
    }

    @GetMapping("/config")
    public String show() {
        return env.getProperty("book.admin-email");
    }
}
```

适合配置项的名字要在运行时才能确定的情况，平时用得少。

**方式三：`@ConfigurationProperties`**，把一组配置绑定到一个对象上。这是 Boot 提供的，官方推荐自定义配置都用这种方式：

```java
@ConfigurationProperties(prefix = "book")
public record BookProperties(int pageSize, String adminEmail, List<String> categories) {
}
```

然后在启动类上加 `@ConfigurationPropertiesScan`，让 Boot 扫描并注册这类配置对象：

```java
@SpringBootApplication
@ConfigurationPropertiesScan
public class BookApplication { ... }
```

用的地方像普通 bean 一样注入：

```java
@Service
public class BookServiceImpl implements BookService {

    private final BookProperties props;

    public BookServiceImpl(BookProperties props) {
        this.props = props;
    }
    // props.pageSize()、props.categories()
}
```

注意配置里写的是 `page-size`，Java 里是 `pageSize`，照样绑得上。这叫**宽松绑定**（relaxed binding）：下面四种写法都能绑到 `pageSize` 上：

| 写法 | 说明 |
| --- | --- |
| `book.page-size` | 短横线分隔（kebab-case），配置文件里的推荐写法 |
| `book.pageSize` | 驼峰 |
| `book.page_size` | 下划线 |
| `BOOK_PAGESIZE` | 全大写加下划线，用在操作系统环境变量里 |

宽松绑定只作用于配置文件这一侧。注解里的 `prefix` 本身，官方要求必须写成短横线分隔的小写形式，比如 `my-book`，不能写成驼峰的 `myBook`。

用 record 时，Boot 通过构造器把值传进去，这要求编译时保留参数名（`-parameters`），继承了 `spring-boot-starter-parent` 就已经开好了。也可以写成带 getter/setter 的普通类。

三种方式怎么选，官方文档给了一张对比表：

| | `@ConfigurationProperties` | `@Value` |
| --- | --- | --- |
| 宽松绑定 | 支持 | 有限支持 |
| 元数据（IDE 自动补全配置项） | 支持 | 不支持 |
| SpEL 表达式 | 不支持 | 支持 |

结论：自己定义的、成组的配置用 `@ConfigurationProperties`，得到一个有类型的对象，IDE 还能补全；临时读一两个值用 `@Value`。用 `@Value` 时，占位符里的名字也写成短横线小写形式（`${book.page-size}`），这样它也能享受宽松绑定，`book.pageSize` 和环境变量 `BOOK_PAGESIZE` 都能读到。

**`@PropertySource` 不能加载 YAML。** SSM 里用 `@PropertySource("classpath:jdbc.properties")` 加载属性文件，这个注解只认 properties 格式。Boot 项目里的配置都放进 `application.yml`，用不着它。

### 配置文件可以放在哪：四个位置

`src/main/resources` 下的文件打包后进了 jar 里。生产环境的数据库密码不可能写进代码仓库，就需要在 jar 外面再放一份配置。Boot 默认会到这几个位置找 `application.yml`，**后面的覆盖前面的**：

1. classpath 根目录（`src/main/resources/`）
2. classpath 下的 `config/` 目录（`src/main/resources/config/`）
3. 当前目录（执行 `java -jar` 时所在的目录）
4. 当前目录下的 `config/` 子目录
5. `config/` 下的直接子目录（`config/*/`）

前两个在 jar 里，后三个在 jar 外。实际部署时，目录一般是这样：

```text
/opt/book/
├── book-demo.jar          里面带着开发用的 application.yml
└── config/
    └── application.yml    只写生产环境要改的那几项
```

在 `/opt/book` 下执行 `java -jar book-demo.jar`，外面的 `config/application.yml` 优先级更高。

覆盖是**按配置项**进行的，不是整个文件替换。外面的文件里只写了 `spring.datasource.password`，那就只有密码被换掉，jar 里的端口、连接池等其他配置照常生效。所以外部文件可以只写差异部分。

### 命令行参数和环境变量

配置文件之外，还有更高优先级的来源。官方文档列了十几个，日常用到的从低到高是：

```text
jar 里的 application.yml
  < jar 里的 application-{profile}.yml
  < jar 外的 application.yml
  < jar 外的 application-{profile}.yml
  < 操作系统环境变量
  < Java 系统属性（-D）
  < 命令行参数（--）
```

`application-{profile}.yml` 是下一节多环境用的文件。最常用的是最高优先级的命令行参数，临时改一个值不用动任何文件：

```bash
java -jar book-demo.jar --server.port=9000
```

`--` 开头的参数会被转换成配置项，覆盖所有配置文件里的同名项。

容器化部署时常用环境变量，按宽松绑定的规则把名字转成全大写加下划线：

```bash
SERVER_PORT=9000 java -jar book-demo.jar
```

一个配置项的值不符合预期时，就按这张优先级表从高往低查：命令行有没有传、环境变量里有没有、jar 外有没有配置文件。

## 多环境

### 问题

开发连本机数据库，测试环境连测试库，生产连生产库。[[Maven Profile]] 解决的是同一个问题，做法是**打包时**选一套配置写进包里，于是每个环境要打一个不同的包。

Boot 的做法是把三套配置都放进 jar，**启动时**用一个参数选择用哪套。同一个 jar 可以在任何环境运行，测试环境验证过的包就是上生产的包。

Boot 把这样一套环境配置叫一个 **profile**，名字自己起，常见的是 `dev`、`test`、`prod`。

### 多文件写法

每个环境一个文件，命名规则是 `application-{profile}.yml`：

```text
src/main/resources/
├── application.yml          公共配置 + 默认激活哪个环境
├── application-dev.yml
├── application-test.yml
└── application-prod.yml
```

```yaml
# application.yml
spring:
  profiles:
    active: dev
mybatis:
  type-aliases-package: com.example.domain
```

```yaml
# application-dev.yml
spring:
  datasource:
    url: jdbc:mysql://localhost:3306/ssm_db
    username: root
    password: root
```

```yaml
# application-prod.yml
server:
  port: 80
spring:
  datasource:
    url: jdbc:mysql://生产库地址:3306/ssm_db
    username: book_app
    password: ${DB_PASSWORD}
```

激活了 `dev`，Boot 会同时加载 `application.yml` 和 `application-dev.yml`，两者都有的配置项以 `application-dev.yml` 为准。公共配置只写在 `application.yml` 里，环境文件只写差异。

`${DB_PASSWORD}` 是占位符，从环境变量里取值。生产密码不进代码仓库，由服务器上的环境变量提供。

一个 profile 都没激活时，Boot 会启用一个名为 `default` 的默认 profile，这时如果有 `application-default.yml` 就会加载它。

### 单文件写法

环境不多时，也可以全写在一个 `application.yml` 里，用 `---` 分成多个文档（YAML 的多文档语法见 [[YAML]]）：

```yaml
spring:
  profiles:
    active: dev
---
spring:
  config:
    activate:
      on-profile: dev
server:
  port: 8080
---
spring:
  config:
    activate:
      on-profile: prod
server:
  port: 80
```

`spring.config.activate.on-profile` 表示这个文档只在指定的 profile 激活时生效。文档从上往下处理，后面的覆盖前面的。

properties 文件没有多文档语法，Boot 专门规定用单独一行的 `#---` 作为分隔符。

环境多、每个环境配置多的话，单文件会很长，用多文件写法更清楚。

### 激活和切换

`spring.profiles.active` 本身也是一个配置项，遵循上一节的优先级：文件里写的 `dev` 只是默认值，启动时用命令行参数就能**替换**它：

```bash
java -jar book-demo.jar --spring.profiles.active=prod
```

或者用环境变量 `SPRING_PROFILES_ACTIVE=prod`。同一个 jar，换一个参数就换一套环境。

可以同时激活多个，用逗号分隔：`--spring.profiles.active=prod,live`。多个环境文件里有同一个配置项时，**后列出的赢**，这里 `application-live.yml` 会覆盖 `application-prod.yml`。

有一条限制容易踩：**`spring.profiles.active` 只能写在非环境专属的地方。** 不能写在 `application-dev.yml` 里，也不能写在带 `on-profile` 的文档里。原因是要先知道激活了哪个 profile，才能决定加载哪个环境文件；如果环境文件里又写着「激活某个 profile」，就成了循环依赖。官方文档把这种写法明确列为无效配置。`spring.profiles.include`（在已激活的基础上追加 profile）和 `spring.profiles.group`（给一组 profile 起个总名字）也有同样的限制。

profile 不只用来切换配置值，也能控制哪些 bean 生效：类上加 `@Profile("dev")`，这个 bean 只在 `dev` 激活时才注册。比如只在开发环境注册一个往库里塞测试数据的组件。

### 和 Maven profile 联动

有时希望打包时就决定默认环境，比如提测的包默认就是 `test`，免得测试同学启动时忘了加参数。可以让 [[Maven Profile]] 把值写进 `application.yml`。

`spring-boot-starter-parent` 默认对 `application*.yml`、`application*.properties` 开启了资源过滤，但把占位符从 Maven 默认的 `${...}` 改成了 `@...@`，因为 `${...}` 已经是 Spring 自己的占位符语法，两边会冲突。

```yaml
# application.yml
spring:
  profiles:
    active: "@profile.active@"
```

```xml
<profiles>
  <profile>
    <id>dev</id>
    <activation>
      <activeByDefault>true</activeByDefault>
    </activation>
    <properties>
      <profile.active>dev</profile.active>
    </properties>
  </profile>
  <profile>
    <id>test</id>
    <properties>
      <profile.active>test</profile.active>
    </properties>
  </profile>
</profiles>
```

执行 `mvn package -P test`，打出的 jar 里 `application.yml` 的内容就变成了 `active: test`。

**`"@profile.active@"` 必须加引号。** `@` 是 YAML 的保留字符，不能出现在普通标量的开头。不加引号时，文件在被 Maven 替换之前就不是合法的 YAML，用 PyYAML 解析会直接报错：

```text
found character '@' that cannot start any token
```

比如在 IDE 里没走 Maven 的资源处理就直接运行，读到的就是这个原始文件。

这样打出来的包只是带了一个默认值，启动时仍然可以用 `--spring.profiles.active` 换掉。

## 整合 JUnit 和 MyBatis：迁移图书案例

现在把 [[SSM 整合]] 的图书管理接口整个搬到 Boot 上。

### 依赖

```xml
<dependencies>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-webmvc</artifactId>
    </dependency>
    <dependency>
        <groupId>org.mybatis.spring.boot</groupId>
        <artifactId>mybatis-spring-boot-starter</artifactId>
        <version>${mybatis-spring-boot.version}</version>
    </dependency>
    <dependency>
        <groupId>com.mysql</groupId>
        <artifactId>mysql-connector-j</artifactId>
        <scope>runtime</scope>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-test</artifactId>
        <scope>test</scope>
    </dependency>
</dependencies>
```

和 SSM 的依赖列表对照：

- `spring-webmvc`、`jakarta.servlet-api`、`jackson-databind` → 都在 `spring-boot-starter-webmvc` 里
- `mybatis`、`mybatis-spring`、`spring-jdbc` → 都在 `mybatis-spring-boot-starter` 里。它依赖了 `spring-boot-starter-jdbc`，所以连接池 HikariCP 也一起带进来了
- `mysql-connector-j` → 在 Boot 的版本清单上，不用写版本。驱动只在运行时用到，所以 scope 是 `runtime`
- `spring-test`、`junit-jupiter` → 都在 `spring-boot-starter-test` 里

**只有 MyBatis 的 starter 要写版本**，因为它不在 Boot 的清单上。版本要和 Boot 的版本对应，按 MyBatis 官方 README 里的对应关系：Boot 4.0 用 4.0.x，Boot 4.1 用 4.1.x，Boot 3.2~3.5 用 3.0.x。

SSM 用的连接池是 Druid，Boot 默认用 HikariCP。要换成别的连接池，引入它的依赖，再用 `spring.datasource.type` 指定实现类。

### 配置

SSM 的 `jdbc.properties` 和 `MyBatisConfig` 里的设置，全部换成 `application.yml` 里的几行：

```yaml
spring:
  datasource:
    url: jdbc:mysql://localhost:3306/ssm_db
    username: root
    password: root
mybatis:
  type-aliases-package: com.example.domain
```

不用写驱动类名，Boot 能从 URL 推断出大多数数据库的驱动。`spring.datasource.*` 是 Boot 的配置项，`mybatis.*` 是 MyBatis starter 定义的配置项，后者还支持 `mapper-locations`（XML 映射文件位置）、`configuration.map-underscore-to-camel-case`（下划线列名自动映射到驼峰属性）等。

### 五个配置类去哪了

逐项对照，SSM 里每一处手写的配置在 Boot 里由谁接管：

| SSM 里手写的 | Boot 里由谁完成 |
| --- | --- |
| `JdbcConfig` 的 `DataSource` | `DataSourceAutoConfiguration`，读 `spring.datasource.*` |
| `JdbcConfig` 的事务管理器 | `DataSourceTransactionManagerAutoConfiguration` |
| `@EnableTransactionManagement` | `TransactionAutoConfiguration` |
| `MyBatisConfig` 的 `SqlSessionFactory` | MyBatis starter 的 `MybatisAutoConfiguration` |
| `@MapperScan` | MyBatis starter 自动扫描 `@Mapper` 接口 |
| `SpringConfig` 的 `@ComponentScan` | `@SpringBootApplication` |
| `SpringMvcConfig` 的 `@EnableWebMvc` | `WebMvcAutoConfiguration` |
| `ServletContainerInitConfig` | `DispatcherServletAutoConfiguration` + 内嵌 Tomcat |
| 编码过滤器 `CharacterEncodingFilter` | `HttpEncodingAutoConfiguration` |
| 静态资源放行 | 默认映射 classpath 下的 `static/` 目录 |

`config` 包可以整个删掉。

还有一个变化不在表里：**父子容器没有了。** SSM 里根容器和 MVC 容器分开，扫描范围交叠会导致 Controller 404、事务静默失效（见 [[Spring MVC]]）。Boot 应用只有一个容器，`@SpringBootApplication` 从根包扫一遍，这类问题不再存在。

### Dao：给接口加 @Mapper

```java
@Mapper
public interface BookDao {

    @Select("SELECT * FROM tbl_book WHERE id = #{id}")
    Book getById(Integer id);

    // 其余方法和 SSM 里完全一样
}
```

MyBatis starter 默认会从启动类所在的包开始扫描带 `@Mapper` 的接口，为它们生成代理对象并注册成 bean。接口多时，嫌每个都加注解麻烦，也可以不加 `@Mapper`，在启动类上写 `@MapperScan("com.example.dao")`，效果一样。

Service、Controller 一行不用改，包括 `@Transactional`。

### 测试：@SpringBootTest

SSM 里测 Service 用的是 `@SpringJUnitConfig(SpringConfig.class)`，要手动指定加载哪个配置类。Boot 里换成：

```java
@SpringBootTest
class BookServiceTest {

    @Autowired
    private BookService bookService;

    @Test
    void getById() {
        System.out.println(bookService.getById(1));
    }
}
```

`@SpringBootTest` 不用指定配置类。它从测试类所在的包开始**往上**一层层找，直到找到带 `@SpringBootApplication` 的类，然后像正式启动一样创建整个容器，`application.yml` 也会照常加载。

这又是一条包结构的规矩：**测试类要放在启动类的包或其子包里。** 测试类在 `com.example.service`，往上找到 `com.example.BookApplication`，没问题。要是测试类放在 `com.demo` 下，往上找不到启动类，测试启动就失败。

另外两个默认行为：

- 默认**不启动**真正的 Web 服务器，只提供一个模拟的 Web 环境，测 Service、Dao 足够了。需要真实的 HTTP 端口时，用 `@SpringBootTest(webEnvironment = WebEnvironment.RANDOM_PORT)` 启动在一个随机端口上
- 测试方法上加 `@Transactional`，每个测试方法结束时事务**默认回滚**。测「新增图书」时数据不会真的留在库里，测试可以反复跑

`@SpringBootTest` 上已经带了 JUnit 的 Spring 扩展，不需要再写 `@ExtendWith(SpringExtension.class)`。

### 静态资源

SSM 的页面放在 `src/main/webapp/pages/` 下，还要在 `SpringMvcConfig` 里配置放行。Boot 打的是 jar，没有 `webapp` 目录，静态文件放到 classpath 下的 `static/` 目录即可：

```text
src/main/resources/
├── static/
│   ├── pages/books.html
│   ├── js/
│   └── css/
└── application.yml
```

`static/pages/books.html` 通过 `http://localhost:8080/pages/books.html` 访问，不需要任何配置。除了 `static/`，`public/`、`resources/`、`META-INF/resources/` 这几个目录也会被当作静态资源目录。

### 不用动的部分

`Result`、`Code`、`BusinessException`、`SystemException`、`@RestControllerAdvice` 这套统一响应和统一异常处理，是 Spring MVC 本身的功能，和怎么搭工程无关，从 [[SSM 整合]] 原样复制过来就能用。

迁移后的工程结构：

```text
book-demo
├── pom.xml                                    packaging 为 jar（默认）
└── src
    ├── main
    │   ├── java/com/example
    │   │   ├── BookApplication.java           启动类，在根包
    │   │   ├── controller                     BookController、Result、Code、异常处理器
    │   │   ├── dao/BookDao.java               加了 @Mapper
    │   │   ├── domain/Book.java
    │   │   ├── exception
    │   │   └── service
    │   └── resources
    │       ├── application.yml
    │       ├── application-dev.yml
    │       ├── application-prod.yml
    │       └── static/                        原 webapp 下的页面
    └── test/java/com/example/service/BookServiceTest.java
```

和 SSM 的结构比，少了整个 `config` 包、`jdbc.properties` 和 `webapp` 目录，多了一个启动类和几个配置文件。业务代码没有变化。

## 参考

- [Spring Boot 官方文档](https://docs.spring.io/spring-boot/index.html)
- [Developing Your First Spring Boot Application](https://docs.spring.io/spring-boot/tutorial/first-application/index.html)：最小项目、可执行 jar
- [Build Systems：Starters](https://docs.spring.io/spring-boot/reference/using/build-systems.html)、[Maven 插件：Inheriting the Starter Parent POM](https://docs.spring.io/spring-boot/maven-plugin/using.html)：parent 提供的默认配置
- [Auto-configuration](https://docs.spring.io/spring-boot/reference/using/auto-configuration.html)、[Creating Your Own Auto-configuration](https://docs.spring.io/spring-boot/reference/features/developing-auto-configuration.html)：条件注解与 imports 清单
- [Externalized Configuration](https://docs.spring.io/spring-boot/reference/features/external-config.html)：配置来源优先级、文件位置、宽松绑定、`@ConfigurationProperties` 与 `@Value` 对比
- [Profiles](https://docs.spring.io/spring-boot/reference/features/profiles.html)
- [Servlet Web Applications](https://docs.spring.io/spring-boot/reference/web/servlet.html)：MVC 自动配置与 `@EnableWebMvc`、静态资源
- [Testing Spring Boot Applications](https://docs.spring.io/spring-boot/reference/testing/spring-boot-applications.html)
- [MyBatis-Spring-Boot-Starter](https://mybatis.org/spring-boot-starter/mybatis-spring-boot-autoconfigure/)、[版本对应关系（README）](https://github.com/mybatis/spring-boot-starter)
