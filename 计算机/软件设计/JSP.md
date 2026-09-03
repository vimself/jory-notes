---
tags: [类型/概念, 技术/JSP, 技术/Servlet, 技术/Java]
aliases: [JavaServer Pages, Jakarta Server Pages, Jakarta Pages]
created: 2026-09-03
updated: 2026-09-03
---
> JSP 是反过来写的 [[Servlet]]：Servlet 在 Java 代码里拼 HTML，JSP 在 HTML 里开口子填数据。容器会把 `.jsp` 翻译成一个 Servlet 类再编译，两者运行时是同一个东西——所以学 JSP 的重点不是学一门新技术，是学怎么把「算数据」和「摆页面」分开。

## 典型场景

[[Servlet 整合 MyBatis]] 里那个用户列表页，HTML 是这么吐出来的：

```java
out.write("<h2>用户列表</h2><table border='1'>");
out.write("<tr><th>id</th><th>姓名</th><th>年龄</th></tr>");
for (User u : users) {
    out.write("<tr><td>" + u.getId() + "</td><td>"
            + u.getUserName() + "</td><td>" + u.getAge() + "</td></tr>");
}
```

它能跑。但把它当成长期方案，你会遇到三件事：改一处表格边框要重新编译、重启容器；HTML 写漏一个 `</td>` 编译器完全不管，跑起来看到页面塌了才知道；懂前端的人打不开这个文件。

根子在**比例反了**。一个列表页里 90% 是从不变化的 HTML，10% 是随数据变的部分，而上面这段代码把那 90% 塞进了 Java 字符串里。

JSP 把比例倒回来：文件本体就是一份正常的 HTML，只在要填数据的地方开个口子。上面那段代码在本篇末尾会被改写成一个不含任何 Java 语句的页面。

## JSP 是怎么变成 Servlet 的

这是理解 JSP 的第一块基石：**`.jsp` 文件不是被「解释执行」的，它是被翻译成 Java 源码再编译成 class 的。**

规范把一个 JSP 页面的一生切成两个阶段：

| 阶段 | 发生什么 |
| --- | --- |
| **翻译阶段**（translation phase） | 容器校验 `.jsp` 的语法，为它确定一个对应的**「JSP 页面实现类」**（JSP page implementation class） |
| **请求阶段** | 发给这个 JSP 的请求被投递给该实现类的对象处理 |

这个实现类实现 `jakarta.servlet.Servlet`，同时实现 `jakarta.servlet.jsp.JspPage`（HTTP 场景下是它的子接口 `HttpJspPage`）。**它就是一个 Servlet**，只不过不是你手写的。

生命周期方法也一一对得上：

| Servlet 里的 | JSP 实现类里的 | 什么时候调 |
| --- | --- | --- |
| `init` | `jspInit()` | 第一个请求到达时（如果页面定义了它） |
| `service` | `_jspService()` | 每个请求 |
| `destroy` | `jspDestroy()` | 回收资源时 |

**你写在 `.jsp` 里的 HTML 和 Java 代码，最后全在 `_jspService()` 方法体里。** 这解释了后面很多规则：为什么你不能自己声明一个和内置对象重名的变量、为什么 `<%! %>` 声明的东西和 `<% %>` 里的变量不是一回事——前者在类里，后者在方法里。

翻译的时机规范说得很宽松：可以发生在**部署进容器到收到第一个请求之间的任何时刻**。Tomcat 的选择是第一次访问时翻译，生成的 `.java` 和 `.class` 落在它的 `work/` 目录里（见 [[Tomcat]] 的目录结构）。

**去看一眼那个生成文件，是 JSP 排错最省事的一招。** JSP 报编译错误时给的行号常常是生成的 Java 文件的行号，跟你的 `.jsp` 对不上；打开 `work/` 里那份源码，一眼就知道你的哪一行被翻译成了什么。

## 语法：五种尖括号

JSP 在 HTML 里开的口子只有五种形状：

