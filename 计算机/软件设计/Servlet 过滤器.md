---
tags: [类型/概念, 技术/Servlet, 技术/Java]
aliases: []
created: 2026-09-03
updated: 2026-09-03
---
> 过滤器是容器给你的一道关卡，架在请求到达 [[Servlet]] 之前。它能改请求、能改响应，也能干脆不放行。凡是「每个请求都要做一遍」的事——设编码、查登录、记日志——都该搬到这里，而不是复制到每个 Servlet 的开头。

## 典型场景

后台有二十个页面，每一个都要求「没登录就踢回登录页」。

按最直白的写法，二十个 Servlet 的 `doGet` 开头都得贴上同一段：

```java
HttpSession session = req.getSession(false);
if (session == null || session.getAttribute("user") == null) {
    resp.sendRedirect(req.getContextPath() + "/login.jsp");
    return;
}
```

复制二十遍已经够难受了。真正的问题是第二十一个页面——新人加了个 Servlet，忘了贴这段，于是这个页面谁都能直接访问，而且没有任何报错提醒你。**安全检查靠人记得去写，等于没有。**

过滤器把这段代码从「二十个地方各写一遍」变成「一个地方写一次，所有请求都过」。

## 它站在哪

```text
浏览器请求 /app/user/list
   │
   ▼
Tomcat 按 url-pattern 挑出该走的过滤器，排成一条链
   │
   ▼
EncodingFilter.doFilter()          ← 放行前：设编码
   │  chain.doFilter(req, resp)
   ▼
LoginFilter.doFilter()             ← 放行前：查登录，不通过就直接重定向，链到此为止
   │  chain.doFilter(req, resp)
   ▼
UserListServlet.doGet()            ← 真正干活的
   │
   ▲  （原路返回）
   │
LoginFilter  chain.doFilter 之后的代码
   │
   ▲
EncodingFilter  chain.doFilter 之后的代码
   │
   ▼
浏览器收到响应
```

**过滤器是链式的，而且请求走一趟、响应回来还要再走一趟。** 这条「去而复返」的路径是理解 `doFilter` 的关键，下一节展开。

## 三个方法

```java
public interface Filter {
    default void init(FilterConfig filterConfig) throws ServletException;
    void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException;
    default void destroy();
}
```

`init` 和 `destroy` 都是**默认方法**，不需要的话不用写，实现类里只留一个 `doFilter` 就能编译。

生命周期和 Servlet 是同一套思路：规范规定，**每个过滤器声明在容器的每个 JVM 里只有一个实例**，容器在任何请求访问到被过滤的资源之前就完成实例化并调用 `init`。所以过滤器和 Servlet 一样，**是多个请求线程共享的**——别在成员变量里存跟单次请求有关的东西。

注意 `doFilter` 的参数类型是 `ServletRequest` 而不是 `HttpServletRequest`：过滤器这套机制不限于 HTTP。写 Web 应用时第一件事就是强转：

```java
HttpServletRequest req = (HttpServletRequest) request;
HttpServletResponse resp = (HttpServletResponse) response;
```

## `doFilter` 的两半

这是整篇最要紧的一节。`chain.doFilter(request, response)` 这一行叫**放行**——它的意思是「把请求交给链上的下一个过滤器，如果我是最后一个，就交给 Servlet」。它是一次**同步调用**：下游全部执行完，它才返回。

于是你写的代码被这一行切成了两半：

```java
@Override
public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
        throws IOException, ServletException {

    // ① 放行前：Servlet 还没执行，可以改请求、可以决定不放行
    long start = System.currentTimeMillis();

    chain.doFilter(request, response);          // ← 放行，Servlet 在这一行里跑完

    // ② 放行后：Servlet 已经执行完了，可以看结果、可以补响应头
    System.out.println("耗时 " + (System.currentTimeMillis() - start) + " ms");
}
```

**忘了写 `chain.doFilter` 是新手第一号 bug。** 现象很迷惑：浏览器返回 200，页面一片空白，控制台没有任何异常——因为请求确实被处理了，只是被这个过滤器截住了，从来没到达 Servlet。凡是「加了过滤器之后页面变空白」，先去数一数有没有放行。

反过来，**不放行是一种正当用法**：登录校验不通过时，直接 `sendRedirect` 然后 `return`，故意不调 `chain.doFilter`，这就是「拦下来」。

## 怎么配

用注解最省事，`@WebFilter` 的值就是拦截路径：

```java
@WebFilter("/*")                       // 拦所有请求
@WebFilter("/user/*")                  // 只拦 /user 开头的
@WebFilter(urlPatterns = {"/a/*", "/b/*"})
```

路径的匹配规则和 Servlet 的 `url-pattern` 完全一样，见 [[Servlet]] 的「URL pattern 配置」。

`@WebFilter` 还有几个用得上的元素：`filterName` 指定名字，`initParams` 配初始化参数（在 `init` 里通过 `FilterConfig.getInitParameter` 读），`servletNames` 按 Servlet 名字而不是路径来匹配，`dispatcherTypes` 见下一节。

**顺序**是注解方式的短板。规范规定的顺序是按 `web.xml` 里 `<filter-mapping>` 出现的先后：先按 `<url-pattern>` 匹配的映射、按它们在部署描述符里出现的顺序，再按 `<servlet-name>` 匹配的映射、同样按出现顺序。`@WebFilter` 的文档里没有对应的顺序规定。**所以只要多个过滤器之间有先后依赖（比如编码过滤器必须排在所有读参数的过滤器前面），就老老实实用 `web.xml` 声明映射。**

