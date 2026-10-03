---
tags: [类型/概念, 技术/Spring, 技术/Java]
aliases: [Spring 拦截器]
created: 2026-10-03
updated: 2026-10-03
---
> 拦截器是 [[Spring MVC]] 内部的关卡，夹在 `DispatcherServlet` 和 Controller 方法之间，有三个时机：方法执行前（`preHandle`，能拦下请求）、方法执行后（`postHandle`）、整个请求结束后（`afterCompletion`）。它和 [[Servlet 过滤器]] 最大的区别是：它知道这次请求要执行的是哪个 Controller 方法。

## 典型场景

[[SSM 整合]] 里的图书系统要加两条规则：

1. 除了登录接口，所有接口都要先登录才能调
2. 统计每个接口的耗时，慢于 500 毫秒的记一条日志

这两件事和 [[Servlet 过滤器]] 开头的「登录检查」是同一类：每个接口都要做，不能复制到每个方法里。用过滤器当然能做，但很快会碰到过滤器做不好的地方：

- 产品又提了一条：「图书列表和详情允许游客看」。过滤器只能按 URL 判断，`GET /books/1` 放行、`DELETE /books/1` 拦截，同一个 URL 要按 HTTP 方法再分一次，规则全写在过滤器的 `if` 里。如果能在 Controller 方法上打一个「公开」标记，让拦截逻辑读这个标记来决定，就清楚多了。过滤器做不到这一点，因为它执行的时候，Spring MVC 还没决定这个请求交给哪个方法
- 过滤器里抛出的异常，[[SSM 整合]] 里配好的 `@RestControllerAdvice` 接不住，前端又会收到 Tomcat 的错误页

拦截器正好补上这两点。它运行在 `DispatcherServlet` 内部，执行时**已经知道要调用哪个 Controller 方法**，可以读方法上的注解；它抛的异常也走 Spring MVC 的异常处理流程。

## 它站在哪

```text
浏览器请求 GET /ssm/books/1
   │
   ▼
Tomcat
   │
   ▼
Filter 链（CharacterEncodingFilter 等）         ← 过滤器：Servlet 规范，Tomcat 调用
   │
   ▼
DispatcherServlet
   │  HandlerMapping：/books/1 → BookController.getById() + 拦截器列表
   │
   ▼
LoginInterceptor.preHandle()        ← 返回 false：请求到此为止
   │  返回 true
   ▼
BookController.getById()            ← 真正的业务方法
   │
   ▼
LoginInterceptor.postHandle()       ← 方法正常执行完才会调
   │
   ▼
（视图渲染，返回 JSON 的接口没有这一步）
   │
   ▼
LoginInterceptor.afterCompletion()  ← 请求结束，无论成功还是异常都会调
   │
   ▼
响应返回浏览器
```

拦截器是 `HandlerMapping` 找处理器时一起返回的「执行链」的一部分（处理流程见 [[Spring MVC]]）。所以它只对**进了 `DispatcherServlet`、而且找到了处理器**的请求生效。

## 三个方法

`HandlerInterceptor` 接口的三个方法都有默认实现（空实现，`preHandle` 默认返回 `true`），用到哪个重写哪个：

```java
public interface HandlerInterceptor {

    default boolean preHandle(HttpServletRequest request, HttpServletResponse response,
                              Object handler) throws Exception {
        return true;
    }

    default void postHandle(HttpServletRequest request, HttpServletResponse response,
                            Object handler, @Nullable ModelAndView modelAndView) throws Exception {
    }

    default void afterCompletion(HttpServletRequest request, HttpServletResponse response,
                                 Object handler, @Nullable Exception ex) throws Exception {
    }
}
```

三个方法都有一个 `handler` 参数，这就是「要执行的那个处理器」。注解开发时它的实际类型是 `HandlerMethod`，里面装着 Controller 对象和要调用的 `Method`，能读到方法上的注解。

### preHandle：执行前，能拦截

Controller 方法执行之前调用，返回 `boolean`：

- **返回 `true`**：放行，继续执行下一个拦截器，最后执行 Controller 方法
- **返回 `false`**：执行链到此中断，Controller 方法不会被调用。`DispatcherServlet` 认为拦截器**已经自己处理好了响应**，所以返回 `false` 之前要么写好响应内容，要么设置状态码，否则前端收到的是一个空白的 200

