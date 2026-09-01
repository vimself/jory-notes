---
tags: [类型/概念, 技术/Servlet, 技术/Java]
aliases: [Jakarta Servlet, jakarta.servlet, javax.servlet, Servlet 容器, Web 容器, Servlet 引擎]
created: 2026-09-01
updated: 2026-09-01
---
> Servlet 是 Java 这边「收到一个 HTTP 请求、跑一段我的代码、吐出一个 HTTP 响应」的标准接口——你只写 `doGet` 里那几行业务逻辑，拆报文、开线程、管对象生死这些脏活由 Servlet 容器包办。

## 典型场景

你要做一个页面，显示「当前在线人数」。这个数字每秒都在变，所以它不可能是磁盘上一个写死的 `.html` 文件——普通的静态文件服务器把文件原样读出来发走，它没有「执行一段代码再决定发什么」的能力。

你需要的是：浏览器访问 `/online` 时，服务器跑一段你写的 Java 代码，把代码算出来的结果当成响应正文发回去。

Servlet 就是这个「一段你写的 Java 代码」的标准形状。规范规定好了容器该怎么调用你、你能从参数里拿到什么，你负责填空。

## Servlet 和容器的分工

先说清楚一个前置概念：**Servlet 容器**（也叫 Servlet 引擎、Web 容器）是一段常驻运行的程序，[[Tomcat]] 是最常见的一个。规范里它的职责写得很明确——提供收发请求的网络服务、解析 HTTP 报文、以及**管理 Servlet 的整个生命周期**。

所以一次请求的活儿是这么分的：

| 谁干 | 干什么 |
| --- | --- |
| 容器 | 监听端口、接 TCP 连接、按 [[HTTP]] 规则解析出方法/路径/请求头/请求体 |
| 容器 | 根据路径找到该由哪个 Servlet 处理 |
| 容器 | 把解析结果包装成 `HttpServletRequest` 对象，准备好空的 `HttpServletResponse` |
| **你** | **在 `doGet` / `doPost` 里读请求、写响应** |
| 容器 | 把你写进 response 的东西组装成 HTTP 响应报文发回去 |

**你这辈子写 Servlet 都不会碰到 `Socket`、不会自己拼状态行、不会自己数 `Content-Length`。** 这就是容器存在的意义：它把 HTTP 这个文本协议翻译成了两个 Java 对象递到你手上。

`HttpServletRequest` 上最常用的是 `getParameter`——它把 URL 查询串和 POST 表单体里的参数统一成一套 `名字 → 值` 来读，你不用关心数据是从 `?name=jory` 来的还是从请求体来的。规范里说得很清楚：查询串和 POST 正文的数据会被**汇总进同一个参数集合**，查询串的值排在前面。

## 执行流程

按规范的说法，容器收到一个映射到某 Servlet 的请求时，先检查这个 Servlet 有没有实例，没有就加载类、创建实例、调 `init` 初始化，然后才调 `service` 处理请求。

完整走一遍：

```text
浏览器  GET /online HTTP/1.1
   │
   ▼
容器    解析报文，按 url-pattern 找到 OnlineServlet
   │
   ▼
容器    这个 Servlet 有实例吗？
   │        没有 → 加载类 → new 一个实例 → 调 init(ServletConfig)   ← 一辈子只走一次
   │        有   → 直接往下
   ▼
容器    包装出 request / response，调 service(req, resp)          ← 每个请求都走
   │
   ▼
HttpServlet.service()  看请求方法是 GET，转调 doGet(req, resp)
   │
   ▼
你的代码  resp.getWriter().write("当前在线 42 人")
   │
   ▼
容器    组装成 HTTP/1.1 200 OK + 正文，发回浏览器
```

**第 4 步的转发是理解 Servlet 的关键**，它是下一节的全部内容。

## service、doGet 和 doPost 的分工

这三个方法经常被并列着记，其实它们**是一条调用链上的三层，不是三个平级选项**。

| | 谁定义的 | 谁来调 | 你该不该重写 |
| --- | --- | --- | --- |
| `service` | `Servlet` 接口 | **容器**调它，每个请求一次 | 一般不 |
| `service`（HTTP 版） | `HttpServlet` 已实现 | 上面那个 `service` 转调进来 | 一般不 |
| `doGet` / `doPost` | `HttpServlet` 的空壳实现 | `service` 按请求方法挑一个调 | **就重写这两个** |