| 写法 | 叫法 | 干什么 | 落在生成类的哪 |
| --- | --- | --- | --- |
| `<%@ ... %>` | 指令（directive） | 给翻译阶段下指示，不产生输出 | 影响整个类怎么生成 |
| `<%! ... %>` | 声明（declaration） | 声明成员变量和方法 | **类体里**，在 `_jspService` 之外 |
| `<% ... %>` | 脚本片段（scriptlet） | 一段 Java 语句 | `_jspService` 方法体里 |
| `<%= ... %>` | 表达式（expression） | 求值后输出到页面 | `_jspService` 里的一次输出调用 |
| `<%-- ... --%>` | JSP 注释 | 只给自己看 | 哪都不去，翻译时就被丢掉 |

最后一条值得单独说：`<%-- --%>` 和 HTML 注释 `<!-- -->` 的区别不是风格问题。HTML 注释会被原样送到浏览器，用户按 F12 就能看到；JSP 注释在翻译阶段就消失了，浏览器收不到。**注释里写了敏感信息或调试线索，就得用 `<%-- --%>`。**

`<%! %>` 和 `<% %>` 的区别同样是位置决定的。`<%! int count = 0; %>` 声明的是**实例字段**，整个 JSP 只有一个实例，所有请求共用这一个 `count`——这就是 Servlet 里那个线程安全问题原封不动地搬了过来。而 `<% int count = 0; %>` 是方法里的局部变量，每个请求一份，互不干扰。

### page 指令与中文乱码

`page` 指令是最常打交道的一个。它管的是这个页面整体怎么翻译、怎么输出：

```jsp
<%@ page contentType="text/html;charset=UTF-8" pageEncoding="UTF-8" %>
```

这两个属性长得像，管的是完全不同的两件事：

- **`pageEncoding` 管「读进来」**：容器在翻译阶段按什么编码去解码 `.jsp` 这个源文件的字节。写错了，源码里的中文在翻译时就已经烂了
- **`contentType` 管「发出去」**：响应的 `Content-Type` 头和响应体的字符编码，也就是浏览器该按什么编码解析

**`contentType` 不写的后果是确定的乱码**，因为规范给它的默认值是 `text/html; charset=ISO-8859-1`——一个单字节编码，表示不了汉字。这和 [[Servlet]] 里 `setContentType` 那条坑是同一个默认值、同一个成因，只是换了个写法。

其余常用属性和它们的默认值：

| 属性 | 默认值 | 说明 |
| --- | --- | --- |
| `session` | `true` | 是否参与 HTTP 会话，`false` 时页面里就没有 `session` 内置对象 |
| `buffer` | `8kb` | 输出缓冲区大小 |
| `autoFlush` | `true` | 缓冲区满了自动 flush |
| `isELIgnored` | `false` | **默认不忽略 EL**，所以 `${}` 开箱即用 |
| `isErrorPage` | `false` | 为 `true` 时页面里才有 `exception` 内置对象 |
| `errorPage` | 无 | 出异常时转到哪个页面 |
| `import` | 已含 `java.lang`、`java.io`、`jakarta.servlet`、`jakarta.servlet.http`、`jakarta.servlet.jsp` | 额外要导的包才需要写 |

`errorPage` 和 `isErrorPage` 是一对：出错的页面写 `<%@ page errorPage="/error.jsp" %>`，而 `/error.jsp` 自己写 `<%@ page isErrorPage="true" %>`，这样它才拿得到 `exception` 对象。

### 九个内置对象

它们是容器在 `_jspService` 开头替你声明好的局部变量，你直接用就行，不用也不该自己 new：

| 名字 | 类型 | 作用域 | 就是 Servlet 里的哪个 |
| --- | --- | --- | --- |
| `request` | `HttpServletRequest` | request | 一模一样 |
| `response` | `HttpServletResponse` | request | 一模一样 |
| `session` | `HttpSession` | session | 一模一样 |
| `application` | `ServletContext` | application | 一模一样 |
| `config` | `ServletConfig` | page | 一模一样 |
| `out` | `JspWriter` | page | 对应 `response.getWriter()`，但带缓冲 |
| `pageContext` | `jakarta.servlet.jsp.PageContext` | page | Servlet 里没有，JSP 独有 |
| `page` | `Object`（就是 `this`） | page | Servlet 里没有 |
| `exception` | `Throwable` | page | 只在 `isErrorPage="true"` 的页面里有 |