这是三个方法里最常用的一个，登录检查、权限判断、参数预处理都写在这里。

### postHandle：执行后，渲染视图前

Controller 方法**正常执行完**之后、视图渲染之前调用。方法抛了异常就不会调用它。参数里的 `ModelAndView` 是方法返回的模型和视图，可以往里面补数据，所有页面都要用的公共数据（比如当前用户名）可以在这里统一加。

有一个限制要记住：**`@ResponseBody` 和 `ResponseEntity` 的方法，响应在 `HandlerAdapter` 内部就已经写完并提交了，然后才调 `postHandle`**。这时候再想加响应头、改返回内容，已经晚了。前后端分离项目里所有接口都是返回 JSON 的，所以 `postHandle` 在这类项目里基本用不上。确实要统一改 JSON 响应的，官方推荐实现 `ResponseBodyAdvice` 接口，声明成 Controller Advice bean。

### afterCompletion：请求结束后

整个请求处理完（包括视图渲染）之后调用，**不管成功还是抛了异常都会调**，适合做清理工作和统计。

两个注意点：

- **只有当前拦截器的 `preHandle` 返回了 `true`，它的 `afterCompletion` 才会被调用。** 自己都没放行，也就没有需要清理的东西
- **参数 `ex` 不包括已经被异常解析器处理掉的异常。** 在 [[SSM 整合]] 里，异常都被 `@RestControllerAdvice` 处理成了统一响应结果，到这里 `ex` 往往是 `null`。所以不能靠「`ex` 是不是 `null`」来判断这次请求有没有出错

## 最原始的写法：实现接口 + XML 注册

```java
public class LoginInterceptor implements HandlerInterceptor {

    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response,
                             Object handler) throws Exception {
        Object user = request.getSession().getAttribute("user");
        if (user == null) {
            response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);   // 401
            return false;
        }
        return true;
    }
}
```

在 Spring MVC 的 XML 配置文件里注册：

```xml
<mvc:interceptors>
    <mvc:interceptor>
        <mvc:mapping path="/**"/>
        <mvc:exclude-mapping path="/users/login"/>
        <bean class="com.example.interceptor.LoginInterceptor"/>
    </mvc:interceptor>
</mvc:interceptors>
```

`<mvc:mapping>` 指定拦截哪些路径，`<mvc:exclude-mapping>` 指定排除哪些路径，`/**` 表示任意多级路径。和 [[Spring MVC]] 里讲过的一样，`<mvc:*>` 命名空间从 Spring Framework 7.0 起已被弃用，这种写法只需要能看懂。

## 工程写法：WebMvcConfigurer.addInterceptors

拦截器本身写成一个 Spring bean：

```java
@Component
public class LoginInterceptor implements HandlerInterceptor {
    // preHandle 同上
}
```

在 MVC 配置类里注册：

```java
@Configuration
@ComponentScan({"com.example.controller", "com.example.interceptor"})
@EnableWebMvc
public class SpringMvcConfig implements WebMvcConfigurer {

    private final LoginInterceptor loginInterceptor;

    public SpringMvcConfig(LoginInterceptor loginInterceptor) {
        this.loginInterceptor = loginInterceptor;
    }

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(loginInterceptor)
                .addPathPatterns("/**")
                .excludePathPatterns("/users/login");
    }
}
```

几点说明：

- **拦截器要放进 MVC 容器**：它属于 Web 层，扫描路径要在 `SpringMvcConfig` 这边。拦截器是 Spring bean，所以它可以注入 Service，比如查数据库校验 token。父子容器的分工见 [[Spring MVC]]
- **`addPathPatterns` 和 `excludePathPatterns`** 对应 XML 里的 `mapping` 和 `exclude-mapping`，都接受多个路径
- **路径不包含应用的上下文路径**：应用部署在 `/ssm` 下时，排除登录接口写 `/users/login`，不写 `/ssm/users/login`

## 手把手：登录检查 + 耗时统计

回到开头的两条需求，用上面学到的东西写完整。

### 第一步：用注解标记公开接口

```java
@Target(ElementType.METHOD)
@Retention(RetentionPolicy.RUNTIME)
public @interface PublicApi {
}
```

