---
tags: [类型/概念, 技术/Spring, 技术/Servlet, 技术/Java]
aliases: [SpringMVC, Spring Web MVC]
created: 2026-10-03
updated: 2026-10-05
---
> Spring MVC 用一个总入口 `DispatcherServlet` 接管所有请求，再按 URL 分发给普通 Java 类里的普通方法；取参数、转类型、转 JSON 这些每个 [[Servlet]] 都在重复的活，由框架统一做掉。你写的 Controller 方法只剩「收参数 → 调 Service → 返回结果」三行。

## 典型场景

用 [[Servlet]] 给用户模块写增删改查，会得到四个类：`UserSaveServlet`、`UserDeleteServlet`、`UserUpdateServlet`、`UserQueryServlet`。每个类的开头都长这样：

```java
@WebServlet("/user/query")
public class UserQueryServlet extends HttpServlet {
    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String idStr = req.getParameter("id");             // 1. 取参数，永远是 String
        Integer id = Integer.valueOf(idStr);                // 2. 自己转类型，空串就炸
        User user = userService.findById(id);               // 3. 真正的业务，只有这一行
        resp.setContentType("application/json;charset=utf-8");
        resp.getWriter().write(mapper.writeValueAsString(user));  // 4. 自己转 JSON 写回去
    }
}
```

十几行代码里，业务只占一行，其余都是搬运：从请求里抠字符串、转成 `Integer`、把对象序列化成 [[JSON]]、设响应头。模块一多，Servlet 的数量跟着接口数量线性增长，每个类里都是同一套搬运代码。

换成 Spring MVC 之后，同一个功能是这样：

```java
@RestController
@RequestMapping("/users")
public class UserController {

    private final UserService userService;

    public UserController(UserService userService) {
        this.userService = userService;
    }

    @GetMapping("/{id}")
    public User findById(@PathVariable Integer id) {
        return userService.findById(id);
    }
}
```

参数直接是 `Integer`，返回值直接是 `User` 对象，四个接口写在同一个类里。中间那些搬运代码去了哪里，要从原理讲起。

## 原理：所有请求先进一个总入口

### 前端控制器

[[MVC 模式]] 里的 Controller 在 Servlet 时代是「一个 URL 一个 Servlet」，Spring MVC 改成了两级：

```text
                         ┌──────────────────────┐
浏览器 ──所有请求──▶     │  DispatcherServlet   │   ← 唯一注册到容器里的 Servlet
                         └──────────┬───────────┘
                                    │ 查表：这个 URL 归谁管？
                ┌───────────────────┼───────────────────┐
                ▼                   ▼                   ▼
     UserController.save()  UserController.findById()  BookController.list()
           （普通方法）           （普通方法）             （普通方法）
```

`DispatcherServlet` 叫**前端控制器**（front controller）：一个设计模式名词，意思是「所有请求先经过同一个入口，由它决定交给谁处理」。它本身就是一个标准的 `HttpServlet`，按 [[Servlet]] 规范注册到 [[Tomcat]] 里，容器眼里只有它一个 Servlet；后面那些 Controller 方法对容器来说是不可见的，它们只是 Spring 容器里的普通 bean。

这样拆的好处是，「取参数、转类型、写 JSON」这些公共逻辑只需要在入口处写一次，所有 Controller 方法共享。

### DispatcherServlet 手下的几个组件

`DispatcherServlet` 自己不干具体的活，而是委托给 Spring 容器里几类「特殊 bean」。入门阶段记住四个：

| 组件 | 负责什么 | 打个比方 |
| --- | --- | --- |
| `HandlerMapping` | 根据请求找到该由哪个处理器（handler）处理，连同要经过的拦截器一起返回。注解开发用的是 `RequestMappingHandlerMapping`，它认 `@RequestMapping` | 前台查通讯录：这个 URL 找谁 |
| `HandlerAdapter` | 真正调用那个处理器。调用注解方法需要解析参数上的注解、转换类型，这些细节都封在这里，`DispatcherServlet` 不用关心 | 翻译：把 HTTP 请求翻成方法参数 |
| `ViewResolver` | 把方法返回的字符串视图名（比如 `"userList"`）解析成真正的视图（比如 `/WEB-INF/userList.jsp`） | 把「去会议室」翻成具体门牌号 |
| `HandlerExceptionResolver` | 处理请求过程中抛出的异常，映射到错误页面或错误响应 | 事故处理组 |

**处理器（handler）** 在注解开发里就是那个 Controller 方法。Spring MVC 用「handler」这个泛称，是因为它也支持别的形态的处理器，`HandlerAdapter` 存在的意义就是把不同形态的处理器统一成一种调用方式。

### 一次请求的完整路径

官方文档把 `DispatcherServlet` 处理请求的过程列成了几步，去掉国际化、文件上传这类可选环节，主线是：

