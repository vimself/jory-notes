---
tags: [类型/概念, 技术/Servlet, 技术/Java]
aliases: []
created: 2026-09-03
updated: 2026-09-03
---
> 监听器是你在容器里挂的几个钩子：应用启动了、会话创建了、请求进来了、域里的属性被改了——事情一发生，容器主动回调你的方法。你不用去轮询，也不用找地方「插一脚」。

## 典型场景

应用启动的时候要干点事：加载一份配置文件、建好数据库连接池、把字典表读进内存缓存起来。

这段代码放哪？

- 放某个 Servlet 的 `init()` 里——[[Servlet]] 默认是**第一次被访问时才创建实例**，那这段初始化要等到有人恰好访问了那个 Servlet 才执行，而且换个人删掉这个 Servlet，初始化就跟着没了
- 放 `main` 方法里——Web 应用没有 `main`，入口在容器手里
- 放静态代码块里——类什么时候被加载不由你说了算

真正需要的是一个明确的入口：**「这个 Web 应用启动完成了」的那一刻通知我**。这就是 `ServletContextListener` 存在的理由。

## 三组事件，八个接口

监听器不是一个接口，是一族。按「监听谁」分成三组，规范里就是这么排的：

**第一组，监听 ServletContext（整个应用，全局唯一）**

| 接口 | 什么时候被调 |
| --- | --- |
| `ServletContextListener` | 应用刚创建好准备接第一个请求时、应用即将关闭时 |
| `ServletContextAttributeListener` | application 域里的属性被添加、删除、替换时 |

**第二组，监听 HttpSession（一个用户的会话）**

| 接口 | 什么时候被调 |
| --- | --- |
| `HttpSessionListener` | 会话被创建、作废或超时 |
| `HttpSessionAttributeListener` | session 域里的属性被添加、删除、替换 |
| `HttpSessionIdListener` | 会话的 id 变了（比如登录后调了 `changeSessionId`） |
| `HttpSessionActivationListener` | 会话被钝化到磁盘 / 从磁盘活化回来 |
| `HttpSessionBindingListener` | 某个对象被绑进会话 / 从会话里解绑 |

**第三组，监听 ServletRequest（一次请求）**

| 接口 | 什么时候被调 |
| --- | --- |
| `ServletRequestListener` | 请求开始被 Web 组件处理、处理完毕 |
| `ServletRequestAttributeListener` | request 域里的属性被添加、删除、替换 |
| `AsyncListener` | 异步处理超时、连接断开或完成 |

规律其实很整齐：**每类作用域都配一对——一个管「这东西的生死」，一个管「这东西里的属性变动」。** 记住这个规律，八个接口的名字就不用背了。

日常真正会写的是第一组的 `ServletContextListener` 和第二组的 `HttpSessionListener`，剩下的知道有就行，需要时按上表去查。

## 手把手：应用启动时初始化

监听器要满足两个硬性条件：**实现对应接口**，并且**有一个 public 的无参构造方法**（规范明文要求，因为容器要靠反射 new 它）。声明方式用注解最省事：

```java
package com.example.listener;

import jakarta.servlet.ServletContextEvent;
import jakarta.servlet.ServletContextListener;
import jakarta.servlet.annotation.WebListener;

@WebListener
public class AppInitListener implements ServletContextListener {

    @Override
    public void contextInitialized(ServletContextEvent sce) {
        // 应用启动：把要全局共享的东西放进 application 域
        sce.getServletContext().setAttribute("onlineCount", 0);
        System.out.println("应用启动完成");
    }

    @Override
    public void contextDestroyed(ServletContextEvent sce) {
        // 应用关闭：关连接池、停线程池，都在这
        System.out.println("应用即将关闭");
    }
}
```

时机在文档里定得很死，这也正是它比 `init()` 靠谱的原因：

- **`contextInitialized` 在这个应用里任何 Filter 和 Servlet 被初始化之前调用**，所以你在这里准备好的东西，后面所有组件都能直接用
- **`contextDestroyed` 在所有 Servlet 和 Filter 都销毁之后才调用**，所以清理资源时不用担心还有组件正在使用它

