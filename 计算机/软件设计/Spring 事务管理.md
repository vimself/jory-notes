---
tags: [类型/概念, 技术/Java, 技术/Spring]
aliases: [Spring 声明式事务]
created: 2026-09-05
updated: 2026-09-05
---
> 在方法上打一个 `@Transactional`，Spring 用 [[Spring AOP]] 的代理在方法前后自动开启、提交或回滚事务。省下的是每个方法都要写一遍的 try-catch-commit-rollback，但有两个坑必须先知道：默认只对运行时异常回滚，以及同类内部调用不生效。

## 典型场景

转账：从 A 账户扣 100，往 B 账户加 100。

[[三层架构]] 说事务边界在 Service 层，[[MyBatis]] 里事务的单位是 `SqlSession`，于是你老老实实这么写：

```java
public void transfer(int fromId, int toId, BigDecimal amount) {
    SqlSession session = MyBatisUtil.openSession();
    try {
        AccountMapper mapper = session.getMapper(AccountMapper.class);
        mapper.decrease(fromId, amount);
        mapper.increase(toId, amount);
        session.commit();
    } catch (Exception e) {
        session.rollback();
        throw e;
    } finally {
        session.close();
    }
}
```

逻辑没错。问题是：

- **业务只有两行**（`decrease` 和 `increase`），事务管理占了 10 行
- **Service 里有 30 个写方法，这 10 行要抄 30 遍**
- **抄错一次就是生产事故。** 漏掉 `commit()` 的表现是日志里 SQL 明明执行了、数据库里查不到——[[Servlet 整合 MyBatis]] 里踩过一次；漏掉 `close()` 则是连接泄漏，压测时才暴露
- **Service 因此认识了 MyBatis。** 哪天换成 JPA，30 个方法全得重写

这些代码横切了所有写方法，且和业务无关——**这正是 AOP 的用武之地**，而 Spring 已经把这个切面写好了。

## 三件套：让 @Transactional 生效

只有一个注解是不够的，需要三样东西同时到位。

### 一、一个 TransactionManager bean

事务管理器是「怎么开事务」的具体实现。JDBC/MyBatis 场景用 `DataSourceTransactionManager`：

```java
@Configuration
@EnableTransactionManagement
public class AppConfig {

    @Bean
    public PlatformTransactionManager txManager(DataSource dataSource) {
        return new DataSourceTransactionManager(dataSource);
    }
}
```

它来自 `org.springframework.jdbc.datasource` 包，需要一个 `DataSource`。XML 写法是等价的：

```xml
<bean id="txManager" class="org.springframework.jdbc.datasource.DataSourceTransactionManager">
    <property name="dataSource" ref="dataSource"/>
</bean>
```

### 二、开启注解驱动

`@EnableTransactionManagement` 打在配置类上，作用是「扫描 `@Transactional` 并生成代理」。

用注解配置时，它会使用容器里任意一个 `TransactionManager` bean。**XML 配置有个额外规则**：`<tx:annotation-driven/>` 的 `transaction-manager` 属性，当那个 bean 的名字正好叫 `transactionManager` 时可以省略，否则必须显式写出来。

`@Transactional` 的 `transactionManager` 属性默认值也是 `transactionManager` 这个 bean 名字。**所以把事务管理器 bean 命名成 `transactionManager` 能省掉一堆配置**，这是约定俗成的写法。

### 三、在方法上标注

```java
@Service
public class AccountServiceImpl implements AccountService {

    private final AccountMapper accountMapper;

    public AccountServiceImpl(AccountMapper accountMapper) {
        this.accountMapper = accountMapper;
    }

    @Transactional
    public void transfer(int fromId, int toId, BigDecimal amount) {
        accountMapper.decrease(fromId, amount);
        accountMapper.increase(toId, amount);
    }
}
```

开头那 10 行事务管理代码全没了，`SqlSession`、`commit`、`rollback`、`close` 一个都不用写。Service 也不再认识 MyBatis 了。

注解**打在类上表示这个类的所有方法都受管**，打在方法上则只管这一个；方法上的标注会覆盖类上的。

## 头号坑：默认只对运行时异常回滚

这是所有 Spring 事务问题里最常见、后果最严重的一个。

**默认规则：运行时异常（`RuntimeException`）和错误（`Error`）触发回滚；受检异常（checked exception）不回滚。**

写成代码就是这样一个陷阱：

```java
@Transactional
public void transfer(int fromId, int toId, BigDecimal amount) throws IOException {
    accountMapper.decrease(fromId, amount);
    writeAuditLog();                  // 抛 IOException —— 受检异常
    accountMapper.increase(toId, amount);
}
```

`writeAuditLog()` 抛了 `IOException`，方法中断，**但事务照样提交**——钱从 A 扣掉了，B 没收到。

原因是历史包袱：这个规则沿袭自 EJB，逻辑是「受检异常是业务上可预期、调用方应该处理的情况，不算失败」。但绝大多数人的直觉恰恰相反——**方法异常退出了，事务就该回滚。**

两种改法：

```java
@Transactional(rollbackFor = Exception.class)          // 这个方法：所有异常都回滚
public void createUser(User user) { ... }
```

```java
@EnableTransactionManagement(rollbackOn = ALL_EXCEPTIONS)   // Spring 6.2 起：全局改默认
```

反向的属性是 `noRollbackFor`（以及字符串版的 `rollbackForClassName` / `noRollbackForClassName`），用来指定「这几种异常不要回滚」。

**建议：写 `@Transactional` 时顺手带上 `rollbackFor = Exception.class`**，除非你明确知道自己在依赖默认行为。多打几个字，换掉一整类隐蔽的数据不一致。