```text
GET /users/1
  │
  ▼
DispatcherServlet.service()
  │ ① 把 Spring 容器绑定到 request 属性上，后面的组件都能拿到
  │
  │ ② 问 HandlerMapping：/users/1 归谁？
  │      → UserController.findById() + 拦截器列表
  │
  │ ③ 执行链：拦截器前置处理 → 交给 HandlerAdapter 调用方法 → 拦截器后置处理
  │      HandlerAdapter：从 URL 抠出 "1" → 转成 Integer → 调方法 → 拿到 User 对象
  │      方法标了 @ResponseBody：直接把 User 转成 JSON 写进响应，不走视图
  │
  │ ④ 如果返回的是视图名：ViewResolver 找到视图，渲染页面
  │
  │ ⑤ 任何一步抛了异常：交给 HandlerExceptionResolver 处理
  ▼
响应返回浏览器
```

第 ③ 步有个分叉：**注解方式的 Controller，响应可以在 `HandlerAdapter` 内部就直接写完，不再返回视图**。前后端分离项目返回 JSON 时走的都是这条路，`ViewResolver` 根本不参与。这个细节会在 [[Spring MVC 拦截器]] 里再出现一次：拦截器的后置方法执行时，JSON 响应已经写出去了，改不了。

拦截器是 `HandlerMapping` 返回的执行链的一部分，也就是说它工作在 `DispatcherServlet` 内部；[[Servlet 过滤器]] 则在 `DispatcherServlet` 外面，由 Tomcat 调用。两者的区别见 [[Spring MVC 拦截器]]。

## 最原始的写法：web.xml + XML 配置

先用最「手工」的方式搭一遍，每一步都看得见，后面的简化写法才知道简化掉了什么。

### 依赖

```xml
<dependencies>
    <dependency>
        <groupId>org.springframework</groupId>
        <artifactId>spring-webmvc</artifactId>
        <version>${spring.version}</version>
    </dependency>
    <dependency>
        <groupId>jakarta.servlet</groupId>
        <artifactId>jakarta.servlet-api</artifactId>
        <version>${servlet.version}</version>
        <scope>provided</scope>
    </dependency>
</dependencies>
```

`spring-webmvc` 就是 Spring MVC 本体，它是 [[Spring Framework]] 的一个模块，会通过 [[Maven]] 的传递依赖把 `spring-context`、`spring-web` 一起带进来。Servlet API 用 `provided`，因为运行时 Tomcat 自己带了这套类，打进 war 包反而会冲突。

版本要对得上容器：**Spring Framework 7.0 以 Jakarta Servlet 6.1 为基线，要求部署在 Tomcat 11 及以上**。包名一律是 `jakarta.servlet`，`javax` 和 `jakarta` 的坑见 [[Servlet]]。

### 第一步：在 web.xml 里注册 DispatcherServlet

```xml
<web-app xmlns="https://jakarta.ee/xml/ns/jakartaee" version="6.1">

    <servlet>
        <servlet-name>app</servlet-name>
        <servlet-class>org.springframework.web.servlet.DispatcherServlet</servlet-class>
        <init-param>
            <param-name>contextConfigLocation</param-name>
            <param-value>classpath:spring-mvc.xml</param-value>
        </init-param>
        <load-on-startup>1</load-on-startup>
    </servlet>

    <servlet-mapping>
        <servlet-name>app</servlet-name>
        <url-pattern>/</url-pattern>
    </servlet-mapping>

</web-app>
```

逐项看：

- **`servlet-class`**：注册的就是 Spring 提供的 `DispatcherServlet`，你自己一个 Servlet 都不用写
- **`contextConfigLocation`**：`DispatcherServlet` 初始化时会自己创建一个 Spring 容器，这个参数告诉它去哪里读配置
- **`load-on-startup`**：Tomcat 启动时就初始化它。不写的话要等第一个请求进来才建 Spring 容器，第一个用户会等很久，而且配置写错了也要到那时才暴露
- **`url-pattern` 写 `/`**：把它设成默认 Servlet，所有没被别的 Servlet 认领的请求都归它。不写成 `/*`，因为 `/*` 是路径前缀匹配，优先级高于 `*.jsp` 这样的扩展名匹配，连服务器内部转发到 JSP 的请求都会被它截走，页面就渲染不出来了（匹配顺序见 [[Servlet]]）

写 `/` 也有代价：Tomcat 原本靠默认 Servlet 返回 `.html`、`.js`、图片这些静态文件，现在这个位置被 `DispatcherServlet` 占了，静态资源会 404。解决办法见 [[SSM 整合]]。

### 第二步：Spring MVC 配置文件

`src/main/resources/spring-mvc.xml`：