`pageContext` 是这里唯一的新面孔，它是一个「总入口」：从它身上能拿到其他所有内置对象，也能跨四个域读写属性。后面 EL 那节 `${pageContext.request.contextPath}` 就是靠它拿上下文路径。

### 四个域

`setAttribute` / `getAttribute` 这套在 JSP 里有四层，范围从小到大：

| 域 | 活多久 |
| --- | --- |
| **page** | 只在当前这个页面里，出了这页就没了 |
| **request** | 一次请求内有效，**转发过去的页面还能读到**（这正是下面 MVC 案例的基础） |
| **session** | 同一个用户的整个会话 |
| **application** | 整个 web 应用，所有用户共享 |

选择原则很朴素：**能用小的就不用大的。** 数据只是查出来交给页面渲染，就用 request 域；放进 session 意味着它会一直占着内存直到会话结束（会话本身是怎么回事，见 [[会话跟踪]]）。

## 为什么不该再往 JSP 里写 `<% %>`

前面把脚本片段讲清楚了，现在讲为什么讲完就该忘掉它。

用 `<% %>` 写页面，是把 Java 代码从 `.java` 挪到了 `.jsp`，典型场景里那三件事一件都没解决：

- HTML 语法错误编译器依然不管
- 逻辑散在页面各处，同一段判断在三个页面里抄三遍
- 前端还是打不开这个文件——现在里面不但有 Java，还有一半是 Java 拼出来的 HTML

真正的分工应该是：**[[Servlet]] 负责算出数据，JSP 只负责把算好的数据摆出来。** 而「只负责摆」意味着 JSP 里不该出现循环、判断、方法调用这些东西——至少不该以 Java 语句的形式出现。

于是需要两样替代品：一种不写 Java 的取值语法（EL），和一套不写 Java 的流程控制标签（JSTL）。

## EL 表达式

EL（Expression Language，表达式语言）的形态就一个：`${...}`。

```jsp
<td>${user.userName}</td>
```

它做的事等价于「找到那个叫 `user` 的对象，读它的 `userName` 属性」。`.` 走的是 JavaBean 属性访问，也就是调 `getUserName()`；`user` 这个对象怎么来的，见下一节。

### `${user}` 是从哪找出来的

没写限定的时候，容器**按域从小到大依次搜索：page → request → session → application，第一个命中的赢。**

想跳过搜索直接指定，用带 `Scope` 后缀的隐含对象：

```jsp
${requestScope.user}      <%-- 只在 request 域里找 --%>
${sessionScope.user}
```

平时写 `${user}` 就够了，需要明确指定的场合通常是**两个域里有同名属性**——这种时候不指定就是在赌，赌哪个域先被搜到。

### 隐含对象

EL 有自己的一套隐含对象，和上一节 JSP 的九个内置对象是两套东西，别搞混：

| 隐含对象 | 拿到什么 |
| --- | --- |
| `pageScope` / `requestScope` / `sessionScope` / `applicationScope` | 对应域里的属性 |
| `param` | 单值请求参数，`${param.name}` 相当于 `request.getParameter("name")` |
| `paramValues` | 多值请求参数（复选框那种） |
| `header` / `headerValues` | 单值 / 多值请求头 |
| `cookie` | 请求里的 Cookie 对象 |
| `initParam` | `web.xml` 里配的初始化参数 |
| `pageContext` | 就是那个 `PageContext` 对象 |

最后一个最常用的写法是拼上下文路径：

```jsp
<a href="${pageContext.request.contextPath}/user/list">用户列表</a>
```

一路点下去是 `pageContext.getRequest().getContextPath()`。**链接前缀千万别写死**，理由在 [[Servlet 整合 MyBatis]] 里讲过：上下文路径是部署时才确定的。

### null 不会炸

这是 EL 相比 `<%= %>` 最实在的一个改善。

`<%= user.getUserName() %>`，`user` 是 null 的话，页面直接 500，栈顶是 `NullPointerException`。

`${user.userName}`，`user` 是 null 的话，表达式求值得到 null；而规范规定 null 转成 String 时**返回空串**（「If `A` is `null`, return `""`」）。页面上就是那一格空着，其余照常渲染。