### service 到底做了什么

`Servlet` 接口只规定了一个 `service`，它不认识 HTTP，参数是 `ServletRequest` 和 `ServletResponse`。`HttpServlet` 在此之上实现了一个 HTTP 版本的 `service`，干的事情就一件：**读出请求方法名，转调对应的 `doXxx`。**

从 `HttpServlet` 源码精简出来的骨架：

```java
protected void service(HttpServletRequest req, HttpServletResponse resp) {
    String method = req.getMethod();

    if (method.equals("GET")) {
        long lastModified = getLastModified(req);
        if (lastModified == -1) {
            doGet(req, resp);                    // 没实现 getLastModified，直接调
        } else {
            // 拿 If-Modified-Since 和 lastModified 比
            // 内容更新了就 doGet，没更新就回 304 Not Modified
        }
    } else if (method.equals("HEAD")) {
        doHead(req, resp);
    } else if (method.equals("POST")) {
        doPost(req, resp);
    } else if (method.equals("PUT")) {
        doPut(req, resp);
    } else if (method.equals("DELETE")) {
        doDelete(req, resp);
    } else if (method.equals("OPTIONS")) {
        doOptions(req, resp);
    }
    // ...
}
```

分发目标一共七个，和 HTTP 方法一一对应：

| 方法 | 处理的 HTTP 方法 |
| --- | --- |
| `doGet` | `GET` |
| `doPost` | `POST` |
| `doPut` | `PUT` |
| `doDelete` | `DELETE` |
| `doHead` | `HEAD` |
| `doOptions` | `OPTIONS` |
| `doTrace` | `TRACE` |

规范也直说了：绝大多数开发者只关心 `doGet` 和 `doPost`，剩下的是给「非常熟悉 HTTP 编程」的人用的。

注意 `GET` 那条分支比别的复杂——`service` 顺手实现了**条件 GET**：你要是重写了 `getLastModified` 告诉它「这份内容最后什么时候变的」，它会拿浏览器带来的 `If-Modified-Since` 比一比，没变就直接回 `304 Not Modified`，连 `doGet` 都不进。这是白送的缓存能力，也是**不该乱重写 `service` 的第一个理由**：重写了，这段逻辑就没了。

### 为什么不该重写 service

重写 `service` 会把上面那整套分发和条件 GET 全盖掉，后果是 `doGet` / `doPost` 再也不会被调用——你写在里面的代码变成死代码，而且没有任何报错提示。

想给所有请求做统一的前置处理（登录校验、日志、编码设置），正确的位置是**过滤器**（`Filter`），它在容器层面拦在 Servlet 之前，不用动 `service`。

### doGet 和 doPost 的区别

**这个区别不是你在代码里选的，是请求自己决定的。** `service` 看的是请求行里的方法名，浏览器发 `GET` 就进 `doGet`，发 `POST` 就进 `doPost`。

那么请求方法又是谁决定的：

| 触发方式 | 实际发出的方法 |
| --- | --- |
| 地址栏输入网址、点普通链接 | `GET` |
| `<form method="get">` 或不写 `method` | `GET` |
| `<form method="post">` | `POST` |
| `fetch` / `axios` 里指定的 | 你写什么就是什么 |

两者在 Servlet 这一侧的实际差别：

| | `doGet` | `doPost` |
| --- | --- | --- |
| 参数在哪 | URL 查询串，`?name=jory` | 请求体 |
| 参数怎么读 | **都用 `getParameter`，写法完全一样** | 同左 |
| 地址栏可见 | 是，会进浏览器历史和服务器日志 | 否 |
| 长度限制 | 受 URL 长度限制 | 基本不受限 |
| 能否被缓存/收藏 | 能 | 不能 |
| 语义 | 查询，不该改数据 | 提交，会改数据 |

**「参数怎么读」那一行是最值得记的：`getParameter` 屏蔽了两者的差异。** 规范规定查询串和 POST 表单体的数据会被汇总进同一个参数集合，所以你的读参数代码在 `doGet` 和 `doPost` 里可以一字不差。

