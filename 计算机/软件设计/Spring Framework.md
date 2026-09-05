---
tags: [类型/概念, 技术/Java, 技术/Spring]
aliases: [Spring, Spring 框架]
created: 2026-09-05
updated: 2026-09-05
---
> 「Spring」这个词同时指两样东西：一个叫 Spring Framework 的具体框架，和一整个建在它之上的项目家族。Framework 提供的是最底下那层地基——一个替你 `new` 对象、并在方法前后插入横切逻辑的容器，其余一切都长在这上面。

## 典型场景

你决定给项目引入 Spring，打开搜索框，然后就懵了。

同一节课里，老师一会儿说「Spring」，一会儿说「SpringBoot」，一会儿又冒出「SpringMVC」；Maven 仓库里搜 spring，跳出来 `spring-core`、`spring-context`、`spring-webmvc`、`spring-boot-starter-web`、`spring-cloud-starter-gateway`……几十个坐标，长得都差不多。

**到底该往 `pom.xml` 里加哪个？这些名字之间是并列关系还是包含关系？**

这篇不教你写代码，只回答这一个问题：把这张地图铺开，让你知道后面每一篇笔记站在哪一格上。

## 「Spring」指的是哪个 Spring

先把这个歧义拆开，它是所有困惑的源头。

| 说到「Spring」时 | 实际指 | 关系 |
| --- | --- | --- |
| 窄义 | **Spring Framework** 这一个项目 | 全家桶的地基，2003 年就有的那个 |
| 广义 | 整个 **Spring 家族**：Boot、Data、Security、Cloud…… | 都建在 Framework 之上 |

官方文档对此有明确说法：Spring Framework 是「一切开始的地方」，其他 Spring 项目是后来建在它上面的；日常口语里人们说「Spring」通常指整个家族，而参考文档本身只讲 Framework。

**本篇以及 [[Spring IoC 与 DI]]、[[Spring AOP]]、[[Spring 事务管理]] 讲的都是窄义的那个 Framework。**

## 它当年解决的什么问题

Spring 诞生于 **2003 年**，是对早期 J2EE 规范复杂度的一次回应。

这句话对没经历过那个年代的人等于没说，所以翻译一下：那时候要写一个「从数据库查用户」的功能，你得实现一堆规范强加的接口、写几份 XML 描述符、把类打成特定结构的包、再部署到一台重量级应用服务器上才能跑起来——**业务代码只有 5 行，脚手架有 500 行，而且这 500 行离开那台服务器就跑不了，连单元测试都做不了。**

Spring 的回答是：让你的业务类回归普通 Java 类，不实现任何框架接口、不继承任何框架基类，框架从外面把它们组装起来。这个思路的落地就是 [[Spring IoC 与 DI]] 里的容器。

它没有去和 Jakarta EE（J2EE 的现名）打对台，而是**挑着用**——Servlet API、JPA、Bean Validation 这些规范该用就用，只是不把整套 EE 容器一起吞下去。

有几条设计原则贯穿至今，其中两条你迟早会有体感：

- **每一层都提供选择。** 换持久化实现只改配置、不改代码，这不是宣传语，是 [[Spring 整合 MyBatis]] 里真实发生的事
- **强调向后兼容。** 版本之间很少有破坏性变更，代价是 API 里留着不少历史包袱

## 模块地图

Spring Framework 自己是拆成一堆 Gradle 模块的，发布到 Maven 上就是一堆 `org.springframework:spring-*` 坐标。按职责归一下类：