这个特性让 JSP 页面对「数据没查到」有了天然的容错。代价是**错别字不报错**：`${user.usreName}` 也只是渲染出一片空白，你会盯着空页面找半天。**页面上某个字段莫名其妙是空的，先怀疑属性名拼错了。**

### 运算符

EL 自带一套运算符，每个都有符号和关键字两种写法：

| 类别 | 符号 | 关键字 |
| --- | --- | --- |
| 相等 | `==` / `!=` | `eq` / `ne` |
| 比较 | `<` `>` `<=` `>=` | `lt` `gt` `le` `ge` |
| 逻辑 | `&&` `\|\|` `!` | `and` `or` `not` |
| 算术 | `+` `-` `*` `/` `%` | `div` `mod` |
| 三元 | `A ? B : C` | — |

**关键字写法存在的理由是 XML。** `${a < b}` 里那个 `<` 在标签属性里会让 XML 解析器犯迷糊，写成 `${a lt b}` 就没这问题。

单独拎出来的是 `empty`，判空判得很全，规范列的规则是：

- `A` 是 `null` → `true`
- `A` 是空字符串 → `true`
- `A` 是空数组 → `true`
- `A` 是空 `Map` → `true`
- `A` 是空 `Collection` → `true`

所以 `${empty users}` 一个表达式同时挡住了「查询返回 null」和「查出来是空列表」两种情况，不用写 `users != null && users.size() > 0`。

## JSTL

EL 解决了取值，还剩循环和判断。JSTL（Jakarta Standard Tag Library，标准标签库）就是把这些流程控制包装成 HTML 标签的样子。

### 先把依赖装对

**容器不自带 JSTL。** Tomcat 的文档说得很直接：要用 JSTL，得把它的 jar 拷进你 web 应用的 `WEB-INF/lib` 目录。

放到 Maven 项目里，这意味着 JSTL 的依赖**不能像 `jakarta.servlet-api` 那样写 `<scope>provided</scope>`**。servlet-api 写 provided 是因为容器带了一份（见 [[Tomcat]]），JSTL 没人替你带，必须用默认的 `compile` scope 让它进 war 包。

规范页给出的 API 坐标是 `jakarta.servlet.jsp.jstl:jakarta.servlet.jsp.jstl-api`（3.0 对应的版本是 `3.0.2`）。注意**这只是接口**，还得再引一个实现，具体坐标在 Maven Central 上查当前版本。

### URI 换过名字

引好 jar 之后，页面顶部用 `taglib` 指令声明前缀：

```jsp
<%@ taglib prefix="c" uri="jakarta.tags.core" %>
```

`uri` 那串是 JSTL 最容易卡住人的地方，因为**它在版本之间换过**：

| 库 | JSTL 2.0 的 URI | JSTL 3.0 的 URI |
| --- | --- | --- |
| 核心 | `http://java.sun.com/jsp/jstl/core` | `jakarta.tags.core` |
| 格式化 | `http://java.sun.com/jsp/jstl/fmt` | `jakarta.tags.fmt` |
| 函数 | `http://java.sun.com/jsp/jstl/functions` | `jakarta.tags.functions` |
| SQL | `http://java.sun.com/jsp/jstl/sql` | `jakarta.tags.sql` |
| XML | `http://java.sun.com/jsp/jstl/xml` | `jakarta.tags.xml` |

`prefix="c"` 只是你给这个库起的本地别名，写成 `core` 也行，但全世界都用 `c`，跟着用别人才看得懂。

**URI 和 jar 版本必须配套。** 网上 2020 年前的教程清一色是 `http://java.sun.com/...` 那一列，照抄到引了 3.0 的项目里就是找不到标签库。这和 [[Servlet]] 里 `javax` 换 `jakarta` 是同一场迁移的两个战场——**遇到「明明照着教程写的却不认」，先对版本，别对代码。**

顺带一提，SQL 那个库是能在页面里直接连数据库查数据的。**别用**，它把数据访问塞回了视图层，正好走在这篇笔记要解决的问题的反方向上。

### 核心标签

**`<c:forEach>`——循环**

```jsp
<c:forEach items="${users}" var="u" varStatus="s">
  <tr><td>${s.count}</td><td>${u.userName}</td></tr>
</c:forEach>
```