```xml
<beans xmlns="http://www.springframework.org/schema/beans"
       xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
       xmlns:context="http://www.springframework.org/schema/context"
       xmlns:mvc="http://www.springframework.org/schema/mvc"
       xsi:schemaLocation="
            http://www.springframework.org/schema/beans
            https://www.springframework.org/schema/beans/spring-beans.xsd
            http://www.springframework.org/schema/context
            https://www.springframework.org/schema/context/spring-context.xsd
            http://www.springframework.org/schema/mvc
            https://www.springframework.org/schema/mvc/spring-mvc.xsd">

    <!-- 扫描 Controller，把它们注册成 bean -->
    <context:component-scan base-package="com.example.controller"/>

    <!-- 打开 Spring MVC 的注解功能：@RequestMapping、JSON 转换等 -->
    <mvc:annotation-driven/>

</beans>
```

两行配置各管一件事：`component-scan` 让 Controller 进容器（扫描机制见 [[Spring IoC 与 DI]]），`annotation-driven` 注册 `HandlerMapping`、`HandlerAdapter` 等一整套 MVC 基础组件，并按类路径上有没有 Jackson 决定要不要支持 JSON。

**`<mvc:*>` 这套 XML 命名空间从 Spring Framework 7.0 起已被标记为弃用**，官方推荐改用 Java 配置。学它是为了看懂老项目，新项目直接用下一节的写法。

### 第三步：写一个 Controller

```java
package com.example.controller;

import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseBody;

@Controller
public class HelloController {

    @RequestMapping("/hello")
    @ResponseBody
    public String hello() {
        return "hello spring mvc";
    }
}
```

三个注解：

- **`@Controller`**：声明这是一个处理请求的 bean，本质和 `@Component` 一样，只是语义更明确
- **`@RequestMapping("/hello")`**：这个方法处理 `/hello` 请求。`HandlerMapping` 启动时会扫描所有带这个注解的方法，建一张「URL → 方法」的映射表
- **`@ResponseBody`**：把返回值直接写进响应体。不加的话，Spring MVC 会把 `"hello spring mvc"` 当成**视图名**去找一个叫这个名字的页面，结果是 404

部署到 Tomcat（上下文路径设为 `/demo`）后访问：

```bash
curl http://localhost:8080/demo/hello
```

```text
hello spring mvc
```

`@ResponseBody` 漏写导致 404，是入门阶段最常见的一个坑。404 的原因不是方法没被找到，而是方法执行完之后找视图没找到，看日志时注意区分。

## 去掉 web.xml：用 Java 配置启动

### 容器怎么在没有 web.xml 的情况下找到 Spring

Servlet 3.0 起规范提供了一个启动钩子 `ServletContainerInitializer`：容器启动时会扫描 jar 包里声明的这个接口的实现并调用它。`spring-web` 里带了一个实现 `SpringServletContainerInitializer`，它又会去找项目里所有实现了 Spring 自家接口 `WebApplicationInitializer` 的类，挨个调用它们的 `onStartup` 方法。

所以链条是：**Tomcat 启动 → 调 Spring 的钩子 → 调你写的 `WebApplicationInitializer` → 你在代码里注册 `DispatcherServlet`**。`web.xml` 里那段 `<servlet>` 配置，变成了 Java 代码。

### 第一步：直接实现 WebApplicationInitializer

先写 Spring MVC 的配置类，替代 `spring-mvc.xml`：

```java
@Configuration
@ComponentScan("com.example.controller")
@EnableWebMvc
public class SpringMvcConfig {
}
```

`@EnableWebMvc` 对应 XML 里的 `<mvc:annotation-driven/>`。然后手动注册 `DispatcherServlet`，这段代码和官方文档的示例是同一个结构：

```java
public class MyWebAppInitializer implements WebApplicationInitializer {

    @Override
    public void onStartup(ServletContext servletContext) {
        // 1. 创建 Spring 容器，加载 MVC 配置类
        AnnotationConfigWebApplicationContext context = new AnnotationConfigWebApplicationContext();
        context.register(SpringMvcConfig.class);

        // 2. 创建 DispatcherServlet 并注册到 Tomcat
        DispatcherServlet servlet = new DispatcherServlet(context);
        ServletRegistration.Dynamic registration = servletContext.addServlet("app", servlet);
        registration.setLoadOnStartup(1);
        registration.addMapping("/");
    }
}
```

和 `web.xml` 一一对照：`addServlet` 对应 `<servlet>`，`setLoadOnStartup(1)` 对应 `<load-on-startup>`，`addMapping("/")` 对应 `<url-pattern>`。信息量完全一样，只是从 XML 换成了 Java。

### 第二步：继承 AbstractDispatcherServletInitializer

上面那段代码里，「创建 `DispatcherServlet`、注册、设启动顺序」在每个项目里都一模一样，真正因项目而异的只有两件事：**用哪个 Spring 容器**、**映射哪些路径**。Spring 把固定部分写进了抽象类 `AbstractDispatcherServletInitializer`，你只需要填空：

