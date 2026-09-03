---
tags: [类型/概念, 技术/JSON, 技术/Java]
aliases: []
created: 2026-09-03
updated: 2026-09-03
---
> JSON 是一段人能直接读的纯文本，用来在两个语言不通的程序之间传结构化数据。它长得像 JavaScript 对象，但语法严格得多：键必须用双引号、不能写注释、不能留尾逗号。

## 典型场景

前端用 [[AJAX]] 请求用户列表，后端手里是一个 `List<User>`。

JavaScript 不认识 Java 对象，Java 也不认识 JavaScript 对象，两边唯一共享的东西是 HTTP 响应体里那串字节。所以需要一种中立的格式，它得同时满足三件事：**是文本**（能塞进响应体、能打印出来调试）、**能表达嵌套结构**（用户下面还挂着地址和标签）、**两边都有现成的解析器**（不用自己写词法分析）。

JSON 就是这个格式。它本来是 JavaScript 的一个子集，因为够简单，最后变成了跨语言的通用选择。

## 它长什么样

```json
{
  "id": 1,
  "userName": "张三",
  "age": 18,
  "vip": true,
  "address": null,
  "tags": ["java", "web"],
  "profile": { "city": "杭州" }
}
```

RFC 8259 把可选项说得很死：**一个 JSON 值必须是对象、数组、数字或字符串，或者 `false`、`null`、`true` 这三个字面量之一。**

请注意这个清单里**没有的**东西：没有日期类型，没有整数和浮点数之分（数字就是数字），没有二进制。后面几节的麻烦基本都能追溯到这三个缺口。

对象里的名字（也就是键）本身也是字符串，规范说同一个对象里的名字**应当**唯一——只有名字全都唯一时，所有解析器才会对结果达成一致。重复的键会怎样，各家实现自己说了算，别去试。

## 三条铁律

JSON 看着像 JavaScript 的对象字面量，于是很多人顺手按写 JS 的习惯写它，然后被解析器打回来。三条最常见的：

**一、键和字符串必须用双引号。** 单引号不行，不加引号更不行。规范里字符串的定义就是「以引号开始、以引号结束」，只有双引号算引号。

**二、不能写注释。** RFC 8259 的语法里没有任何位置容纳注释。想给字段加说明，要么写在文档里，要么老老实实加一个 `"_comment"` 字段。

**三、不能有尾逗号。** 逗号只允许出现在成员与成员之间，最后一个成员后面多打一个，整份文档直接不合法。

```json
{
  "a": 1,
  "b": 2,      // 这行注释不合法
  "c": 3,      ← 这个逗号也不合法
}
```

写 JSON 配置文件让人烦躁的原因，主要就是第二条。

## JavaScript 侧：两个函数

浏览器内置了 `JSON` 这个全局对象，来回转换各一个方法：

```javascript
const obj  = JSON.parse('{"userName":"张三","age":18}');   // 文本 → 对象
const text = JSON.stringify({ userName: "张三", age: 18 }); // 对象 → 文本
```

实际用 Axios 时这两步基本不用自己写：发送时它会把对象自动序列化，接收时 `res.data` 拿到的已经是解析好的对象，细节见 [[AJAX]]。知道底下是这两个函数就行。

## Java 侧：用 Jackson 转换

Java 标准库里没有 JSON 支持，得引库。最常用的是 Jackson，Maven 坐标是 `com.fasterxml.jackson.core:jackson-databind`（怎么加依赖见 [[Maven]]）。

核心类是 `ObjectMapper`，两个方向各一个方法：

```java
ObjectMapper mapper = new ObjectMapper();

String json = mapper.writeValueAsString(user);       // Java 对象 → JSON 字符串
User user   = mapper.readValue(json, User.class);    // JSON 字符串 → Java 对象
```

集合要多绕一步：

```java
List<User> users = mapper.readValue(json, new TypeReference<List<User>>() {});
```

原因是**泛型在运行时被擦除**。如果直接传 `List.class`，Jackson 只知道你要一个 `List`，不知道里面的元素该转成什么类型，取出来的元素就不是 `User`，用的时候才在某个不相干的地方炸掉。`TypeReference` 这个匿名子类的作用就是把 `List<User>` 这个完整类型信息保存下来传进去。

### POJO 要满足什么

- **字段得让 Jackson 看得见**：要么是 public 字段，要么是私有字段配上 getter/setter
- **反序列化默认要一个无参构造方法**。只写了全参构造的类会抛 `ValueInstantiationException`，报错信息就是找不到可用的构造器
- **JSON 里多出来的字段默认会报错**。对方接口加了个新字段，你的 POJO 没跟上，反序列化就失败——需要宽容处理时关掉 `FAIL_ON_UNKNOWN_PROPERTIES` 这个特性

## 在 Servlet 里收发 JSON

**发**：把对象转成字符串写进响应体，同时声明格式和字符集。

```java
resp.setContentType("application/json;charset=utf-8");
resp.getWriter().write(mapper.writeValueAsString(users));
```

`setContentType` 决定了对方怎么解释这串文本（Axios 靠它决定要不要自动 `JSON.parse`），后半截 `charset` 决定中文会不会变成问号，原因见 [[Servlet]] 的响应乱码一节。

**收**：从请求体里把原文读出来再解析。

```java
String body = req.getReader().lines().collect(Collectors.joining());
User user = mapper.readValue(body, User.class);
```

**这里最容易卡住的是「为什么 `getParameter` 取不到值」。** [[Servlet]] 里讲过规范的规定：只有 `Content-Type` 是 `application/x-www-form-urlencoded` 的 POST 请求体，才会被容器解析进参数集合。Axios 发对象时用的是 `application/json`，容器不管这种格式，`getParameter` 自然返回 `null`，你只能自己从流里读。

顺带记住配套的那条：请求体是**只能消费一次的流**，`getParameter` 和 `getReader` 二选一，先读的那个拿到数据。

## 三个坑

**一、大整数传到前端会丢精度。** JavaScript 的数字是双精度浮点数，能精确表示的整数上限是 2^53 − 1（9007199254740991）。Java 那边的 `Long` 一旦超过这个范围（雪花算法生成的 id 就常常超），前端拿到的值会**悄悄变成一个相近但不相等的数**——不报错，只是查不到数据。稳妥的做法是把这类 id 序列化成字符串。

**二、日期没有标准表示。** JSON 的值类型里没有日期，所以怎么表示全靠约定：时间戳数字、`"2026-09-03"`、带时区的 ISO 字符串都有人用。`java.time` 里的类型（`LocalDateTime` 这些）还需要给 `ObjectMapper` 注册 `JavaTimeModule` 才能正常转换。**接口定型之前先打印一次实际输出**，别照着想象写前端的解析代码。

**三、把 JSON 当日志或字符串拼出来。** 手动拼 `"{\"name\":\"" + name + "\"}"` 这种写法，遇到名字里带引号或换行就生成非法 JSON，而且往往在生产环境才暴露。转换交给库，字符转义是它的职责。

## 参考

- [RFC 8259: The JavaScript Object Notation (JSON) Data Interchange Format](https://www.rfc-editor.org/rfc/rfc8259) — 值类型、字符串与对象名字的规定
- [Jackson databind](https://github.com/FasterXML/jackson-databind) — `ObjectMapper` 的读写方法与配置项
- [MDN: JSON](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/JSON) — `parse` 与 `stringify`