正因如此，很多项目里两个方法长得一模一样，标准写法是让一个直接转调另一个：

```java
@Override
protected void doPost(HttpServletRequest req, HttpServletResponse resp)
        throws ServletException, IOException {
    doGet(req, resp);          // GET 和 POST 处理逻辑相同时的常见写法
}
```

### 没重写的方法会怎样

没重写的方法不是不存在，而是 `HttpServlet` 给了个默认实现：调 `sendError` 报错。错误码取决于请求的协议版本——`HTTP/1.1` 及以上是 `405 Method Not Allowed`，`HTTP/1.0` 和 `HTTP/0.9` 是 `400 Bad Request`。

这解释了一个高频困惑：**表单提交上去报 405，八成是你只写了 `doGet`，而表单的 `method` 是 `post`。** 请求确实到了你的类，只是掉进了没重写的那个方法里。

## 生命周期

规范把生命周期落在三个方法上，全部由容器调用，你一个都不许自己调：

| 方法 | 调用时机 | 调几次 | 拿来干什么 |
| --- | --- | --- | --- |
| `init(ServletConfig)` | 实例创建之后、处理第一个请求之前 | **1 次** | 读配置、建数据库连接池这类一次性的贵活儿 |
| `service(req, resp)` | 每次请求 | **N 次** | 干活 |
| `destroy()` | 容器决定把它移出服务时 | **1 次** | 释放资源、保存状态 |

三个关键细节，都是踩过才知道的：

**默认是懒加载。** 加载和实例化「可以发生在容器启动时，也可以推迟到容器认为需要它来服务某个请求时」。Tomcat 这类容器默认选后者——第一个请求到达才创建。所以你在 `init` 里放了个耗时 3 秒的初始化，倒霉的是第一个访问的用户。

想改成启动时就加载，用 `loadOnStartup`：

```java
@WebServlet(urlPatterns = "/online", loadOnStartup = 1)
```

规范里 `load-on-startup` 元素的定义是「指定该组件相对于其他 web 组件的初始化顺序」——所以它的值不只是开关，还是排序依据，值小的先初始化。

**一个 Servlet 声明只有一个实例。** 规范原话是非分布式环境下容器「每个 Servlet 声明只能使用一个实例」。这条直接推出下一条。

**Servlet 不是线程安全的，这个责任在你身上。** 规范明确要求开发者「设计出能应对多个线程同时在 `service` 方法中执行的 Servlet」。既然全站共用一个实例，那么：

```java
@WebServlet("/count")
public class CountServlet extends HttpServlet {
    private int count = 0;          // ← 所有请求线程共享这一个字段

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) {
        count++;                    // ← 并发下必然丢计数
        // ...
    }
}
```

**Servlet 的成员变量是所有用户共用的。** 上面这段在压测下一定对不上账，更糟的写法是把用户身份存成员变量，那会直接串号——A 用户看到 B 用户的数据。规矩很简单：**请求相关的状态一律放方法内的局部变量，成员变量只放不可变的、或者本身线程安全的东西。**

`destroy` 还有个容易误解的地方：容器不承诺 Servlet 活多久，可能几毫秒也可能几年。调 `destroy` 之前，容器必须让正在 `service` 里跑的线程执行完（或者超过一个服务端设定的时限）。`destroy` 一旦调过，这个实例就不会再收到请求了，容器要是还想用这个 Servlet，会**新建一个实例**。

## 体系结构

规范里说 `Servlet` 接口是「Jakarta Servlet API 的核心抽象」，所有 Servlet 都直接或间接实现它。API 里实现了这个接口的两个类是 `GenericServlet` 和 `HttpServlet`：

```text
        Servlet（接口）
        定义 init / service / destroy 等生命周期方法
              │
              ▼
     GenericServlet（抽象类）
     把生命周期方法做了空实现，只留 service 抽象
     与协议无关，理论上可以处理非 HTTP 协议
              │
              ▼
      HttpServlet（抽象类）
      实现 service：按 HTTP 方法名分发到 doGet / doPost / ...
              │
              ▼
      你的 XxxServlet
      只重写 doGet / doPost
```