| 属性 | 作用 |
| --- | --- |
| `items` | 要遍历的东西：数组、`Collection`、`Iterator`、`Enumeration`、`Map`（拿到的是 `Map.Entry`）都行 |
| `var` | 每轮循环里当前元素的变量名 |
| `varStatus` | 循环状态对象（`LoopTagStatus`），`count` 是第几次（从 1 开始），`index` 是下标 |
| `begin` / `end` / `step` | 不给 `items` 时当计数循环用，给了 `items` 时用来截取区间 |

两个规范里写明、实际会踩到的行为：

- **`items` 是 null 时按空集合处理，一次都不循环**，不会报错。配合上面 EL 的 null 容错，「查询没结果」这条路径基本不用特殊处理
- **`var` 导出的变量是「嵌套可见」的**：它存在 page 域，但只在标签体内部可见，**循环结束后取不到**。想在循环外用最后一个元素的值，得自己另存

**`<c:if>`——判断**

```jsp
<c:if test="${empty users}">
  <p>还没有用户</p>
</c:if>
```

`test` 收一个布尔表达式。**它没有 `else`**，需要分支就用下面这组。

**`<c:choose>` / `<c:when>` / `<c:otherwise>`——多分支**

```jsp
<c:choose>
  <c:when test="${u.age < 18}">未成年</c:when>
  <c:when test="${u.age < 60}">成年</c:when>
  <c:otherwise>退休</c:otherwise>
</c:choose>
```

**第一个 `test` 为 true 的 `<c:when>` 执行自己的标签体，后面的不再尝试**，和 Java 里 `if / else if / else` 的短路行为一致。`<c:otherwise>` 在所有 `<c:when>` 都没命中时执行。

**`<c:out>`——转义输出**

```jsp
<c:out value="${u.userName}" default="匿名"/>
```

它比直接写 `${u.userName}` 多做两件事：`value` 为 null 时输出 `default`（不给 `default` 就是空串），以及——**默认转义 HTML**。

`escapeXml` 的默认值是 `true`，会把 `<`、`>`、`&`、`'`、`"` 转成对应的字符实体。这条默认值就是它存在的主要理由：

```jsp
${u.userName}                       <%-- 原样输出，用户名是 <script>… 就真的执行了 --%>
<c:out value="${u.userName}"/>      <%-- 转义成 &lt;script&gt;，浏览器当文本显示 --%>
```

**规则记成一句：凡是用户能填进来的内容，输出时都过一遍 `<c:out>`。** 自己写死的常量和数字随意。

其余标签用得少，知道有就行：`<c:set>` / `<c:remove>` 读写域属性，`<c:url>` 生成带上下文路径和参数的 URL，`<c:redirect>` 重定向，`<c:catch>` 抓标签体里抛出的 `Throwable`，`<c:forTokens>` 按分隔符切字符串再遍历。

## 综合案例：把用户列表页改成 MVC

现在把典型场景里那段 `out.write` 拆开。数据仍旧由 Servlet 查，页面交给 JSP，两边靠 request 域接头——这套角色分工就是 [[MVC 模式]]。

**第一步，Servlet 只做两件事：查数据、转发。**

```java
@WebServlet("/user/list")
public class UserListServlet extends HttpServlet {

    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp)
            throws ServletException, IOException {

        List<User> users;
        try (SqlSession session = MyBatisUtil.openSession()) {
            users = session.getMapper(UserMapper.class).selectAll();
        }

        req.setAttribute("users", users);                                 // 存进 request 域
        req.getRequestDispatcher("/WEB-INF/views/list.jsp")
           .forward(req, resp);                                           // 交给 JSP 渲染
    }
}
```

和 [[Servlet 整合 MyBatis]] 里的版本比，`resp.setContentType(...)` 和整段拼 HTML 的代码全没了——编码由 JSP 的 `page` 指令管，HTML 由 JSP 自己管。

**第二步，`src/main/webapp/WEB-INF/views/list.jsp`：**