`@Retention(RetentionPolicy.RUNTIME)` 让注解保留到运行时，拦截器才能通过反射读到它。

```java
@RestController
@RequestMapping("/books")
public class BookController {

    @PublicApi
    @GetMapping("/{id}")
    public Result getById(@PathVariable Integer id) { ... }

    @PublicApi
    @GetMapping
    public Result getAll() { ... }

    @DeleteMapping("/{id}")
    public Result delete(@PathVariable Integer id) { ... }   // 没有标记，需要登录
}
```

「哪些接口公开」现在写在接口自己身上，新增接口时一眼就能看到，不用去翻拦截器里的路径列表。

### 第二步：登录拦截器读注解

```java
@Component
public class LoginInterceptor implements HandlerInterceptor {

    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response,
                             Object handler) {
        // 1. 不是 Controller 方法（比如静态资源），直接放行
        if (!(handler instanceof HandlerMethod method)) {
            return true;
        }
        // 2. 标了 @PublicApi 的方法，放行
        if (method.hasMethodAnnotation(PublicApi.class)) {
            return true;
        }
        // 3. 已登录，放行
        if (request.getSession().getAttribute("user") != null) {
            return true;
        }
        // 4. 未登录：抛业务异常，交给统一异常处理返回 JSON
        throw new BusinessException(Code.BUSINESS_ERR, "请先登录");
    }
}
```

逐条解释：

- **第 1 步为什么要判断类型**：`handler` 不一定是 `HandlerMethod`。[[SSM 整合]] 里讲过静态资源的两种放行方式，用 `addResourceHandlers` 那种时，`/pages/books.html` 由 Spring MVC 的资源处理器（`ResourceHttpRequestHandler`）处理，它所在的映射同样会挂上你注册的拦截器。这时 `handler` 是资源处理器而不是 Controller 方法，直接强转会抛 `ClassCastException`。`instanceof HandlerMethod method` 是 Java 16 起的模式匹配写法，判断和转换一步完成
- **第 2 步**：`hasMethodAnnotation` 检查方法上有没有某个注解，这一步过滤器做不到
- **第 4 步为什么抛异常而不是返回 `false`**：拦截器运行在 `DispatcherServlet` 内部，它抛的异常会交给 [[SSM 整合]] 里的 `@RestControllerAdvice` 处理，前端收到的就是统一格式的 `{"code":40000,"data":null,"msg":"请先登录"}`。如果返回 `false`，就得自己设置响应头、自己把 `Result` 转成 JSON 写进响应，重复了异常处理器已经做好的事

### 第三步：耗时统计拦截器

```java
@Component
public class TimeInterceptor implements HandlerInterceptor {

    private static final Logger log = LoggerFactory.getLogger(TimeInterceptor.class);
    private static final String START = "TimeInterceptor.start";

    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response,
                             Object handler) {
        request.setAttribute(START, System.currentTimeMillis());
        return true;
    }

    @Override
    public void afterCompletion(HttpServletRequest request, HttpServletResponse response,
                                Object handler, Exception ex) {
        long start = (long) request.getAttribute(START);
        long cost = System.currentTimeMillis() - start;
        if (cost > 500) {
            log.warn("慢接口 {} {} 耗时 {} ms", request.getMethod(), request.getRequestURI(), cost);
        }
    }
}
```

（`Logger` 来自 SLF4J，需要单独引入日志依赖。）

**开始时间存在 request 里，不能存在拦截器的成员变量里。** 拦截器是 Spring 容器里的单例 bean，所有请求共用同一个对象。如果写成 `private long start;`，请求 A 刚记下开始时间，请求 B 进来就把它覆盖了，A 算出来的耗时就是错的，而且是偶尔才错，很难复现。request 对象每个请求一份，存在它的属性里天然隔离（请求域见 [[Servlet]]）。这条规则对所有单例 bean 都成立：**不要在单例 bean 的成员变量里保存某一次请求的数据**。

耗时统计写在 `afterCompletion` 而不是 `postHandle`：`postHandle` 在方法抛异常时不会被调用，而出异常的慢请求同样需要记录。

### 第四步：注册两个拦截器

```java
@Override
public void addInterceptors(InterceptorRegistry registry) {
    registry.addInterceptor(timeInterceptor).addPathPatterns("/**");
    registry.addInterceptor(loginInterceptor).addPathPatterns("/**");
}
```