## 第二个坑：自调用不生效

```java
@Service
public class OrderService {

    public void createOrder(Order o) {
        this.doCreate(o);          // ← 内部调用，事务不生效
    }

    @Transactional
    public void doCreate(Order o) { ... }
}
```

官方原话说得很清楚：在代理模式（也就是默认模式）下，**只有从代理进来的外部方法调用才会被拦截**；自调用——目标对象内部调用自己的另一个方法——在运行时**不会产生真正的事务**，哪怕被调的方法标了 `@Transactional`。

根因和 [[Spring AOP]] 那篇里的自调用失效完全是同一件事：`this` 指向目标对象，不是代理。想彻底理解，去看那篇的「自调用为什么会失效」一节。

解法也一样，首选**把方法挪到另一个 bean 里**，通过注入调过去。官方另给了一条路：切到 AspectJ 模式，此时不再有代理，而是直接改目标类的字节码：

```java
@EnableTransactionManagement(mode = AdviceMode.ASPECTJ)
```

代价是要引入 AspectJ 的织入配置，一般项目不值当。

### 方法可见性也有讲究

`@Transactional` 通常用在 `public` 方法上。**从 Spring 6.0 起，`protected` 和包级可见的方法在类代理（CGLIB）下也可以是事务性的**；但**接口代理（JDK 动态代理）下的事务方法必须是 `public` 且定义在被代理的接口里**。

`private` 方法则任何情况下都不行——代理没法重写它。

## 传播行为：事务方法调用事务方法

`transfer` 里调了另一个带 `@Transactional` 的方法，此时该开一个新事务，还是加入现有的？这就是**传播行为**（propagation），用 `propagation` 属性控制。

七个取值：

| 取值 | 已有事务时 | 没有事务时 |
| --- | --- | --- |
| **`REQUIRED`**（默认） | 加入当前事务 | 新建一个 |
| `REQUIRES_NEW` | **挂起**当前事务，新建一个独立的 | 新建一个 |
| `NESTED` | 在当前事务里建一个**保存点** | 行为等同 `REQUIRED` |
| `SUPPORTS` | 加入当前事务 | 不用事务，直接执行 |
| `NOT_SUPPORTED` | **挂起**当前事务，不用事务执行 | 不用事务，直接执行 |
| `MANDATORY` | 加入当前事务 | **抛异常** |
| `NEVER` | **抛异常** | 不用事务，直接执行 |

写法：

```java
@Transactional(propagation = Propagation.REQUIRED)
public void processOrder() {
    // ... 创建订单 ...
    updateInventory();
}

@Transactional(propagation = Propagation.REQUIRES_NEW)
public void updateInventory() {
    // ... 在一个全新的事务里更新库存 ...
}
```

### 三个主力的区别，说清楚

**`REQUIRED` —— 所有逻辑范围合并成同一个物理事务。** 内层和外层是一回事，一起提交、一起回滚。这里藏着一个反直觉的行为：**内层如果把事务标记成 rollback-only，会影响到外层**，外层提交时会抛出 `UnexpectedRollbackException`。也就是说「我在内层 catch 住异常不往外抛，事务应该没事吧」——不一定。

另外，`REQUIRED` 加入已有事务时，会**静默忽略**内层自己声明的隔离级别、超时和只读标志（除非开启了 `validateExistingTransaction`）。所以内层方法上那些属性可能根本没起作用。

**`REQUIRES_NEW` —— 两个真正独立的物理事务。** 外层被挂起，内层拿自己的资源（比如一条新的数据库连接）独立执行，独立提交或回滚。典型用途是「不管主流程成不成，这条操作日志都要留下」。

代价是实打实的：**它会额外占用一条连接**。官方明确警告，用不好会耗尽连接池、造成死锁，要求连接池大小至少比并发线程数多 1。在高并发路径上随手写 `REQUIRES_NEW`，是把连接池打爆的经典方式。

**`NESTED` —— 一个物理事务，多个保存点。** 内层可以回滚到自己的保存点，而不影响外层已经做的事。它有个硬性前提：**只对 JDBC 资源事务有效**，因为它映射到的就是 JDBC 的保存点机制，开箱即用的场景是配合 `DataSourceTransactionManager`。换成 JTA 之类的就未必支持了。

## 其余几个属性

| 属性 | 默认值 | 干什么 |
| --- | --- | --- |
| `readOnly` | `false` | 声明这是只读事务，便于底层优化 |
| `isolation` | `ISOLATION_DEFAULT` | 隔离级别，默认跟随数据库自身的设置 |
| `timeout` / `timeoutString` | 底层事务系统的默认值 | 超时秒数，超了自动回滚 |
| `rollbackFor` / `noRollbackFor` | 无 | 见上面「头号坑」 |
| `value` / `transactionManager` | `transactionManager` | 用哪个事务管理器（多数据源时才需要） |

`readOnly` 的写法：

```java
@Transactional(readOnly = true)
public List<Product> findAllProducts() {
    return productDao.findAllProducts();
}
```

它不只是个标记，底层的持久化实现可以据此跳过脏检查、走只读副本等优化。**查询方法一律加上它**，成本为零。

`isolation` 的默认值是「用数据库自己的」，多数情况下不该动它——改隔离级别是解决并发问题的重手段，先确认问题真的出在这里再说。

## 参考

- [Declarative Transaction Management](https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative.html)
- [Using @Transactional](https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/annotations.html)
- [Transaction Propagation](https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/tx-propagation.html)
- [Propagation 枚举 Javadoc](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/transaction/annotation/Propagation.html)