**每往下一层，你要写的代码就少一点。** 直接实现 `Servlet` 接口，五个方法一个都不能少写，哪怕四个是空的；继承 `GenericServlet`，只用管 `service`；继承 `HttpServlet`，连 `service` 都不用管，直接写 `doGet`。

规范给的建议很直接：「多数情况下开发者会扩展 `HttpServlet` 来实现自己的 Servlet。」写 web 应用没有理由用另外两个。

一个最小的 Servlet：

```java
import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import java.io.IOException;

@WebServlet("/online")
public class OnlineServlet extends HttpServlet {

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp)
            throws IOException {
        resp.setContentType("text/html;charset=UTF-8");
        resp.getWriter().write("当前在线 42 人");
    }
}
```

`setContentType` 那行的位置和写法都有讲究，写错就是中文乱码，规则在下面的响应一节里讲。

### 一个包名的坑：javax 还是 jakarta

Java EE 捐给 Eclipse 基金会后改名 Jakarta EE，包名从 `javax.servlet` 整体换成了 `jakarta.servlet`。这不是别名，是两套互不兼容的类。

分界线在容器版本上：**Tomcat 9 及以前是 `javax.*`，Tomcat 10 开始是 `jakarta.*`。** 网上 2020 年前的教程清一色 `javax`，照抄到新版 Tomcat 上，现象是启动没报错、访问就 404，因为容器扫描注解时压根不认识 `javax.servlet.annotation.WebServlet`。

**报 404 之前先看你的 import 和容器版本对不对得上。**

## URL pattern 配置

`url-pattern` 决定「什么路径的请求交给这个 Servlet」。规范里定义了四种写法：

| 写法 | 叫法 | 例子 | 匹配什么 |
| --- | --- | --- | --- |
| `/foo/bar` | 精确匹配 | `/catalog` | 只匹配一模一样的路径 |
| `/foo/*` | 路径匹配 | `/baz/*` | 以 `/baz` 开头的所有路径 |
| `*.xxx` | 扩展名匹配 | `*.do` | 以 `.do` 结尾的路径。**注意它不以 `/` 开头** |
| `/` | 缺省 Servlet | `/` | 前三种都没匹配上时兜底 |

还有一个特例：**空串 `""`** 精确匹配应用的上下文根，也就是 `http://host:port/<context-root>` 这种不带后续路径的请求。

### 匹配顺序

规范写的是「按下列顺序使用，第一个匹配成功的即被采用，不再尝试后续规则」：

1. **精确匹配** — 请求路径和某个 Servlet 的路径完全相同
2. **最长路径前缀匹配** — 沿路径树一级一级往下找，用 `/` 分隔，**最长的那个赢**
3. **扩展名匹配** — 最后一段里有扩展名（`.` 之后的部分）时，找处理该扩展名的 Servlet
4. **缺省 Servlet** — 前三条都没中，交给 `/` 映射的 Servlet；容器通常自带一个用来发静态文件

匹配是**大小写敏感**的，`/Catalog` 和 `/catalog` 不是一回事。

### 走一遍规范给的例子

假设配置了这四条映射：

| url-pattern | Servlet |
| --- | --- |
| `/foo/bar/*` | servlet1 |
| `/baz/*` | servlet2 |
| `/catalog` | servlet3 |
| `*.bop` | servlet4 |

那么各种请求的归属是：

| 请求路径 | 谁处理 | 为什么 |
| --- | --- | --- |
| `/foo/bar/index.html` | servlet1 | 路径前缀 `/foo/bar/*` 命中 |
| `/foo/bar/index.bop` | servlet1 | **路径匹配的优先级高于扩展名匹配**，servlet4 抢不到 |
| `/baz` | servlet2 | `/baz/*` 也匹配不带尾巴的 `/baz` |
| `/baz/index.html` | servlet2 | 路径前缀命中 |
| `/catalog` | servlet3 | 精确匹配 |
| `/catalog/index.html` | **缺省 Servlet** | `/catalog` 是精确匹配，多一截就不匹配了 |
| `/catalog/racecar.bop` | servlet4 | `/catalog` 精确匹配不上，落到扩展名匹配 |
| `/index.bop` | servlet4 | 扩展名匹配 |

