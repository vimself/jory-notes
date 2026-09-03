---
tags: [类型/概念, 技术/Java, 技术/Servlet, 技术/JSP]
aliases: [MVC, Model-View-Controller]
created: 2026-09-03
updated: 2026-09-03
---
> MVC 把一次请求的活拆成三份——谁来接（Controller）、谁来算（Model）、谁来显示（View）。它要换来的不是图纸好看，是「改样式」和「改业务」这两件事永远不用打开同一个文件。

## 典型场景

用户列表页上线了。接下来两周，你大概会收到这么三种需求：

- 表格加一列「注册时间」，顺便把边框改细
- 只显示 18 岁以上的用户
- 数据库从 MySQL 换成 PostgreSQL

提需求的是三拨人，出错的后果也完全不同。可如果这个页面是一个 Servlet 从头包到尾——连数据库、算过滤条件、`out.write` 一行行拼 HTML——那么这三种需求最后都落在同一个文件、同一个方法里。改样式的人要在 SQL 语句中间找 `<td>`；改 SQL 的人手一抖，把 `</table>` 删了。

MVC 要解决的就是这件事：**让不同原因引起的修改，落到不同的文件上。**

## 三个角色分别干什么

| 角色 | 它负责 | 它绝不碰 | Java Web 里谁演 |
| --- | --- | --- | --- |
| **Model**（模型） | 业务数据和业务规则：一个用户长什么样、年龄不能是负数、注册要先查重 | HTML、HTTP、请求参数 | 实体类（JavaBean）+ 业务类 |
| **View**（视图） | 把 Model 给的数据摆成用户看得见的样子 | 数据库、业务判断 | [[JSP]] 或别的模板 |
| **Controller**（控制器） | 接住请求、把参数翻译成 Model 认识的东西、调 Model、挑一个 View 交出去 | SQL、拼 HTML | [[Servlet]] |

**JavaBean** 是这里第一个要就地解释的词：它不是什么高级机制，就是一个普通 Java 类，私有字段配上 getter/setter，再留一个无参构造方法。之所以有个专门的名字，是因为 JSP、EL 表达式这些工具都按这套约定去取值——`${user.userName}` 实际上调的是 `getUserName()`。

三行字总结职责边界，比记定义管用：

- **Controller 是翻译**，它把 HTTP 世界的东西（字符串参数、请求头、Cookie）翻译成 Java 世界的东西（对象、方法调用），再把结果翻译回去
- **Model 不知道自己活在网页里**，它同样可以被一个定时任务或命令行脚本调用
- **View 是只读的**，它只负责显示别人算好的结果

## 一次请求怎么在三者之间流动

```text
浏览器  GET /user/list
   │
   ▼
Controller（UserListServlet）
   │  ① 读参数：req.getParameter("minAge")
   │  ② 调 Model：查出 List<User>
   │  ③ 把结果放进 request 域：req.setAttribute("users", users)
   │  ④ 转发：req.getRequestDispatcher("/WEB-INF/views/list.jsp").forward(req, resp)
   ▼
View（list.jsp）
   │  用 EL 和 JSTL 把 users 渲染成表格
   ▼
浏览器  HTTP/1.1 200 OK + 一张表格
```

这条链上有两个细节值得停一下。

**第一，View 不是浏览器直接访问的。** 上面那个 JSP 放在 `/WEB-INF/views/` 下面，而 `WEB-INF` 目录里的东西浏览器根本请求不到——用户敲 `/WEB-INF/views/list.jsp` 只会得到 404。这不是为了防谁，是为了保证页面拿到的数据一定是 Controller 准备好的：直接访问 JSP 意味着 `users` 这个属性压根不存在，页面只会渲染出一张空表。

**第二，交接靠的是转发，不是重定向。** 两者的区别在 [[Servlet]] 里讲透了，这里只说结论：转发是服务器内部的一次接力，`request` 对象是同一个，所以 Controller 塞进 request 域的数据 View 才读得到；重定向是让浏览器重新发一个请求，request 对象换了新的，塞进去的东西全丢。**「转发后页面数据是空的」和「重定向后页面数据是空的」，后者几乎总是这个原因。**

完整可运行的代码见 [[JSP]] 里的「把用户列表页改成 MVC」，这里不重复。

## 怎么判断职责串味了

不用背原则，问三个问题就够，任何一个答「有」，就说明角色开始越界：

1. **JSP 里有没有出现 `select`、`insert` 这类词？** 有 → View 在查数据库
2. **Servlet 里有没有出现 `<table>`、`<div>`？** 有 → Controller 在拼页面
3. **实体类或业务类里有没有 `import jakarta.servlet.*`？** 有 → Model 认识 HTTP 了

第三条最容易被放过，代价却最大。一个业务方法只要签名里出现 `HttpServletRequest`，它就被焊死在 Web 环境里了：定时任务调不了它，命令行导入脚本调不了它，写单元测试得先造一个假的 request 对象。**Model 层的参数应该是 `String userName, int age` 或者一个 `User` 对象，而不是「请求」本身。**

## MVC 不是三层架构

这两个词经常被当成同义词用，其实它们是两把不同方向的刀：MVC 切的是「一次请求里的角色分工」，三层架构切的是「代码按职责摞成几层」。两者能叠在一起用，对应关系见 [[三层架构]]——那篇里有一张图专门讲它们怎么重合。

## 参考

- [Jakarta EE Tutorial: Jakarta Servlet Technology](https://eclipse-ee4j.github.io/jakartaee-tutorial/#jakarta-servlet-technology)
- [Jakarta Servlet Specification](https://jakarta.ee/specifications/servlet/) — 转发与 `RequestDispatcher` 见「Dispatching Requests」