```java
public class ServletContainerInitConfig extends AbstractDispatcherServletInitializer {

    // 给 DispatcherServlet 用的容器（Spring MVC 的 bean）
    @Override
    protected WebApplicationContext createServletApplicationContext() {
        AnnotationConfigWebApplicationContext ctx = new AnnotationConfigWebApplicationContext();
        ctx.register(SpringMvcConfig.class);
        return ctx;
    }

    // DispatcherServlet 映射的路径
    @Override
    protected String[] getServletMappings() {
        return new String[]{"/"};
    }

    // 根容器（Spring 的 bean：Service、Dao 等）
    @Override
    protected WebApplicationContext createRootApplicationContext() {
        AnnotationConfigWebApplicationContext ctx = new AnnotationConfigWebApplicationContext();
        ctx.register(SpringConfig.class);
        return ctx;
    }
}
```

这里第一次出现了**两个容器**：`createServletApplicationContext` 和 `createRootApplicationContext`。为什么要两个，见下一节。

### 第三步：继承 AbstractAnnotationConfigDispatcherServletInitializer（工程里的最终写法）

上一步的两个方法里，「`new` 一个注解容器 → `register` 配置类 → 返回」又是固定套路。Spring 再往下封装一层，你只交出配置类：

```java
public class ServletContainerInitConfig extends AbstractAnnotationConfigDispatcherServletInitializer {

    @Override
    protected Class<?>[] getRootConfigClasses() {
        return new Class<?>[]{SpringConfig.class};
    }

    @Override
    protected Class<?>[] getServletConfigClasses() {
        return new Class<?>[]{SpringMvcConfig.class};
    }

    @Override
    protected String[] getServletMappings() {
        return new String[]{"/"};
    }
}
```

三个方法，三句话：根容器加载哪些配置、MVC 容器加载哪些配置、`DispatcherServlet` 管哪些路径。不用 Spring Boot 的项目，用的基本都是这个写法，[[SSM 整合]] 也基于它。

回头看三步的演进：

| 写法 | 你要写的 | 框架替你做的 |
| --- | --- | --- |
| `web.xml` + XML | Servlet 注册、容器配置文件路径、XML 配置 | 创建容器 |
| `WebApplicationInitializer` | 建容器、注册 Servlet、设映射 | 被 Tomcat 自动发现 |
| `AbstractDispatcherServletInitializer` | 建容器、设映射 | 注册 Servlet |
| `AbstractAnnotationConfigDispatcherServletInitializer` | 给配置类、设映射 | 建容器、注册 Servlet |

## Spring 和 Spring MVC 为什么分开加载 bean

项目里已经有 Spring 容器，Spring MVC 仍要单独加载一份配置、单独扫描一次包。这是有意的分工，扫描范围没划清还会出问题。

### 两个容器，一父一子

上面的配置建出来的是一个**容器层级**：

```text
┌──────────────────────────────────────────────┐
│ 根容器（root WebApplicationContext）           │   由 getRootConfigClasses 加载
│   UserService、UserDao、DataSource、事务管理器   │   放「共享」的 bean
└──────────────────────▲───────────────────────┘
                       │ 子容器能看到父容器的 bean
                       │ 父容器看不到子容器的 bean
┌──────────────────────┴───────────────────────┐
│ DispatcherServlet 的容器（子容器）              │   由 getServletConfigClasses 加载
│   UserController、HandlerMapping、ViewResolver │   放「Web 相关」的 bean
└──────────────────────────────────────────────┘
```

官方文档的分工很明确：

- **DispatcherServlet 的容器**放 Web 相关的 bean：Controller、视图解析器、`HandlerMapping` 等
- **根容器**放共享的 bean：Service、Repository（Dao）、数据源等

查找 bean 时，子容器先找自己，找不到再去父容器找。所以 `UserController` 可以注入 `UserService`（子找父），而 `UserService` 注入不了任何 Controller（父看不到子）。这条单向可见性正好和 [[三层架构]] 的依赖方向一致：表现层依赖业务层，业务层不该反过来知道表现层的存在。

### 为什么要这样设计

这个设计最初是为「一个 Web 应用里有多个 `DispatcherServlet`」准备的。比如 `/app1/*` 和 `/app2/*` 由两个 `DispatcherServlet` 处理，各有一套 Controller，但它们共用同一批 Service 和数据源。共用的放根容器，各自的放子容器，Service 就只需要创建一份。

现在的项目大多只有一个 `DispatcherServlet`，分层的实际价值变成了两点：

1. **职责隔离**：Web 层的组件（Controller、拦截器、视图解析器）和业务层的组件分开管理，替换表现层技术时业务层的配置不用动
2. **防止层间反向依赖**：父看不到子，Service 不可能「顺手」注入一个 Controller

官方也说了，层级不是必须的：如果不需要，可以把所有配置都放进 `getRootConfigClasses`，`getServletConfigClasses` 返回 `null`，整个应用只有一个容器。