**倒数第三行是最反直觉的一条：`/catalog` 配的是精确匹配，`/catalog/index.html` 就跟它没关系了。** 想让 `/catalog` 底下所有路径都归 servlet3，得写成 `/catalog/*`。

再有一条硬规则：合并完注解和 `web.xml` 之后，**如果同一个 url-pattern 映射到了多个 Servlet，部署必须失败**。所以两个 Servlet 抢同一个路径时，容器不会随机挑一个，而是直接拒绝启动。

## XML 配置方式

Servlet 3.0 之前没有注解，映射关系全写在 `WEB-INF/web.xml` 里——这个文件叫**部署描述符**（deployment descriptor）。语法是两段，靠 `servlet-name` 这个逻辑名字对上：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<web-app xmlns="https://jakarta.ee/xml/ns/jakartaee"
         version="6.0">

  <servlet>
    <servlet-name>onlineServlet</servlet-name>
    <servlet-class>com.example.OnlineServlet</servlet-class>
    <load-on-startup>1</load-on-startup>
  </servlet>

  <servlet-mapping>
    <servlet-name>onlineServlet</servlet-name>
    <url-pattern>/online</url-pattern>
  </servlet-mapping>

</web-app>
```

规范对这几个元素的定义：`servlet-name` 是「一个逻辑名字，用来在 WAR 里的其他 web 组件中定位这个端点描述」，`servlet-class` 是「该端点实现的全限定 Java 类名」，`load-on-startup` 是「该组件相对于其他 web 组件的初始化顺序」。

**为什么要拆成两段？** 因为一个 Servlet 可以映射多个路径——写多个 `<servlet-mapping>` 指向同一个 `servlet-name` 就行，而 `<servlet>` 那段只声明一次。逻辑名字是把「这个类是谁」和「它管哪些路径」解耦开的中间层。

### 注解和 XML 怎么选

`@WebServlet` 就是上面这堆 XML 的等价物，规范对它的要求是：`urlPatterns` 或 `value` **必须有一个**，其余属性都可选；两者不能同时写；被注解的类**必须继承 `HttpServlet`**。规范建议只写路径时用 `value`，还要配别的属性时用 `urlPatterns`：

```java
@WebServlet("/foo")                                    // 只有路径，用 value
@WebServlet(name = "MyServlet", urlPatterns = {"/foo", "/bar"})   // 配了别的，用 urlPatterns
```

不写 `name` 时，Servlet 的默认名字是类的全限定名。

日常开发用注解，路径就写在类头上，读代码的人不用翻 XML。`web.xml` 现在主要用来放注解表达不了的全局配置（会话超时、错误页、过滤器顺序），以及在不改代码的前提下临时调整映射——它的优先级高于注解。

规范还明确了一点：**如果应用里没有任何 Servlet、Filter、Listener，或者全部用注解声明，`web.xml` 可以完全不存在。** 只有静态文件和 JSP 的应用不需要它。

## HttpServletRequest：把请求读出来

容器把 [[HTTP]] 请求报文解析完，结果就装在这个对象里。**它的方法基本是照着请求报文的三段结构排的**，知道报文长什么样就不用背 API。

继承关系是 `ServletRequest`（与协议无关）→ `HttpServletRequest`（HTTP 专用）。`getParameter`、`getAttribute` 这些通用方法在父接口上，`getMethod`、`getHeader` 这些 HTTP 专属的在子接口上。

### 对着报文三段读

```http
POST /app/user/list?page=2 HTTP/1.1     ← 请求行
Host: localhost:8080                     ← 请求头
Content-Type: application/x-www-form-urlencoded
                                         ← 空行