```
核心容器  spring-core        工具类与基础设施，所有模块的公共底座
          spring-beans       bean 的定义、装配、生命周期
          spring-context     ApplicationContext，也就是你天天用的那个「容器」
          spring-expression  SpEL 表达式语言

切面      spring-aop         代理式 AOP，Spring 自己的事务就架在它上面
          spring-aspects     基于 AspectJ 编织的增强版

数据访问  spring-jdbc        JdbcTemplate 之类
          spring-tx          事务抽象，@Transactional 在这
          spring-orm         对接 Hibernate / JPA
          spring-r2dbc       响应式数据库访问

Web       spring-web         Web 层公共部分
          spring-webmvc      基于 Servlet 的 MVC 框架，就是「SpringMVC」
          spring-webflux     响应式 Web 栈
          spring-websocket   WebSocket 支持

其他      spring-test        测试支持，TestContext 框架在这
          spring-messaging   消息抽象
          spring-jms / spring-oxm / spring-instrument / spring-context-support ...
```

读这张表时，有三件事和直觉不一样：

**一、`spring-webmvc` 就是 SpringMVC。** 它不是一个独立项目，是 Framework 的一个模块。所以「Spring 和 SpringMVC 什么关系」这个问题的答案是：包含关系，不是并列关系。

**二、你几乎不需要手写这些坐标。** 模块之间有依赖，你声明 `spring-context`，Maven 会把 `spring-core`、`spring-beans`、`spring-expression` 一起拖进来——这就是 [[Maven]] 的传递依赖。用 Spring Boot 的话连 `spring-context` 都不用写。

**三、这是「按需取用」的设计。** 写个纯命令行工具只要核心容器，一个 Web 模块都不用引。

## Framework、Boot、Cloud 的边界

这三个名字最容易被摆成并列关系，其实是**层层叠加**的：

| | 它是什么 | 它替你省掉的事 |
| --- | --- | --- |
| **Spring Framework** | 地基：IoC 容器 + AOP + 各种集成抽象 | 手动 `new` 和手写横切逻辑 |
| **Spring Boot** | Framework 之上的一层「自动配置 + 起步依赖 + 内嵌服务器」 | 手写一大堆 XML/Java 配置、手动装 [[Tomcat]] |
| **Spring Cloud** | Boot 之上的分布式工具箱：服务发现、配置中心、网关…… | 微服务之间的那些通信设施 |

关键在于：**Boot 没有取代 Framework，它只是把 Framework 的配置工作自动化了。** 你用 Boot 写的 `@Service`、`@Autowired`、`@Transactional`，全都是 Framework 的东西。所以先学 Framework 不是绕远路——那是 Boot 帮你自动配的东西本身。

反过来说，**跳过 Framework 直接学 Boot，遇到问题就只能靠搜**：Boot 帮你配好的那层一旦不符合预期，你连它配了什么都不知道。

[[Spring MVC]]、[[Spring Boot]]、[[Spring Cloud]] 各自都是独立的大主题，学到了再单独成篇。

## 概念之间的依赖顺序

Spring 的知识点之间有硬性的先后关系，顺序错了后面会一直卡：

```
Spring IoC 与 DI  ────┬──→  Spring 整合 MyBatis
   （核心容器）        │        （容器接管 SqlSession）
        │              │
        ↓              │
   Spring AOP  ────────┴──→  Spring 事务管理
   （代理与增强）              （AOP 的头号应用）
```

- **[[Spring IoC 与 DI]] 是绝对的第一站。** 后面所有东西都是「往容器里放东西」和「容器帮你做事」的变体
- **[[Spring 整合 MyBatis]] 紧随其后**，因为它是 IoC 最直观的收益：[[Servlet 整合 MyBatis]] 里那个手写的 `MyBatisUtil` 会整个消失
- **[[Spring AOP]] 必须排在 [[Spring 事务管理]] 前面。** 声明式事务就是一段现成的 AOP 通知，不懂代理机制，你就无法理解「为什么在同一个类里调用带 `@Transactional` 的方法，事务不生效」这类问题
- **家族成员放最后。** [[Spring MVC]] 取代 [[Servlet]] 做表现层，[[Spring Boot]] 把前面所有配置自动化

## 参考

- [Spring Framework Overview](https://docs.spring.io/spring-framework/reference/overview.html)
- [Spring Framework 源码仓库](https://github.com/spring-projects/spring-framework)