### 扫描范围交叠会出什么事

分两个容器之后，真正的坑在于**两边的扫描范围有交叠**。假设 `SpringConfig` 偷懒写成 `@ComponentScan("com.example")`，把 `controller` 包也扫进了根容器：

```text
根容器扫描 com.example     → UserService、UserDao、UserController（多扫了）
子容器扫描 com.example     → UserController、UserService（多扫了）、UserDao（多扫了）
```

会出现两类问题。

**问题一：Controller 只在根容器里时，请求全部 404。** `RequestMappingHandlerMapping` 默认只在**自己所在的容器**里找带 `@RequestMapping` 的方法，不会去父容器里找。如果 Controller 被扫进了根容器，而子容器的扫描范围里没有它，映射表里就是空的。启动时一切正常，访问时全部 404。

**问题二：Service 在子容器里又有一份时，`@Transactional` 静默失效。** 这个更隐蔽。`@EnableTransactionManagement` 写在根容器的配置里，它注册的「给 `@Transactional` 方法生成代理」的处理器属于 `BeanPostProcessor`。官方文档明确说过，**`BeanPostProcessor` 只处理它所在容器里的 bean，即使两个容器在同一个层级里也一样**。于是：

- 根容器里的 `UserService`：被处理过，是带事务的代理对象
- 子容器里又扫出来一个 `UserService`：没人处理，是没有事务的原始对象
- `UserController` 注入 `UserService` 时，子容器先找自己，**拿到的是没有事务的那份**

结果是 `@Transactional` 写了、事务管理器配了、代码看着完全正确，但出了异常数据不回滚，也不报任何错。事务代理的原理见 [[Spring AOP]] 和 [[Spring 事务管理]]。

### 怎么划清扫描范围

**做法一：按包精确扫描（推荐）。** 两边各扫各的，不交叠：

```java
@Configuration
@ComponentScan({"com.example.service", "com.example.dao"})
public class SpringConfig { }

@Configuration
@ComponentScan("com.example.controller")
@EnableWebMvc
public class SpringMvcConfig { }
```

**做法二：根容器扫大包，排除 Controller。** 包结构不规整、没法按包分开时用：

```java
@Configuration
@ComponentScan(
    value = "com.example",
    excludeFilters = @ComponentScan.Filter(type = FilterType.ANNOTATION, classes = Controller.class)
)
public class SpringConfig { }
```

`FilterType.ANNOTATION` 表示按注解过滤，`classes = Controller.class` 表示带 `@Controller` 的类不要。`@RestController` 上面标注了 `@Controller`，所以也会被一起排除。

做法二要注意：如果 `SpringMvcConfig` 本身也在 `com.example` 包下，它带着 `@Configuration`，会被根容器扫进去，连带着它上面的 `@ComponentScan("com.example.controller")` 也在根容器里生效，Controller 又被扫进来了。所以要么把 `SpringMvcConfig` 放到扫描范围之外的包，要么在 `excludeFilters` 里把它也排除掉。做法一没有这个问题，这也是推荐它的原因。

## 请求：参数交给框架绑定

### 先看原始写法

Controller 方法的参数里可以直接声明 `HttpServletRequest`，Spring MVC 会把当前请求对象传进来，写法和 Servlet 完全一样：

```java
@RequestMapping("/save")
@ResponseBody
public String save(HttpServletRequest request) {
    String name = request.getParameter("name");
    int age = Integer.parseInt(request.getParameter("age"));
    return "ok";
}
```

能用，但等于没用上框架。

### 同名参数：什么都不用写

```java
@RequestMapping("/save")
@ResponseBody
public String save(String name, int age) {
    return "name=" + name + ", age=" + age;
}
```

```bash
curl "http://localhost:8080/demo/save?name=tom&age=18"
```

```text
name=tom, age=18
```

请求参数名和方法形参名相同，就自动绑定，`"18"` 也自动转成了 `int`。背后的规则是官方文档里的一条兜底规则：**一个方法参数如果没有被其他参数解析器认领，而且是「简单类型」，就当成加了 `@RequestParam` 处理；不是简单类型，就当成 `@ModelAttribute`（按属性绑定成对象）处理。**

「简单类型」指基本类型及其包装类、`String`、枚举、数字、日期、`java.time` 时间类型、`UUID`、`URI` 等，以及**由这些类型组成的数组**。

这条规则有个前提：**编译时得保留参数名**。字节码里默认不保存形参名，Spring 拿不到 `name`、`age` 这两个名字就没法按名字匹配。从 Spring 6.1 起要求编译时带上 `-parameters` 标志，否则按名字匹配会失败，详见 [[Spring IoC 与 DI]]。用 Spring Boot 的父 POM 会自动加上这个标志，自己搭的项目要在 `maven-compiler-plugin` 里配。

### @RequestParam：名字对不上，或者要设成可选