name=jory&age=18                         ← 请求体
```

| 报文部分 | 方法 | 上面例子里的返回值 |
| --- | --- | --- |
| 请求行 | `getMethod()` | `"POST"` |
| 请求行 | `getRequestURI()` | `"/app/user/list"`，不含查询串 |
| 请求行 | `getRequestURL()` | `"http://localhost:8080/app/user/list"`，是 `StringBuffer` |
| 请求行 | `getQueryString()` | `"page=2"` |
| 请求行 | `getProtocol()` | `"HTTP/1.1"` |
| 请求头 | `getHeader(name)` | `getHeader("Host")` → `"localhost:8080"` |
| 请求头 | `getHeaderNames()` | 所有头名字的 `Enumeration` |
| 请求体 | `getReader()` | 读字符流 |
| 请求体 | `getInputStream()` | 读字节流，上传文件时用 |

同名请求头可能出现多次（比如 `Cache-Control`）。**`getHeader` 只返回第一个**，要全部就用 `getHeaders`，它返回 `Enumeration<String>`。头里装的是数字或日期时，可以用 `getIntHeader` / `getDateHeader` 让容器帮你转——转不动会分别抛 `NumberFormatException` 和 `IllegalArgumentException`。

### 路径三兄弟

`getRequestURI` 拿到的是整条路径，但你常常只想要其中一段。规范把它拆成三份：

| 方法 | 是什么 |
| --- | --- |
| `getContextPath()` | 应用的上下文路径。部署在根上时是**空串**，否则以 `/` 开头、不以 `/` 结尾 |
| `getServletPath()` | 直接对应「激活这次请求的那条映射」的部分。被 `/*` 或 `""` 匹配时是空串 |
| `getPathInfo()` | 剩下的部分。没有多余路径时是 **`null`**，否则以 `/` 开头 |

规范保证这个等式恒成立：

```text
requestURI = contextPath + servletPath + pathInfo
```

规范给的例子，上下文路径是 `/catalog`，映射了 `/lawn/*`、`/garden/*` 和 `*.jsp`：

| 请求路径 | contextPath | servletPath | pathInfo |
| --- | --- | --- | --- |
| `/catalog/lawn/index.html` | `/catalog` | `/lawn` | `/index.html` |
| `/catalog/garden/implements/` | `/catalog` | `/garden` | `/implements/` |
| `/catalog/help/feedback.jsp` | `/catalog` | `/help/feedback.jsp` | `null` |

**最后一行是重点**：被 `*.jsp` 这种扩展名映射命中时，整条路径都算 servletPath，pathInfo 是 `null` 而不是空串。写 `pathInfo.substring(1)` 之前先判空，否则就是一个 `NullPointerException`。

### 读参数：`getParameter` 家族

这是日常用得最多的一组，也是唯一**不用关心数据来自查询串还是请求体**的一组：

| 方法 | 返回 | 什么时候用 |
| --- | --- | --- |
| `getParameter(name)` | `String` | 单值，最常用 |
| `getParameterValues(name)` | `String[]` | 多选框这类一个名字多个值 |
| `getParameterNames()` | `Enumeration<String>` | 遍历所有参数名 |
| `getParameterMap()` | `Map<String, String[]>` | 一次全拿走，常用来做参数对象封装 |

规范规定：**查询串和 POST 正文的数据被汇总进同一个参数集合，查询串的值排在前面。** 所以 `?a=hello` 配上请求体 `a=goodbye&a=world`，`getParameterValues("a")` 得到的是 `["hello", "goodbye", "world"]`，而 `getParameter("a")` 拿到的是其中第一个，也就是 `"hello"`。

**参数为空时返回的是 `null`，不是空串**，直接 `.trim()` 会炸。

表单数据被填进参数集合有三个前提条件，规范列得很死：

1. HTTP 方法是 `POST` 或 `QUERY`
2. content type 是 `application/x-www-form-urlencoded`
3. Servlet 调用过 `getParameter` 家族中的任意一个方法

**条件不满足时，表单数据仍然能从请求的输入流里读到；条件满足时，这些数据就再也不能从输入流里直接读了。** 这条说的其实是 `getParameter` 和 `getInputStream` **二选一**：请求体是个只能消费一次的流，谁先读谁拿到。前端发的是 JSON（content type 不是 `x-www-form-urlencoded`）时 `getParameter` 拿不到东西，得走 `getReader`，原因就在这里。

### 请求参数的中文乱码

规范把默认编码定得很具体：客户端没在 `Content-Type` 里带 charset 时，如果 content type 是 `application/x-www-form-urlencoded`，容器解析 POST 数据用的默认编码必须是 **`US-ASCII`**（`%nn` 转义值按 ISO-8859-1 解码）；其他 content type 则默认 **`ISO-8859-1`**。两个都表示不了汉字。

补救方法是 `setCharacterEncoding`：

```java
req.setCharacterEncoding("UTF-8");        // 必须在读任何参数之前
String name = req.getParameter("name");
```

**位置是死的：规范要求它必须在解析 POST 数据或读取任何输入之前调用，数据一旦读过再调就不起作用了。** 而且不报错，就是静默失效——所以「我明明设了 UTF-8 还是乱码」十有八九是这行写在 `getParameter` 后面了。

想一次性配好整个应用，用 `web.xml` 里的 `<request-character-encoding>` 元素，或者 `ServletContext.setRequestCharacterEncoding`，就不用每个 Servlet 写一遍。

### 请求域：`setAttribute` / `getAttribute`

属性（attribute）是**挂在请求对象上的临时数据**，规范说它的用途之一就是「由某个 Servlet 设置，用来传递信息给另一个 Servlet（通过 `RequestDispatcher`）」。

```java
req.setAttribute("user", user);                    // 存
User u = (User) req.getAttribute("user");          // 取，返回 Object，要强转
req.removeAttribute("user");                       // 删
```

三个要点：

- **一个名字只能对应一个值**，重复 `setAttribute` 是覆盖
- **`getAttribute` 返回 `Object`**，取出来必须强转，转错了是运行时 `ClassCastException`
- **作用范围就是这一次请求**，请求处理完就没了。所以它只在转发（forward）的场景下有意义——重定向是两次独立请求，属性传不过去

`jakarta.` 开头的属性名是规范保留的，别自己用。

### 请求转发

转发（forward）是**在服务器内部把请求交给另一个资源继续处理**，浏览器完全不知情：

```java
req.setAttribute("users", list);
req.getRequestDispatcher("/WEB-INF/views/list.jsp").forward(req, resp);
```

两种拿 `RequestDispatcher` 的方式，区别只在路径怎么算：

| 来源 | 路径要求 |
| --- | --- |
| `request.getRequestDispatcher(path)` | 可以用**相对当前请求**的相对路径 |
| `servletContext.getRequestDispatcher(path)` | 必须是**相对上下文根**的绝对路径，以 `/` 开头或为空 |

规范举的例子：上下文根是 `/`，当前请求是 `/garden/tools.html`，那么 `request.getRequestDispatcher("header.html")` 等价于 `servletContext.getRequestDispatcher("/garden/header.html")`。

`forward` 有个硬性前提：**只能在还没有内容提交给客户端时调用。** 响应缓冲区里有未提交的数据会先被清空；响应已经提交了还调，必须抛 `IllegalStateException`。所以**别在 `getWriter().write(...)` 之后再 forward**。

注意 `/WEB-INF/` 下的资源浏览器直接访问是 404，但转发过去完全没问题——这正是把页面模板藏在 `WEB-INF` 下的常见做法。

## HttpServletResponse：把响应写回去

和请求对称，这个对象的方法也是照着响应报文的三段排的。

### 对着报文三段写

| 报文部分 | 方法 |
| --- | --- |
| 状态行 | `setStatus(int)` |
| 响应头 | `setHeader` / `addHeader` / `setIntHeader` / `setDateHeader` / `addIntHeader` / `addDateHeader` |
| 响应体 | `getWriter()` 写字符，`getOutputStream()` 写字节 |

**`setHeader` 和 `addHeader` 的区别**：`setHeader` 是替换——同名的旧值会被清掉换成新的；`addHeader` 是追加——同名的多个值并存。发多个 `Set-Cookie` 必须用 `addHeader`，用 `setHeader` 只会剩最后一个。

**`getWriter` 和 `getOutputStream` 互斥，一次响应里只能用一个。** API 里写死了：已经调过 `getWriter` 再调 `getOutputStream` 抛 `IllegalStateException`，反过来也一样。写文本用 `getWriter`，下载文件、输出图片用 `getOutputStream`。

### 响应体的中文乱码

前面体系结构那节留的坑在这里填上。规范把规则定得很死，三条缺一不可：

- **`setContentType` 必须在 `getWriter()` 之前调用。** 规范原话是，在 `getWriter` 被调用之后、或响应已提交之后再调这些方法，**对字符编码不产生任何影响**——不报错，就是静默失效
- **content type 串里必须带 `charset`。** 规范说 `setContentType` 只有在给定的 content type 提供了 `charset` 属性时才会设置字符编码。所以写 `"text/html"` 等于没设，得写 `"text/html;charset=UTF-8"`
- **不设的后果是默认 `ISO-8859-1`。** 规范明确：Servlet 没在 `getWriter` 之前指定编码，就用 `ISO-8859-1`，一个表示不了汉字的单字节编码

```java
resp.setContentType("text/html;charset=UTF-8");   // 必须在前面，必须带 charset
resp.getWriter().write("你好");
```

三条连起来就是中文乱码的完整成因，也解释了为什么「把 `setContentType` 挪到 `getWriter` 上面一行」这个看着像玄学的修复真的有效。

容器还会把这个编码通过 `Content-Type` 头告诉浏览器——**如果你压根没设 content type，编码就没法通过 HTTP 头传达**，浏览器只能自己猜。

### 缓冲与「提交」

容器允许（但不强制）缓冲响应内容。这带来一个贯穿始终的概念：**响应一旦「提交」（committed），头就发出去了，再改无效。**

规范的原话是：头必须在响应提交前设置，提交后设置的头会被容器忽略。相关方法：

| 方法 | 作用 |
| --- | --- |
| `isCommitted()` | 查响应是否已提交 |
| `flushBuffer()` | 强制把缓冲区内容发给客户端，**这会导致提交** |
| `resetBuffer()` | 清空缓冲区里的内容，保留头和状态码 |
| `reset()` | 连头和状态码一起清空 |
| `setBufferSize` / `getBufferSize` | 读写缓冲区大小 |

「响应已提交」是 `IllegalStateException` 最常见的来源：转发、重定向、`sendError` 全都要求响应还没提交。

### 重定向

```java
resp.sendRedirect("/app/user/list");
```

`sendRedirect(location)` 在 API 里的定义是转调 `sendRedirect(location, SC_FOUND, true)`，**也就是发一个 `302 Found` 加一个 `Location` 头**。浏览器收到后自己再发一次请求到新地址。

`sendError(int, String)` 则是发错误响应并清空缓冲区，容器默认生成一个 `text/html` 的错误页。要是应用为这个状态码配了 `error-page`，那个页面会被优先返回，你传的 msg 被忽略。两个方法都会**提交响应**，之后不该再往里写东西。

### 转发和重定向的区别

这两个都是「让另一个资源来处理」，但机制完全不同，是面试和排错的高频点：

| | 转发 `forward` | 重定向 `sendRedirect` |
| --- | --- | --- |
| 谁在跳 | **服务器内部**跳，浏览器不知情 | 服务器让**浏览器**再发一次请求 |
| 请求次数 | 1 次 | 2 次 |
| 地址栏 | **不变** | **变成新地址** |
| 状态码 | 没有特殊状态码 | `302` + `Location` 头 |
| request 域 | **能共享**，`setAttribute` 传得过去 | **传不过去**，是两次独立请求 |
| 能去哪 | 只能是**本应用内部**的资源 | **任意 URL**，可以跳到别的站 |
| 能访问 `WEB-INF` 吗 | **能** | 不能，浏览器直接访问是 404 |
| 刷新会怎样 | 可能重复提交表单 | 刷新的是新地址，安全 |

**怎么选：** 需要把数据通过 request 域带给下一个资源（比如查完数据交给页面渲染）→ 转发；处理完一次写操作、不希望用户刷新时重复提交 → 重定向。第二条就是所谓的 **POST-重定向-GET** 模式，下面的综合案例里会用到。

## 综合案例

把上面这些接到真数据库上跑一遍——查列表、表单提交新增、数据落进 MySQL，单例与线程安全、请求编码、POST-重定向-GET 在那里都有实际用法：[[Servlet 整合 MyBatis]]。

## 参考
- [Jakarta Servlet Specification](https://jakarta.ee/specifications/servlet/) — 生命周期见「The Servlet Interface」，映射规则见「Mapping Requests to Servlets」
- [Jakarta EE Tutorial: Jakarta Servlet Technology](https://eclipse-ee4j.github.io/jakartaee-tutorial/#jakarta-servlet-technology)
- [Apache Tomcat 版本与 Servlet 规范对照表](https://tomcat.apache.org/whichversion.html)