`ServletContextEvent` 参数唯一的用处就是 `getServletContext()`——拿到那个全应用共享的上下文对象，往里放东西或读初始化参数。

两个方法都是**默认方法**（接口里带 `default` 实现，默认什么都不做），所以只关心启动就只重写 `contextInitialized`，不用被迫写一个空的 `contextDestroyed`。

除了 `@WebListener`，也可以在 `web.xml` 里声明：

```xml
<listener>
  <listener-class>com.example.listener.AppInitListener</listener-class>
</listener>
```

**多个监听器需要保证调用顺序时，只能用 `web.xml`**——规范说的是「按它们被调用的顺序列出类名」，也就是写在前面的先调；注解方式没有规定顺序。

## 统计在线人数

[[Servlet]] 那篇开头举的例子是一个显示「当前在线人数」的页面。那个数字从哪来？一人一个会话，于是「在线人数」约等于「活着的会话数」，这正是 `HttpSessionListener` 的两个回调：

```java
@WebListener
public class OnlineCountListener implements HttpSessionListener {

    @Override
    public void sessionCreated(HttpSessionEvent se) {
        change(se, 1);
    }

    @Override
    public void sessionDestroyed(HttpSessionEvent se) {
        change(se, -1);
    }

    private void change(HttpSessionEvent se, int delta) {
        ServletContext ctx = se.getSession().getServletContext();
        synchronized (ctx) {                       // 多个请求线程会同时进来
            Integer count = (Integer) ctx.getAttribute("onlineCount");
            ctx.setAttribute("onlineCount", (count == null ? 0 : count) + delta);
        }
    }
}
```

两个细节：

**计数放在 application 域里**，因为它要跨所有用户共享；放 session 域每个人看到的都是自己那份。

**必须加锁。** 多个用户同时进站时，`sessionCreated` 是在不同的请求线程里并发执行的，`读—加一—写回` 这三步不是原子操作，不同步就会丢计数。

再提醒一句，`sessionDestroyed` 的触发时间取决于会话超时，用户关掉浏览器不会立刻触发它——[[会话跟踪]] 里解释了为什么。所以这个数字的含义是「最近 30 分钟内活跃过的人数」，不是「此刻还开着页面的人数」。

## 容易记混的一对：Attribute 和 Binding

`HttpSessionAttributeListener` 和 `HttpSessionBindingListener` 名字像，角色完全不同：

| | `HttpSessionAttributeListener` | `HttpSessionBindingListener` |
| --- | --- | --- |
| 谁来实现 | 一个专门的监听器类 | **被存进会话的那个对象自己**（比如 `User` 类） |
| 要不要注册 | 要（`@WebListener` 或 `web.xml`） | **不用**，容器发现它实现了这个接口就会回调 |
| 关心什么 | 这个应用里**所有**会话的属性变动 | 只关心**自己**被绑进哪个会话、什么时候被解绑 |

判断标准很简单：想在「任何人往会话里放东西」时统一做点什么，用前者；想让某个类在「自己被放进会话 / 被踢出会话」时做点什么（比如断开它持有的连接），用后者。

## 什么时候不该用监听器

监听器是全局生效的钩子，代价是**调用它的代码在源码里看不见**——读 Servlet 的人不会知道有个监听器在背后改了 application 域。所以：

- **应用级的一次性初始化和清理**：适合，这是它的主场
- **每个请求都要做的统一处理**（登录校验、编码、日志）：用 [[Servlet 过滤器]]，过滤器能拦截、能改写、能决定放不放行，监听器只能被动接收通知
- **业务逻辑**：不适合。把「下单后扣库存」挂在属性变动上，三个月后没人找得到这段代码在哪触发

## 参考

- [Jakarta Servlet Specification](https://jakarta.ee/specifications/servlet/) — 事件类型与监听器接口对照表见「Application Lifecycle Events」
- [ServletContextListener（Jakarta Servlet API 文档）](https://jakarta.ee/specifications/servlet/6.0/apidocs/jakarta.servlet/jakarta/servlet/servletcontextlistener) — 两个回调的调用时机