```java
@RequestMapping("/save")
@ResponseBody
public String save(@RequestParam("username") String name,
                   @RequestParam(required = false) Integer age) {
    return "name=" + name + ", age=" + age;
}
```

- **改名**：前端传的是 `username`，方法里想叫 `name`，用 `@RequestParam("username")` 指明
- **可选**：**加了 `@RequestParam` 的参数默认是必传的**，请求里没有这个参数就直接返回 400。要设成可选，写 `required = false`，或者把参数类型声明成 `Optional<Integer>`

可选参数要用 `Integer` 而不是 `int`：参数缺失时值是 `null`，基本类型 `int` 装不下 `null`。

### POJO：参数多了直接收成对象

```java
public class User {
    private String name;
    private Integer age;
    private Address address;    // 嵌套对象
    // getter / setter 省略
}

public class Address {
    private String city;
    // getter / setter 省略
}
```

```java
@RequestMapping("/save")
@ResponseBody
public String save(User user) {
    return user.toString();
}
```

```bash
curl "http://localhost:8080/demo/save?name=tom&age=18&address.city=beijing"
```

`User` 不是简单类型，按兜底规则当成 `@ModelAttribute`：框架先创建一个 `User`，再把请求参数按名字设到同名属性上。嵌套属性用点号表示，`address.city` 会被设到 `user.getAddress().setCity(...)`。

### 数组和集合

同名参数传多个值，比如复选框：

```bash
curl "http://localhost:8080/demo/likes?like=game&like=music"
```

**数组**直接收，因为字符串数组属于「简单类型组成的数组」：

```java
@RequestMapping("/likes")
@ResponseBody
public String likes(String[] like) {
    return Arrays.toString(like);
}
```

**集合必须加 `@RequestParam`**：

```java
@RequestMapping("/likes")
@ResponseBody
public String likes(@RequestParam List<String> like) {
    return like.toString();
}
```

不加会出错，原因还是那条兜底规则：`List` 不是简单类型，框架会把它当成 `@ModelAttribute`，试图「创建一个 `List` 对象，再把参数设到它的属性上」。`List` 是接口，没法创建，而且 `like` 也不是 `List` 的属性。加上 `@RequestParam` 就是明确告诉框架：这是一个请求参数，把多个值收成集合。

### 日期

请求参数里的日期是字符串，转成日期类型需要知道格式：

```java
@RequestMapping("/date")
@ResponseBody
public String date(@DateTimeFormat(pattern = "yyyy-MM-dd") LocalDate day) {
    return day.toString();
}
```

`@DateTimeFormat` 也可以写在 POJO 的字段上。它只管**请求参数**（URL 查询串和表单），管不到下面要讲的 JSON 请求体：JSON 由 Jackson 解析，日期格式要用 Jackson 自己的 `@JsonFormat` 注解来指定。两套注解分别对应两套转换机制，用错了地方不会报错，只是不生效。

### JSON 请求体：@RequestBody

前后端分离项目里，前端用 [[AJAX]] 发的通常是 JSON：

```http
POST /demo/users HTTP/1.1
Content-Type: application/json

{"name":"tom","age":18,"address":{"city":"beijing"}}
```

[[JSON]] 那篇讲过，这种请求体 `getParameter` 读不到，得自己从流里读出来再用 Jackson 解析。Spring MVC 里一个注解就够了：

```java
@PostMapping("/users")
@ResponseBody
public String save(@RequestBody User user) {
    return user.toString();
}
```

`@RequestBody` 让框架读取请求体，交给 **`HttpMessageConverter`（消息转换器）** 转成 `User`。消息转换器是一组「请求体/响应体 ↔ Java 对象」的转换器，JSON 用的是基于 Jackson 的那个。它要生效需要两个条件：

1. **类路径上有 Jackson**。Spring Framework 7 默认使用 Jackson 3（Maven 坐标 `tools.jackson.core:jackson-databind`），Jackson 2（`com.fasterxml.jackson.core`）只作为后备，已被标记为弃用
2. **开启了 MVC 配置**：`@EnableWebMvc`，它会按类路径探测并注册 JSON 转换器

集合同理，`@RequestBody List<User> users` 可以直接接收 JSON 数组。

### 中文乱码：一个过滤器统一解决

POST 表单里的中文，在 [[Servlet]] 里需要在读参数之前调 `request.setCharacterEncoding("UTF-8")`。Spring 提供了现成的过滤器 `CharacterEncodingFilter` 干这件事，在初始化类里重写 `getServletFilters` 注册：

```java
public class ServletContainerInitConfig extends AbstractAnnotationConfigDispatcherServletInitializer {
    // ...前面三个方法省略

    @Override
    protected Filter[] getServletFilters() {
        CharacterEncodingFilter filter = new CharacterEncodingFilter();
        filter.setEncoding("UTF-8");
        return new Filter[]{filter};
    }
}
```