```jsp
<%@ page contentType="text/html;charset=UTF-8" pageEncoding="UTF-8" %>
<%@ taglib prefix="c" uri="jakarta.tags.core" %>
<!doctype html>
<html>
<head><title>用户列表</title></head>
<body>
<h2>用户列表</h2>

<c:choose>
  <c:when test="${empty users}">
    <p>还没有用户</p>
  </c:when>
  <c:otherwise>
    <table border="1">
      <tr><th>#</th><th>姓名</th><th>年龄</th></tr>
      <c:forEach items="${users}" var="u" varStatus="s">
        <tr>
          <td>${s.count}</td>
          <td><c:out value="${u.userName}"/></td>
          <td>${u.age}</td>
        </tr>
      </c:forEach>
    </table>
  </c:otherwise>
</c:choose>

<a href="${pageContext.request.contextPath}/user/add.jsp">新增</a>
</body>
</html>
```

**整个页面一行 Java 语句都没有。** 几个细节值得停一下：

- **文件放在 `WEB-INF/views/` 下。** [[Servlet]] 里提过，`WEB-INF` 里的资源浏览器直接访问是 404，但转发过去完全没问题。这不是为了藏起来好玩——它保证了**没有任何路径能绕过 Servlet 直接打开这个页面**，也就保证了页面渲染时 `users` 一定已经在 request 域里了
- **姓名过了 `<c:out>`，序号和年龄没过。** 前者是用户填的，后者一个是循环计数一个是数字
- **`${s.count}` 从 1 开始**，正好当行号用；要从 0 开始的下标是 `${s.index}`
- **`users` 是空或 null，页面显示「还没有用户」**，不会报错也不会渲染出一个空表格

**第三步，表单页也能顺手改成 JSP。** [[Servlet 整合 MyBatis]] 里的 `add.html` 把上下文路径写死在 `action` 里（`action="/user-demo/user/add"`），换个部署路径就全挂。改名成 `add.jsp` 之后：

```jsp
<%@ page contentType="text/html;charset=UTF-8" pageEncoding="UTF-8" %>
<form action="${pageContext.request.contextPath}/user/add" method="post">
  姓名：<input name="userName"><br>
  年龄：<input name="age"><br>
  <button type="submit">提交</button>
</form>
```

**一个纯静态的页面只要用上 `${pageContext.request.contextPath}`，就值得从 `.html` 改成 `.jsp`。** 代价只是多一次翻译，收益是链接不再和部署路径绑死。

## 常见坑

| 现象 | 原因 |
| --- | --- |
| 页面中文全是问号 | `page` 指令没写 `contentType`，用了默认的 `ISO-8859-1` |
| 源码里的中文在翻译时就烂了 | `pageEncoding` 和文件实际编码对不上 |
| 报错行号和 `.jsp` 对不上 | 行号是生成的 Java 文件的，去 Tomcat `work/` 目录看那份源码 |
| 找不到标签库 | `taglib` 的 `uri` 和 JSTL 版本对不上，`jakarta.tags.core` 和 `http://java.sun.com/...` 是两代 |
| 引了 JSTL 依然找不到标签 | 依赖写成了 `provided`，jar 没进 war 包——容器不自带 JSTL |
| 某个字段渲染出来是空白 | EL 里属性名拼错了，null 转 String 是空串，不报错 |
| `<c:forEach>` 循环外取不到 `var` | `var` 是嵌套可见的，出了标签体就没了 |
| 用户名里的 `<script>` 被执行了 | 直接 `${}` 输出不转义，不可信内容要走 `<c:out>` |
| `session` 内置对象是 null | `page` 指令里写了 `session="false"` |
| `exception` 对象用不了 | 错误页面没写 `isErrorPage="true"` |

## 参考

- [Jakarta Server Pages 4.0 Specification](https://jakarta.ee/specifications/pages/4.0/jakarta-server-pages-spec-4.0) — 翻译阶段与实现类见「JSP Page Implementation Class」，`page` 指令属性表见「Directives」
- [Jakarta Standard Tag Library 3.0 Specification](https://jakarta.ee/specifications/tags/3.0/jakarta-tags-spec-3.0.html) — 核心标签的属性与语义
- [Jakarta Expression Language 5.0 Specification](https://jakarta.ee/specifications/expression-language/5.0/jakarta-expression-language-spec-5.0.html) — 运算符、`empty`、类型强制转换规则
- [Apache Tomcat — Apache Taglibs](https://tomcat.apache.org/taglibs.html)