```xml
<filter>
  <filter-name>EncodingFilter</filter-name>
  <filter-class>com.example.filter.EncodingFilter</filter-class>
</filter>
<filter-mapping>
  <filter-name>EncodingFilter</filter-name>
  <url-pattern>/*</url-pattern>
</filter-mapping>
```

## 转发进来的请求，默认不过滤

一个请求的「派发类型」（`DispatcherType`）决定了哪些过滤器会被应用到它身上。规范定义了这几种：

| 类型 | 什么时候是这个类型 |
| --- | --- |
| `REQUEST` | 请求直接来自客户端。**这是初始类型，也是没写 `<dispatcher>` 时的默认值** |
| `FORWARD` | 通过 `RequestDispatcher.forward()` 转发过来的 |
| `INCLUDE` | 通过 `RequestDispatcher.include()` 包含进来的 |
| `ERROR` | 被容器的错误处理机制派发到错误页 |
| `ASYNC` | 通过 `AsyncContext.dispatch()` 派发的 |

`@WebFilter` 的 `dispatcherTypes` 默认值只有 `{REQUEST}`。这意味着：**Servlet 转发到 JSP 时，过滤器不会再执行一次。**

这个默认值多数时候正合适（编码只需设一次，登录也只需查一次），但也有反过来的场景。比如你想给「所有最终渲染的 JSP」加统一处理，而 JSP 是被 Servlet 转发过去的，那就得显式写上：

```java
@WebFilter(urlPatterns = "/WEB-INF/views/*",
           dispatcherTypes = {DispatcherType.REQUEST, DispatcherType.FORWARD})
```

## 案例一：统一设置编码

[[Servlet]] 里讲过，`setCharacterEncoding` 必须在第一次 `getParameter` 之前调用，否则 POST 上来的中文就是乱码，而且不报错。把它放进过滤器，就不用指望每个 Servlet 的作者都记得这件事：

```java
package com.example.filter;

import jakarta.servlet.*;
import jakarta.servlet.annotation.WebFilter;
import java.io.IOException;

@WebFilter("/*")
public class EncodingFilter implements Filter {

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {

        request.setCharacterEncoding("UTF-8");
        response.setContentType("text/html;charset=UTF-8");

        chain.doFilter(request, response);
    }
}
```

这个过滤器必须排在链的最前面——它要保证自己在任何人读参数之前执行完。这也是上一节说的「顺序有依赖就用 `web.xml`」的典型例子。

## 案例二：登录校验

把开头那段复制二十遍的代码收进一处。难点不在判断，在**放行名单**：

```java
package com.example.filter;

import jakarta.servlet.*;
import jakarta.servlet.annotation.WebFilter;
import jakarta.servlet.http.*;
import java.io.IOException;
import java.util.List;

@WebFilter("/*")
public class LoginFilter implements Filter {

    /** 这些路径不查登录，否则登录页自己也会被拦，浏览器会在重定向里转圈 */
    private static final List<String> ALLOWED =
            List.of("/login.jsp", "/user/login", "/css/", "/js/", "/img/");

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {

        HttpServletRequest req = (HttpServletRequest) request;
        HttpServletResponse resp = (HttpServletResponse) response;

        // getRequestURI 带着上下文路径（/app/user/list），减掉它才是应用内的路径
        String path = req.getRequestURI().substring(req.getContextPath().length());

        boolean allowed = ALLOWED.stream().anyMatch(path::startsWith);
        HttpSession session = req.getSession(false);
        boolean loggedIn = session != null && session.getAttribute("user") != null;

        if (allowed || loggedIn) {
            chain.doFilter(request, response);          // 放行
        } else {
            resp.sendRedirect(req.getContextPath() + "/login.jsp");   // 拦下
        }
    }
}
```

三个要点：

**一、放行名单不能忘。** 用 `/*` 拦一切，登录页和登录接口本身也在「一切」里面。漏掉它们的现象是浏览器提示「重定向次数过多」——没登录 → 重定向到登录页 → 登录页又被拦 → 再重定向，无限套娃。静态资源（CSS、JS、图片）同理，漏了的话登录页会变成一张没有样式的裸 HTML。

**二、`getSession(false)`，别用无参版本。** 无参版本会给每个未登录的访客创建一个空会话，白白占内存，原因见 [[会话跟踪]]。

**三、路径要减掉上下文路径。** `getRequestURI()` 返回的是 `/app/user/list` 这种带部署路径的完整路径，而你的名单里写的是 `/user/login`。三个路径方法的分工见 [[Servlet]] 的「路径三兄弟」。

## 过滤器、监听器、Servlet 怎么分工

| | 什么时候执行 | 能不能改请求/响应 | 能不能中断请求 |
| --- | --- | --- | --- |
| [[Servlet 监听器]] | 某个事件发生时（应用启动、会话创建……） | 不能 | 不能 |
| **过滤器** | 每个匹配的请求，Servlet 前后各一次 | 能 | **能** |
| [[Servlet]] | 请求匹配到它时 | —— | —— |

一句话选型：**要「被通知」用监听器，要「插手」用过滤器。**

## 参考

- [Jakarta Servlet Specification](https://jakarta.ee/specifications/servlet/) — 生命周期与链的顺序见「Filtering」一章
- [Filter（Jakarta Servlet API 文档）](https://jakarta.ee/specifications/servlet/6.0/apidocs/jakarta.servlet/jakarta/servlet/filter) — 接口的三个方法与典型实现模式
- [@WebFilter（Jakarta Servlet API 文档）](https://jakarta.ee/specifications/servlet/6.0/apidocs/jakarta.servlet/jakarta/servlet/annotation/webfilter) — 各元素的默认值