这里返回的过滤器会**自动映射到 `DispatcherServlet` 上**，所有经过它的请求都会先设好编码。过滤器的工作方式见 [[Servlet 过滤器]]。

### 三个参数注解怎么选

| 注解 | 数据从哪来 | 典型场景 |
| --- | --- | --- |
| `@RequestParam` | URL 查询串 `?id=1`、表单 | 分页参数、搜索条件、少量简单值 |
| `@PathVariable` | URL 路径本身 `/users/1` | REST 风格里标识资源的 id（见下文） |
| `@RequestBody` | 请求体（JSON） | 新增、修改时提交的整个对象 |

一个方法里 `@RequestBody` 最多只能有一个：请求体是只能读一次的流，读完就没了。

## 响应：返回页面还是返回数据

### 返回页面

方法返回 `String` 且**没有** `@ResponseBody` 时，返回值是视图名：

```java
@Controller
public class PageController {

    @RequestMapping("/toList")
    public String toList() {
        return "userList";     // 交给 ViewResolver 找页面
    }

    @RequestMapping("/afterSave")
    public String afterSave() {
        return "redirect:/toList";    // 重定向
    }
}
```

用 [[JSP]] 时，在 MVC 配置类里注册 JSP 视图解析器，它的默认前缀是 `/WEB-INF/`、后缀是 `.jsp`，`"userList"` 就会被解析成 `/WEB-INF/userList.jsp`。JSP 放在 `WEB-INF` 下面，浏览器不能直接访问，只能经过 Controller 跳转，这是官方推荐的做法。

```java
@Configuration
@ComponentScan("com.example.controller")
@EnableWebMvc
public class SpringMvcConfig implements WebMvcConfigurer {

    @Override
    public void configureViewResolvers(ViewResolverRegistry registry) {
        registry.jsp();
    }
}
```

视图名前加 `redirect:` 表示重定向，剩下的部分是重定向地址，`/` 开头时相对于当前应用。转发和重定向的区别见 [[Servlet]]。

### 返回数据：@ResponseBody

前后端分离项目基本不返回页面，而是返回 JSON：

```java
@RequestMapping("/user")
@ResponseBody
public User getUser() {
    User user = new User();
    user.setName("tom");
    user.setAge(18);
    return user;
}
```

```bash
curl -i http://localhost:8080/demo/user
```

```text
HTTP/1.1 200
Content-Type: application/json

{"name":"tom","age":18,"address":null}
```

`@ResponseBody` 让返回值经过 `HttpMessageConverter` 写进响应体，和 `@RequestBody` 是同一套机制的两个方向。返回 `String` 时用的是字符串转换器，原样输出；返回对象或集合时用 JSON 转换器，序列化成 JSON，`Content-Type` 也由它设置。

`@ResponseBody` 可以写在类上，表示类里所有方法都这样返回。`@Controller` 加类级 `@ResponseBody` 太常见了，于是有了合并注解 `@RestController`，下一节就用它。

## REST 风格：用 URL 表示资源，用 HTTP 方法表示动作

### 问题：URL 越写越乱

按前面的写法，用户模块的接口大概是这样：

```text
/user/save          新增
/user/delete?id=1   删除
/user/update        修改
/user/getById?id=1  查一个
/user/getAll        查全部
```

URL 里混着动词（save、delete、getById），每个人起名习惯不同，团队里很快会出现 `/user/add`、`/user/remove`、`/user/queryOne` 这样的同义词。前端拿到一份接口文档，得一个个记。

### REST 的做法

**REST**（Representational State Transfer，表述性状态转移）是一种接口设计风格。核心思想只有两条：

1. **URL 只表示资源**（名词），一般用复数：`/users` 是用户集合，`/users/1` 是 id 为 1 的用户
2. **动作由 HTTP 方法表示**（动词）

| 操作 | 原来的 URL | REST 风格 |
| --- | --- | --- |
| 新增 | `POST /user/save` | `POST /users` |
| 删除 | `GET /user/delete?id=1` | `DELETE /users/1` |
| 修改 | `POST /user/update` | `PUT /users` |
| 查一个 | `GET /user/getById?id=1` | `GET /users/1` |
| 查全部 | `GET /user/getAll` | `GET /users` |

同一个 URL `/users/1`，`GET` 是查、`DELETE` 是删，动作的含义交给 [[HTTP]] 协议本身。HTTP 方法还带着「安全」「幂等」的语义：`GET` 不应该改数据，`PUT`、`DELETE` 重复发也不会造成额外影响，这些性质对缓存、自动重试都有意义。原来用 `GET /user/delete?id=1` 删数据，就违反了 `GET` 只读的约定，如果哪个爬虫或预加载插件顺着链接访问一遍，数据就被删了。

REST 是**风格**，不是规范。「资源用复数」「修改用 `PUT`」这些都是约定，不遵守也不会报错，所以团队内部要统一。