耗时统计放在前面注册，原因见下一节的执行顺序。

## 多个拦截器的执行顺序

### 按注册顺序进，按反序出

多个拦截器的顺序默认就是注册顺序，也可以用 `.order(int)` 显式指定。执行规则：

- `preHandle`：**按顺序**执行
- `postHandle`：**反序**执行
- `afterCompletion`：**反序**执行，而且只执行那些 `preHandle` 返回了 `true` 的拦截器

假设注册了 A、B 两个拦截器，每个方法里打一行日志。请求正常通过时：

```text
A.preHandle
B.preHandle
Controller 方法
B.postHandle
A.postHandle
B.afterCompletion
A.afterCompletion
```

形状和 [[Servlet 过滤器]] 的「去而复返」一样，先进去的后出来。

### 中间有一个拦截了

如果 B 的 `preHandle` 返回 `false`：

```text
A.preHandle            → true
B.preHandle            → false，执行链中断
A.afterCompletion      ← 只有 A 放行过，所以只有 A 收尾
```

Controller 方法不执行，所有的 `postHandle` 都不执行；B 自己没放行，它的 `afterCompletion` 也不执行；A 已经放行过，它的 `afterCompletion` 仍然会被调用，保证 A 在 `preHandle` 里申请的资源能被释放。

回到上一节的注册顺序：`TimeInterceptor` 在前，`LoginInterceptor` 在后。未登录的请求在 `LoginInterceptor` 被拦下时，`TimeInterceptor` 已经放行过，它的 `afterCompletion` 照样执行，这个请求也会被统计到。反过来注册的话，被拦下的请求不会经过 `TimeInterceptor`，统计里就漏掉了这部分请求。

## 拦截器和过滤器怎么选

| | [[Servlet 过滤器]] | Spring MVC 拦截器 |
| --- | --- | --- |
| 属于谁 | Servlet 规范 | Spring MVC 框架 |
| 谁来调用 | Tomcat | `DispatcherServlet` |
| 作用范围 | 按 `url-pattern` 匹配的所有请求，包括静态资源、JSP | 只有进入 `DispatcherServlet` 并找到处理器的请求 |
| 能拿到什么 | 请求和响应 | 请求、响应，以及**要执行的处理器**（方法和方法上的注解）、`ModelAndView` |
| 执行时机 | 包在 `DispatcherServlet` 外面 | 包在 Controller 方法外面 |
| 抛出的异常 | `@ExceptionHandler` 接不住，交给 Tomcat | 交给 Spring MVC 的异常处理器 |
| 能否注入 Spring bean | 由 Tomcat 创建，默认不是 Spring bean | 本身就是 Spring bean，直接注入 |

按这张表选：

- **和 Spring MVC 无关、所有请求都要做的事**用过滤器：字符编码、跨域、请求日志、压缩。它们在 `DispatcherServlet` 之前执行，静态资源请求也能覆盖到
- **需要知道「调用的是哪个方法」，或者需要用 Spring bean 的事**用拦截器：基于注解的权限检查、接口耗时统计、往模型里补公共数据

有一个例外：**安全认证**。官方文档明确指出，拦截器不适合作为安全层，因为拦截器的路径匹配规则和 Controller 注解的路径匹配可能对不上，存在绕过的风险。官方推荐用 Spring Security，或者类似的、集成在 Servlet 过滤器链上的方案，并且越早执行越好。上面的登录拦截器适合学习和内部小项目，正式的认证授权交给 Spring Security。

## 在 Spring Boot 里

拦截器的写法完全一样：实现 `HandlerInterceptor`，在一个实现了 `WebMvcConfigurer` 的配置类里 `addInterceptors`。唯一的区别是配置类上**不要**加 `@EnableWebMvc`，原因见 [[Spring MVC]]。

## 参考

- [Spring MVC：Interception](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-servlet/handlermapping-interceptor.html)：三个方法的调用时机，`postHandle` 与 `@ResponseBody` 的限制
- [Spring MVC Config：Interceptors](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-config/interceptors.html)：注册方式，以及「不适合作为安全层」的说明
- [HandlerInterceptor Javadoc](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/web/servlet/HandlerInterceptor.html)