### 原始实现：@RequestMapping 指定方法 + @PathVariable

```java
@Controller
public class UserController {

    @RequestMapping(value = "/users", method = RequestMethod.POST)
    @ResponseBody
    public String save(@RequestBody User user) {
        return "save " + user;
    }

    @RequestMapping(value = "/users/{id}", method = RequestMethod.DELETE)
    @ResponseBody
    public String delete(@PathVariable Integer id) {
        return "delete " + id;
    }

    @RequestMapping(value = "/users", method = RequestMethod.PUT)
    @ResponseBody
    public String update(@RequestBody User user) {
        return "update " + user;
    }

    @RequestMapping(value = "/users/{id}", method = RequestMethod.GET)
    @ResponseBody
    public String getById(@PathVariable Integer id) {
        return "getById " + id;
    }

    @RequestMapping(value = "/users", method = RequestMethod.GET)
    @ResponseBody
    public String getAll() {
        return "getAll";
    }
}
```

新出现的两样东西：

- **`method = RequestMethod.DELETE`**：同一个 URL 按 HTTP 方法区分处理器，`DELETE /users/1` 和 `GET /users/1` 进的是不同的方法
- **`{id}` 和 `@PathVariable`**：`{id}` 是 URL 模板变量，占住路径里的一段；`@PathVariable` 把这一段的值绑定到同名参数上。变量名和参数名不同时写 `@PathVariable("id") Integer userId`

```bash
curl -X DELETE http://localhost:8080/demo/users/1
```

```text
delete 1
```

### 工程写法：@RestController + 方法专用注解

上面每个方法都在重复三样东西：路径前缀 `/users`、`method = ...`、`@ResponseBody`。逐个消掉：

```java
@RestController                  // = @Controller + @ResponseBody
@RequestMapping("/users")        // 类级公共路径
public class UserController {

    @PostMapping
    public String save(@RequestBody User user) {
        return "save " + user;
    }

    @DeleteMapping("/{id}")
    public String delete(@PathVariable Integer id) {
        return "delete " + id;
    }

    @PutMapping
    public String update(@RequestBody User user) {
        return "update " + user;
    }

    @GetMapping("/{id}")
    public String getById(@PathVariable Integer id) {
        return "getById " + id;
    }

    @GetMapping
    public String getAll() {
        return "getAll";
    }
}
```

- **`@RestController`**：类级的 `@Controller` + `@ResponseBody`，类里所有方法都直接返回数据
- **类上的 `@RequestMapping("/users")`**：所有方法共享的路径前缀，方法上只写剩下的部分
- **`@GetMapping`、`@PostMapping`、`@PutMapping`、`@DeleteMapping`、`@PatchMapping`**：`@RequestMapping(method = ...)` 的简写，一个 HTTP 方法对应一个

这就是开头那段 Controller 的完整形态。

### 浏览器表单只能发 GET 和 POST

用 [[AJAX]]（Axios、`fetch`）可以直接发 `PUT`、`DELETE`，没有限制。但 HTML 的 `<form>` 只支持 `GET` 和 `POST`。用传统表单提交时，Spring 提供了 `HiddenHttpMethodFilter` 过滤器：表单用 `POST` 提交，再带一个隐藏字段 `_method`，过滤器会把请求方法改成这个字段的值。

```html
<form action="/demo/users/1" method="post">
    <input type="hidden" name="_method" value="DELETE">
    <button>删除</button>
</form>
```

它只允许把 `POST` 改成 `PUT`、`DELETE`、`PATCH` 三种。注册方式和 `CharacterEncodingFilter` 一样，放进 `getServletFilters` 返回的数组里。前后端分离项目用不到它。

## 在 Spring Boot 里

上面的初始化类、`@EnableWebMvc`、编码过滤器、Jackson 依赖、Tomcat 部署，在 [[Spring Boot]] 里都由自动配置完成，项目里通常只剩 Controller 本身。Boot 项目里**不要**加 `@EnableWebMvc`，原因和替代写法见 [[Spring Boot#覆盖默认配置]]。

## 参考

- [Spring Web MVC 官方文档](https://docs.spring.io/spring-framework/reference/web/webmvc.html)
- [DispatcherServlet](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-servlet.html)：特殊 bean、处理流程见子页面「Special Bean Types」「Processing」
- [Context Hierarchy](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-servlet/context-hierarchy.html)：父子容器
- [Servlet Config](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-servlet/container-config.html)：`AbstractAnnotationConfigDispatcherServletInitializer`
- [Method Arguments](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-controller/ann-methods/arguments.html)：参数绑定的兜底规则
- [Spring Framework 7.0 Release Notes](https://github.com/spring-projects/spring-framework/wiki/Spring-Framework-7.0-Release-Notes)：Jackson 3、Servlet 6.1 基线、XML 命名空间弃用
